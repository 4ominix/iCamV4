#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>
#import "VCFFrameRenderer.h"

// ──────────────────────────────────────────────
// paths & notifications (no auth, no license)
// ──────────────────────────────────────────────
static NSString *const kVCFSharedDir        = @"/var/jb/var/mobile/Library/VCamFree";
static NSString *const kVCFCameraConfigPath = @"/var/jb/var/mobile/Library/VCamFree/CameraConfig.plist";
static NSString *const kVCFCameraStatusPath = @"/var/jb/var/mobile/Library/VCamFree/CameraStatus.plist";
static NSString *const kVCFStreamDir        = @"/var/jb/var/mobile/Library/VCamFree/Streams";
static NSString *const kVCFMediaDir         = @"/var/jb/var/mobile/Library/VCamFree/Media";

static NSString *const kNotifConfigChanged  = @"com.vcamfree.camera.config.changed";
static NSString *const kNotifStatusChanged  = @"com.vcamfree.camera.status.changed";

static os_log_t vcf_log;

// ──────────────────────────────────────────────
// state
// ──────────────────────────────────────────────
static BOOL           gInjectionEnabled   = NO;
static VCFSourceType  gCurrentSource      = VCFSourceTypeNone;
static NSString      *gCurrentMediaPath   = nil;
static int            gHookedClassCount   = 0;

// ──────────────────────────────────────────────
// config read/write (simple plists, zero server)
// ──────────────────────────────────────────────
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

    if (!gInjectionEnabled) {
        [[VCFFrameRenderer shared] unloadSource];
        gCurrentSource = VCFSourceTypeNone;
        VCFWriteStatus(@{@"active": @NO, @"reason": @"disabled"});
        return;
    }

    VCFFrameRenderer *renderer = [VCFFrameRenderer shared];

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
        @"hooked_classes": @(gHookedClassCount)
    });
    os_log(vcf_log, "config applied: enabled=%d source=%{public}s ready=%d",
           gInjectionEnabled, sourceType.UTF8String, renderer.ready);
}

// ──────────────────────────────────────────────
// CMSampleBuffer replacement
// ──────────────────────────────────────────────
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

    // copy attachments from original
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

// ──────────────────────────────────────────────
// ObjC method hooking via Substrate
// ──────────────────────────────────────────────

// storage for original IMPs, keyed by "ClassName.selectorName"
static NSMutableDictionary<NSString *, NSValue *> *gOriginalIMPs;

typedef void (*DeliveryIMP)(id self, SEL _cmd, id output, CMSampleBufferRef sampleBuffer, id connection);

static void VCFHookedDelivery(id self, SEL _cmd, id output,
                              CMSampleBufferRef sampleBuffer, id connection) {
    NSString *key = [NSString stringWithFormat:@"%s.%s",
                     object_getClassName(self), sel_getName(_cmd)];
    NSValue *origVal = gOriginalIMPs[key];
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

// hook a single ObjC method on a class, save original IMP
static BOOL VCFHookMethod(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    const char *clsName = class_getName(cls);
    const char *selName = sel_getName(sel);
    NSString *key = [NSString stringWithFormat:@"%s.%s", clsName, selName];

    if (gOriginalIMPs[key]) return NO; // already hooked

    // verify method signature matches delivery pattern: (id, SEL, id, CMSampleBufferRef, id)
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;

    // basic ABI check: should have 5 arguments total (self, _cmd, output, buffer, connection)
    unsigned argCount = method_getNumberOfArguments(m);
    if (argCount != 5) return NO;

    IMP origIMP = method_getImplementation(m);
    gOriginalIMPs[key] = [NSValue valueWithPointer:(void *)origIMP];

    MSHookMessageEx(cls, sel, (IMP)VCFHookedDelivery, NULL);
    os_log(vcf_log, "hooked %{public}s on %{public}s", selName, clsName);
    return YES;
}

// ──────────────────────────────────────────────
// runtime class scanning — find camera delivery targets
// ──────────────────────────────────────────────

// known delivery selectors to search for
static SEL gTargetSelectors[8];
static int gTargetSelectorCount = 0;

static void VCFBuildTargetSelectors(void) {
    gTargetSelectors[0] = sel_registerName("captureOutput:didOutputSampleBuffer:fromConnection:");
    gTargetSelectors[1] = sel_registerName("captureOutput:didDropSampleBuffer:fromConnection:");
    gTargetSelectors[2] = sel_registerName("outputSequenceWasFlushed:");
    gTargetSelectorCount = 2;  // main two delivery methods
}

// name-based heuristic: does this class look like it handles camera frames?
static BOOL VCFClassLooksLikeCamera(const char *name) {
    if (!name) return NO;
    // match patterns: FigCapture*, CMIOExtension*, AVCapture*, *CameraOutput*
    if (strstr(name, "FigCapture")) return YES;
    if (strstr(name, "CMIOExtension")) return YES;
    if (strstr(name, "CameraOutput")) return YES;
    if (strstr(name, "CaptureOutput")) return YES;
    if (strstr(name, "VideoDataOutput")) return YES;
    if (strstr(name, "SampleBuffer")) return YES;
    return NO;
}

static void VCFInstallCameraHooks(void) {
    gOriginalIMPs = [NSMutableDictionary dictionary];
    VCFBuildTargetSelectors();

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int hooked = 0;

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;

        // strategy 1: class name looks camera-related
        BOOL nameMatch = VCFClassLooksLikeCamera(name);

        // strategy 2: class responds to known delivery selectors
        for (int s = 0; s < gTargetSelectorCount; s++) {
            Method m = class_getInstanceMethod(cls, gTargetSelectors[s]);
            if (m) {
                if (VCFHookMethod(cls, gTargetSelectors[s])) {
                    hooked++;
                }
            }
        }

        // strategy 3: for camera-named classes, scan all methods for
        // anything that takes a CMSampleBufferRef argument
        if (nameMatch) {
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(cls, &mcount);
            if (methods) {
                for (unsigned int mi = 0; mi < mcount; mi++) {
                    SEL sel = method_getName(methods[mi]);
                    const char *selName = sel_getName(sel);
                    // look for methods containing "deliver", "output", "sample", "buffer"
                    if (selName &&
                        (strstr(selName, "deliver") || strstr(selName, "didOutput") ||
                         strstr(selName, "sampleBuffer") || strstr(selName, "Buffer:from"))) {
                        unsigned argCnt = method_getNumberOfArguments(methods[mi]);
                        if (argCnt == 5) {
                            if (VCFHookMethod(cls, sel)) hooked++;
                        }
                    }
                }
                free(methods);
            }
        }
    }
    free(classes);

    gHookedClassCount = hooked;
    os_log(vcf_log, "hook scan complete: %d methods hooked across %u classes scanned",
           hooked, classCount);
}

// ──────────────────────────────────────────────
// notification handler
// ──────────────────────────────────────────────
static void VCFConfigChangedCallback(CFNotificationCenterRef center, void *observer,
    CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VCFApplyConfig();
    });
}

// ──────────────────────────────────────────────
// constructor — entry point when dylib loads in cameracaptured/mediaserverd
// ──────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        vcf_log = os_log_create("com.vcamfree.camera", "hook");

        NSString *procName = [NSProcessInfo processInfo].processName;
        os_log(vcf_log, "starting in process %{public}s", procName.UTF8String);

        VCFInstallCameraHooks();
        VCFApplyConfig();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, VCFConfigChangedCallback,
            (__bridge CFStringRef)kNotifConfigChanged,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
