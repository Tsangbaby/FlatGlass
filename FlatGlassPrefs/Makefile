include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FlatGlassPrefs

FlatGlassPrefs_FILES = FGSettingsListController.m $(wildcard ../Shared/*.m)
FlatGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
FlatGlassPrefs_RESOURCE_DIRS = Resources
FlatGlassPrefs_FRAMEWORKS = UIKit Foundation
FlatGlassPrefs_PRIVATE_FRAMEWORKS = Preferences
FlatGlassPrefs_CFLAGS = -fobjc-arc -I../Shared -I.
FlatGlassPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
