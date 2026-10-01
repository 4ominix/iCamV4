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

@property (nonatomic, assign) float brightness;
@property (nonatomic, assign) float contrast;
@property (nonatomic, assign) float saturation;

@property (nonatomic, assign) float offsetX;
@property (nonatomic, assign) float offsetY;
@property (nonatomic, assign) float zoom;

+ (instancetype)shared;

- (void)loadImageSource:(NSString *)path;
- (void)loadVideoSource:(NSString *)path;
- (void)loadStreamSource:(NSString *)streamDir;
- (void)unloadSource;

- (CVPixelBufferRef)renderFrameMatchingFormat:(CMFormatDescriptionRef)fmt
                                    timestamp:(CMTime)pts;

@end
