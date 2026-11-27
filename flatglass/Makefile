include $(THEOS)/makefiles/common.mk

TOOL_NAME = flatglass

flatglass_FILES = $(wildcard *.m)
flatglass_FRAMEWORKS = Foundation UIKit CoreGraphics
flatglass_INSTALL_PATH = /usr/libexec
flatglass_CFLAGS = -fobjc-arc -O2

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
flatglass_CFLAGS += -DFG_ROOTHIDE=1
# The official header module also autolinks this; keep non-module builds valid.
flatglass_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tool.mk
