//
//  FGEffects.h
//  FlatGlass
//
//  The two bitmap passes that produce the "glass" look. Both operate on a
//  straight RGBA8888 buffer, non-premultiplied, top-left origin.
//
//  IGDrawChicletHighlights is the expensive one: it builds a distance/normal
//  field from the silhouette and shades a light sweep across the top edge.
//  IG_STEPS (environment) controls the sweep resolution; the binary defaults it
//  to 32 and multiplies by four internally.
//

#ifndef FG_EFFECTS_H
#define FG_EFFECTS_H

#import <Foundation/Foundation.h>

/// Shades a highlight sweep into `rgba` using `shape` (w*h floats, 1.0 inside).
/// `flags` is passed through from the caller; bit 0 enables the artwork pass.
void IGDrawChicletHighlights(uint8_t *rgba, const float *shape, int w, int h, int flags);

/// Composite a stack of layers. Each layer is RGBA8888 of the same size.
void IGDrawGroup(uint8_t *dst, uint8_t **layers, const float *opacity,
                 int layerCount, int w, int h);

#endif /* FG_EFFECTS_H */
