LIBRARY_NAME = VCFCameraHook

VCFCameraHook_FILES = VCFCameraHook.xm VCFFrameRenderer.m
VCFCameraHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
VCFCameraHook_FRAMEWORKS = CoreMedia CoreVideo VideoToolbox CoreImage CoreGraphics AVFoundation Foundation ImageIO
VCFCameraHook_PRIVATE_FRAMEWORKS = CydiaSubstrate
VCFCameraHook_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk
