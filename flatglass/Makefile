include $(THEOS)/makefiles/common.mk

TOOL_NAME = flatglass

flatglass_FILES = main.m FGDiagDaemon.m FGDiagReport.c $(wildcard ../Shared/*.m)
flatglass_FRAMEWORKS = Foundation CoreGraphics ImageIO
flatglass_INSTALL_PATH = /usr/libexec
flatglass_CFLAGS = -fobjc-arc -I../Shared -I. -DFG_INSTALL_PREFIX='@"$(THEOS_PACKAGE_INSTALL_PREFIX)"'
flatglass_LDFLAGS = -undefined dynamic_lookup

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
flatglass_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tool.mk
