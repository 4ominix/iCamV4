#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface VCFFrameEngine : NSObject
+ (instancetype)sharedEngine;
- (instancetype)initForPreview:(BOOL)preview;
- (CVPixelBufferRef)copyFrameForWidth:(size_t)width height:(size_t)height
                               format:(OSType)format CF_RETURNS_RETAINED;
- (void)setSuspended:(BOOL)suspended;
- (void)setInstalledHooks:(unsigned)count;
- (void)recordReplacement;
@end
