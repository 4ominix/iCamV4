#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>
#import "VCFFrameRenderer.h"

static NSString *const kVCFMediaDir         = @"/var/jb/var/mobile/Library/VCamFree/Media";
static NSString *const kVCFStreamDir        = @"/var/jb/var/mobile/Library/VCamFree/Streams";
static NSString *const kVCFCameraConfigPath = @"/var/jb/var/mobile/Library/VCamFree/CameraConfig.plist";
static NSString *const kVCFCameraStatusPath = @"/var/jb/var/mobile/Library/VCamFree/CameraStatus.plist";

static NSString *const kNotifConfigChanged  = @"com.vcamfree.camera.config.changed";
static NSString *const kNotifStatusChanged  = @"com.vcamfree.camera.status.changed";

static os_log_t vcf_log;

static BOOL           gInjectionEnabled   = NO;
static VCFSourceType  gCurrentSource      = VCFSourceTypeNone;
static int            gHookedMethodCount  = 0;

static NSMutableDictionary<NSString *, NSValue *> *gOriginalIMPs;

// ── config ──────────────────────────────────────

static NSDictionary *VCFReadConfig(void) {
    NSData *data = [NSData dataWithContentsOfFile:kVCFCameraConfigPath];
    if (!data) return nil;
    return [NSPropertyListSerialization propertyListWithData:data
                options:NSPropertyListImmutable format:NULL error:NULL];
}

static void VCFWriteStatus(NSDictionary *status) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:status
                    format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    [data writeToFile:kVCFCameraStatusPath atomically:YES];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifStatusChanged, NULL, NULL, true);
}

static void VCFApplyConfig(void) {
    NSDictionary *cfg = VCFReadConfig();
    if (!cfg) {
        gInjectionEnabled = NO;
        gCurrentSource = VCFSourceTypeNone;
        [[VCFFrameRenderer shared] unloadSource];
        VCFWriteStatus(@{@"active": @NO, @"reason": @"no_config"});
        return;
    }

    gInjectionEnabled = [cfg[@"enabled"] boolValue];
    NSString *sourceType = cfg[@"source_type"] ?: @"none";
    NSString *mediaPath  = cfg[@"media_path"] ?: @"";

    VCFFrameRenderer *renderer = [VCFFrameRenderer shared];
    renderer.brightness = [cfg[@"color_brightness"] floatValue];
    renderer.contrast   = [cfg[@"color_contrast"] floatValue] ?: 1.0f;
    renderer.saturation = [cfg[@"color_saturation"] floatValue] ?: 1.0f;
    renderer.offsetX    = [cfg[@"offset_x"] floatValue];
    renderer.offsetY    = [cfg[@"offset_y"] floatValue];
    renderer.zoom       = [cfg[@"scale"] floatValue] ?: 1.0f;

    if (!gInjectionEnabled) {
        [renderer unloadSource];
        gCurrentSource = VCFSourceTypeNone;
        VCFWriteStatus(@{@"active": @NO, @"reason": @"disabled"});
        return;
    }

    if ([sourceType isEqualToString:@"image"]) {
        NSString *fullPath = [kVCFMediaDir stringByAppendingPathComponent:mediaPath];
        [renderer loadImageSource:fullPath];
        gCurrentSource = VCFSourceTypeImage;
    } else if ([sourceType isEqualToString:@"video"]) {
        NSString *fullPath = [kVCFMediaDir stringByAppendingPathComponent:mediaPath];
        [renderer loadVideoSource:fullPath];
        gCurrentSource = VCFSourceTypeVideo;
    } else if ([sourceType isEqualToString:@"stream"]) {
        [renderer loadStreamSource:kVCFStreamDir];
        gCurrentSource = VCFSourceTypeStream;
    } else {
        [renderer unloadSource];
        gCurrentSource = VCFSourceTypeNone;
    }

    VCFWriteStatus(@{
        @"active": @(renderer.ready),
        @"source": sourceType,
        @"hooked_methods": @(gHookedMethodCount),
        @"process": [NSProcessInfo processInfo].processName ?: @"unknown"
    });
    os_log(vcf_log, "config applied: enabled=%d source=%{public}s ready=%d hooks=%d",
           gInjectionEnabled, sourceType.UTF8String, renderer.ready, gHookedMethodCount);
}

// ── CMSampleBuffer replacement ──────────────────

static void vcf_copy_dict_entry(const void *key, const void *val, void *ctx) {
    CFDictionarySetValue((CFMutableDictionaryRef)ctx, key, val);
}

static CMSampleBufferRef VCFCreateReplacementBuffer(CMSampleBufferRef original) {
    if (!gInjectionEnabled) return NULL;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(original);
    if (!fmt) return NULL;
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(fmt);
    if (mediaType != kCMMediaType_Video) return NULL;

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(original);
    CVPixelBufferRef rendered = [[VCFFrameRenderer shared] renderFrameMatchingFormat:fmt
                                                                          timestamp:pts];
    if (!rendered) return NULL;

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = pts;
    timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(original);
    timing.duration = CMSampleBufferGetDuration(original);

    CMVideoFormatDescriptionRef newFmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, rendered, &newFmt);
    if (!newFmt) { CVPixelBufferRelease(rendered); return NULL; }

    CMSampleBufferRef newBuf = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
        rendered, newFmt, &timing, &newBuf);
    CFRelease(newFmt);

    CFArrayRef srcAttach = CMSampleBufferGetSampleAttachmentsArray(original, false);
    if (srcAttach && CFArrayGetCount(srcAttach) > 0) {
        CFArrayRef dstAttach = CMSampleBufferGetSampleAttachmentsArray(newBuf, true);
        if (dstAttach && CFArrayGetCount(dstAttach) > 0) {
            CFMutableDictionaryRef srcDict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(srcAttach, 0);
            CFMutableDictionaryRef dstDict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(dstAttach, 0);
            CFDictionaryApplyFunction(srcDict, vcf_copy_dict_entry, dstDict);
        }
    }

    CVPixelBufferRelease(rendered);
    return newBuf;
}

// ── hook delivery ───────────────────────────────

typedef void (*DeliveryIMP)(id self, SEL _cmd, id output, CMSampleBufferRef sampleBuffer, id connection);

static void VCFHookedDelivery(id self, SEL _cmd, id output,
                              CMSampleBufferRef sampleBuffer, id connection) {
    const char *selName = sel_getName(_cmd);
    Class cls = object_getClass(self);
    NSValue *origVal = nil;
    while (cls) {
        NSString *key = [NSString stringWithFormat:@"%s.%s", class_getName(cls), selName];
        origVal = gOriginalIMPs[key];
        if (origVal) break;
        cls = class_getSuperclass(cls);
    }
    if (!origVal) return;
    DeliveryIMP origIMP = (DeliveryIMP)[origVal pointerValue];

    if (gInjectionEnabled && sampleBuffer) {
        CMSampleBufferRef replacement = VCFCreateReplacementBuffer(sampleBuffer);
        if (replacement) {
            origIMP(self, _cmd, output, replacement, connection);
            CFRelease(replacement);
            return;
        }
    }
    origIMP(self, _cmd, output, sampleBuffer, connection);
}

// ── hook installer ──────────────────────────────

static BOOL VCFHookMethod(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    const char *clsName = class_getName(cls);
    const char *selName = sel_getName(sel);
    NSString *key = [NSString stringWithFormat:@"%s.%s", clsName, selName];

    if (gOriginalIMPs[key]) return NO;

    unsigned argCount = method_getNumberOfArguments(m);
    if (argCount != 5) return NO;

    IMP origIMP = method_getImplementation(m);
    gOriginalIMPs[key] = [NSValue valueWithPointer:(void *)origIMP];

    MSHookMessageEx(cls, sel, (IMP)VCFHookedDelivery, NULL);
    gHookedMethodCount++;
    os_log(vcf_log, "hooked [%{public}s %{public}s] (total: %d)", clsName, selName, gHookedMethodCount);
    return YES;
}

// ── class scanning ──────────────────────────────

static BOOL VCFClassLooksLikeCamera(const char *name) {
    if (!name) return NO;
    if (strstr(name, "FigCapture")) return YES;
    if (strstr(name, "CMIOExtension")) return YES;
    if (strstr(name, "CameraOutput")) return YES;
    if (strstr(name, "CaptureOutput")) return YES;
    if (strstr(name, "VideoDataOutput")) return YES;
    if (strstr(name, "SampleBuffer")) return YES;
    if (strstr(name, "CAMCapture")) return YES;
    if (strstr(name, "AVCapture")) return YES;
    return NO;
}

static void VCFScanAndHook(void) {
    SEL deliverySelectors[] = {
        sel_registerName("captureOutput:didOutputSampleBuffer:fromConnection:"),
        sel_registerName("captureOutput:didDropSampleBuffer:fromConnection:"),
    };
    int numSelectors = 2;

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;

        for (int s = 0; s < numSelectors; s++) {
            Method m = class_getInstanceMethod(cls, deliverySelectors[s]);
            if (m) {
                VCFHookMethod(cls, deliverySelectors[s]);
            }
        }

        if (VCFClassLooksLikeCamera(name)) {
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(cls, &mcount);
            if (methods) {
                for (unsigned int mi = 0; mi < mcount; mi++) {
                    SEL sel = method_getName(methods[mi]);
                    const char *sn = sel_getName(sel);
                    if (sn && (strstr(sn, "deliver") || strstr(sn, "didOutput") ||
                               strstr(sn, "sampleBuffer") || strstr(sn, "Buffer:from"))) {
                        if (method_getNumberOfArguments(methods[mi]) == 5) {
                            VCFHookMethod(cls, sel);
                        }
                    }
                }
                free(methods);
            }
        }
    }
    free(classes);
    os_log(vcf_log, "scan done: %d hooks across %u classes", gHookedMethodCount, classCount);
}

// ── dynamic delegate hooking ────────────────────

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (delegate) {
        Class cls = [delegate class];
        SEL outSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        if (class_getInstanceMethod(cls, outSel)) {
            if (VCFHookMethod(cls, outSel)) {
                os_log(vcf_log, "dynamic: hooked delegate %{public}s", class_getName(cls));
            }
        }
        SEL dropSel = @selector(captureOutput:didDropSampleBuffer:fromConnection:);
        if (class_getInstanceMethod(cls, dropSel)) {
            VCFHookMethod(cls, dropSel);
        }
    }
}

%end

// ── config notification ─────────────────────────

static void VCFConfigChangedCallback(CFNotificationCenterRef center, void *observer,
    CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VCFApplyConfig();
    });
}

// ── constructor ─────────────────────────────────

%ctor {
    @autoreleasepool {
        vcf_log = os_log_create("com.vcamfree.camera", "hook");
        gOriginalIMPs = [NSMutableDictionary dictionary];

        NSString *procName = [NSProcessInfo processInfo].processName;
        os_log(vcf_log, "VCFCameraHook loaded in %{public}s pid=%d", procName.UTF8String, getpid());

        VCFScanAndHook();
        VCFApplyConfig();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, VCFConfigChangedCallback,
            (__bridge CFStringRef)kNotifConfigChanged,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        os_log(vcf_log, "VCFCameraHook ready: %d hooks in %{public}s", gHookedMethodCount, procName.UTF8String);
    }
}
