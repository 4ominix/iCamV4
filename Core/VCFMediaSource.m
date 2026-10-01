#import "VCFMediaSource.h"
#import "VCFPaths.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

@implementation VCFMediaSource {
    NSURL *_url;
    CIImage *_image;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    CMSampleBufferRef _pending;
    double _start, _firstPTS, _end, _frameDuration;
    CGAffineTransform _orientation;
    BOOL _eof;
}

- (instancetype)initWithPath:(NSString *)path kind:(NSString *)kind error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _url = [NSURL fileURLWithPath:path];
    _video = [kind isEqualToString:@"video"];

    if (_video) {
        if (![self resetReader:0]) {
            if (error) *error = _error;
            return nil;
        }
    } else {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)_url, NULL);
        NSDictionary *info = source ?
            CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
        if (source) CFRelease(source);

        double width = [info[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        double height = [info[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || width * height > 32000000) {
            if (error) *error = VCFError(@"Image too large or unreadable (max 32 megapixels).");
            return nil;
        }
        _image = [CIImage imageWithContentsOfURL:_url
                   options:@{kCIImageApplyOrientationProperty: @YES}];
        if (!_image) {
            if (error) *error = VCFError(@"Cannot decode image.");
            return nil;
        }
    }
    return self;
}

- (BOOL)resetReader:(double)time {
    if (_pending) { CFRelease(_pending); _pending = NULL; }
    [_reader cancelReading];
    _reader = nil; _output = nil; _error = nil; _eof = NO;
    _firstPTS = NAN; _end = 0; _start = time;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_url options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) {
        _error = VCFError(@"Video has no video track.");
        return NO;
    }

    CGSize size = track.naturalSize;
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width <= 0 || size.height <= 0 ||
        size.width > 4096 || size.height > 4096 ||
        size.width * size.height > 8300000) {
        _error = VCFError(@"Video too large (max 4096 per dimension, 8.3 megapixels).");
        return NO;
    }

    _orientation = track.preferredTransform;
    double fps = track.nominalFrameRate;
    _frameDuration = isfinite(fps) && fps > 0 ? 1 / fps : 1 / 30.0;

    NSError *error = nil;
    _reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    _output.alwaysCopiesSampleData = NO;

    if (!_reader || ![_reader canAddOutput:_output]) {
        _error = error ?: VCFError(@"Cannot create video reader.");
        return NO;
    }
    [_reader addOutput:_output];
    if (![_reader startReading]) {
        _error = _reader.error ?: VCFError(@"Cannot start video decoding.");
        return NO;
    }
    return YES;
}

- (CIImage *)imageAtTime:(double)time loop:(BOOL)loop {
    if (!_video) return _image;
    if (!_start) _start = time;
    double elapsed = fmax(0, time - _start);

    if (_eof && elapsed >= _end) {
        if (!loop) return _image;
        if (![self resetReader:time]) return nil;
        _image = nil;
        elapsed = 0;
    }

    for (int count = 0; count < 8; count++) {
        if (!_pending) _pending = [_output copyNextSampleBuffer];
        if (!_pending) {
            if (_reader.status == AVAssetReaderStatusFailed) {
                _error = _reader.error ?: VCFError(@"Video decode failed.");
                return nil;
            }
            if (!_image) {
                _error = VCFError(@"Video has no decodable frames.");
                return nil;
            }
            _eof = YES;
            break;
        }

        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(_pending));
        if (!isfinite(pts)) {
            _error = VCFError(@"Video has invalid timestamps.");
            return nil;
        }
        if (!isfinite(_firstPTS)) _firstPTS = pts;
        double relative = fmax(0, pts - _firstPTS);
        if (relative > elapsed && _image) break;

        CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(_pending);
        if (!pixels) {
            _error = VCFError(@"Video frame has no pixel buffer.");
            return nil;
        }
        _image = [[CIImage imageWithCVPixelBuffer:pixels]
                  imageByApplyingTransform:_orientation];
        double duration = CMTimeGetSeconds(CMSampleBufferGetDuration(_pending));
        if (!isfinite(duration) || duration <= 0) duration = _frameDuration;
        _end = relative + duration;
        CFRelease(_pending);
        _pending = NULL;
    }
    return _image;
}

- (void)dealloc {
    if (_pending) CFRelease(_pending);
    [_reader cancelReading];
}
@end
