//
//  FGCatalog.m
//  分层图标数据模型 + CUICatalog 索引 + 各类资源块解析
//
//  地址对照：
//     0x5088 NGCatalogHasStack   0x5114 findStack      0x53ac indexFor
//     0xada8 index block         0x7e68 layerRefs      0x7f98 resolve
//     0xacc4 keyValue            0xaf78 rawData        0xb194 keyListDesc
//     0xb5ac byName              0xb7a8 createColor    0x4cfc HasLayeredPrimaryResource
//

#import "FGInternal.h"
#import "FGPrivateCalls.h"
#import <dlfcn.h>
#import <compression.h>

@implementation NGRendition @end
@implementation NGLayerRef @end
@implementation NGCatalogIndex @end
@implementation NGGradient @end

#pragma mark - ISTC 容器布局
//
//  NGRendition.csi:
//    +0x000 u32 magic = 'ISTC' (0x43545349)
//    +0x00C u32 width
//    +0x010 u32 height
//    +0x018 u32 pixelFormat
//    +0x024 u16 layout
//    +0x028 char name[0x80]   (NUL 结尾)
//    +0x0A8 u32 recordsSize   —— 0x0B8 起的记录区长度
//    +0x0B4 u32 payloadSize   —— 0x0B8+recordsSize 起的主数据块长度
//    +0x0B8 记录区: { u32 tag; u32 len; u8 payload[len]; } * N
//
//  记录 tag 与 rendition.layout 共用同一套值：
//    0x3F4 图层表（frame / blendMode / opacity / keyList）
//    0x3FC 组（lighting / blur / fill）
//    0x3FD 填充（specular / translucency / shadow）
//    0x3FB iconstack
//    0x3F9 / 9 图像（SVG 或 CUIImage）

#define ISTC_HEADER   0xB8
#define ISTC_RECORDS  0xA8
#define ISTC_PAYLOAD  0xB4

static const uint8_t *FGPayload(NGRendition *r, uint32_t *outLen) {
    NSData *csi = r.csi;
    if (csi.length < ISTC_HEADER) return NULL;
    const uint8_t *base = csi.bytes;
    uint32_t recSize = *(const uint32_t *)(base + ISTC_RECORDS);
    uint32_t paySize = *(const uint32_t *)(base + ISTC_PAYLOAD);
    if ((size_t)ISTC_HEADER + recSize + paySize > csi.length) return NULL;
    if (outLen) *outLen = paySize;
    return base + ISTC_HEADER + recSize;
}

#pragma mark - keyValue / keyListDesc / byName

uint16_t FGKeyValue(NGRendition *r, uint16_t key) {
    NSData *kd = r.key;
    if (kd.length < 4) return 0;
    const uint8_t *p = kd.bytes;
    for (NSUInteger i = 0; i < kd.length / 4; i++) {
        if (*(const uint16_t *)(p + i * 4) == key) return *(const uint16_t *)(p + i * 4 + 2);
    }
    return 0;
}

NSString *FGKeyListDesc(NSData *keyList) {
    NSMutableString *s = [NSMutableString string];
    if (keyList.length >= 4) {
        const uint8_t *p = keyList.bytes;
        for (NSUInteger i = 0; i + 4 <= keyList.length; i += 4) {
            uint16_t k = *(const uint16_t *)(p + i);
            if (k == 0) break;
            [s appendFormat:@"%u=%u ", (unsigned)k, (unsigned)*(const uint16_t *)(p + i + 2)];
        }
    }
    return s;
}

NGRendition *FGByName(NGCatalogIndex *index, NSString *name, uint16_t theme) {
    NGRendition *themed = nil, *plain = nil;
    for (NGRendition *r in index.renditions) {
        if (![r.name isEqualToString:name]) continue;
        uint16_t kv = FGKeyValue(r, 7);
        if (kv == theme) return r;
        if (kv != 0) { if (!themed) themed = r; }
        else         { if (!plain)  plain  = r; }
    }
    return plain ?: themed;
}

#pragma mark - 资源块

NSData *FGRawData(NGRendition *r) {
    uint32_t paySize = 0;
    const uint8_t *p = FGPayload(r, &paySize);
    if (!p) return nil;
    if (paySize < 0x0C || *(const uint32_t *)p != 0x52415744 /* 'DWAR' */) {
        return [NSData dataWithBytes:p length:paySize];
    }

    uint32_t unpacked = *(const uint32_t *)(p + 8);
    uint32_t payloadLen = paySize - 0x0C;
    uint32_t compLen = (unpacked < payloadLen) ? unpacked : payloadLen;
    uint8_t flags = *(const uint8_t *)(p + 4);

    if ((flags & 1) == 0) return [NSData dataWithBytes:p + 0x0C length:compLen];
    if (compLen > 0x800000) goto fail;

    {
        size_t cap = (size_t)compLen * 8;
        if (cap < 0x10000) cap = 0x10000;
        for (;;) {
            NSMutableData *buf = [NSMutableData dataWithLength:cap];
            size_t n = compression_decode_buffer(buf.mutableBytes, cap, p + 0x0C, compLen,
                                                 NULL, COMPRESSION_LZFSE);
            if (n == 0) goto fail;
            if (n < cap) { [buf setLength:n]; return buf; }
            if (cap >= 0x01000001) goto fail;
            cap *= 4;
        }
    }
fail:
    if (FGLog) FGLog([NSString stringWithFormat:@"lzfse %@ failed", r.name]);
    return nil;
}

CGColorSpaceRef FGSharedExtendedSRGB(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB); });
    return cs;
}

CGColorRef FGCreateColor(NGRendition *r) {
    uint32_t paySize = 0;
    const uint8_t *p = FGPayload(r, &paySize);
    if (!p || paySize < 0x10) return NULL;
    if (*(const uint32_t *)p != 0x434f4c52 /* 'RLOC' */) return NULL;

    uint32_t n = *(const uint32_t *)(p + 0x0C);
    if (n - 1 > 4) return NULL;
    if ((uint64_t)n * 8 + 0x10 > paySize) return NULL;

    double c[4] = {0, 0, 0, 1};
    c[0] = *(const double *)(p + 0x10);
    if (n >= 2) c[1] = *(const double *)(p + 0x18);
    if (n >= 3) c[2] = *(const double *)(p + 0x20);
    if (n >= 4) c[3] = *(const double *)(p + 0x28);

    double comps[4];
    if (n < 3) {                    // 灰度（n==2 时 alpha 也按 1.0，与原实现一致）
        comps[0] = comps[1] = comps[2] = c[0];
        comps[3] = 1.0;
        return CGColorCreate(FGSharedExtendedSRGB(), comps);
    }
    comps[0] = c[0];
    comps[1] = c[1];
    comps[2] = (n == 3) ? c[2] : c[3];
    comps[3] = (n == 3) ? 1.0  : c[3];

    CGColorSpaceRef space;
    switch (*(const uint32_t *)(p + 0x08)) {
        case 3:  space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3); break;
        case 4:  space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB); break;
        case 5:  space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB); break;
        default: space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); break;
    }
    CGColorRef color = CGColorCreate(space, comps);
    CGColorSpaceRelease(space);
    return color;
}

#pragma mark - CoreSVG

static void *pSVGCreate, *pSVGSize, *pSVGDraw, *pSVGRelease;

static void FGLoadSVG(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_NOW);
        if (!h) return;
        pSVGCreate  = dlsym(h, "CGSVGDocumentCreateFromData");
        pSVGRelease = dlsym(h, "CGSVGDocumentRelease");
        pSVGSize    = dlsym(h, "CGSVGDocumentGetCanvasSize");
        pSVGDraw    = dlsym(h, "CGContextDrawSVGDocument");
    });
}

BOOL FGDrawContents(CGContextRef c, id catalog, NGRendition *r, CGRect frame) {
    if (r.layout == FG_LAYOUT_IMAGE || r.layout == FG_LAYOUT_IMAGE_ALT) {
        NSData *svgData = FGRawData(r);
        if (!svgData) return NO;
        FGLoadSVG();
        if (!pSVGCreate || !pSVGRelease || !pSVGSize || !pSVGDraw) return NO;

        void *svg = ((void *(*)(CFDataRef, void *))pSVGCreate)((__bridge CFDataRef)svgData, NULL);
        if (!svg) return NO;
        CGSize sz = ((CGSize (*)(void *))pSVGSize)(svg);
        BOOL ok = (sz.width > 0 && sz.height > 0);
        if (ok) {
            CGContextSaveGState(c);
            CGContextTranslateCTM(c, frame.origin.x, CGRectGetMaxY(frame));
            CGContextScaleCTM(c, frame.size.width / sz.width, -frame.size.height / sz.height);
            ((void (*)(CGContextRef, void *))pSVGDraw)(c, svg);
            CGContextRestoreGState(c);
        }
        ((void (*)(void *))pSVGRelease)(svg);
        return ok;
    }

    // 非 SVG：借 IconServices 的 _themeStore + renditionWithKey: + unslicedImage
    @try {
        NSMutableData *key = [[r key] mutableCopy] ?: [NSMutableData data];
        [key increaseLengthBy:8];

        SEL selStore   = NSSelectorFromString(@"_themeStore");
        SEL selRend    = NSSelectorFromString(@"renditionWithKey:");
        SEL selImage   = NSSelectorFromString(@"unslicedImage");

        id store = FGPrivateObject(catalog, selStore);
        if (!FGMethodIs(FGGetMethod(store, selRend), 1, "@", "^", NULL)) return NO;
        NS_VALID_UNTIL_END_OF_SCOPE id themeRendition =
            ((id (*)(id, SEL, const void *))objc_msgSend)(store, selRend, key.bytes);
        if (!FGMethodIs(FGGetMethod(themeRendition, selImage), 0, @encode(CGImageRef), NULL, NULL)) return NO;
        CGImageRef img = ((CGImageRef (*)(id, SEL))objc_msgSend)(themeRendition, selImage);
        if (!img) return NO;

        CGContextSaveGState(c);
        CGContextTranslateCTM(c, frame.origin.x, CGRectGetMaxY(frame));
        CGContextScaleCTM(c, 1.0, -1.0);
        CGContextDrawImage(c, CGRectMake(0, 0, frame.size.width, frame.size.height), img);
        CGContextRestoreGState(c);
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

#pragma mark - 图层表 / 解析

// 原 0x7e68 layerRefs：遍历 csi 记录区，按 tag 分三趟填同一批 NGLayerRef。
NSArray *FGLayerRefs(NSData *csi) {
    NSMutableArray *refs = [NSMutableArray array];
    if (csi.length < ISTC_HEADER) return refs;

    const uint8_t *base = csi.bytes;
    uint32_t recSize = *(const uint32_t *)(base + ISTC_RECORDS);
    if ((size_t)ISTC_HEADER + recSize > csi.length || recSize < 8) return refs;

    const uint8_t *p   = base + ISTC_HEADER;
    const uint8_t *end = p + recSize;

    while (p + 8 <= end) {
        uint32_t tag = *(const uint32_t *)p;
        uint32_t len = *(const uint32_t *)(p + 4);
        const uint8_t *body = p + 8;
        const uint8_t *bodyEnd = body + len;
        if (bodyEnd > end) break;

        if (tag == 0x3F4) {
            // 图层表：count + count 条 {flags, x, y, w, h, blendMode, opacity, keyLen, key[]}
            uint32_t count = len >= 8 ? *(const uint32_t *)body : 0;
            if (count && len >= 0x28) {
                const uint8_t *entry = body + 8;
                for (uint32_t i = 0; i < count; i++) {
                    if (entry + 0x20 > bodyEnd) break;
                    NGLayerRef *layer = [NGLayerRef new];
                    layer.flags = *(const uint32_t *)(entry);
                    layer.frame = CGRectMake((double)(int32_t)*(const uint32_t *)(entry + 0x04),
                                             (double)(int32_t)*(const uint32_t *)(entry + 0x08),
                                             (double)*(const uint32_t *)(entry + 0x0C),
                                             (double)*(const uint32_t *)(entry + 0x10));
                    layer.blendMode = *(const uint32_t *)(entry + 0x14);
                    layer.opacity   = *(const float *)(entry + 0x18);
                    uint32_t keyLen = *(const uint32_t *)(entry + 0x1C);
                    const uint8_t *keys = entry + 0x20;
                    if (keys + keyLen > bodyEnd) break;
                    layer.keyList = [NSData dataWithBytes:keys length:keyLen];
                    [refs addObject:layer];
                    entry = keys + keyLen;
                }
            }
        } else if (tag == 0x3FC) {
            uint32_t count = len >= 0x14 ? *(const uint32_t *)body : 0;
            if (count) {
                const uint8_t *entry = body + 8;
                for (uint32_t i = 0; i < count && i < refs.count; i++) {
                    if (entry + 0x0C > bodyEnd) break;
                    NGLayerRef *layer = refs[i];
                    layer.lighting = (*(const uint32_t *)entry & 1) != 0;
                    layer.blur     = *(const float *)(entry + 4);
                    uint32_t fillLen = *(const uint32_t *)(entry + 8);
                    if (fillLen && entry + 0x0C + fillLen <= bodyEnd) {
                        NSString *s = [[NSString alloc] initWithBytes:entry + 0x0C
                                                              length:fillLen - 1
                                                            encoding:NSUTF8StringEncoding];
                        if (s) layer.fill = s;
                    }
                    entry += 0x0C + fillLen;
                }
            }
        } else if (tag == 0x3FD) {
            uint32_t count = len >= 4 ? *(const uint32_t *)body : 0;
            if (count) {
                const uint8_t *q = body + 8;
                for (uint32_t i = 0; i < count && i < refs.count; i++) {
                    if (q + 0x10 > bodyEnd) break;
                    NGLayerRef *layer = refs[i];
                    layer.specular      = (*(const uint32_t *)q & 1) != 0;
                    layer.translucency  = *(const float *)(q + 4);
                    layer.shadowStyle   = *(const uint32_t *)(q + 8);
                    layer.shadowOpacity = *(const float *)(q + 12);
                    q += 0x14;
                }
            }
        }
        p = bodyEnd;
    }
    return refs;
}

// 原 0x7f98 resolve：keyList 是 (u16 key, u16 value) 对，全部命中且 key7 == theme 才算匹配。
NGRendition *FGResolve(id catalog, NSData *keyList, uint16_t theme) {
    NGCatalogIndex *index = FGIndexFor(catalog);
    if (!index) return nil;

    const uint8_t *p = keyList.bytes;
    NSUInteger pairs = keyList.length / 4;

    NGRendition *themed = nil, *plain = nil;
    for (NGRendition *r in index.renditions) {
        BOOL match = YES;
        for (NSUInteger i = 0; i < pairs; i++) {
            uint16_t k = *(const uint16_t *)(p + i * 4);
            uint16_t v = *(const uint16_t *)(p + i * 4 + 2);
            if (k == 0) break;
            if (FGKeyValue(r, k) != v) { match = NO; break; }
        }
        if (!match) continue;

        uint16_t kv = FGKeyValue(r, 7);
        if (kv == theme) { themed = r; break; }
        if (kv == 0) plain = r;
    }
    return themed ?: plain;
}

#pragma mark - findStack / indexFor / HasStack

// 原 0x5114：iconstack 的 name 是 name + ".iconstack"，layout 必须是 0x3FB。
id FGFindStack(NGCatalogIndex *index, NSString *name, uint32_t appearance) {
    if (!index || !name) return nil;

    NSString *stackName = [name stringByAppendingString:@".iconstack"];
    NSString *appKey = (appearance == 2) ? @"ISAppearanceTintable"
                     : (appearance == 1) ? @"UIAppearanceDark"
                                         : @"UIAppearanceLight";
    NSNumber *appNum = index.appearances[appKey];
    uint16_t want = (uint16_t)[appNum unsignedShortValue];

    NGRendition *fallback = nil;
    for (NGRendition *r in index.renditions) {
        if (r.layout != 0x3FB) continue;
        if (![r.name isEqualToString:stackName]) continue;
        uint16_t kv = FGKeyValue(r, 7);
        if (kv == want) return r;
        if (!fallback || kv == 0) fallback = r;
    }
    return (appearance == 0) ? fallback : nil;
}

BOOL FGHasStack(id catalog, NSString *name) {
    return FGFindStack(FGIndexFor(catalog), name, 0) != nil;
}

// 原 0xada8：themeStore 的 (key, chunk) 逐条转成 NGRendition
static void FGAddRendition(NSMutableArray *rends, const void *keyTokens,
                           NSUInteger tokenCount, id chunk) {
    if (![chunk isKindOfClass:[NSData class]]) return;
    NSData *data = chunk;
    if (data.length < ISTC_HEADER) return;
    const uint8_t *p = data.bytes;
    if (*(const uint32_t *)p != 0x43545349 /* 'ISTC' */) return;

    NGRendition *r = [NGRendition new];
    r.layout      = *(const uint16_t *)(p + 0x24);
    r.width       = *(const uint32_t *)(p + 0x0C);
    r.height      = *(const uint32_t *)(p + 0x10);
    r.pixelFormat = *(const uint32_t *)(p + 0x18);
    r.csi         = data;

    NSString *name = [[NSString alloc] initWithBytes:p + 0x28
                                              length:strnlen((const char *)p + 0x28, 0x80)
                                            encoding:NSUTF8StringEncoding];
    r.name = name ?: @"";

    if (keyTokens) {
        const uint8_t *q = keyTokens;
        NSUInteger n = 0;
        NSUInteger limit = tokenCount + 4;
        while (n < limit) {
            if (*(const uint16_t *)(q + n * 4) == 0) break;
            n++;
        }
        r.key = [NSData dataWithBytes:keyTokens length:n * 4];
    }
    [rends addObject:r];
}

static const void *kFGIndexKey = &kFGIndexKey;

// 原 0x53ac indexFor：把 catalog 的 themeStore 一次性物化，并作为关联对象缓存。
NGCatalogIndex *FGIndexFor(id catalog) {
    if (!catalog) return nil;
    @synchronized (catalog) {
        NGCatalogIndex *cached = objc_getAssociatedObject(catalog, kFGIndexKey);
        if (cached) return cached;

        NGCatalogIndex *index = [NGCatalogIndex new];

        @try {
            id store = FGPrivateObject(catalog, NSSelectorFromString(@"_themeStore"));
            id themeStore = FGPrivateObject(store, NSSelectorFromString(@"themeStore"));
            SEL enumSel = @selector(enumerateKeysAndObjectsUsingBlock:);
            SEL formatSel = NSSelectorFromString(@"keyFormat");
            if (!FGMethodIs(FGGetMethod(themeStore, formatSel), 0, "^", NULL, NULL) ||
                !FGMethodIs(FGGetMethod(themeStore, enumSel), 1, "v", "@?", NULL) ||
                [themeStore isKindOfClass:[NSDictionary class]]) return nil;

            // Original contract: { u32, u32, u32 count, u32 tokens[] } owned by
            // the theme store. KVC may box pointers; never reinterpret an object.
            const uint32_t *format = ((const uint32_t *(*)(id, SEL))objc_msgSend)(themeStore, formatSel);
            if (!format) return nil;
            uint32_t tokenCount = format[2];
            if (tokenCount == 0 || tokenCount > 64) return nil;
            NSMutableArray *tokens = [NSMutableArray arrayWithCapacity:tokenCount];
            for (uint32_t i = 0; i < tokenCount; i++) [tokens addObject:@(format[3 + i])];
            index.tokens = tokens;

            id appearances = FGPrivateObject(themeStore, @selector(appearances));
            if ([appearances isKindOfClass:[NSDictionary class]]) index.appearances = appearances;

            // Original block type v24@?0r^v8@16: not NSDictionary's
            // (id key, id value, BOOL *stop). The raw key is only used synchronously.
            NSMutableArray *rends = [NSMutableArray array];
            ((void (*)(id, SEL, void (^)(const void *, id)))objc_msgSend)(themeStore, enumSel,
                ^(const void *key, id value) {
                    if (key) FGAddRendition(rends, key, tokenCount, value);
                });
            index.renditions = rends;
            objc_setAssociatedObject(catalog, kFGIndexKey, index, OBJC_ASSOCIATION_RETAIN);
            return index;
        } @catch (__unused NSException *e) {
            return nil;
        }
    }
}

#pragma mark - HasLayeredPrimaryResource

// 原 0x4cfc HasLayeredPrimaryResource
//
// 判据链：hook 已装 -> 取 resourceProvider -> resourceNamed:kISPrimaryResourceKey
//         -> 结果必须是 ISAssetCatalogResource -> 且它的 catalog 里有同名 iconstack。
BOOL FGHasLayeredPrimaryResource(id self) {
    static NSString *primaryKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void **sym = (void **)dlsym(RTLD_DEFAULT, "kISPrimaryResourceKey");
        NSString *key = @"kISPrimaryResourceKey";
        if (sym && *sym) key = (__bridge NSString *)(*sym);
        primaryKey = [key copy];
    });

    id provider = nil;
    @try { provider = [self valueForKey:@"resourceProvider"]; } @catch (__unused NSException *e) {}
    SEL named = @selector(resourceNamed:);
    if (!FGOriginalResourceImage || !FGResourceClass ||
        !FGMethodIs(FGGetMethod(provider, named), 1, "@", "@", NULL)) return NO;

    @try {
        id resource = ((id (*)(id, SEL, NSString *))objc_msgSend)(provider, named, primaryKey);
        if (![resource isKindOfClass:FGResourceClass]) return NO;
        id catalog2 = FGPrivateObject(resource, @selector(catalog));
        NSString *imageName = FGPrivateObject(resource, @selector(imageName));
        return catalog2 && [imageName isKindOfClass:[NSString class]] && FGHasStack(catalog2, imageName);
    } @catch (__unused NSException *e) {
        return NO;
    }
}
