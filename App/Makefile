APPLICATION_NAME = VCamFree

VCamFree_FILES = VCFAppDelegate.m VCFMainViewController.m VCFMediaStore.m \
    ../Overlay/VCFAdjustments.m \
    ../Core/VCFPaths.m ../Core/VCFSettings.m ../Core/VCFRender.m \
    ../Core/VCFSample.m ../Core/VCFMediaSource.m ../Core/VCFFrameEngine.m
VCamFree_CFLAGS = -fobjc-arc -I../Core -I../Overlay
VCamFree_FRAMEWORKS = UIKit Foundation CoreGraphics AVFoundation PhotosUI \
    CoreMedia CoreVideo CoreImage QuartzCore ImageIO
VCamFree_CODESIGN_FLAGS = -Sentitlements.plist
VCamFree_INSTALL_PATH = /Applications

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/application.mk
