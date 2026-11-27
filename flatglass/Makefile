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

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
flatglass_FILES += ../Shared/FGModeStore.c
TOOL_NAME += flatglassdiag
flatglassdiag_FILES = FGDiagInstall.c FGDiagReport.c ../Shared/FGModeStore.c
flatglassdiag_CFLAGS = -I../Shared -DFG_MODE_STORE_PREPARE=1
flatglassdiag_LIBRARIES += roothide
flatglassdiag_INSTALL_PATH = /usr/libexec
endif

include $(THEOS_MAKE_PATH)/tool.mk
