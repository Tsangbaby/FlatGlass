#ifndef FG_RENDER_POLICY_H
#define FG_RENDER_POLICY_H

#include <math.h>
#include <stdbool.h>
#include <stddef.h>

#define FG_MIN_PIXELS 16
#define FG_MAX_PIXELS 1024

typedef struct {
    size_t pixelSide;
    double imageScale;
} FGRenderDimensions;

// The original rounded and bounded the pixel side before converting it to an
// integer. IFImage's scale is pixels per point of the requested longest side.
static inline bool FGResolveRenderDimensions(double w, double h, double scale,
                                              FGRenderDimensions *out) {
    if (!out || !isnormal(w) || !isnormal(h) || !isnormal(scale) ||
        w <= 0 || h <= 0 || scale <= 0) return false;
    const double side = fmax(w, h);
    const double pixels = fmin(FG_MAX_PIXELS, fmax(FG_MIN_PIXELS, ceil(side * scale)));
    const double imageScale = pixels / side;
    if (!isfinite(imageScale) || imageScale <= 0) return false;
    *out = (FGRenderDimensions){(size_t)pixels, imageScale};
    return true;
}

typedef enum { FGRenderOriginal, FGRenderRimmed, FGRenderGlassed } FGComposedStyle;

static inline FGComposedStyle FGComposedStyleForMode(int mode, bool hasLayeredPrimary) {
    if (mode == 3 || (mode == 1 && hasLayeredPrimary)) return FGRenderRimmed;
    return mode == 1 ? FGRenderGlassed : FGRenderOriginal;
}

#endif
