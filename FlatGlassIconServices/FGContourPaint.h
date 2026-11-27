#ifndef FG_CONTOUR_PAINT_H
#define FG_CONTOUR_PAINT_H

#include <stdbool.h>

// rgb contains straight RGB triples; coverage and shape are borrowed, read-only
// alpha planes. A NULL coverage means opaque artwork. shape is the silhouette
// (NULL means a full square for the standalone highlight primitive).
bool FGPaintContour(float *rgb, const float *coverage, const float *shape, int n,
                    bool chiclet, bool outline, float style);
void FGDrawOutline(float *rgb, const float *coverage, const float *shape,
                   int n, float style, float unusedStrength);
void FGDrawChicletHighlights(float *rgb, const float *shape, int n);

#endif
