include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FlatGlassRefresh

FlatGlassRefresh_FILES = Tweak.x $(wildcard ../Shared/*.m)
FlatGlassRefresh_FRAMEWORKS = Foundation UIKit
FlatGlassRefresh_CFLAGS = -fobjc-arc -I../Shared
FlatGlassRefresh_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
