#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
CF_ASSUME_NONNULL_BEGIN
CMSampleBufferRef _Nullable VCFCopySampleFromPixels(CMSampleBufferRef original,
                                                     CVPixelBufferRef pixels,
                                                     OSStatus * _Nullable status) CF_RETURNS_RETAINED;
CF_ASSUME_NONNULL_END
