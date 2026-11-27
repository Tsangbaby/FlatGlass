//
//  FGResolve.m
//  FlatGlass
//

#import "FGResolve.h"
#import "FGCommon.h"
#import "FGLog.h"
#import <compression.h>
#import <string.h>

static inline uint32_t FGReadU32(const uint8_t *p) {
    uint32_t v; memcpy(&v, p, sizeof(v)); return v;
}
static inline uint16_t FGReadU16(const uint8_t *p) {
    uint16_t v; memcpy(&v, p, sizeof(v)); return v;
}
static inline float FGReadF32(const uint8_t *p) {
    float v; memcpy(&v, p, sizeof(v)); return v;
}

uint16_t FGKeyValue(NGRendition *rendition, uint16_t key) {
    NSData *keyList = rendition.key;
    if (!keyList || keyList.length < 4) return 0;

    const uint8_t *bytes = (const uint8_t *)keyList.bytes;
    NSUInteger pairs = keyList.length / 4;
    for (NSUInteger i = 0; i < pairs; i++) {
        if (FGReadU16(bytes + i * 4) == key) {
            return FGReadU16(bytes + i * 4 + 2);
        }
    }
    return 0;
}

NSString *FGKeyListDescription(NSData *keyList) {
    if (!keyList || keyList.length < 4) return @"";
    NSMutableString *out = [NSMutableString string];
    const uint8_t *bytes = (const uint8_t *)keyList.bytes;
    NSUInteger pairs = keyList.length / 4;
    for (NSUInteger i = 0; i < pairs; i++) {
        [out appendFormat:@"%u=%u ", FGReadU16(bytes + i * 4), FGReadU16(bytes + i * 4 + 2)];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Layer records
// ---------------------------------------------------------------------------

// Record ids that carry drawing instructions. 1012 is a plain layer, 1020 a
// nested group and 1021 a fill; the group/fill variants reuse the same
// NGLayerRef shape so the renderer only has to branch on `layout` later.
enum {
    FGRecordLayer    = 1012,   // 0x3f4
    FGRecordGroup    = 1020,   // 0x3fc
    FGRecordFill     = 1021,   // 0x3fd
};

NSArray<NGLayerRef *> *FGParseLayerRefs(NSData *csi) {
    NSMutableArray<NGLayerRef *> *refs = [NSMutableArray array];
    if (csi.length < 0xb8) return refs;

    const uint8_t *base = (const uint8_t *)csi.bytes;
    uint32_t recordLen = FGReadU32(base + 0xa8);

    if (recordLen < 8 || (uint64_t)0xb8 + recordLen > csi.length) return refs;

    const uint8_t *p = base + 0xb8;
    const uint8_t *end = p + recordLen;

    while (p + 8 <= end) {
        uint32_t recordID = FGReadU32(p);
        uint32_t length   = FGReadU32(p + 4);
        if (p + 8 + length > end) break;
        const uint8_t *rec = p + 8;

        if (recordID == FGRecordLayer && length >= 0x28) {
            NGLayerRef *layer = [NGLayerRef new];
            layer.flags     = FGReadU32(rec);
            layer.frame     = CGRectMake(FGReadF32(rec + 4),  FGReadF32(rec + 8),
                                         FGReadF32(rec + 12), FGReadF32(rec + 16));
            layer.blendMode = FGReadU32(rec + 0x14);
            layer.opacity   = FGReadF32(rec + 0x18);

            uint32_t keyLen = FGReadU32(rec + 0x1c);
            if (0x20 + (uint64_t)keyLen <= length) {
                layer.keyList = [NSData dataWithBytes:rec + 0x20 length:keyLen];
            }
            [refs addObject:layer];
        } else if (recordID == FGRecordGroup && length >= 0x14) {
            // A group record: flags, child count, then a string table holding
            // lighting / specular / fill names in that order.
            NGLayerRef *layer = [NGLayerRef new];
            layer.flags = FGReadU32(rec);

            uint32_t count = FGReadU32(rec + 8);
            const uint8_t *cursor = rec + 0x14;
            const uint8_t *recEnd = rec + length;

            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (uint32_t i = 0; i < count && cursor < recEnd; i++) {
                // Strings are NUL terminated and padded to four bytes.
                NSUInteger maxLen = (NSUInteger)(recEnd - cursor);
                size_t len = strnlen((const char *)cursor, maxLen);
                NSString *s = [[NSString alloc] initWithBytes:cursor
                                                       length:len
                                                     encoding:NSUTF8StringEncoding];
                if (s) [names addObject:s];
                cursor += ((len + 4) & ~3u);
            }

            if (names.count > 0) layer.lighting     = names[0];
            if (names.count > 1) layer.specular     = names[1];
            if (names.count > 2) layer.fill         = names[2];

            uint32_t blurIndex = FGReadU32(rec + 0x1c);
            (void)blurIndex;

            [refs addObject:layer];
        } else if (recordID == FGRecordFill && length >= 0x14) {
            NGLayerRef *layer = [NGLayerRef new];
            layer.flags = FGReadU32(rec);
            [refs addObject:layer];
        }

        p += 8 + length;
    }

    return refs;
}

// ---------------------------------------------------------------------------
// Rendition selection
// ---------------------------------------------------------------------------

static BOOL FGKeyListMatches(NGRendition *r, NSData *keyList) {
    if (!keyList || keyList.length < 4) return YES;

    const uint8_t *bytes = (const uint8_t *)keyList.bytes;
    NSUInteger pairs = keyList.length / 4;
    for (NSUInteger i = 0; i < pairs; i++) {
        uint16_t key = FGReadU16(bytes + i * 4);
        if (key == 0) break;
        uint16_t want = FGReadU16(bytes + i * 4 + 2);
        if (FGKeyValue(r, key) != want) return NO;
    }
    return YES;
}

NGRendition *FGResolve(NGCatalogIndex *index, NSData *keyList, uint32_t token) {
    if (!index) return nil;

    NGRendition *untagged = nil;
    NGRendition *first    = nil;

    for (NGRendition *r in index.renditions) {
        if (!FGKeyListMatches(r, keyList)) continue;

        uint16_t appearance = FGKeyValue(r, FGKeyAppearance);
        if (appearance == token) return r;

        if (!untagged && appearance == 0) untagged = r;
        if (!first) first = r;
    }

    return untagged ?: first;
}

NGRendition *FGByName(NGCatalogIndex *index, NSString *name, uint32_t token) {
    if (!name.length || !index) return nil;

    NGRendition *untagged = nil;
    NGRendition *first    = nil;

    for (NGRendition *r in index.renditions) {
        if (!r.name || ![r.name isEqualToString:name]) continue;

        uint16_t appearance = FGKeyValue(r, FGKeyAppearance);
        if (appearance == token) return r;

        if (!untagged && appearance == 0) untagged = r;
        if (!first) first = r;
    }

    return untagged ?: first;
}

// ---------------------------------------------------------------------------
// Payload
// ---------------------------------------------------------------------------

NSData *FGRawData(NGRendition *rendition) {
    NSData *csi = rendition.csi;
    if (!csi || csi.length < 0xb8) return csi;

    const uint8_t *base = (const uint8_t *)csi.bytes;

    // Two shapes exist in the wild:
    //   "DWAR" — the bytes are already plain, just offset into the payload.
    //   "LZFSE" — the payload is compressed; decode into a fresh buffer.
    if (memcmp(base, "DWAR", 4) == 0) {
        uint32_t offset = FGReadU32(base + 0xa8);
        uint32_t length = FGReadU32(base + 0xb4);
        if ((uint64_t)0xb8 + offset + length > csi.length) return nil;
        return [NSData dataWithBytes:base + 0xb8 + offset length:length];
    }

    uint32_t uncompressed = FGReadU32(base + 0xb4);
    if (uncompressed == 0 || uncompressed > (16u << 20)) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:uncompressed];
    if (!out) return nil;

    size_t written = compression_decode_buffer((uint8_t *)out.mutableBytes, uncompressed,
                                               base, csi.length, NULL,
                                               COMPRESSION_LZFSE);
    if (written == 0) {
        FGLogf(@"lzfse %@ failed", rendition.name);
        return nil;
    }
    if (written < uncompressed) out.length = written;
    return out;
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

// RLOC record:
//   0x00  char[4]  "RLOC"
//   0x04  uint32   version / flags
//   0x08  uint32   component count
//   0x0c  uint32   colour space id  (3 = sRGB, 4 = extended sRGB, 5 = gray)
//   0x10  float[]  components, component count of them
CGColorRef FGCreateColor(NGRendition *rendition) {
    NSData *csi = rendition.csi;
    if (!csi || csi.length < 0x14) return NULL;

    const uint8_t *p = (const uint8_t *)csi.bytes;
    if (memcmp(p, "RLOC", 4) != 0) return NULL;

    uint32_t count      = FGReadU32(p + 8);
    uint32_t spaceID    = FGReadU32(p + 0xc);
    if (count == 0 || count > 4) return NULL;
    if (0x10 + count * 4 > csi.length) return NULL;

    CGFloat components[4] = {0, 0, 0, 1};
    for (uint32_t i = 0; i < count; i++) {
        components[i] = FGReadF32(p + 0x10 + i * 4);
    }
    if (count < 4) components[3] = 1.0;

    CGColorSpaceRef space = NULL;
    if (spaceID == 5) {
        space = CGColorSpaceCreateDeviceGray();
    } else {
        space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    }
    if (!space) return NULL;

    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return color;
}
