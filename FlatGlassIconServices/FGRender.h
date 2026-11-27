//
//  FGRender.h
//  FlatGlass
//
//  The compositor. Everything below maps one-to-one onto a function in the
//  shipped dylib; the comments name the original symbol and its address so a
//  future diffs against a new build stay cheap.
//
//  Call graph:
//
//      FGResourceImage          (ISAssetCatalogResource -imageForSize:scale:)
//        └── NGCreateFlatIcon     bytes 0x60e4
//        └── NGCreateGlassIconContent  0x68cc
//
//      FGComposedImage          (ISCompositor -imageForSize:scale:)
//        └── NGCreateRimmedImage   0x9324
//        └── NGCreateGlassedImage  0x996c
//
//      drawNode 0x64cc ──> drawFill 0x81e4 / drawElement 0x8c60 / drawNode
//                     └─> drawContents 0xb9e8
//

#ifndef FG_RENDER_H
#define FG_RENDER_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FGTypes.h"

/// Shared render state threaded through the whole walk. Offsets matter: the
/// layer code reads `bounds` straight off this struct, so keep the layout.
typedef struct {
    CGSize            pixelSize;   // +0x00  square canvas edge in pixels
    CGAffineTransform ctm;         // +0x10  canvas -> icon space
    CGRect            bounds;      // +0x40  the rect every node is drawn into
    BOOL              tintable;    // +0x60  appearance == ISAppearanceTintable
} FGDrawState;

/// 0x60e4 — flattens a stack into an opaque square image.
CGImageRef NGCreateFlatIcon(NGCatalogIndex *index, NSString *name,
                            uint32_t appearance, uint64_t pixelSize);

/// 0x68f8 — same but keeps the artwork so highlights can be added later.
CGImageRef NGCreateGlassIcon(NGCatalogIndex *index, NSString *name,
                             uint32_t appearance, uint64_t pixelSize);
CGImageRef NGCreateGlassIconContent(NGCatalogIndex *index, NSString *name,
                                    uint32_t appearance, uint64_t pixelSize);

/// 0x9324 — "Edge Only": recolour the rim of an already composited icon.
CGImageRef NGCreateRimmedImage(CGImageRef source);

/// 0x996c — "Edge and Artwork": rim plus a chiclet highlight pass.
CGImageRef NGCreateGlassedImage(CGImageRef source, uint32_t flags);

/// 0x64cc — walks one node's children.
BOOL FGDrawNode(CGContextRef ctx, FGDrawState *state, id resource,
                NGCatalogIndex *index, NGRendition *rendition, uint32_t token);

/// 0x81e4 — solid or gradient fill inside `rect`.
BOOL FGDrawFill(CGContextRef ctx, NGCatalogIndex *index, NSString *name,
                uint32_t token, BOOL normalizeDirection, CGRect rect, id resource);

/// 0x8c60 — one layer: draw content, use it as an alpha mask, fill through it.
BOOL FGDrawElement(CGContextRef ctx, FGDrawState *state, id resource,
                   NGCatalogIndex *index, NGRendition *rendition,
                   NGLayerRef *layer, uint32_t token, CGRect frame);

/// 0xb9e8 — bitmap or SVG payload for a single rendition.
BOOL FGDrawContents(CGContextRef ctx, id resource, NGRendition *rendition, CGRect frame);

// Hook entry points (must be plain C so their IMPs can be swapped in).
id FGResourceImage(id self, SEL _cmd, CGSize size, double scale);
id FGComposedImage(id self, SEL _cmd, CGSize size, double scale);

#endif /* FG_RENDER_H */
