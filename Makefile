INSTALL_TARGET_PROCESSES = SpringBoard cameracaptured mediaserverd

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
THEOS_PACKAGE_INSTALL_PREFIX = /var/jb

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = App CameraHook Overlay StreamDaemon

include $(THEOS)/makefiles/aggregate.mk

after-stage::
	$(ECHO_NOTHING)cp -a $(THEOS_PROJECT_DIR)/layout/* $(THEOS_STAGING_DIR)/$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/prerm$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 $(THEOS_STAGING_DIR)/var/jb/usr/libexec/VCFStreamDaemon 2>/dev/null || true$(ECHO_END)
