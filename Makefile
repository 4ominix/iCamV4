INSTALL_TARGET_PROCESSES = SpringBoard cameracaptured mediaserverd

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = App CameraHook Overlay StreamDaemon

include $(THEOS)/makefiles/aggregate.mk

after-stage::
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/prerm$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/usr/libexec/VCFStreamDaemon$(ECHO_END)
