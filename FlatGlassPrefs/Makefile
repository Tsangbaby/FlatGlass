include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FlatGlassPrefs

FlatGlassPrefs_FILES = $(wildcard *.m)
FlatGlassPrefs_FRAMEWORKS = Foundation UIKit
# The selected iPhoneOS SDK must supply the system private framework stub.
FlatGlassPrefs_PRIVATE_FRAMEWORKS = Preferences
FlatGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
FlatGlassPrefs_CFLAGS = -fobjc-arc -O2
# The original executable is MH_BUNDLE, with no LC_ID_DYLIB.
FlatGlassPrefs_DYNAMIC_LIBRARY = 0
FlatGlassPrefs_LDFLAGS += -bundle

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
FlatGlassPrefs_CFLAGS += -DFG_ROOTHIDE=1
# The official header module also autolinks this; keep non-module builds valid.
FlatGlassPrefs_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/bundle.mk
