#include "../FlatGlassIconServices/FGRenderPolicy.h"
#include <assert.h>
#include <float.h>
#include <stdio.h>

int main(void) {
    FGRenderDimensions dims = {0};
    assert(FGResolveRenderDimensions(60, 40, 3, &dims));
    assert(dims.pixelSide == 180 && dims.imageScale == 3);
    assert(FGResolveRenderDimensions(40, 60, 3, &dims));
    assert(dims.pixelSide == 180 && dims.imageScale == 3);
    assert(FGResolveRenderDimensions(20.5, 19, 2.5, &dims));
    assert(dims.pixelSide == 52 && dims.imageScale == 52.0 / 20.5);
    assert(FGResolveRenderDimensions(1, 2, 0.5, &dims));
    assert(dims.pixelSide == 16 && dims.imageScale == 8);
    assert(FGResolveRenderDimensions(1500, 1250, 3, &dims));
    assert(dims.pixelSide == 1024 && dims.imageScale == 1024.0 / 1500);
    assert(FGResolveRenderDimensions(DBL_MAX, DBL_MAX, DBL_MAX, &dims));
    assert(dims.pixelSide == 1024 && isfinite(dims.imageScale));
    assert(!FGResolveRenderDimensions(DBL_MIN, DBL_MIN, 1, &dims));
    assert(!FGResolveRenderDimensions(0, 20, 2, &dims));
    assert(!FGResolveRenderDimensions(-5, 20, 2, &dims));
    assert(!FGResolveRenderDimensions(INFINITY, 20, 2, &dims));
    assert(!FGResolveRenderDimensions(20, NAN, 2, &dims));
    assert(!FGResolveRenderDimensions(20, 20, 0, &dims));
    assert(!FGResolveRenderDimensions(20, 20, INFINITY, &dims));
    assert(!FGResolveRenderDimensions(20, 20, 2, NULL));
    assert(!FGResolveRenderDimensions(DBL_TRUE_MIN, 20, 2, &dims));

    assert(FGComposedStyleForMode(-1, false) == FGRenderOriginal);
    assert(FGComposedStyleForMode(0, false) == FGRenderOriginal);
    assert(FGComposedStyleForMode(2, true) == FGRenderOriginal);
    assert(FGComposedStyleForMode(4, true) == FGRenderOriginal);
    assert(FGComposedStyleForMode(1, false) == FGRenderGlassed);
    assert(FGComposedStyleForMode(1, true) == FGRenderRimmed);
    assert(FGComposedStyleForMode(3, false) == FGRenderRimmed);
    assert(FGComposedStyleForMode(3, true) == FGRenderRimmed);
    puts("Render policy: all 29 assertions passed (geometry, clamping, mode routing)");
    return 0;
}
