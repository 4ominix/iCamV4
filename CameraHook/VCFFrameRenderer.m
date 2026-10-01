#import "VCFFrameRenderer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

static NSString *const kSharedDir = @"/var/jb/var/mobile/Library/VCamFree";
static NSString *const kStreamDir = @"/var/jb/var/mobile/Library/VCamFree/Streams";

@implementation VCFFrameRenderer {
    dispatch_queue_t _renderQueue;
    VTPixelTransferSessionRef _transferSession;

    // image source
    CVPixelBufferRef _staticBuffer;

    // video source
    AVAssetReader *_assetReader;
    AVAssetReaderTrackOutput *_trackOutput;
    Float64 _videoFPS;
    uint64_t _videoFrameIndex;
    NSString *_videoPath;

    // stream source (FLV from RTMP daemon)
    NSString *_streamDirectory;
    dispatch_source_t _streamPollTimer;
    VTDecompressionSessionRef _decompSession;
    CMVideoFormatDescriptionRef _decompFmt;
    CVPixelBufferRef _decompOutBuffer;

    CVPixelBufferRef _latestRendered;
}

+ (instancetype)shared {
    static VCFFrameRenderer *inst;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderQueue = dispatch_queue_create("com.vcamfree.render", DISPATCH_QUEUE_SERIAL);
        _sourceType = VCFSourceTypeNone;
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transferSession);
    }
    return self;
}

#pragma mark - Image Source

- (void)loadImageSource:(NSString *)path {
    dispatch_sync(_renderQueue, ^{
        [self _teardown];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return;

        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!src) return;
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!img) return;

        size_t w = CGImageGetWidth(img);
        size_t h = CGImageGetHeight(img);

        NSDictionary *attrs = @{
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferRef pb = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb);
        if (!pb) { CGImageRelease(img); return; }

        CVPixelBufferLockBaseAddress(pb, 0);
        void *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                            kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CGImageRelease(img);

        _staticBuffer = pb;
        _sourceType = VCFSourceTypeImage;
        _ready = YES;
    });
}

#pragma mark - Video Source

- (void)loadVideoSource:(NSString *)path {
    dispatch_sync(_renderQueue, ^{
        [self _teardown];
        _videoPath = [path copy];
        _videoFrameIndex = 0;
        [self _resetVideoReader];
        _sourceType = VCFSourceTypeVideo;
        _ready = (_assetReader != nil);
    });
}

- (void)_resetVideoReader {
    _assetReader = nil;
    _trackOutput = nil;

    NSURL *url = [NSURL fileURLWithPath:_videoPath];
    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return;

    AVAssetTrack *vt = tracks[0];
    _videoFPS = vt.nominalFrameRate > 0 ? vt.nominalFrameRate : 30.0;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    _trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt
                                                             outputSettings:settings];
    _trackOutput.alwaysCopiesSampleData = NO;

    NSError *err = nil;
    _assetReader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!_assetReader) return;
    [_assetReader addOutput:_trackOutput];
    [_assetReader startReading];
}

- (CVPixelBufferRef)_nextVideoFrame {
    if (!_assetReader || _assetReader.status != AVAssetReaderStatusReading) {
        [self _resetVideoReader]; // loop
        if (!_assetReader) return NULL;
    }
    CMSampleBufferRef sb = [_trackOutput copyNextSampleBuffer];
    if (!sb) {
        [self _resetVideoReader];
        sb = [_trackOutput copyNextSampleBuffer];
        if (!sb) return NULL;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb) CVPixelBufferRetain(pb);
    CFRelease(sb);
    return pb;
}

#pragma mark - Stream Source (FLV from RTMP)

- (void)loadStreamSource:(NSString *)streamDir {
    dispatch_sync(_renderQueue, ^{
        [self _teardown];
        _streamDirectory = [streamDir copy] ?: kStreamDir;
        _sourceType = VCFSourceTypeStream;

        _streamPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _renderQueue);
        dispatch_source_set_timer(_streamPollTimer, DISPATCH_TIME_NOW,
                                  (uint64_t)(1.0/30.0 * NSEC_PER_SEC), NSEC_PER_MSEC);
        __weak typeof(self) ws = self;
        dispatch_source_set_event_handler(_streamPollTimer, ^{
            [ws _pollStreamFrame];
        });
        dispatch_resume(_streamPollTimer);
        _ready = YES;
    });
}

- (void)_pollStreamFrame {
    NSString *livePath = [_streamDirectory stringByAppendingPathComponent:@"live.vcf"];
    NSString *latestPath = [_streamDirectory stringByAppendingPathComponent:@"latest.flv"];

    NSString *path = [[NSFileManager defaultManager] fileExistsAtPath:livePath] ? livePath : latestPath;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;

    NSData *nalData = [self _extractLatestNALFromFLV:path];
    if (!nalData) return;

    [self _decodeH264NAL:nalData];
}

- (NSData *)_extractLatestNALFromFLV:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    [fh seekToEndOfFile];
    unsigned long long fileSize = fh.offsetInFile;
    if (fileSize < 13) { [fh closeFile]; return nil; }

    // read last 4 bytes = previous tag size, then read that tag
    [fh seekToFileOffset:fileSize - 4];
    NSData *prevSizeData = [fh readDataOfLength:4];
    if (prevSizeData.length < 4) { [fh closeFile]; return nil; }

    const uint8_t *ps = prevSizeData.bytes;
    uint32_t prevTagSize = ((uint32_t)ps[0] << 24) | ((uint32_t)ps[1] << 16) |
                           ((uint32_t)ps[2] << 8) | ps[3];
    if (prevTagSize == 0 || prevTagSize + 4 > fileSize) { [fh closeFile]; return nil; }

    unsigned long long tagOffset = fileSize - 4 - prevTagSize;
    [fh seekToFileOffset:tagOffset];
    NSData *tagData = [fh readDataOfLength:prevTagSize];
    [fh closeFile];

    if (tagData.length < 12) return nil;
    const uint8_t *tag = tagData.bytes;

    // FLV tag: type(1) + dataSize(3) + timestamp(3) + timestampExt(1) + streamId(3) + data
    uint8_t tagType = tag[0];
    if (tagType != 0x09) return nil; // not video

    uint32_t dataSize = ((uint32_t)tag[1] << 16) | ((uint32_t)tag[2] << 8) | tag[3];
    if (11 + dataSize > tagData.length) return nil;

    const uint8_t *videoData = tag + 11;
    // AVC: frameType(4bits) + codecId(4bits) + AVCPacketType(1) + compositionTime(3)
    if (dataSize < 5) return nil;
    uint8_t codecId = videoData[0] & 0x0F;
    if (codecId != 7) return nil; // not AVC/H.264
    uint8_t pktType = videoData[1];
    if (pktType == 0) {
        // SPS/PPS sequence header — store for decoder init
        return [NSData dataWithBytes:videoData length:dataSize];
    }
    if (pktType != 1) return nil; // not NALU
    return [NSData dataWithBytes:videoData + 5 length:dataSize - 5];
}

- (void)_decodeH264NAL:(NSData *)nalData {
    const uint8_t *bytes = nalData.bytes;
    NSUInteger len = nalData.length;
    if (len < 5) return;

    // check if this is SPS/PPS (sequence header)
    uint8_t pktType = bytes[1];
    if (pktType == 0 && len > 10) {
        [self _initDecoderWithAVCConfig:nalData];
        return;
    }

    if (!_decompSession || !_decompFmt) return;

    // AVCC format: length-prefixed NALUs
    CMBlockBufferRef blockBuf = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
        (void *)(bytes), len, kCFAllocatorNull, NULL, 0, len, 0, &blockBuf);
    if (!blockBuf) return;

    CMSampleBufferRef sampleBuf = NULL;
    const size_t sampleSizes[] = { len };
    CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuf, _decompFmt,
                              1, 0, NULL, 1, sampleSizes, &sampleBuf);
    CFRelease(blockBuf);
    if (!sampleBuf) return;

    VTDecodeInfoFlags infoFlags = 0;
    VTDecompressionSessionDecodeFrame(_decompSession, sampleBuf,
        kVTDecodeFrame_EnableAsynchronousDecompression, NULL, &infoFlags);
    VTDecompressionSessionWaitForAsynchronousFrames(_decompSession);

    CFRelease(sampleBuf);
}

- (void)_initDecoderWithAVCConfig:(NSData *)configData {
    if (_decompSession) {
        VTDecompressionSessionInvalidate(_decompSession);
        CFRelease(_decompSession);
        _decompSession = NULL;
    }
    if (_decompFmt) { CFRelease(_decompFmt); _decompFmt = NULL; }

    const uint8_t *p = configData.bytes;
    NSUInteger total = configData.length;
    // skip FLV AVC header: frameType+codecId(1) + pktType(1) + compositionTime(3)
    if (total < 16) return;
    p += 5; total -= 5;

    // AVCDecoderConfigurationRecord
    if (total < 7) return;
    uint8_t numSPS = p[5] & 0x1F;
    const uint8_t *cursor = p + 6;
    const uint8_t *end = p + total;

    NSMutableArray *paramSets = [NSMutableArray array];
    NSMutableArray *paramSizes = [NSMutableArray array];

    for (int i = 0; i < numSPS && cursor + 2 <= end; i++) {
        uint16_t spsLen = ((uint16_t)cursor[0] << 8) | cursor[1];
        cursor += 2;
        if (cursor + spsLen > end) return;
        [paramSets addObject:[NSData dataWithBytes:cursor length:spsLen]];
        [paramSizes addObject:@(spsLen)];
        cursor += spsLen;
    }

    if (cursor + 1 > end) return;
    uint8_t numPPS = cursor[0];
    cursor++;

    for (int i = 0; i < numPPS && cursor + 2 <= end; i++) {
        uint16_t ppsLen = ((uint16_t)cursor[0] << 8) | cursor[1];
        cursor += 2;
        if (cursor + ppsLen > end) return;
        [paramSets addObject:[NSData dataWithBytes:cursor length:ppsLen]];
        [paramSizes addObject:@(ppsLen)];
        cursor += ppsLen;
    }

    if (paramSets.count < 2) return;

    const uint8_t *paramPtrs[paramSets.count];
    size_t paramLens[paramSets.count];
    for (NSUInteger i = 0; i < paramSets.count; i++) {
        NSData *d = paramSets[i];
        paramPtrs[i] = d.bytes;
        paramLens[i] = d.length;
    }

    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, paramSets.count, paramPtrs, paramLens, 4, &_decompFmt);
    if (st != noErr) return;

    NSDictionary *destAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionOutputCallbackRecord callback;
    callback.decompressionOutputCallback = vcf_decomp_callback;
    callback.decompressionOutputRefCon = (__bridge void *)self;

    VTDecompressionSessionCreate(kCFAllocatorDefault, _decompFmt, NULL,
        (__bridge CFDictionaryRef)destAttrs, &callback, &_decompSession);
}

static void vcf_decomp_callback(void *refCon, void *srcRefCon, OSStatus status,
    VTDecodeInfoFlags flags, CVImageBufferRef imageBuffer, CMTime pts, CMTime duration) {
    if (status != noErr || !imageBuffer) return;
    VCFFrameRenderer *self = (__bridge VCFFrameRenderer *)refCon;
    CVPixelBufferRef old = self->_decompOutBuffer;
    CVPixelBufferRetain(imageBuffer);
    self->_decompOutBuffer = imageBuffer;
    if (old) CVPixelBufferRelease(old);
}

#pragma mark - Unload

- (void)unloadSource {
    dispatch_sync(_renderQueue, ^{
        [self _teardown];
    });
}

- (void)_teardown {
    _ready = NO;
    _sourceType = VCFSourceTypeNone;

    if (_staticBuffer) { CVPixelBufferRelease(_staticBuffer); _staticBuffer = NULL; }

    _assetReader = nil;
    _trackOutput = nil;
    _videoPath = nil;

    if (_streamPollTimer) { dispatch_source_cancel(_streamPollTimer); _streamPollTimer = nil; }
    if (_decompSession) {
        VTDecompressionSessionInvalidate(_decompSession);
        CFRelease(_decompSession);
        _decompSession = NULL;
    }
    if (_decompFmt) { CFRelease(_decompFmt); _decompFmt = NULL; }
    if (_decompOutBuffer) { CVPixelBufferRelease(_decompOutBuffer); _decompOutBuffer = NULL; }
    if (_latestRendered) { CVPixelBufferRelease(_latestRendered); _latestRendered = NULL; }
}

#pragma mark - Render

- (CVPixelBufferRef)renderFrameMatchingFormat:(CMFormatDescriptionRef)fmt
                                    timestamp:(CMTime)pts {
    __block CVPixelBufferRef result = NULL;

    dispatch_sync(_renderQueue, ^{
        CVPixelBufferRef srcPB = NULL;

        switch (_sourceType) {
            case VCFSourceTypeImage:
                srcPB = _staticBuffer;
                if (srcPB) CVPixelBufferRetain(srcPB);
                break;

            case VCFSourceTypeVideo:
                srcPB = [self _nextVideoFrame];
                break;

            case VCFSourceTypeStream:
                srcPB = _decompOutBuffer;
                if (srcPB) CVPixelBufferRetain(srcPB);
                break;

            default:
                break;
        }

        if (!srcPB) return;

        CMVideoDimensions targetDim = CMVideoFormatDescriptionGetDimensions(fmt);
        OSType targetFmt = CMFormatDescriptionGetMediaSubType(fmt);

        size_t srcW = CVPixelBufferGetWidth(srcPB);
        size_t srcH = CVPixelBufferGetHeight(srcPB);
        OSType srcFmt = CVPixelBufferGetPixelFormatType(srcPB);

        if ((int)srcW == targetDim.width && (int)srcH == targetDim.height && srcFmt == targetFmt) {
            result = srcPB; // direct use, already retained
            return;
        }

        // need pixel transfer (scale + format convert)
        NSDictionary *attrs = @{
            (id)kCVPixelBufferWidthKey: @(targetDim.width),
            (id)kCVPixelBufferHeightKey: @(targetDim.height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(targetFmt),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferRef dstPB = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, targetDim.width, targetDim.height,
                            targetFmt, (__bridge CFDictionaryRef)attrs, &dstPB);
        if (!dstPB) { CVPixelBufferRelease(srcPB); return; }

        if (_transferSession) {
            VTPixelTransferSessionTransferImage(_transferSession, srcPB, dstPB);
        }
        CVPixelBufferRelease(srcPB);
        result = dstPB;
    });

    if (_latestRendered) CVPixelBufferRelease(_latestRendered);
    _latestRendered = result;
    if (result) CVPixelBufferRetain(result);

    return result;
}

- (CVPixelBufferRef)latestPixelBuffer {
    return _latestRendered;
}

- (void)dealloc {
    [self _teardown];
    if (_transferSession) { VTPixelTransferSessionInvalidate(_transferSession); CFRelease(_transferSession); }
}

@end
