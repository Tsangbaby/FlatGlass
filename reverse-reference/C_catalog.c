// =============================================================================
// FlatGlassIconServices.dylib  (注入 iconservicesagent) — 目录/图标栈解析还原
//
// 来源: arm64 iOS dylib, strip 过符号但保留函数名。
// 本文件只覆盖下列函数（其余同 dylib 的辅助函数以 extern 声明, 属于他人还原范围）:
//   0x5088  NGCatalogHasStack
//   0x5114  findStack
//   0x53ac  indexFor                  (+ 0xada8 __indexFor_block_invoke)
//   0x5764  NGDescribeStack           (+ 0x5948 describe)
//   0x4cfc  HasLayeredPrimaryResource (+ 0x4e20 __HasLayeredPrimaryResource_block_invoke)
//
// arm64 约定: x0..x7 整型/对象参数, v0..v7 浮点/结构体返回, x0/v0 返回值。
//             反汇编里大量 objc_retain / objc_release 是真实调用（-O 产物）,
//             本文逐个保留, 便于与地址一一对照; 不影响语义, 但不要当成伪代码噪音。
//
// 说明: 0x149a0 (__DATA_CONST/__got+0x358) 被 d2.py 注解成
//       "SYM ___block_descriptor_32_e8_v12?0i8l", 实际是 __stack_chk_guard 的 GOT
//       槽（每个函数 ldur/stur + 结尾 cmp + __stack_chk_fail）, 本文省略该栈保护层。
// =============================================================================

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>

// -----------------------------------------------------------------------------
// 数据结构（字段偏移全部来自 getter/setter 反汇编, 非猜测）
// -----------------------------------------------------------------------------

// 布局: +0x00 isa
//       +0x08 NSArray      *_renditions   // NGRendition*
//       +0x10 NSArray      *_tokens       // NSNumber*（u32 -> NSNumber）
//       +0x18 NSDictionary *_appearances  // NSString* -> NSNumber*（u16）
@interface NGCatalogIndex : NSObject
{
@public
    NSArray      *_renditions;      // 0x5010 getter: ldr x0,[x0,#8]
    NSArray      *_tokens;          // 0x5024 getter: ldr x0,[x0,#0x10]
    NSDictionary *_appearances;     // 0x5038 getter: ldr x0,[x0,#0x18]
}
- (NSArray *)renditions;
- (void)setRenditions:(NSArray *)v;
- (NSArray *)tokens;
- (void)setTokens:(NSArray *)v;
- (NSDictionary *)appearances;
- (void)setAppearances:(NSDictionary *)v;
@end

// 布局: +0x00 isa
//       +0x08 u32       _layout      // 0x3fb = iconstack 层树, 0x3fc = 同类层树, 9/0x3f9 = 文本(SVG)
//       +0x0c u32       _pixelFormat
//       +0x10 u32       _width
//       +0x14 u32       _height
//       +0x18 NSData   *_key         // 若干 (u16 tokenId, u16 value) 对, 见 "key 编码"
//       +0x20 NSData   *_csi         // "ISTC" 复合图像记录, 见 "CSI 布局"
//       +0x28 NSString *_name        // copy 语义 (objc_setProperty_nonatomic_copy)
@interface NGRendition : NSObject
{
@public
    uint32_t  _layout;         // +0x08
    uint32_t  _pixelFormat;    // +0x0c
    uint32_t  _width;          // +0x10
    uint32_t  _height;         // +0x14
    NSData   *_key;            // +0x18
    NSData   *_csi;            // +0x20
    NSString *_name;           // +0x28
}
- (NSData *)key;
- (void)setKey:(NSData *)v;
- (NSData *)csi;
- (void)setCsi:(NSData *)v;
- (NSString *)name;
- (void)setName:(NSString *)v;
- (uint32_t)layout;
- (void)setLayout:(uint32_t)v;
- (uint32_t)pixelFormat;
- (void)setPixelFormat:(uint32_t)v;
- (uint32_t)width;
- (void)setWidth:(uint32_t)v;
- (uint32_t)height;
- (void)setHeight:(uint32_t)v;
@end

// 布局（getter 反汇编 0x4f14..0x4fd0）:
//   +0x00 isa
//   +0x08 u8      _lighting       // 0x4fa0: ldrb w0,[x0,#8]
//   +0x09 u8      _specular       // 0x4fb0: ldrb w0,[x0,#9]
//   +0x0c u32     _blendMode
//   +0x10 u32     _flags
//   +0x14 f32     _opacity
//   +0x18 f32     _blur
//   +0x1c f32     _translucency
//   +0x20 u32     _shadowStyle
//   +0x24 f32     _shadowOpacity
//   +0x28 NSData *_keyList        // (u16,u16) 对, 供 resolve 用
//   +0x30 id      _fill           // NGGradient* / 颜色对象
//   +0x38 CGRect  _frame          // 4x double: 0x38(x) 0x40(y) 0x48(w) 0x50(h)
@interface NGLayerRef : NSObject
{
@public
    uint8_t   _lighting;       // +0x08
    uint8_t   _specular;       // +0x09
    uint32_t  _blendMode;      // +0x0c
    uint32_t  _flags;          // +0x10
    float     _opacity;        // +0x14
    float     _blur;           // +0x18
    float     _translucency;   // +0x1c
    uint32_t  _shadowStyle;    // +0x20
    float     _shadowOpacity;  // +0x24
    NSData   *_keyList;        // +0x28
    id        _fill;           // +0x30
    CGRect    _frame;          // +0x38
}
- (CGRect)frame;
- (uint32_t)blendMode;
- (uint32_t)flags;
- (float)opacity;
- (float)blur;
- (float)translucency;
- (uint8_t)lighting;
- (uint8_t)specular;
- (uint32_t)shadowStyle;
- (float)shadowOpacity;
- (NSData *)keyList;
- (id)fill;
@end

// 布局: +0x08 i64 _type, +0x10 CGPoint _start, +0x20 CGPoint _end,
//       +0x30 NSArray *_colors, +0x38 NSArray *_stops
@interface NGGradient : NSObject
@end

// -----------------------------------------------------------------------------
// 外部符号 / 同 dylib 内其它函数（不在本次还原范围, 仅声明）
// -----------------------------------------------------------------------------

// 0xacc4: 在 rendition.key 的 (u16 tokenId, u16 value) 序列里按 tokenId 查 value;
//         找不到返回 0。任务确认由他人还原, 这里假定存在。
extern uint16_t keyValue(NGRendition *r, uint16_t key);

// 0x4c88: KVC 读属性, @try/@catch 包裹 valueForKey:, 异常返回 nil。
extern id ReadProperty(id obj, NSString *key);

// 0xaf78: 把 rendition.csi 里的载荷解出来（遇 "DWAR" 块且 flags&1 时用 lzfse 解压:
//         compression_decode_buffer(..., 0x801)）。
extern NSData *rawData(NGRendition *r);

// 0x7e68: 解析 csi 的图层数组（NSArray<NGLayerRef*>）。
extern NSArray *layerRefs(NSData *csi);

// 0x7f98: 用 keyList + appearance 在 index.renditions 里找匹配的 rendition。
extern NGRendition *resolve(NGCatalogIndex *index, NSData *keyList, uint16_t appearance);

// 0xb194: (u16,u16) 对序列 -> "%u=%u " 拼接串, 首个 u16==0 停止。
extern NSString *keyListDesc(NSData *keyList);

// 0x18da8: 全局日志回调（由外部注入, 本 dylib 只读不写）。
//          调用处是 `blr x24`, 仅传 x0 = NSString*, 所以是函数指针, 不是 block。
extern void (*NGLog)(NSString *message);

// 0x18d40 / 0x18d48: 由 0x4000 _StartFlatGlassIconServices 写入:
//   ResourceClass         = objc_getClass("ISAssetCatalogResource")
//   OriginalResourceImage = 被替换掉的 -[ISAssetCatalogResource imageForSize:scale:] 原 IMP
//                           (非空 == hook 已安装; 见 0x41a8 method_getImplementation)
extern Class ResourceClass;
extern IMP   OriginalResourceImage;

// =============================================================================
// key / 令牌编码（findStack、block、describe 共同使用）
//   NGRendition._key 是若干 4 字节单元:
//     +0x00 u16 tokenId      // 与 index.tokens 下标对应
//     +0x02 u16 value
//   tokenId == 7 是 appearance 槽位（findStack / NGDescribeStack 都用 keyValue(r, 7)）。
//   index.appearances 的值就是某个 appearance key 对应的 token#7 目标值(u16)。
// =============================================================================

// =============================================================================
// 1) NGCatalogHasStack — 0x5088, 0x3c 字节
//    BOOL NGCatalogHasStack(id catalog, NSString *name)
//      == findStack(indexFor(catalog), name, 0) != nil
// =============================================================================
// @addr 0x5088 NGCatalogHasStack
BOOL NGCatalogHasStack(id catalog, NSString *name)
{
    // 0x5098: cbz x1 -> 返回 NO（name == nil）
    if (name == nil)
        return NO;

    objc_retain(catalog);                    // 0x509c..0x50a4  (x19 = catalog)
    NSString *n = objc_retain(name);         // 0x50a0..0x50a8  (x20)

    NGCatalogIndex *index = indexFor(catalog);                  // 0x50b0  bl 0x53ac
    index = objc_retainAutoreleasedReturnValue(index);          // 0x50b8

    // 0x50c8: x2 = 0 -> appearance = light/默认
    NGRendition *stack = findStack(index, n, 0);                // bl 0x5114
    stack = objc_retainAutoreleasedReturnValue(stack);          // 0x50d0

    objc_release(n);                         // 0x50dc
    BOOL has = (stack != NULL);              // 0x50e0 cmp / 0x50e4 cset
    objc_release(stack);                     // 0x50ec
    objc_release(index);                     // 0x50f4
    return has;
}

// =============================================================================
// 2) findStack — 0x5114 .. 0x53ac (0x298 字节)
//    NGRendition *findStack(NGCatalogIndex *index, NSString *name, uint64_t appearance)
//
//    appearance 编码（0x5178..0x51a0 的 csel 链）:
//      0 (以及 >2) -> @"UIAppearanceLight"
//      1           -> @"UIAppearanceDark"
//      2           -> @"ISAppearanceTintable"
//    want = [index.appearances[key] unsignedShortValue]
//
//    匹配规则:
//      layout == 0x3fb 且 name == name + ".iconstack" 且 keyValue(r,7) == want  -> 命中
//      否则记录候选: 优先 token#7 == 0（默认外观）的那一条, 否则第一条同名
//      枚举结束: appearance == 0 时返回候选, 否则返回 nil
// =============================================================================
// @addr 0x5114 findStack
NGRendition *findStack(NGCatalogIndex *index, NSString *name, uint64_t appearance)
{
    objc_retain(index);                          // 0x514c  (x19 = index)
    name = objc_retain(name);                    // 0x5154  (sp+0x10)

    // 0x5168: [name stringByAppendingString:@".iconstack"]
    NSString *stackName = [name stringByAppendingString:@".iconstack"];   // x21
    stackName = objc_retainAutoreleasedReturnValue(stackName);

    // 0x5178..0x51a0: appearance -> 字典 key
    NSString *appearanceKey =
          (appearance == 2) ? @"ISAppearanceTintable"     // CFSTR 0x14500
        : (appearance == 1) ? @"UIAppearanceDark"         // CFSTR 0x144e0
        :                     @"UIAppearanceLight";       // CFSTR 0x14520
    appearanceKey = objc_retain(appearanceKey);           // 0x51a4 (x23)

    NSDictionary *apps = [index appearances];             // 0x51b0
    apps = objc_retainAutoreleasedReturnValue(apps);      // x24
    NSNumber *appNum = apps[appearanceKey];               // 0x51c4 objectForKeyedSubscript:
    appNum = objc_retainAutoreleasedReturnValue(appNum);  // x25
    objc_release(appearanceKey);                          // 0x51d8
    uint16_t want = [appNum unsignedShortValue];          // 0x51e0 (x23 复用为 want)
    objc_release(appNum);                                 // 0x51ec
    objc_release(apps);                                   // 0x51f4

    NGRendition *fallback = nil;      // x24
    NGRendition *found    = nil;      // x22
    NSArray *renditions = [index renditions];             // 0x520c
    renditions = objc_retainAutoreleasedReturnValue(renditions);   // x25

    for (NGRendition *r in renditions) {                  // 0x5228 countByEnumerating...
        // 0x52b0: 只有 layout == 0x3fb (1019) 才可能是 iconstack
        if ([r layout] != 0x3fb)
            continue;

        // 0x52bc..0x52e4: 名字必须等于 name + ".iconstack"
        NSString *rn = [r name];
        rn = objc_retainAutoreleasedReturnValue(rn);              // x28
        BOOL sameName = [rn isEqualToString:stackName];           // 0x52d4
        objc_release(rn);                                         // 0x52e0
        if (!sameName)
            continue;

        uint16_t kv = keyValue(r, 7);                     // 0x52e8  token#7 = appearance
        if (kv == want) {
            found = objc_retain(r);                       // 0x5314
            objc_release(renditions);                     // 0x5320
            goto epilogue;                                // -> 0x534c
        }

        // 0x52fc..0x5310: if (fallback == nil || keyValue(r,7) == 0) fallback = retain(r);
        if (fallback == NULL || kv == 0) {
            NGRendition *n2 = objc_retain(r);             // 0x5268..0x5270
            objc_release(fallback);                       // 0x5274
            fallback = n2;
        }
    }

    objc_release(renditions);                             // 0x5334
    // 0x5338..0x5348: 只有 appearance == 0 才回退; 1/2 必须精确命中
    found = (appearance == 0) ? objc_retain(fallback) : nil;

epilogue:
    // 0x534c..0x5368
    objc_release(fallback);
    objc_release(stackName);
    objc_release(name);
    objc_release(index);
    return found;                                         // 0x53a4 autoreleaseReturnValue
}

// =============================================================================
// 3) indexFor — 0x53ac .. 0x5764
//    把 catalog（ISAssetCatalogResource 之类）背后的 ISThemeStore "物化"为
//    NGCatalogIndex, 并作为关联对象缓存（@synchronized(catalog) 保护）。
//
//    associated(catalog, &kIndexKey) ? 返回
//    store      = [catalog  valueForKey:@"_themeStore"]   (KVC, 可能抛异常)
//    themeStore = [store    valueForKey:@"themeStore"]    (KVC, 可能抛异常)
//    keyFormat  = [themeStore valueForKey:@"keyFormat"]   -> u32 数组 -> index.tokens
//    appearances= [themeStore valueForKey:@"appearances"] -> index.appearances（原样）
//    renditions = [themeStore enumerateKeysAndObjectsUsingBlock:] 逐条解析 CSI
//
//    注意: 这三处 valueForKey: 都是 NSSelectorFromString + objc_msgSend 形式
//          （strip 后无法 @selector）, 目标 selector 名取自 CFSTR:
//          0x143a0 "_themeStore", 0x143c0 "themeStore",
//          0x14340 "keyFormat",  0x14360 "appearances"。
//    异常表: 3 个 landing pad
//          0x5728 -> store = nil        （覆盖 "_themeStore"）
//          0x5708 -> themeStore = nil   （覆盖 "themeStore" -> no storage）
//          0x56ec -> 跳过 keyFormat/appearances 段, 继续枚举 renditions
// =============================================================================

// 0x18d69: static char kIndexKey;（取地址当 key）
static char kIndexKey;

// CSI 布局（"ISTC" 记录, 由 __indexFor_block_invoke 与 rawData(0xaf78) 共同揭示）:
//   +0x00 u32  magic       'ISTC' (0x54435349, 小端字节 "ISTC")
//   +0x04 u32  ?            // TODO(未确定)
//   +0x08 u32  ?
//   +0x0c u32  width                     -> NGRendition.width
//   +0x10 u32  height                    -> NGRendition.height
//   +0x14 u32  ?
//   +0x18 u32  pixelFormat               -> NGRendition.pixelFormat
//   +0x1c u32  ?
//   +0x20 u32  ?
//   +0x24 u16  layout                    -> NGRendition.layout (0x3fb == iconstack)
//   +0x26 u16  ?
//   +0x28 char name[0x80]                -> NGRendition.name (strnlen(..,0x80), UTF-8)
//   +0xa8 u32  payload 偏移修正量         // rawData: 载荷起点 = 0xb8 + 该值
//   +0xac u32  ?                          // TODO(未确定)
//   +0xb0 u32  ?                          // TODO(未确定)
//   +0xb4 u32  payloadLength              // rawData: 载荷可用长度
//   +0xb8 ...  载荷（可能再套一层子块）
// 记录长度下限 0xb8; 取子块前还会校验剩余长度 >= 0xc。
// 子块 "DWAR"（rawData 0xaf78）:
//   +0x00 u32 magic 'DWAR'
//   +0x04 u8  flags      bit0 = lzfse 压缩 -> compression_decode_buffer(.., 0x801)
//   +0x08 u32 解压后长度
//   +0x0c u8[] 数据（未压缩时即原文; 解压时输出缓冲从 8*len 起步, 最多试 4 次翻倍）
// 子块 "ARGG"（_resolve 0x8334 附近）:
//   +0x00 u32 magic 'ARGG'
//   +0x04 u32 ?
//   +0x08 u32 gradient.type -> [NGGradient setType:]
//   +0x0c ... 渐变数据

// @addr 0xada8 __indexFor_block_invoke
//   真实形状（block 捕获布局, 见 0x5584 descriptor "48_e8_32s"）:
//     block +0x00 isa
//     block +0x08 flags = 0xC2000000, reserved = 0   (常量 0x10b50)
//     block +0x10 invoke = 0xada8
//     block +0x18 descriptor = 0x14080
//     block +0x20 NSMutableArray *array      （强引用捕获）
//     block +0x28 NSUInteger      tokenCount （标量捕获）
//   为可读性, 这里写成普通函数 ngParseRendition(array, tokenCount, key, obj)。
static void ngParseRendition(NSMutableArray *array, NSUInteger tokenCount,
                             id key, id obj)
{
    obj = objc_retain(obj);                    // 0xadc8 / 0xadd0（连 retain 两次, 编译器产物）
    obj = objc_retain(obj);                    // x19

    // 0xadd8..0xadf0: [obj isKindOfClass:[NSData class]]
    if (![obj isKindOfClass:[NSData class]])
        goto out;

    // 0xadf8: CSI 记录最短 0xb8 字节
    if ([obj length] < 0xb8)
        goto out;

    // 0xae04..0xae0c: retainAutorelease + bytes
    const uint8_t *bytes = [[obj retain] bytes];

    // 0xae10..0xae1c: magic == 'ISTC'
    if (*(const uint32_t *)bytes != 0x54435349u)     // 'I','S','T','C'
        goto out;

    // 0xae28: layout = *(u16*)(bytes + 0x24)
    uint16_t layout = *(const uint16_t *)(bytes + 0x24);

    NGRendition *r = [NGRendition new];        // 0xae30..0xae38 (objc_opt_new)

    // 0xae3c..0xae70: key 截断长度 = 4 * (第一个 u16==0 的单元下标), 上限 tokenCount+4
    //   注意: 这里把字典 key 对象当**裸字节指针**用（0xae4c mov x10,x23; 直接 ldrh），
    //         没有调用 -bytes。说明 ISThemeStore 枚举出的 key 是内联字节缓冲/裸指针。
    //   TODO(未确定): key 的真实对象类型（若真是 NSData, 此处会读到对象头）。
    NSUInteger n = 0;
    if (tokenCount + 4 != 0) {                 // 0xae40 adds / b.eq 的环绕保护
        size_t limit = tokenCount + 4;
        const uint16_t *units = (const uint16_t *)key;
        while (n < limit) {
            if (units[2 * n] == 0)             // 每个 4 字节单元的第 1 个 u16
                break;
            n++;
        }
    }
    NSData *keyData = [NSData dataWithBytes:key length:4 * n];   // 0xae74..0xae84
    keyData = objc_retainAutoreleasedReturnValue(keyData);       // x23
    [r setKey:keyData];                        // 0xae94
    objc_release(keyData);                     // 0xae9c

    [r setCsi:obj];                                                // 0xaea8
    [r setLayout:layout];                                          // 0xaeb4
    [r setWidth:*(const uint32_t *)(bytes + 0x0c)];                // 0xaeb8
    [r setHeight:*(const uint32_t *)(bytes + 0x10)];               // 0xaec4
    [r setPixelFormat:*(const uint32_t *)(bytes + 0x18)];          // 0xaed0

    // 0xaeec..0xaf08: alloc initWithBytes:bytes+0x28 length:strnlen(..,0x80)
    //                 encoding:NSUTF8StringEncoding(4)
    NSUInteger nameLen = strnlen((const char *)bytes + 0x28, 0x80);
    NSString *nm = [[NSString alloc] initWithBytes:(const char *)bytes + 0x28
                                            length:nameLen
                                          encoding:NSUTF8StringEncoding];
    [r setName:(nm ?: @"")];                   // 0xaf10..0xaf24: nil -> @""
    objc_release(nm);                          // 0xaf2c

    [array addObject:r];                       // 0xaf30..0xaf38
    objc_release(r);                           // 0xaf40

out:
    objc_release(obj);                         // 0xaf44（对应 0xadc8 的 retain）
    objc_release(obj);                         // 0xaf64（尾调用 objc_release, 对应 0xadd0 的 retain）
}

// @addr 0x53ac indexFor
NGCatalogIndex *indexFor(id catalog)
{
    objc_retain(catalog);                       // 0x53cc
    objc_retain(catalog);                       // 0x53d0（同样连 retain 两次, 编译器产物）
    id obj = catalog;                           // x19
    NGCatalogIndex *index = nil;                // x20

    @synchronized (obj) {                       // 0x53d8 objc_sync_enter
        index = objc_getAssociatedObject(obj, &kIndexKey);                   // 0x53e8
        index = objc_retainAutoreleasedReturnValue(index);                   // 0x53f0
        if (index != NULL) {                                             // 0x53f4
            index = objc_retain(index);                                  // 0x53f8
            goto unlock;                                                 // -> 0x5694
        }

        index = [NGCatalogIndex new];            // 0x5404..0x5410 (objc_opt_new)
        id holder = objc_retain(obj);            // 0x5414..0x541c (x21)

        // --- _themeStore ---
        id store = nil;
        @try {
            store = [holder valueForKey:@"_themeStore"];    // 0x5434
        } @catch (id e) {                                   // 0x5728 landing pad
            store = nil;
        }
        store = objc_retainAutoreleasedReturnValue(store);  // 0x543c

        // --- themeStore ---
        id themeStore = nil;
        @try {
            themeStore = [store valueForKey:@"themeStore"]; // 0x5458
        } @catch (id e) {                                   // 0x5708 landing pad
            themeStore = nil;
        }
        themeStore = objc_retainAutoreleasedReturnValue(themeStore);   // 0x5460 (x22)
        objc_release(store);                     // 0x546c
        objc_release(holder);                    // 0x5474

        if (themeStore == NULL) {                // 0x5478 cbz x22
            // 0x5630..0x5668: if (NGLog) NGLog([NSString stringWithFormat:@"no storage for %@", obj]);
            if (NGLog) {
                NSString *msg = [NSString stringWithFormat:@"no storage for %@", obj];
                msg = objc_retainAutoreleasedReturnValue(msg);
                NGLog(msg);                      // 0x5660 blr x24
                objc_release(msg);               // 0x5668
            }
            // 0x566c: 空 index 也缓存（避免反复探测）
            objc_setAssociatedObject(obj, &kIndexKey, index, OBJC_ASSOCIATION_RETAIN);
            index = objc_retain(index);          // 0x5684
            goto unlock;                         // -> 0x568c
        }

        // --- tokens: keyFormat 的 u32 数组 ---
        NSMutableArray *tokens = [NSMutableArray array];    // 0x5498..0x54ac (x23)
        tokens = objc_retainAutoreleasedReturnValue(tokens);
        // keyFormat 内存布局（0x54b4 / 0x54c8 的访存）:
        //   +0x00 u32 ?            // TODO(未确定)
        //   +0x04 u32 ?            // TODO(未确定)
        //   +0x08 u32 count
        //   +0x0c u32 values[count]   // 逐个包成 NSNumber 入 tokens
        // TODO(未确定): valueForKey:@"keyFormat" 的返回值被直接当裸内存指针使用
        //              （全程没有 -bytes 调用）, 说明它返回的是内联缓冲区。
        @try {
            const uint32_t *kf = (const uint32_t *)[themeStore valueForKey:@"keyFormat"];
            if (kf != NULL && kf[2] != 0) {         // 0x54b0 cbz / 0x54b8 cbz
                for (uint32_t i = 0; i < kf[2]; i++)        // 0x54c4..0x5500
                    [tokens addObject:@(kf[3 + i])];        // numberWithUnsignedInt:
            }
        } @catch (id e) {                    // 0x56ec landing pad: 空 catch
        }
        [index setTokens:tokens];                           // 0x5504..0x550c
        NSUInteger tokenCount = [tokens count];              // 0x5510 (x24, 被 block 捕获)

        // --- appearances: themeStore.appearances 原样搬运 ---
        @try {
            NSDictionary *apps = [themeStore valueForKey:@"appearances"];   // 0x5530
            apps = objc_retainAutoreleasedReturnValue(apps);                // 0x5538
            [index setAppearances:apps];                                    // 0x5548
            objc_release(apps);                                            // 0x5550
        } @catch (id e) {                    // 同一个 landing pad
        }
        // TODO(未确定): 若 keyFormat 阶段抛异常, tokenCount(x24) 可能未初始化 —— 原样保留。

        // --- renditions: 枚举 themeStore 的 key/object, 逐条解析 CSI ---
        NSMutableArray *renditions = [NSMutableArray array]; // 0x5554..0x5560 (x24)
        renditions = objc_retainAutoreleasedReturnValue(renditions);

        // 0x5554..0x5590 构造栈上 block literal, 关键字段见 __indexFor_block_invoke 注释
        void (^block)(id, id) = ^(id key, id value) {
            ngParseRendition(renditions, tokenCount, key, value);   // body @ 0xada8
        };
        [themeStore enumerateKeysAndObjectsUsingBlock:block];        // 0x55d4
        // 0x560c: 释放 enumerate 之前 objc_retainBlock 出来的那份拷贝
        //         （ARC 下由 Block_release/objc_release 完成, 此处略）

        [index setRenditions:renditions];                    // 0x55e0..0x55e8
        objc_release(renditions);                            // 0x561c
        objc_release(tokens);                                // 0x5624

        objc_setAssociatedObject(obj, &kIndexKey, index, OBJC_ASSOCIATION_RETAIN);  // 0x5600
        index = objc_retain(index);                          // 0x5604

    unlock:
        // 0x5694: 释放 0x5604 / 0x53f8 那次额外 retain；返回值仍握有 +1 所有权
        //         （调用方统一用 objc_retainAutoreleasedReturnValue 配平）
        objc_release(index);
        objc_sync_exit(obj);                 // 0x56a0
    }

    objc_release(obj);                       // 0x56a4
    objc_release(obj);                       // 0x56ac
    return index;                            // 0x56b4 / 0x56d4 autoreleaseReturnValue
}

// 0x5948 的前置声明（NGDescribeStack 先用到它）
static void describe(NGCatalogIndex *index, NGRendition *r, uint16_t appearance,
                     unsigned depth, NSMutableString *out);

// =============================================================================
// 4a) NGDescribeStack — 0x5764 .. 0x5948
//     NSString *NGDescribeStack(id catalog, NSString *name, uint64_t appearance)
//     调试输出: appearances 字典 + renditions 数量 + 目标 stack 的完整层级树。
//     （本 dylib 里没有 getenv 开关; 是否打印/打印到哪由调用方 & NGLog 决定,
//       本函数只负责拼字符串返回。）
// =============================================================================
// @addr 0x5764 NGDescribeStack
NSString *NGDescribeStack(id catalog, NSString *name, uint64_t appearance)
{
    name = objc_retain(name);                 // 0x5788..0x5790 (x22)

    NGCatalogIndex *index = indexFor(catalog);            // 0x5798
    index = objc_retainAutoreleasedReturnValue(index);    // 0x57a0 (x19)

    // 0x57b0..0x57ec: appearances.description 去掉所有换行
    NSDictionary *apps = [index appearances];             // 0x57b0
    apps = objc_retainAutoreleasedReturnValue(apps);      // x23
    NSString *appsDesc = [apps description];              // 0x57c0
    appsDesc = objc_retainAutoreleasedReturnValue(appsDesc);          // x24
    NSString *flat = [appsDesc stringByReplacingOccurrencesOfString:@"\n"  // CFSTR 0x142a0
                                                        withString:@""];  // CFSTR 0x142c0
    flat = objc_retainAutoreleasedReturnValue(flat);                  // x25

    // 0x57f0..0x5818: renditions 数量
    NSArray *renditions = [index renditions];             // 0x57f4
    renditions = objc_retainAutoreleasedReturnValue(renditions);      // x26
    NSUInteger count = [renditions count];                // 0x5804
    // 0x5814: +stringWithFormat: 发给 NSMutableString 类（返回可变实例, 后面能 appendString:）
    NSMutableString *out = [NSMutableString stringWithFormat:
                            @"appearances=%@ renditions=%lu\n", flat, (unsigned long)count];
    out = objc_retainAutoreleasedReturnValue(out);                    // x20
    objc_release(renditions);       // 0x5828
    objc_release(flat);             // 0x5830
    objc_release(appsDesc);         // 0x5838
    objc_release(apps);             // 0x5840

    // 0x5854: stack = findStack(index, name, appearance)
    NGRendition *stack = findStack(index, name, appearance);
    stack = objc_retainAutoreleasedReturnValue(stack);                // x23
    objc_release(name);             // 0x5868

    if (stack != NULL) {
        // 0x5870..0x58a0: 再做一次 appearance -> 字典 key 映射
        NSString *appKey =
              (appearance == 2) ? @"ISAppearanceTintable"
            : (appearance == 1) ? @"UIAppearanceDark"
            :                     @"UIAppearanceLight";
        appKey = objc_retain(appKey);                    // x21
        NSDictionary *apps2 = [index appearances];       // 0x58a4
        apps2 = objc_retainAutoreleasedReturnValue(apps2);            // x22
        NSNumber *num = apps2[appKey];                   // 0x58b8
        num = objc_retainAutoreleasedReturnValue(num);                // x24
        objc_release(appKey);                            // 0x58cc
        uint16_t appValue = [num unsignedShortValue];     // 0x58d4 (x21)
        objc_release(num);                               // 0x58e0
        objc_release(apps2);                             // 0x58e8

        // 0x58ec: describe(index, stack, appValue, depth=0, out)
        describe(index, stack, appValue, 0, out);
    } else {
        [out appendString:@"no stack\n"];                // 0x5908..0x5914
    }

    objc_release(stack);            // 0x5918
    objc_release(index);            // 0x5924
    return out;                     // 0x5944 autoreleaseReturnValue
}

// =============================================================================
// 4b) describe — 0x5948 .. 0x605c (0x714 字节)
//     void describe(NGCatalogIndex *index, NGRendition *r, uint16_t appearance,
//                   unsigned depth, NSMutableString *out)
//
//     indent = [@"" stringByPaddingToLength:2*depth withString:@" " startingAtIndex:0]
//     先打一行:
//       "%@%@ layout=0x%x %ux%u key[%@]\n"   (indent, name, layout, w, h, key 展开)
//     key 展开: 每个 4 字节单元 "tokenId=value "
//     分支 A  layout == 9 || 0x3f9 : 文本(SVG)
//       rawData -> UTF-8 字符串 -> 正则 (fill|stop-color|opacity|mix-blend-mode)="..."
//       -> 有序去重 -> 用空格拼接 -> "%@  svg %lu bytes: %@\n"
//     分支 B  layout == 0x3fb || 0x3fc : 图层树
//       layerRefs(csi) -> 每个 NGLayerRef 打一行属性, 再 resolve 出子 rendition 递归 (+2 缩进)
//       解析不出则 "%@   UNRESOLVED\n"
// =============================================================================
// @addr 0x5948 describe
static void describe(NGCatalogIndex *index, NGRendition *r, uint16_t appearance,
                     unsigned depth, NSMutableString *out)
{
    index = objc_retain(index);       // 0x5998 (x23)
    r     = objc_retain(r);           // 0x59a0 (x28)
    out   = objc_retain(out);         // 0x59ac (sp+0xb8)

    // 0x59bc..0x59e4: 2*depth 个空格
    NSString *indent = [@"" stringByPaddingToLength:(NSInteger)(2 * depth)
                                         withString:@" "
                                    startingAtIndex:0];
    indent = objc_retainAutoreleasedReturnValue(indent);      // sp+0xc0

    NSString *name = [r name];                                // 0x59ec (x26)
    name = objc_retainAutoreleasedReturnValue(name);
    uint32_t layout = [r layout];                             // 0x59fc (sp+0xc8)
    uint32_t width  = [r width];                              // 0x5a08 (sp+0xa0)
    uint32_t height = [r height];                             // 0x5a14 (x25)

    // ---- key 展开 ----
    // 0x5a24 又 retain 一次 r（x22, 到函数末尾 0x6000 才释放）; 此处按语义直接用 r。
    NSMutableString *keyDesc = [NSMutableString string];      // 0x5a2c..0x5a3c (x28)
    // 0x5a44..0x5a60: [r key] -> retainAutorelease -> bytes（指针靠 autorelease pool 保活）
    const uint8_t *keyBytes = [[r key] bytes];                // x20
    if ([[r key] length] >= 4) {                              // 0x5a80 / 0x5a94
        for (NSUInteger i = 0; i < ([[r key] length] >> 2); i++) {   // 0x5ac4/0x5ae8 每轮重读 length
            uint16_t k = *(const uint16_t *)(keyBytes + 4 * i);      // 0x5aa8
            uint16_t v = *(const uint16_t *)(keyBytes + 4 * i + 2);  // 0x5aac
            [keyDesc appendFormat:@"%u=%u ", k, v];                  // 0x5abc
        }
    }

    // 0x5af8..0x5b1c: 头部行
    [out appendFormat:@"%@%@ layout=0x%x %ux%u key[%@]\n",
                       indent, name, layout, width, height, keyDesc];
    objc_release(keyDesc);   // 0x5b20
    objc_release(name);      // 0x5b2c

    // ---- 分支 A: layout == 9 (0x9) 或 0x3f9 -> 文本(SVG) ----
    if (layout == 0x9 || layout == 0x3f9) {
        NSData *raw = rawData(r);                             // 0x5b68 bl 0xaf78
        raw = objc_retainAutoreleasedReturnValue(raw);        // x24
        NSString *text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
        objc_release(raw);                                    // 0x5b90
        // 0x5b94..0x5bac
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:
                @"(fill|stop-color|opacity|mix-blend-mode)=\"[^\"]*\""   // CFSTR 0x14420
                                                     options:0
                                                       error:NULL];
        re = objc_retainAutoreleasedReturnValue(re);          // x27
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];   // 0x5bc0 (x28)
        set = objc_retainAutoreleasedReturnValue(set);

        if (text == nil) text = @"";                          // 0x5be0..0x5bec csel
        NSArray *matches = [re matchesInString:text
                                       options:0
                                         range:NSMakeRange(0, [text length])];   // 0x5c0c
        matches = objc_retainAutoreleasedReturnValue(matches);                   // x24
        for (NSTextCheckingResult *m in matches) {            // 0x5c28 快速枚举
            NSString *s = [text substringWithRange:[m range]]; // 0x5c6c..0x5c7c
            s = objc_retainAutoreleasedReturnValue(s);
            [set addObject:s];                                // 0x5c94
            objc_release(s);                                  // 0x5c9c
        }
        objc_release(matches);                                // 0x5ccc

        NSUInteger textLen = [text length];                   // 0x5cd4 (x20)
        NSArray *setArray = [set array];                      // 0x5ce0
        setArray = objc_retainAutoreleasedReturnValue(setArray);   // x24
        NSString *joined = [setArray componentsJoinedByString:@" "];  // 0x5cf8 (CFSTR 0x143e0)
        joined = objc_retainAutoreleasedReturnValue(joined);  // x25
        // 0x5d14: [out appendFormat:@"%@  svg %lu bytes: %@\n", indent, textLen, joined]
        [out appendFormat:@"%@  svg %lu bytes: %@\n",
                            indent, (unsigned long)textLen, joined];
        objc_release(joined);       // 0x5d24
        objc_release(setArray);     // 0x5d30
        objc_release(set);          // 0x5d38
        objc_release(re);           // 0x5d40
        objc_release(text);         // 0x5d48
    }

    // ---- 分支 B: layout == 0x3fb 或 0x3fc -> 图层树 ----
    if (layout == 0x3fb || layout == 0x3fc) {
        NSData *csi = [r csi];                                // 0x5d84
        csi = objc_retainAutoreleasedReturnValue(csi);         // x20
        NSArray *layers = layerRefs(csi);                      // 0x5d98 bl 0x7e68
        layers = objc_retainAutoreleasedReturnValue(layers);   // x19
        objc_release(csi);                                     // 0x5dac

        for (NGLayerRef *layer in layers) {                    // 0x5dc4 / 0x5df0
            // 0x5e58..0x5e80: frame 分 4 次调用取（每次一个 double） -> d8..d11
            CGRect f = [layer frame];
            uint32_t blend    = [layer blendMode];             // 0x5e88 (x20)
            float    opacity  = [layer opacity];               // 0x5e94 (d12)
            uint32_t flags    = [layer flags];                 // 0x5ea0 (x25)
            id       fill     = [layer fill];                  // 0x5eac (x27)
            fill = objc_retainAutoreleasedReturnValue(fill);
            int      lighting = [layer lighting];              // 0x5ec0 (x23, u8 提升)
            int      specular = [layer specular];               // 0x5ecc (x26, u8 提升)
            float    transl   = [layer translucency];          // 0x5ed8 (d13)
            float    blur     = [layer blur];                  // 0x5ee4 (d14)
            uint32_t shStyle  = [layer shadowStyle];           // 0x5ef4 (x19)
            float    shOpacity= [layer shadowOpacity];         // 0x5efc (d15)
            NSData  *keyList  = [layer keyList];               // 0x5f08 (x21)
            keyList = objc_retainAutoreleasedReturnValue(keyList);
            NSString *kd = keyListDesc(keyList);               // 0x5f18 bl 0xb194
            kd = objc_retainAutoreleasedReturnValue(kd);       // x22

            // 0x5f5c: 图层行
            [out appendFormat:
                 @"%@ - ref frame=(%g,%g %gx%g) blend=%u op=%.3f flags=%u fill=%@ "
                 @"light=%d spec=%d transl=%.2f blur=%.2f shadow=%u/%.2f keys[%@]\n",
                 indent, f.origin.x, f.origin.y, f.size.width, f.size.height,
                 blend, opacity, flags, fill,
                 lighting, specular, transl, blur, shStyle, shOpacity, kd];
            objc_release(kd);        // 0x5f68
            objc_release(keyList);   // 0x5f70
            objc_release(fill);      // 0x5f78

            // 0x5f80..0x5fac: child = resolve(index, layer.keyList, appearance)
            NSData *kl = [layer keyList];                      // 0x5f84
            kl = objc_retainAutoreleasedReturnValue(kl);       // x19
            NGRendition *child = resolve(index, kl, appearance);   // 0x5fa8 (x23 = index)
            child = objc_retainAutoreleasedReturnValue(child);     // x20
            objc_release(kl);                                  // 0x5fbc

            if (child != NULL) {
                describe(index, child, appearance, depth + 2, out);   // 0x5fdc 递归
            } else {
                [out appendFormat:@"%@   UNRESOLVED\n", indent];       // 0x5e04..0x5e14
            }
            objc_release(child);   // 0x5e18（两条路径汇合处释放, nil 安全）
        }
        objc_release(layers);      // 0x5fe4
    }

    objc_release(indent);   // 0x5ff0
    objc_release(out);      // 0x5ff8
    objc_release(r);        // 0x6000
    objc_release(index);    // 0x6008
}

// =============================================================================
// 5) HasLayeredPrimaryResource — 0x4cfc (0x74) + block 0x4e20 (0x124)
//    BOOL HasLayeredPrimaryResource(id catalog)
//
//    once: primaryKey = dlsym(RTLD_DEFAULT, "kISPrimaryResourceKey") 所指全局里的
//                       NSString* 值; 解引用为空/符号缺失时退回字面量
//                       @"kISPrimaryResourceKey"。
//    然后: provider = [catalog valueForKey:@"resourceProvider"]     (ReadProperty)
//          res      = [provider resourceNamed:primaryKey]
//          res 必须是 ISAssetCatalogResource 且 hook 已安装(OriginalResourceImage != nil)
//          -> NGCatalogHasStack(res.catalog, res.imageName)
// =============================================================================

// 0x18d58: static NSString *primaryKey;
static NSString *primaryKey = nil;
// 0x18d60: static dispatch_once_t once;
static dispatch_once_t ngPrimaryResourceOnce = 0;

// @addr 0x4e20 __HasLayeredPrimaryResource_block_invoke
//   dispatch_once block: 解析 IconServices 的 kISPrimaryResourceKey 常量
static void __HasLayeredPrimaryResource_block_invoke(void *ctx)
{
    (void)ctx;
    // 0x4e28..0x4e34: dlsym(RTLD_DEFAULT /* (void*)-2 */, "kISPrimaryResourceKey")
    void **sym = (void **)dlsym((void *)-2, "kISPrimaryResourceKey");
    NSString *key = @"kISPrimaryResourceKey";            // 0x14240 fallback
    if (sym != NULL) {
        id v = *(id *)sym;                               // 0x4e44 解引用导出全局
        if (v != nil) key = v;                           // 0x4e48 csel
    }
    objc_storeStrong(&primaryKey, key);                  // 0x4e5c
}

// @addr 0x4cfc HasLayeredPrimaryResource
BOOL HasLayeredPrimaryResource(id catalog)
{
    objc_retain(catalog);                                // 0x4d10 (x19)

    // 0x4d1c..0x4d24: dispatch_once（冷路径 0x4e18 -> 0xe4d4 -> dispatch_once）
    dispatch_once(&ngPrimaryResourceOnce, ^{
        __HasLayeredPrimaryResource_block_invoke(NULL);
    });

    // 0x4d28..0x4d38: provider = [catalog valueForKey:@"resourceProvider"]
    id provider = ReadProperty(catalog, @"resourceProvider");        // ReadProperty 0x4c88
    provider = objc_retainAutoreleasedReturnValue(provider);          // x20

    BOOL result = NO;                                    // w22

    // 0x4d44..0x4d50: [provider respondsToSelector:@selector(resourceNamed:)]
    if (![provider respondsToSelector:NSSelectorFromString(@"resourceNamed:")]) {
        objc_release(provider);                          // 0x4df0
        objc_release(catalog);                           // 0x4df8
        return NO;                                       // 0x4ddc -> 0x4e00
    }

    // 0x4d54..0x4d6c: res = [provider resourceNamed:primaryKey]
    id res = [provider resourceNamed:primaryKey];
    res = objc_retainAutoreleasedReturnValue(res);        // x21

    // 0x4d70..0x4d8c: hook 已装 && res 是 ISAssetCatalogResource
    if (OriginalResourceImage == NULL || ![res isKindOfClass:ResourceClass]) {
        result = NO;                                     // 0x4de4
        objc_release(res);                               // 0x4de8
        objc_release(provider);                          // 0x4df0
        objc_release(catalog);                           // 0x4df8
        return NO;
    }

    // 0x4d90..0x4dc0: NGCatalogHasStack([res catalog], [res imageName])
    id cat2 = [res catalog];
    cat2 = objc_retainAutoreleasedReturnValue(cat2);      // x23
    NSString *imageName = [res imageName];
    imageName = objc_retainAutoreleasedReturnValue(imageName);   // x24
    result = NGCatalogHasStack(cat2, imageName);                 // 0x4dc0 bl 0x5088
    objc_release(imageName);                             // 0x4dcc
    objc_release(cat2);                                  // 0x4dd4
    objc_release(res);                                   // 0x4de8

    objc_release(provider);                              // 0x4df0
    objc_release(catalog);                               // 0x4df8
    return result;                                        // 0x4e00
}
