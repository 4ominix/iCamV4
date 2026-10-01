#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

typedef NS_ENUM(NSInteger, VCFSourceType) {
    VCFSourceTypeNone = 0,
    VCFSourceTypeImage,
    VCFSourceTypeVideo,
    VCFSourceTypeStream
};

@interface VCFFrameRenderer : NSObject

@property (nonatomic, readonly) VCFSourceType sourceType;
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly) CVPixelBufferRef latestPixelBuffer;

+ (instancetype)shared;

- (void)loadImageSource:(NSString *)path;
- (void)loadVideoSource:(NSString *)path;
- (void)loadStreamSource:(NSString *)streamDir;
- (void)unloadSource;

- (CVPixelBufferRef)renderFrameMatchingFormat:(CMFormatDescriptionRef)fmt
                                    timestamp:(CMTime)pts;

@end
