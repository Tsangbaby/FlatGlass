//
//  FGCatalog.h
//  FlatGlass
//
//  Reads IconServices' theme catalogs.
//
//  The shipped tweak asks the ISAssetCatalogResource for its `_themeStore`
//  storage object and walks that. That works, but it ties us to private
//  accessors that Apple renames between releases. This implementation keeps the
//  same fast path *and* carries a straight ISTC binary parser, so when the
//  private accessors move we still have a way in.
//
//  Record layout recovered from the binary (offsets are absolute in the file):
//
//      0x000  char[4]   "ISTC"
//      0x0a8  uint32    record-region length          (call it REC)
//      0x0b4  uint32    payload length                (call it PAY)
//      0x0b8  records   REC bytes: repeat { u32 id, u32 len, u8 data[len] }
//      0xb8+REC         payload, PAY bytes
//
//  Each record id doubles as the rendition's `layout`, which is how the
//  compositor decides what to do with the bytes that follow.
//

#ifndef FG_CATALOG_H
#define FG_CATALOG_H

#import <Foundation/Foundation.h>
#import "FGTypes.h"

/// Parses an ISTC blob into an index. Returns nil when the magic is wrong or
/// the declared lengths run past the end of the buffer.
NGCatalogIndex *FGISTCParse(NSData *data);

/// Cached index for an ISAssetCatalogResource. Safe to call from any thread.
NGCatalogIndex *FGIndexForResource(id resource);

/// Looks up the stack (layout 1020 root) whose name matches `name`.
/// `appearance` is 0 = light, 1 = dark, 2 = tintable.
NGRendition *FGFindStack(NGCatalogIndex *index, NSString *name, uint32_t appearance);

/// YES when the named resource exists and resolves to a stack.
BOOL FGCatalogHasStack(id resource, NSString *name);

/// Appearance key for a numeric appearance index, matching the three strings
/// IconServices stores in its `appearances` dictionary.
NSString *FGAppearanceKey(uint32_t appearance);

#endif /* FG_CATALOG_H */
