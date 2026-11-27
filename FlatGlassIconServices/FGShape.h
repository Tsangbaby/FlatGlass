//
//  FGShape.h
//  FlatGlass
//
//  Geometry and small image-processing helpers used by the highlight passes.
//  All of these originate in IconGlare (credited in the package description)
//  and were re-derived from the disassembly.
//
//  IGCreateIconShape in particular: it renders a squircle path into an 8-bit
//  grayscale bitmap, then converts to a float array with the Y axis flipped so
//  index 0 is the top-left pixel. The original drives the path from a 15-value
//  control table at __TEXT 0x10d30; the values below reproduce the same
//  silhouette (normalised, /1024).
//

#ifndef FG_SHAPE_H
#define FG_SHAPE_H

#import <Foundation/Foundation.h>

/// Returns a malloc'd w*h float array (caller frees) holding the icon
/// silhouette: 1.0 inside, 0.0 outside, antialiased at the edge.
float *IGCreateIconShape(int size);

/// Squared Euclidean distance transform. `grid` is w*h floats, transformed
/// in place into squared distances to the nearest zero.
void FGEDT(float *grid, int w, int h);

/// Three box passes ≈ Gaussian. `grid` is w*h floats, transformed in place.
void FGGaussianBlur(float *grid, int w, int h, float radius);

/// Byte version used by the rim pass: fills `out` with a 0..255 falloff that
/// is 255 on the silhouette edge and decays inward.
void FGEdgeDistance(const uint8_t *mask, uint8_t *out, int w, int h);

/// Soft outline around the silhouette, alpha-blended into `rgba`.
void IGDrawOutline(uint8_t *rgba, float *shape, int *size, float strength);

#endif /* FG_SHAPE_H */
