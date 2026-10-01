LIBRARY_NAME = VCFCameraHook

VCFCameraHook_FILES = VCFCameraHook.xm \
    ../Core/VCFPaths.m ../Core/VCFSettings.m ../Core/VCFRender.m \
    ../Core/VCFSample.m ../Core/VCFMediaSource.m ../Core/VCFFrameEngine.m
VCFCameraHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I../Core
VCFCameraHook_FRAMEWORKS = CoreMedia CoreVideo CoreImage CoreGraphics AVFoundation Foundation ImageIO QuartzCore
VCFCameraHook_PRIVATE_FRAMEWORKS = CydiaSubstrate
VCFCameraHook_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk
