//
//  FGResolve.h
//  FlatGlass
//
//  Turns raw ISTC bytes into the two things the renderer needs:
//    * a list of NGLayerRef drawing instructions (FGParseLayerRefs)
//    * the rendition each instruction points at (FGResolve)
//
//  Plus the small helpers those two lean on: keyed lookups inside a rendition's
//  keyList, raw payload extraction (with LZFSE fallback), name lookup used by
//  the fill path, and colour construction.
//

#ifndef FG_RESOLVE_H
#define FG_RESOLVE_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "FGTypes.h"

// Key ids used inside a keyList. Only #7 is named in the binary; the rest are
// compared by number in the resolver and carry layout/appearance metadata.
#define FGKeyAppearance 7

/// Value stored for `key` inside a rendition's keyList, or 0 when absent.
uint16_t FGKeyValue(NGRendition *rendition, uint16_t key);

/// Walks a composite record's payload and returns its NGLayerRef list.
NSArray<NGLayerRef *> *FGParseLayerRefs(NSData *csi);

/// Picks the rendition matching `keyList` + `token` (appearance). Falls back to
/// the untagged entry, then to any entry, exactly like the original resolver.
NGRendition *FGResolve(NGCatalogIndex *index, NSData *keyList, uint32_t token);

/// Name-based lookup used by the fill and colour paths.
NGRendition *FGByName(NGCatalogIndex *index, NSString *name, uint32_t token);

/// Raw payload for a rendition, transparently decompressing the LZFSE variant
/// that IconServices uses for anything above a few hundred bytes.
NSData *FGRawData(NGRendition *rendition);

/// Human readable keyList, for diagnostics only.
NSString *FGKeyListDescription(NSData *keyList);

/// Colour from an RLOC record. Returns +1 retained; caller releases.
CGColorRef FGCreateColor(NGRendition *rendition);

#endif /* FG_RESOLVE_H */
