include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FlatGlassIconServices

FlatGlassIconServices_FILES = $(wildcard *.m)
FlatGlassIconServices_FRAMEWORKS = Foundation CoreGraphics CoreFoundation
FlatGlassIconServices_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

FlatGlassIconServices_CFLAGS = -fobjc-arc -O2
FlatGlassIconServices_LIBRARIES = compression

include $(THEOS_MAKE_PATH)/library.mk
