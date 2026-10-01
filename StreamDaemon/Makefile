TOOL_NAME = VCFStreamDaemon

VCFStreamDaemon_FILES = main.c vcf_rtmp.c vcf_flv.c
VCFStreamDaemon_CFLAGS = -Wall -Wextra -Wno-unused-parameter -O2
VCFStreamDaemon_CODESIGN_FLAGS = -Sentitlements.plist
VCFStreamDaemon_INSTALL_PATH = /usr/libexec

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tool.mk
