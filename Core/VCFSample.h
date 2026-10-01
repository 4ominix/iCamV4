#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
CMSampleBufferRef VCFCopySampleFromPixels(CMSampleBufferRef original, CVPixelBufferRef pixels,
                                          OSStatus *status) CF_RETURNS_RETAINED;
