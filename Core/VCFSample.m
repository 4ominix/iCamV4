#import "VCFSample.h"

static void CopySampleAttachment(const void *key, const void *value, void *context) {
    CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
}

CMSampleBufferRef VCFCopySampleFromPixels(CMSampleBufferRef original, CVPixelBufferRef pixels,
                                          OSStatus *status) {
    if (status) *status = -50;
    if (!original || !pixels || !CMSampleBufferIsValid(original) ||
        !CMSampleBufferGetImageBuffer(original)) return NULL;

    CVPixelBufferRef real = CMSampleBufferGetImageBuffer(original);
    if (CVPixelBufferGetWidth(real) != CVPixelBufferGetWidth(pixels) ||
        CVPixelBufferGetHeight(real) != CVPixelBufferGetHeight(pixels) ||
        CVPixelBufferGetPixelFormatType(real) != CVPixelBufferGetPixelFormatType(pixels))
        return NULL;

    CMSampleTimingInfo timing;
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef result = NULL;
    CFDictionaryRef attachments = NULL;

    OSStatus code = CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    if (code != noErr) { if (status) *status = code; return NULL; }

    @try {
        code = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &format);
        if (code != noErr || !format) {
            if (status) *status = code != noErr ? code : -50;
            return NULL;
        }
        code = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, true,
                                                  NULL, NULL, format, &timing, &result);
        if (code != noErr || !result) {
            if (status) *status = code != noErr ? code : -50;
            return NULL;
        }

        for (int mode = kCMAttachmentMode_ShouldNotPropagate;
             mode <= kCMAttachmentMode_ShouldPropagate; mode++) {
            attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, original,
                                                       (CMAttachmentMode)mode);
            if (attachments) {
                CMSetAttachments(result, attachments, (CMAttachmentMode)mode);
                CFRelease(attachments);
                attachments = NULL;
            }
        }

        CFArrayRef source = CMSampleBufferGetSampleAttachmentsArray(original, false);
        CFArrayRef destination = CMSampleBufferGetSampleAttachmentsArray(result, true);
        if (source && destination &&
            CFArrayGetCount(source) == 1 && CFArrayGetCount(destination) == 1)
            CFDictionaryApplyFunction(
                (CFDictionaryRef)CFArrayGetValueAtIndex(source, 0),
                CopySampleAttachment,
                (void *)CFArrayGetValueAtIndex(destination, 0));

        if (status) *status = noErr;
        CMSampleBufferRef owned = result;
        result = NULL;
        return owned;
    } @finally {
        if (attachments) CFRelease(attachments);
        if (format) CFRelease(format);
        if (result) CFRelease(result);
    }
}
