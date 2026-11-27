LIBRARY_NAME = FlatGlassIconServices

FlatGlassIconServices_FILES = $(wildcard *.m)
FlatGlassIconServices_FRAMEWORKS = Foundation CoreGraphics CoreFoundation
FlatGlassIconServices_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# 原二进制是 arm64 + arm64e fat，且依赖 libobjc 的 runtime 函数
# (class_replaceMethod / method_getImplementation / method_getTypeEncoding)。
FlatGlassIconServices_CFLAGS = -fobjc-arc -O2
FlatGlassIconServices_LIBRARIES = compression

include $(THEOS_MAKE_PATH)/library.mk
