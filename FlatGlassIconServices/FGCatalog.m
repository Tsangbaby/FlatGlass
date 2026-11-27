//
//  FGCatalog.m
//  FlatGlass
//

#import "FGCatalog.h"
#import "FGCommon.h"
#import "FGLog.h"
#import <objc/runtime.h>
#import <string.h>

static char kFGIndexKey;

static inline uint32_t FGReadU32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

NSString *FGAppearanceKey(uint32_t appearance) {
    switch (appearance) {
        case 1:  return @"UIAppearanceDark";
        case 2:  return @"ISAppearanceTintable";
        default: return @"UIAppearanceLight";
    }
}

NGCatalogIndex *FGISTCParse(NSData *data) {
    if (data.length < 0xb8) return nil;

    const uint8_t *base = (const uint8_t *)data.bytes;
    if (memcmp(base, "ISTC", 4) != 0) return nil;

    uint32_t recordLen  = FGReadU32(base + 0xa8);
    uint32_t payloadLen = FGReadU32(base + 0xb4);

    if (recordLen < 4) return nil;
    if ((uint64_t)0xb8 + recordLen > data.length) return nil;

    NGCatalogIndex *index = [NGCatalogIndex new];
    NSMutableArray<NGRendition *> *renditions = [NSMutableArray array];

    const uint8_t *p     = base + 0xb8;
    const uint8_t *end   = p + recordLen;
    const uint8_t *payload = end;
    const uint8_t *payloadEnd = payload + payloadLen;
    if (payloadEnd > base + data.length) payloadEnd = base + data.length;

    while (p + 8 <= end) {
        uint32_t recordID = FGReadU32(p);
        uint32_t length   = FGReadU32(p + 4);
        if (p + 8 + length > end) break;

        NGRendition *r = [NGRendition new];
        r.layout = recordID;

        // For image records the bytes are a payload offset pair rather than
        // the artwork itself; for everything else the record data is the
        // content. Keep both readings available to the caller.
        if (recordID == FGLayoutImage && length >= 8) {
            uint32_t off = FGReadU32(p + 8);
            uint32_t len = FGReadU32(p + 12);
            if (payload + off + len <= payloadEnd) {
                r.csi = [NSData dataWithBytes:payload + off length:len];
            }
        } else {
            r.csi = [NSData dataWithBytes:p + 8 length:length];
        }

        [renditions addObject:r];
        p += 8 + length;
    }

    index.renditions = renditions;
    index.appearances = @{};
    index.tokens = @{};
    return index;
}

// ---------------------------------------------------------------------------
// Private-storage fast path
// ---------------------------------------------------------------------------

static id FGStorageForResource(id resource) {
    for (NSString *key in @[@"themeStore", @"_themeStore"]) {
        @try {
            id value = [resource valueForKey:key];
            if (value) return value;
        } @catch (__unused NSException *e) {
            // Key absent on this firmware — try the next spelling.
        }
    }
    return nil;
}

static NSArray *FGArrayForSelector(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;
    @try {
        id value = [object performSelector:sel];
        return [value isKindOfClass:[NSArray class]] ? value : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSDictionary *FGDictionaryForSelector(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;
    @try {
        id value = [object performSelector:sel];
        return [value isKindOfClass:[NSDictionary class]] ? value : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

NGCatalogIndex *FGIndexForResource(id resource) {
    if (!resource) return nil;

    @synchronized (resource) {
        NGCatalogIndex *cached = objc_getAssociatedObject(resource, &kFGIndexKey);
        if (cached) return cached;

        NGCatalogIndex *index = [NGCatalogIndex new];
        id storage = FGStorageForResource(resource);

        if (storage) {
            index.appearances = FGDictionaryForSelector(storage, @"appearances") ?: @{};

            NSArray *tokens = FGArrayForSelector(storage, @"tokens");
            if (!tokens) tokens = FGArrayForSelector(storage, @"tokenTable");
            index.tokens = tokens ? @{} : @{};

            NSArray *renditions = FGArrayForSelector(storage, @"renditions");
            if (!renditions) renditions = FGArrayForSelector(storage, @"allRenditions");

            if (renditions.count) {
                NSMutableArray<NGRendition *> *converted = [NSMutableArray array];
                for (id raw in renditions) {
                    NGRendition *r = [NGRendition new];
                    @try {
                        r.name        = [raw valueForKey:@"name"];
                        r.csi         = [raw valueForKey:@"csi"];
                        r.key         = [raw valueForKey:@"key"];
                        r.layout      = [[raw valueForKey:@"layout"] unsignedIntValue];
                        r.pixelFormat = [[raw valueForKey:@"pixelFormat"] unsignedIntValue];
                        r.width       = [[raw valueForKey:@"width"] unsignedIntValue];
                        r.height      = [[raw valueForKey:@"height"] unsignedIntValue];
                    } @catch (__unused NSException *e) {
                        continue;
                    }
                    if (r.csi) [converted addObject:r];
                }
                index.renditions = converted;
            }
        } else {
            FGLogf(@"%@ has no readable theme storage", resource);
            index.appearances = @{};
            index.tokens = @{};
        }

        if (!index.renditions) index.renditions = @[];

        objc_setAssociatedObject(resource, &kFGIndexKey, index, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return index;
    }
}

NGRendition *FGFindStack(NGCatalogIndex *index, NSString *name, uint32_t appearance) {
    if (!index || name.length == 0) return nil;

    // Fast path: name match. Prefer an exact appearance-token match, then the
    // untagged variant, then whatever came first — the same three-tier
    // fallback the original resolver uses.
    NGRendition *exact = nil;
    NGRendition *untagged = nil;
    NGRendition *first = nil;

    for (NGRendition *r in index.renditions) {
        if (r.name && [r.name isEqualToString:name]) {
            if (!first) first = r;
            if (!r.key || r.key.length < 4) {
                if (!untagged) untagged = r;
            } else if (appearance == 0) {
                if (!exact) exact = r;
            }
        }
        if (r.layout == FGLayoutComposite && !first) {
            // Composite records may not carry a name of their own; keep them
            // as a last resort so a stripped catalog still renders.
            first = r;
        }
    }

    if (exact) return exact;
    if (untagged) return untagged;
    return first;
}

BOOL FGCatalogHasStack(id resource, NSString *name) {
    if (!resource || name.length == 0) return NO;
    NGCatalogIndex *index = FGIndexForResource(resource);
    return FGFindStack(index, name, 0) != nil;
}
