include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FlatGlassIconServices

FlatGlassIconServices_FILES = \
    Tweak.x \
    FGTypes.m \
    FGCompat.m \
    FGCatalog.m \
    FGResolve.m \
    FGRender.m \
    FGShape.m \
    FGEffects.m \
    FGWrap.m \
    $(wildcard ../Shared/*.m)

FlatGlassIconServices_FRAMEWORKS = Foundation CoreGraphics UIKit ImageIO
FlatGlassIconServices_LIBRARIES = compression
FlatGlassIconServices_CFLAGS  = -fobjc-arc -I../Shared -I.
FlatGlassIconServices_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
