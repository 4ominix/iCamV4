#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>
#import "../Core/VCFFrameEngine.h"
#import "../Core/VCFSample.h"

static os_log_t vcf_log;
static unsigned gHookCount = 0;

// renderSampleBuffer:forInput: — (CMSampleBufferRef, NSInteger)
typedef void (*RenderIMP)(id, SEL, CMSampleBufferRef, NSInteger);
static RenderIMP orig_BWImageQueueSinkNode_render;
static RenderIMP orig_BWPreviewSinkNode_render;
static RenderIMP orig_BWRemoteQueueSinkNode_render;
static RenderIMP orig_BWStillImageSampleBufferSinkNode_render;
static RenderIMP orig_BWPhotoEncoderNode_render;

// emitSampleBuffer: — (CMSampleBufferRef)
typedef void (*EmitIMP)(id, SEL, CMSampleBufferRef);
static EmitIMP orig_BWNodeOutput_emit;

static CMSampleBufferRef VCFReplace(CMSampleBufferRef original) {
    if (!original || !CMSampleBufferIsValid(original)) return NULL;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(original);
    if (!imageBuffer) return NULL;

    size_t width  = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    OSType format = CVPixelBufferGetPixelFormatType(imageBuffer);

    CVPixelBufferRef frame = [[VCFFrameEngine sharedEngine]
                              copyFrameForWidth:width height:height format:format];
    if (!frame) return NULL;

    OSStatus status = noErr;
    CMSampleBufferRef replaced = VCFCopySampleFromPixels(original, frame, &status);
    CVPixelBufferRelease(frame);

    if (replaced) [[VCFFrameEngine sharedEngine] recordReplacement];
    return replaced;
}

// BWImageQueueSinkNode
static void hook_BWImageQueueSinkNode_render(id self, SEL _cmd,
                                              CMSampleBufferRef buf, NSInteger input) {
    CMSampleBufferRef r = VCFReplace(buf);
    if (r) { orig_BWImageQueueSinkNode_render(self, _cmd, r, input); CFRelease(r); }
    else   { orig_BWImageQueueSinkNode_render(self, _cmd, buf, input); }
}

// BWPreviewSinkNode
static void hook_BWPreviewSinkNode_render(id self, SEL _cmd,
                                           CMSampleBufferRef buf, NSInteger input) {
    CMSampleBufferRef r = VCFReplace(buf);
    if (r) { orig_BWPreviewSinkNode_render(self, _cmd, r, input); CFRelease(r); }
    else   { orig_BWPreviewSinkNode_render(self, _cmd, buf, input); }
}

// BWRemoteQueueSinkNode
static void hook_BWRemoteQueueSinkNode_render(id self, SEL _cmd,
                                               CMSampleBufferRef buf, NSInteger input) {
    CMSampleBufferRef r = VCFReplace(buf);
    if (r) { orig_BWRemoteQueueSinkNode_render(self, _cmd, r, input); CFRelease(r); }
    else   { orig_BWRemoteQueueSinkNode_render(self, _cmd, buf, input); }
}

// BWStillImageSampleBufferSinkNode
static void hook_BWStillImageSampleBufferSinkNode_render(id self, SEL _cmd,
                                                          CMSampleBufferRef buf, NSInteger input) {
    CMSampleBufferRef r = VCFReplace(buf);
    if (r) { orig_BWStillImageSampleBufferSinkNode_render(self, _cmd, r, input); CFRelease(r); }
    else   { orig_BWStillImageSampleBufferSinkNode_render(self, _cmd, buf, input); }
}

// BWPhotoEncoderNode
static void hook_BWPhotoEncoderNode_render(id self, SEL _cmd,
                                            CMSampleBufferRef buf, NSInteger input) {
    CMSampleBufferRef r = VCFReplace(buf);
    if (r) { orig_BWPhotoEncoderNode_render(self, _cmd, r, input); CFRelease(r); }
    else   { orig_BWPhotoEncoderNode_render(self, _cmd, buf, input); }
}

// BWNodeOutput
static void hook_BWNodeOutput_emit(id self, SEL _cmd, CMSampleBufferRef buf) {
    CMSampleBufferRef r = VCFReplace(buf);
    if (r) { orig_BWNodeOutput_emit(self, _cmd, r); CFRelease(r); }
    else   { orig_BWNodeOutput_emit(self, _cmd, buf); }
}

static BOOL VCFInstallRenderHook(const char *className, RenderIMP *origStore, IMP replacement) {
    Class cls = objc_getClass(className);
    if (!cls) {
        os_log(vcf_log, "class not found: %{public}s", className);
        return NO;
    }
    SEL sel = @selector(renderSampleBuffer:forInput:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        os_log(vcf_log, "method not found: -[%{public}s renderSampleBuffer:forInput:]", className);
        return NO;
    }
    MSHookMessageEx(cls, sel, replacement, (IMP *)origStore);
    gHookCount++;
    os_log(vcf_log, "hooked -[%{public}s renderSampleBuffer:forInput:]", className);
    return YES;
}

%ctor {
    @autoreleasepool {
        vcf_log = os_log_create("com.vcamfree.camera", "hook");
        NSString *proc = NSProcessInfo.processInfo.processName;
        os_log(vcf_log, "VCFCameraHook loading in %{public}s (pid %d)", proc.UTF8String, getpid());

        VCFInstallRenderHook("BWImageQueueSinkNode",
                             &orig_BWImageQueueSinkNode_render,
                             (IMP)hook_BWImageQueueSinkNode_render);

        VCFInstallRenderHook("BWPreviewSinkNode",
                             &orig_BWPreviewSinkNode_render,
                             (IMP)hook_BWPreviewSinkNode_render);

        VCFInstallRenderHook("BWRemoteQueueSinkNode",
                             &orig_BWRemoteQueueSinkNode_render,
                             (IMP)hook_BWRemoteQueueSinkNode_render);

        VCFInstallRenderHook("BWStillImageSampleBufferSinkNode",
                             &orig_BWStillImageSampleBufferSinkNode_render,
                             (IMP)hook_BWStillImageSampleBufferSinkNode_render);

        VCFInstallRenderHook("BWPhotoEncoderNode",
                             &orig_BWPhotoEncoderNode_render,
                             (IMP)hook_BWPhotoEncoderNode_render);

        Class nodeOutput = objc_getClass("BWNodeOutput");
        if (nodeOutput) {
            SEL emitSel = @selector(emitSampleBuffer:);
            Method m = class_getInstanceMethod(nodeOutput, emitSel);
            if (m) {
                MSHookMessageEx(nodeOutput, emitSel,
                                (IMP)hook_BWNodeOutput_emit, (IMP *)&orig_BWNodeOutput_emit);
                gHookCount++;
                os_log(vcf_log, "hooked -[BWNodeOutput emitSampleBuffer:]");
            } else {
                os_log(vcf_log, "method not found: -[BWNodeOutput emitSampleBuffer:]");
            }
        } else {
            os_log(vcf_log, "class not found: BWNodeOutput");
        }

        [[VCFFrameEngine sharedEngine] setInstalledHooks:gHookCount];
        os_log(vcf_log, "VCFCameraHook ready: %u hooks in %{public}s", gHookCount, proc.UTF8String);
    }
}
