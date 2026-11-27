// ============================================================================
//  FlatGlassIconServices.dylib  —— 由 arm64 反汇编还原的 C / Objective-C 伪代码
//  目标: iOS 26 图标渲染插件 (注入进程 iconservicesagent)
//  本文件覆盖: drawFill / drawElement / keyValue / rawData / keyListDesc / byName
//              createColor / drawContents / 4 个 block invoke + OUTLINED_FUNCTION_0
//
//  说明
//  ----
//  * 二进制已 strip, 但保留了本地符号名 (函数名可直接对上)。
//  * 所有地址均为 __TEXT 段内虚拟地址(未加 ASLR slide), 与 d2.py 输出一致。
//  * 注释里的 "0xXXXX" 是该逻辑对应的指令地址, 便于逐条回查。
//  * objc_msgSend 调用按注释器给出的 selector 展开成 [recv sel:arg] 形式。
//  * 原码明显是 ARC + 手写 CF 内存管理: 反汇编里 _objc_retain/_objc_release
//    成对出现。本伪代码用 objc_retain()/objc_release() 表示这两个 ARC 运行时
//    内建函数(它们不是消息发送), 其余 CF 对象的 retain/release 保留原调用。
//  * 结构体返回 (CGRect / CGAffineTransform) 走 x8 间接结果指针, 伪代码直接写
//    返回值形式。
//
//  寄存器约定(本文件用到的)
//  ------------------------
//  arm64: x0..x7 整型/对象参数, v0..v7 浮点/结构体参数。
//  CGRect  -> v0=x v1=y v2=w v3=h (4 个 double)
//  CGPoint -> v0=x v1=y ;  CGSize -> v0=w v1=h
//  返回值: x0 (整型/对象) / v0,v1 (CGSize)
// ============================================================================


// ---------------------------------------------------------------------------
// 0. 结构体 / 类布局 (由 ivar 段 + 反汇编访问偏移交叉确认)
// ---------------------------------------------------------------------------

// 栈上绘制上下文, 0x68 字节。drawNode/drawElement/drawContents 都用它。
typedef struct DrawCtx {
    size_t            pixelSize;      // +0x00  位图宽(设备像素)
    size_t            pixelSize2;     // +0x08  位图高(设备像素)
    CGAffineTransform ctm;            // +0x10  48 字节
    CGPoint           origin;         // +0x40  画布原点
    CGSize            size;           // +0x50  画布尺寸
    BOOL              foregroundOnly; // +0x60
    // 其余为填充
} DrawCtx;
// 证据: drawElement 里 `ldp x1,x2,[x24]` 取像素宽高建位图;
//       `ldp q0,q1,[x24,#0x10]` + `ldr q0,[x24,#0x30]` 拷 48 字节 CTM 给 ConcatCTM;
//       drawNode 里 `ldp d0,d1,[x22,#0x40]` / `ldp d2,d3,[x22,#0x50]` 取 origin/size。

// NGRendition: 一个"渲染条目"
//   _layout      unsigned int  @0
//   _pixelFormat unsigned int
//   _width       unsigned int
//   _height      unsigned int
//   _key         NSData*       (u16 键值对序列, 见 keyValue)
//   _csi         NSData*       (容器二进制, 见下面的 "ISTC 容器")
//   _name        NSString*
//   属性 getter: layout / pixelFormat / width / height / key / csi / name

// NGLayerRef: 一层的绘制参数
//   _lighting BOOL, _specular BOOL, _blendMode unsigned, _flags unsigned,
//   _opacity float, _blur float, _translucency float, _shadowStyle unsigned,
//   _shadowOpacity float, _keyList NSData*, _fill NSString*, _frame CGRect

// NGCatalogIndex: _renditions NSArray*, _tokens NSArray*, _appearances NSDictionary*

// NGGradient: _type long long, _colors NSArray*, _stops NSArray*,
//             _start CGPoint, _end CGPoint


// ---------------------------------------------------------------------------
// 1. 二进制容器格式 (全部字段小端)
// ---------------------------------------------------------------------------
//
// (1) NGRendition.csi —— "ISTC 容器" (0xb8 字节定长头 + 一个数据块)
//     由 __indexFor_block_invoke(0xada8) 解析:
//       +0x00  u32   magic = 0x43545349 "ISTC"
//       +0x0c  u32   width
//       +0x10  u32   height
//       +0x18  u32   pixelFormat
//       +0x24  u16   layout              <-- drawFill / drawElement 判定的 layout
//       +0x28  char[0x80] name (NUL 结尾, strnlen 上限 0x80)
//       +0xa8  u32   subOff              <-- 数据块相对 0xb8 的偏移
//       +0xb4  u32   subLen              <-- 数据块长度
//       +0xb8  ...   数据块本体 (地址 = csi.bytes + 0xb8 + subOff)
//     最小长度 0xb8。注意 +0xa8/+0xb4 这一对在本文件 3 个函数里反复出现,
//     说明"一个 rendition 只有一个主数据块"。
//
//     drawFill / createColor / rawData 都按同一套寻址取块, 再按块自己的 magic 分流:
//
//       magic 0x47475241 "ARGG"  -> 渐变: 头 0x20 字节, 带 start/end 点
//       magic 0x41475241 "ARGA"  -> 渐变: 头 0x14 字节
//       magic 0x4e475241 "ARGN"  -> 渐变: 头 0x10 字节
//       magic 0x434f4c52 "RLOC"  -> 颜色 (createColor)
//       magic 0x52415744 "DWAR"  -> 原始数据, 可选 lzfse 压缩 (rawData)
//
// (2) 渐变块 (ARGG/ARGA/ARGN):
//       +0x00 u32 magic
//       +0x04 u32 count      // 色标个数
//       +0x08 u32 type       // 传给 [NGGradient setType:]
//       +0x0c u32 (未使用)
//       [ARGG] +0x10 float startX, +0x14 float startY,
//              +0x18 float endX,   +0x1c float endY
//       之后是 count 个变长条目 (块内偏移 = hdr, hdr 分别为 0x20/0x14/0x10):
//           { float pos;  u32 nameLen;  char name[nameLen]; }   // 8 + nameLen 字节
//       nameLen 只是上限, 实际用 strnlen(name, nameLen) 取 NUL 结尾串。
//
// (3) 颜色块 "RLOC" (createColor):
//       +0x00 u32 magic
//       +0x04 u32 (未使用)
//       +0x08 u32 colorSpaceID  // 3=P3 4=ExtendedSRGB 5=ExtendedLinearSRGB 其它=sRGB
//       +0x0c u32 count         // 必须 1..5
//       +0x10 double comp[count]
//       长度必须 >= 0x10 + count*8。
//
// (4) 原始数据块 "DWAR" (rawData):
//       +0x00 u32 magic
//       +0x04 u8  flags        // bit0 = 1 表示 lzfse 压缩
//       +0x08 u32 unpackedSize
//       +0x0c ... payload
//
// (5) NGLayerRef 元数据块 (由 __layerRefs_block_invoke 解析, tag 就是 layout)
//       tag 0x3f4: +0x00 u32 count
//                  之后 count 个 { u32 flags; i32 f.x; i32 f.y; u32 f.w; u32 f.h;
//                                  u32 blendMode; float opacity; u32 keyListLen;
//                                  u8 keyList[keyListLen]; }   // 每项头 0x20 字节
//                  (整体最小 0x28 = 8 字节前缀 + 一个 0x20 头)
//       tag 0x3fc: +0x00 u32 count
//                  之后 count 个 { u32 flags(bit0=lighting); float blur;
//                                  u32 fillLen; char fill[fillLen]; }  // 头 0xc 字节
//                  (fillLen 含结尾 NUL; 长度用 fillLen-1)
//       tag 0x3fd: +0x00 u32 count
//                  之后 count 个 { u32 flags(bit0=specular); float translucency;
//                                  u32 shadowStyle; float shadowOpacity; u32 pad; }
//                  // 步长 0x14, 最后 4 字节从未被读取
//
// (6) layout 取值汇总 (本文件里出现过的判断)
//       0x3f1 (1009)  drawNode 里的一类节点
//       0x3f4 (1012)  层列表块 (建 NGLayerRef)
//       0x3f9 (1017)  SVG 内容 (drawContents 走 CoreSVG)
//       0x3fc (1020)  层 blur/fill 块
//       0x3fd (1021)  渐变元素 (drawFill 分支 B) / 层阴影参数块
//       9             非 SVG 但走 "先渲染进 RGBA 位图" 的内容


// ---------------------------------------------------------------------------
// 2. 全局状态 / 常量
// ---------------------------------------------------------------------------
//
//   extern id NGLog;                     // 0x18da8  日志 block, 可为 NULL
//   static CGColorSpaceRef extSRGB_cs;   // 0x18d70  = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB)
//   static long extSRGB_once;            // 0x18d78  dispatch_once 谓词
//   static void *pSVGCreate;             // 0x18d80  dlsym "CGSVGDocumentCreateFromData"
//   static void *pSVGSize;               // 0x18d88  dlsym "CGSVGDocumentGetCanvasSize"
//   static void *pSVGDraw;               // 0x18d90  dlsym "CGContextDrawSVGDocument"
//   static void *pSVGRelease;            // 0x18d98  dlsym "CGSVGDocumentRelease"
//   static long loadSVG_once;            // 0x18da0
//
//   全文件共用一个 "extSRGB" 颜色空间, 由 OUTLINED_FUNCTION_0 /
//   __extSRGB_block_invoke 初始化, 实际是 **kCGColorSpaceExtendedSRGB**。
//   下面统一写成 extSRGB()。
//
//   常量池 (__TEXT/__const, 全部为 double):
//     0x10b58 = 0.7152   (Rec.709 G 系数)
//     0x10b60 = 0.0722   (B 系数)
//     0x10b68 = 0.2126   (R 系数)
//     0x10b70 = 0.2
//     0x10b78 = -0.1
//     0x10b80 = -0.2
//     0x10b88 = 0.1
//     0x10b90 = 0.9
//     0x10b98 = 0.01     (本文件函数未用到)
//
//   GOT 里的颜色空间常量:
//     0x14840 = _kCGColorSpaceDisplayP3
//     0x14848 = _kCGColorSpaceExtendedLinearSRGB
//     0x14850 = _kCGColorSpaceExtendedSRGB
//     0x14858 = _kCGColorSpaceSRGB
//     0x14810 = _CGPointZero (CGPoint 结构体地址)

static CGColorSpaceRef extSRGB(void);          // 实现: dispatch_once(OUTLINED_FUNCTION_0) 后返回 extSRGB_cs
static double adjustComponent(double c, double lum, double k);   // 见 drawFill 下方


// ===========================================================================
// @addr 0x81e4  _drawFill
// ---------------------------------------------------------------------------
// BOOL drawFill(CGContextRef c,             // x0
//               NGCatalogIndex *index,      // x1  (任务书写的 catalog; 实测是 index,
//                                           //      因为它第一件事就是 byName(index,...) → [x renditions])
//               NSString *fillName,         // x2
//               unsigned short theme,        // x3 (w3)
//               int forceVertical,           // x4 (w4) 1 = 忽略渐变自带方向, 强制竖排
//               CGRect frame)                // v0..v3
//
// 返回 YES = 已绘制; NO = 名字找不到 / 数据不可解析 / 渐变无颜色。
// 调用点:
//   0x91ec drawElement: fillName = [ref fill], theme, forceVertical = 0, frame = 元素 frame
//   0x676c drawNode:    fillName = [node name](节点自己就是填充), theme, forceVertical = 1,
//                       frame = (ctx->origin, ctx->size) 整画布; 调用前已 SetAlpha([ref opacity])
//   0x6e8c NGCreateGlassIconContent: fillName = [x name], theme, forceVertical = 1
//
// 两条主分支:
//   [node layout] == 0x3fd (1021) -> 渐变
//   否则                          -> 纯色 (createColor + CGContextFillRect)
// ===========================================================================
BOOL drawFill(CGContextRef c, NGCatalogIndex *index, NSString *fillName,
              unsigned short theme, int forceVertical, CGRect frame)
{
    NGRendition *node = byName(index, fillName, theme);         // 0x8268
    if (!node) {                                                // 0x8278
        if (NGLog)
            NGLog([NSString stringWithFormat:@"fill %@ not found", fillName]); // 0x83d0
        return NO;                                              // 0x846c
    }

    // ------------------------------------------------------------------
    // 分支 A: 纯色填充 (layout != 0x3fd)
    // ------------------------------------------------------------------
    if ([node layout] != 0x3fd) {                               // 0x8284
        CGColorRef color = createColor(node);                   // 0x83dc
        if (color) {
            CGContextSetFillColorWithColor(c, color);           // 0x83f0
            CGContextFillRect(c, frame);                        // 0x8408  (v0..v3 = frame)
            CGColorRelease(color);                              // 0x8410
            return YES;                                         // 0x8414 w25 = 1
        }
        if (NGLog)
            NGLog([NSString stringWithFormat:@"fill %@ unreadable (layout 0x%x)",
                   fillName, [node layout]]);                   // 0x8440
        return NO;                                              // 0x8464
    }

    // ------------------------------------------------------------------
    // 分支 B: 渐变 (layout == 0x3fd)
    // ------------------------------------------------------------------
    {
        const uint8_t *bytes = [node csi].bytes;                // 0x82c4
        uint32_t subOff      = *(const uint32_t *)(bytes + 0xa8);// 0x82d4
        uint32_t subLen      = *(const uint32_t *)(bytes + 0xb4);// 0x82d8
        const uint8_t *sub   = bytes + 0xb8 + subOff;           // 0x82dc + 0x830c
        size_t   csiLen      = [[node csi] length];             // 0x82f8

        // 0x8310..0x8320: 数据块必须整体落在 csi 内, 且长度 >= 12
        if ((size_t)(0xb8 + subOff) + subLen > csiLen || subLen < 0x0c)
            return NO;

        NGGradient *grad   = [NGGradient new];                  // 0x832c
        uint32_t stopCount = *(const uint32_t *)(sub + 0x04);    // 0x8334 -> [sp+0x40]
        [grad setType:*(const uint32_t *)(sub + 0x08)];          // 0x833c
        [grad setStart:CGPointZero];                            // 0x8358 (GOT _CGPointZero)
        [grad setEnd:  CGPointZero];                            // 0x8368

        uint32_t magic = *(const uint32_t *)sub;                 // 0x836c
        uint32_t hdr;                                            // 条目的起始偏移

        if (magic == 0x47475241 /* "ARGG" */) {                  // 0x837c
            if (subLen < 0x20)              // 0x8474: 头都不够 -> 放弃
                goto fail_gradient;
            [grad setStart:CGPointMake((double)*(const float *)(sub + 0x10),
                                       (double)*(const float *)(sub + 0x14))]; // 0x84a0
            [grad setEnd:  CGPointMake((double)*(const float *)(sub + 0x18),
                                       (double)*(const float *)(sub + 0x1c))]; // 0x84b8
            hdr = 0x20;                                          // 0x84bc
        } else if (magic == 0x41475241 /* "ARGA" */) {           // 0x8390
            hdr = 0x14;                                          // 0x8488
        } else if (magic == 0x4e475241 /* "ARGN" */) {           // 0x83a4
            hdr = 0x10;                                          // 0x83ac
        } else {
            goto fail_gradient;                                   // 0x847c
        }

        // ---- 收集色标: 每条 = {float pos; u32 nameLen; char name[nameLen]} ----
        NSMutableArray *colors = [NSMutableArray array];          // 0x84c8 -> [sp+0x30]
        NSMutableArray *stops  = [NSMutableArray array];          // 0x84dc -> [sp+0x28]

        if (stopCount != 0) {                                     // 0x84f0
            const uint8_t *end   = sub + subLen;                  // 0x84f8
            const uint8_t *entry = sub + hdr;                     // 0x84f4
            for (uint32_t n = 1; ; n++) {                         // 0x8508 w20
                const uint8_t *namePtr = entry + 8;               // 0x84fc
                if (namePtr > end) break;                         // 0x8500
                float    pos     = *(const float *)entry;         // 0x851c (s12)
                uint32_t nameLen = *(const uint32_t *)(entry + 4);// 0x850c
                if (namePtr + nameLen > end) break;               // 0x8510..0x8518

                // 0x8520..0x854c
                NSString *colorName =
                    [[NSString alloc] initWithBytes:namePtr
                                             length:strnlen((const char *)namePtr, nameLen)
                                           encoding:NSUTF8StringEncoding /*4*/];

                NGRendition *sub0 = byName(index, colorName, theme); // 0x8560
                if (!sub0) {                                     // 0x8570
                    if (NGLog)                                   // 0x864c
                        NGLog([NSString stringWithFormat:@"gradient %@: no color %@",
                               [node name], colorName]);          // 0x867c
                    goto fail_collect;
                }
                CGColorRef col = createColor(sub0);               // 0x8578
                if (!col) {                                      // 0x857c
                    if (NGLog)
                        NGLog([NSString stringWithFormat:@"gradient %@: no color %@",
                               [node name], colorName]);
                    goto fail_collect;
                }
                [colors addObject:(__bridge id)col];              // 0x858c  (CF 对象进 NSArray)
                CGColorRelease(col);                              // 0x8594
                [stops addObject:@(pos)];                         // 0x85b8  (numberWithFloat:)

                if (n >= stopCount) break;                        // 0x85dc
                entry += nameLen + 8;                             // 0x85e4..0x85e8
                if (entry + 8 > end) break;                       // 0x85ec..0x85f4
            }
        }

        if ([colors count] == 0)                                  // 0x8604
            goto fail_collect;                                    // 一个颜色都没有 -> 失败

        [grad setColors:colors];                                  // 0x8618
        [grad setStops:stops];                                    // 0x8628

        // --------------------------------------------------------------
        // 组装 CG 渐变用的颜色数组 (0x86f8..)
        //   [grad type] == 0 或 [grad colors].count == 1
        //       -> 单色扩展成"原色 + 亮度调整色"的 2 色标渐变
        //   否则 -> 原样拷贝 (最多 16 个)
        // --------------------------------------------------------------
        {
            NSMutableArray *cgColors = [NSMutableArray array];    // 0x8700  x26
            double stopPos[16];                                   // [sp+0x70]

            if ([grad type] != 0 && [[grad colors] count] != 1) { // 0x8714..0x874c
                // ---- 多色标: 直接拷贝 (0x8b3c) ----
                if ([[grad colors] count] != 0) {                  // 0x8b60
                    for (NSUInteger i = 0; ; i++) {
                        [cgColors addObject:[[grad colors] objectAtIndexedSubscript:i]];      // 0x8b9c
                        stopPos[i] = [[[grad stops] objectAtIndexedSubscript:i] doubleValue]; // 0x8bd8
                        if (i + 1 >= [[grad colors] count]) break;  // 0x8c18
                        if (i >= 15) break;                         // 0x8c20 (最多 16 个色标)
                    }
                }
            } else {
                // ---- 单色: 用亮度推导第二个色标 (0x8750..) ----
                CGColorRef base = (__bridge CGColorRef)
                                    [[grad colors] objectAtIndexedSubscript:0];   // 0x8768

                // 0x8794: 先转到共享的 ExtendedSRGB 取分量
                CGColorRef matched =
                    CGColorCreateCopyByMatchingToColorSpace(extSRGB(),
                        kCGRenderingIntentDefault /*0*/, base, NULL);
                CGColorRef src = matched ? matched : base;         // 0x87a0 csel

                const CGFloat *comp = CGColorGetComponents(src);    // 0x87a8
                size_t ncomp        = CGColorGetNumberOfComponents(src); // 0x87b4

                double r = comp[0], g, b, a;
                if (ncomp >= 4) {                                  // 0x87c0
                    g = comp[1]; b = comp[2]; a = comp[3];
                } else {
                    a = 1.0; b = r; g = r;                          // 灰度: 三分量同值
                    if (ncomp >= 2) a = comp[1];                    // 0x87e4 (灰度+alpha)
                }
                if (matched) CGColorRelease(matched);               // 0x87f8

                // 0x8808..0x8828: lum = g*0.7152 + r*0.2126 + b*0.0722
                double lum = 0.7152 * g + 0.2126 * r + 0.0722 * b;

                // 0x882c..0x889c: 按亮度四档, 给出两个色标位置与增益 k
                double stopA, stopB, k;
                if (lum <= 0.25) {
                    stopA = 0.0; stopB = 0.7; k =  0.20;    // 0x8888: d1 = 0.2
                } else if (lum <= 0.5) {
                    stopA = 0.0; stopB = 0.7; k =  0.25;    // d1 仍为 0x8830 的 0.25
                } else if (lum <= 0.75) {
                    stopA = 0.0; stopB = 0.7; k =  0.30;    // 0x8874/0x8880 两个 fcsel
                } else {
                    stopA = 1.0; stopB = 0.3; k = -0.10;    // 0x8858 d13=1.0, d15=0.3, d1=-0.1
                }

                // 0x889c..0x8910: 逐分量 (r,g 用 2 路 double 向量化, b 单独算, 数学等价)
                //     base' = c + (-0.2) * (lum - c)
                //     k >= 0 -> base' * (1 + k)
                //     k <  0 -> base' + (1 - base') * k
                double adj[4];
                adj[0] = adjustComponent(r, lum, k);
                adj[1] = adjustComponent(g, lum, k);
                adj[2] = adjustComponent(b, lum, k);
                adj[3] = a;
                CGColorRef adjusted = CGColorCreate(extSRGB(), adj); // 0x892c

                // 0x8934..0x89a4: 按色标大小决定两者顺序
                //   stopA <  stopB : colors = {adjusted, base},  stops = {stopA, stopB}
                //   stopA >= stopB : colors = {base, adjusted},  stops = {stopB, stopA}
                // 每个颜色都是 "拿到 +1 引用 -> addObject(数组自己 retain) -> CGColorRelease"
                if (stopA < stopB) {
                    CGColorRef c1 = adjusted;                       // 0x892c 的 +1 直接转手 (x23)
                    CGColorRef c2 = CGColorRetain(base);            // 0x8940 (x22)
                    [cgColors addObject:(__bridge id)c1];           // 0x8988
                    CGColorRelease(c1);                             // 0x8990
                    [cgColors addObject:(__bridge id)c2];           // 0x899c
                    CGColorRelease(c2);                             // 0x89a4
                    stopPos[0] = stopA;                             // [sp+0x70] = d13
                    stopPos[1] = stopB;                             // [sp+0x78] = d15
                } else {
                    CGColorRef c1 = CGColorRetain(base);            // 0x8958 (x23)
                    CGColorRef c2 = adjusted;                       // (x22)
                    [cgColors addObject:(__bridge id)c1];           // 0x8988
                    CGColorRelease(c1);                             // 0x8990
                    [cgColors addObject:(__bridge id)c2];           // 0x899c
                    CGColorRelease(c2);                             // 0x89a4
                    stopPos[0] = stopB;                             // [sp+0x70] = d15
                    stopPos[1] = stopA;                             // [sp+0x78] = d13
                }
            }

            // ----------------------------------------------------------
            // 渐变几何 (0x89a8..0x8a3c)
            // ----------------------------------------------------------
            CGPoint p0 = [grad start];      // 0x89ac: v0 -> d15(start.x), v1 -> d14(start.y)
            CGPoint p1 = [grad end];        // 0x89bc: v0 -> d13(end.x),  v1 -> d12(end.y)
            if (p0.x == p1.x && p0.y == p1.y) {   // 0x89c8 / 0x89d0: 退化
                p0 = CGPointMake(0.0, 0.0);        // 0x89e0..0x89ec
                p1 = CGPointMake(0.0, 1.0);        // 自上而下
            }
            if (forceVertical) {                   // 0x89f4: w4 != 0
                // 强制竖直: x 归零, y 用 0.1/0.9, 并按原方向决定谁在上
                if (p0.y > p1.y) { p0.y = 0.9; p1.y = 0.1; }    // 0x89fc..0x8a0c fcsel(gt)
                else             { p0.y = 0.1; p1.y = 0.9; }
                p0.x = 0.0; p1.x = 0.0;                         // 0x8a14/0x8a18
            }

            CGGradientRef g = CGGradientCreateWithColors(extSRGB(), cgColors, stopPos); // 0x8a38

            // 0x8a40..0x8a9c: 归一化坐标映射进 frame
            CGPoint s = CGPointMake(CGRectGetMinX(frame) + p0.x * frame.size.width,
                                    CGRectGetMinY(frame) + p0.y * frame.size.height);
            CGPoint e = CGPointMake(CGRectGetMinX(frame) + p1.x * frame.size.width,
                                    CGRectGetMinY(frame) + p1.y * frame.size.height);

            // 0x8ab8: options = 3 = kCGGradientDrawsBeforeStartLocation |
            //                       kCGGradientDrawsAfterEndLocation
            CGContextDrawLinearGradient(c, g, s, e, 3);

            CGGradientRelease(g);                      // 0x8ac0
            // objc_release(cgColors); objc_release(grad);  -> 0x8ac8 / 0x8ad0
            return YES;
        }

    fail_collect:
        // 0x86a8..0x86d0: 依次 release 颜色/色标/渐变, 然后走统一收尾 (返回 0)
        return NO;

    fail_gradient:
        // 0x86d4: release(grad) 后走统一收尾 (返回 0)
        return NO;
    }
}


// 上面单色渐变的单分量调整 (等价于 0x889c..0x8910 的向量化代码)
static double adjustComponent(double c, double lum, double k)
{
    double base = c + (-0.2) * (lum - c);       // 0x88b0..0x88c4 (常量 0xbfc999999999999a = -0.2)
    if (k < 0.0)
        return base + (1.0 - base) * k;         // 0x88cc..0x88d4
    return base * (1.0 + k);                    // 0x88c8
}


// ===========================================================================
// @addr 0x8c60  _drawElement
// ---------------------------------------------------------------------------
// BOOL drawElement(CGContextRef c,        // x0
//                  DrawCtx *ctx,          // x1
//                  id catalog,            // x2
//                  NGCatalogIndex *index, // x3
//                  NGRendition *target,   // x4
//                  NGLayerRef *ref,       // x5
//                  unsigned short theme,  // x6 (w6)
//                  CGRect frame)          // v0..v3
//
// 流程:
//   1) SaveGState; 应用 ref 的 opacity / blendMode
//   2) ref.fill 非空:
//        - 把 target 内容画进一张 kCGImageAlphaOnly 位图(掩膜)
//        - 求 alpha>=9 像素的包围盒, 反变换回用户空间 -> 收紧 frame
//        - 用掩膜裁剪成透明层后调 drawFill 填充
//      ref.fill 为空:
//        - layout == 0x3f9 或 9: 画进 sRGB 位图 -> 转 P3 CGImage -> 直接合成
//        - 其它 layout:           直接 drawContents 到 c
//   3) RestoreGState; 失败时写日志
// ===========================================================================
BOOL drawElement(CGContextRef c, DrawCtx *ctx, id catalog, NGCatalogIndex *index,
                 NGRendition *target, NGLayerRef *ref,
                 unsigned short theme, CGRect frame)
{
    BOOL ok = NO;
    size_t w = ctx->pixelSize;                                   // 0x8d54 (ldp x1,x2,[x24])
    size_t h = ctx->pixelSize2;

    CGContextSaveGState(c);                                      // 0x8ce4
    CGContextSetAlpha(c, (double)[ref opacity]);                  // 0x8cec / 0x8cf8
    CGContextSetBlendMode(c, (CGBlendMode)[ref blendMode]);       // 0x8d00 / 0x8d0c

    NSString *fillName = [ref fill];                              // 0x8d14
    if (fillName.length == 0)                                    // 0x8d34
        goto no_fill;

    // ==================================================================
    // (A) 有 fill: 先渲染 alpha 掩膜, 再裁剪填充
    // ==================================================================
    {
        // 0x8d6c: 8bpp, bytesPerRow = w, 无颜色空间, bitmapInfo = 7 (kCGImageAlphaOnly)
        CGContextRef bmp = CGBitmapContextCreate(NULL, w, h, 8, w, NULL,
                                                 kCGImageAlphaOnly /*7*/);
        if (!bmp) goto finish;                                   // 0x8d70 -> 0x8fbc

        CGContextSetInterpolationQuality(bmp, kCGInterpolationHigh /*3*/); // 0x8d7c
        CGContextConcatCTM(bmp, ctx->ctm);                        // 0x8d98 (48 字节 @ctx+0x10)

        if (!drawContents(bmp, catalog, target, frame)) {          // 0x8db8
            CGContextRelease(bmp);                                // 0x9118
            goto finish;                                          // 0x9210 (w24 = 0)
        }

        // ---- 求可见像素包围盒 (0x8dc0..0x8e68) ----
        const uint8_t *data = CGBitmapContextGetData(bmp);         // 0x8dd0
        size_t bpr          = CGBitmapContextGetBytesPerRow(bmp);  // 0x8ddc
        int64_t minX = (int64_t)w, maxX = -1;                     // 0x8dfc / 0x8df4
        int64_t minY = (int64_t)h, maxY = -1;                     // 0x8e00 / 0x8e04
        for (int64_t row = 0; row < (int64_t)h; row++) {           // 0x8e0c / 0x8e18
            const uint8_t *line = data + row * bpr;
            for (int64_t col = 0; col < (int64_t)w; col++) {       // 0x8e60
                if (line[col] < 9) continue;                       // 0x8e48: alpha < 9 不算可见
                if (col < minX) minX = col;
                if (col > maxX) maxX = col;
                if (row < minY) minY = row;
                if (row > maxY) maxY = row;
            }
        }

        CGAffineTransform inv = CGAffineTransformInvert(ctx->ctm);  // 0x9040

        if (maxX >= 0) {                                           // 0x9044 (tbnz x26,#63 跳过)
            // 0x9048..0x9088: 位图行自上而下, 所以 y 要翻转: y = h-1-maxY
            CGRect box = CGRectMake((double)minX,
                                    (double)((int64_t)h - 1 - maxY),
                                    (double)(maxX - minX + 1),
                                    (double)(maxY - minY + 1));
            frame = CGRectStandardize(CGRectApplyAffineTransform(box, &inv));
        }

        // ---- 用 alpha 数据造掩膜图 (0x909c..0x9108) ----
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();      // 0x909c
        CFDataRef d = CFDataCreate(NULL, data, (CFIndex)(h * bpr)); // 0x90b4 (x2 = h*bytesPerRow)
        CGDataProviderRef prov = CGDataProviderCreateWithCFData(d); // 0x90bc
        CGImageRef mask = CGImageCreate(w, h, 8, 8, bpr, gray,
                                       0 /*bitmapInfo*/, prov, NULL,
                                       false /*shouldInterpolate*/, 0 /*intent*/); // 0x90ec
        CGDataProviderRelease(prov);                                // 0x90f8
        CFRelease(d);                                               // 0x9100
        CGColorSpaceRelease(gray);                                  // 0x9108
        CGContextRelease(bmp);                                      // 0x9118

        if (!mask) goto finish;                                     // 0x9130 -> 0x9210

        CGContextBeginTransparencyLayer(c, NULL);                   // 0x913c
        CGContextConcatCTM(c, inv);                                 // 0x9174  (user space == device)
        CGContextClipToMask(c, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), mask); // 0x9194
        CGContextConcatCTM(c, ctx->ctm);                            // 0x91b0  还原用户空间

        // 0x91ec: 第 2 个参数是 index(不是 catalog), 第 5 个参数 = 0
        ok = drawFill(c, index, [ref fill], theme, 0, frame);

        CGContextEndTransparencyLayer(c);                            // 0x9200
        CGImageRelease(mask);                                        // 0x9208
        goto finish;
    }

no_fill:
    // ==================================================================
    // (B) fill 为空
    // ==================================================================
    if ([target layout] == 0x3f9 /*1017*/ || [target layout] == 9) {  // 0x8e90 / 0x8ea0
        // ---- 走 RGBA 位图, 再转 P3 直接合成 (0x8ea8..) ----
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);     // 0x8eb8
        CGColorSpaceRef p3   = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3); // 0x8ecc

        // 0x8eec: 8bpp, bytesPerRow=0(自动), bitmapInfo = 0x2002
        //         = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
        CGContextRef bmp = CGBitmapContextCreate(NULL, w, h, 8, 0, srgb, 0x2002);
        if (bmp) {
            CGContextConcatCTM(bmp, ctx->ctm);                       // 0x8f0c
            if (drawContents(bmp, catalog, target, frame)) {          // 0x8f2c
                CGImageRef img = CGBitmapContextCreateImage(bmp);     // 0x8f3c
                if (img) {
                    CGImageRef img2 = CGImageCreateCopyWithColorSpace(img, p3); // 0x8f50
                    if (img2) {
                        CGContextSaveGState(c);                       // 0x8f60
                        CGAffineTransform inv2 = CGAffineTransformInvert(ctx->ctm); // 0x8f7c
                        CGContextConcatCTM(c, inv2);                  // 0x8f88
                        CGContextDrawImage(c, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h),
                                           img2);                     // 0x8fa8
                        CGContextRestoreGState(c);                    // 0x8fb0
                        ok = YES;                                     // 0x8fb4
                        CGImageRelease(img2);                         // 0x9224
                    }
                    CGImageRelease(img);                              // 0x922c
                }
            }
            CGContextRelease(bmp);                                    // 0x9234
        }
        CGColorSpaceRelease(srgb);                                    // 0x9240
        CGColorSpaceRelease(p3);                                      // 0x9248
        goto finish;
    }

    // ---- 其它 layout: 直接画到目标上下文 (0x8fe4) ----
    ok = drawContents(c, catalog, target, frame);
    goto finish;

finish:
    CGContextRestoreGState(c);                                        // 0x92d4
    if (!ok && NGLog)                                                 // 0x9268
        NGLog([NSString stringWithFormat:@"element %@ (layout 0x%x) failed",
               [target name], [target layout]]);                      // 0x92a4
    // objc_release(ref / target / index / catalog) -> 0x92d8..0x92f4
    return ok;
}


// ===========================================================================
// @addr 0xacc4  _keyValue
// ---------------------------------------------------------------------------
// unsigned short keyValue(NGRendition *r, unsigned short key)
//
// 【重要】这不是 switch 表, 而是通用的 "u16 键 -> u16 值" 查表函数:
//   NGRendition._key (NSData) 里是若干 4 字节记录 { u16 key; u16 value; },
//   线性扫描, 命中第一个 key 就返回其 value; 找不到(或 key 数据 < 4 字节)返回 0。
//   所以 key→属性 的映射是**数据驱动**的, 二进制里没有静态 switch 表。
//   唯一的强约定(来自 byName): key = 7 表示"外观/主题"(theme / appearance)。
//   参考 __cstring: "UIAppearanceDark" / "UIAppearanceLight" /
//   "ISAppearanceTintable" —— 这些外观名会被索引成 token 参与 key 的构造。
// ===========================================================================
unsigned short keyValue(NGRendition *r, unsigned short key)
{
    const uint8_t *p = [r key].bytes;                        // 0xacf8
    if ([[r key] length] < 4) return 0;                       // 0xad2c / 0xad30

    uint32_t i = 0;                                           // x24
    const uint8_t *q = p + 2;                                 // 0xad38
    do {
        if (*(const uint16_t *)(q - 2) == key)                // 0xad3c / 0xad40
            return *(const uint16_t *)q;                      // 0xad84
        i++;                                                  // 0xad48
        q += 4;                                               // 0xad70
    } while (i < ([[r key] length] >> 2));                     // 0xad74 (长度每轮重新取)
    return 0;                                                 // 0xad7c
}


// ===========================================================================
// @addr 0xaf78  _rawData
// ---------------------------------------------------------------------------
// NSData *rawData(NGRendition *r)
//
// 从 csi 容器取出主数据块:
//   - magic 不是 "DWAR" -> 原样返回 dataWithBytes(p, subLen)
//   - magic == "DWAR"   -> 由 flags bit0 决定是否 lzfse 解压
// 解压: 初值 cap = max(compLen*8, 0x10000), 不足则 4 倍扩容重试,
//       compLen > 8MB 或 cap >= 0x01000001 时放弃并记日志。
// ===========================================================================
NSData *rawData(NGRendition *r)
{
    const uint8_t *bytes = [r csi].bytes;                      // 0xafb0
    uint32_t subOff = *(const uint32_t *)(bytes + 0xa8);        // 0xafc0
    uint32_t subLen = *(const uint32_t *)(bytes + 0xb4);        // 0xafc4
    const uint8_t *p = bytes + 0xb8 + subOff;                   // 0xafc8 + 0xaff4
    size_t csiLen    = [[r csi] length];                        // 0xafe4
    size_t end       = (size_t)(0xb8 + subOff) + subLen;        // 0xafcc

    if (end > csiLen || subLen < 0x0c) {                        // 0xaff8..0xb004
        if (end > csiLen) return nil;                           // 0xb024
        return [NSData dataWithBytes:p length:subLen];           // 0xb02c
    }

    if (*(const uint32_t *)p != 0x52415744 /* "DWAR" */)        // 0xb008..0xb018
        return [NSData dataWithBytes:p length:subLen];           // 0xb02c

    {
        uint32_t unpacked   = *(const uint32_t *)(p + 8);        // 0xb074
        uint32_t payloadLen = subLen - 0x0c;                     // 0xb078 (sub w8,w8,#0xc)
        uint32_t compLen    = (unpacked < payloadLen) ? unpacked : payloadLen; // 0xb080
        uint8_t  flags      = *(const uint8_t *)(p + 4);          // 0xb084

        if ((flags & 1) == 0)                                    // 0xb088 (tbnz bit0)
            return [NSData dataWithBytes:p + 0x0c length:compLen]; // 0xb094 / 0xb038

        // ---------------- lzfse 解压 ----------------
        if (compLen > 0x800000)                                  // 0xb09c
            goto lzfse_fail;

        {
            size_t cap = (size_t)compLen * 8;                    // 0xb0a4
            if (cap < 0x10000) cap = 0x10000;                     // 0xb0a8 / 0xb0b0
            for (;;) {
                NSMutableData *buf = [NSMutableData dataWithLength:cap]; // 0xb0c8
                size_t n = compression_decode_buffer(buf.mutableBytes, cap,
                                                     p + 0x0c, compLen,
                                                     NULL,
                                                     COMPRESSION_LZFSE /*0x801*/); // 0xb0f4
                if (n == 0) goto lzfse_fail;                      // 0xb0f8 -> 0xb120
                if (n < cap) {                                    // 0xb104
                    [buf setLength:n];                            // 0xb18c
                    return buf;
                }
                // 缓冲区不够: 4 倍扩容重试 (0xb108..0xb118)
                if (cap >= 0x01000001) goto lzfse_fail;           // 0xb110
                cap *= 4;
            }
        }

    lzfse_fail:
        if (NGLog)                                                // 0xb128
            NGLog([NSString stringWithFormat:@"lzfse %@ failed", [r name]]); // 0xb158
        return nil;                                               // 0xb184 -> 0xb024
    }
}


// ===========================================================================
// @addr 0xb194  _keyListDesc
// ---------------------------------------------------------------------------
// NSString *keyListDesc(NSData *keyList)
//
// 把 u16 键值对序列格式化成 "k=v " 拼接串, 仅用于日志。
// 遇到 key == 0 立即停止; 循环里每次都重新取 keyList.length (原码如此)。
// 计数 i 从 1 开始、每轮 +2, 条件是 i < length/2 —— 编译器对
// "遍历 4 字节一组" 的展开, 效果等于最多遍历前 length/4 组。
// ===========================================================================
NSString *keyListDesc(NSData *keyList)
{
    NSMutableString *s = [NSMutableString string];                // 0xb1bc
    const uint8_t *p = keyList.bytes;                             // 0xb1d4

    if ([keyList length] >= 4) {                                  // 0xb1e0
        const uint8_t *q = p + 2;                                 // 0xb1ec
        uint32_t i = 1;                                           // 0xb1f0
        do {
            uint16_t k = *(const uint16_t *)(q - 2);              // 0xb1fc
            if (k == 0) break;                                    // 0xb200
            uint16_t v = *(const uint16_t *)q;                    // 0xb204 (后置 q += 4)
            q += 4;
            [s appendFormat:@"%u=%u ", (unsigned)k, (unsigned)v]; // 0xb214 (CFSTR 0x144a0)
            i += 2;                                               // 0xb220
        } while (i < ([keyList length] >> 1));                    // 0xb224
    }
    return s;                                                     // 0xb24c
}


// ===========================================================================
// @addr 0xb5ac  _byName
// ---------------------------------------------------------------------------
// NGRendition *byName(NGCatalogIndex *index, NSString *name, unsigned short theme)
//
// 在 index.renditions 里按 name 找条目, 并优先匹配 theme:
//   - keyValue(r, 7) == theme  -> 立刻返回 (精确命中)
//   - 否则记住两个候选: 第一个 keyValue!=0 的、第一个 keyValue==0 的
//   - 最后优先返回 keyValue==0 的那个 (即"无外观"的默认条目), 没有才用另一个
// ===========================================================================
NGRendition *byName(NGCatalogIndex *index, NSString *name, unsigned short theme)
{
    NGRendition *themed = nil;   // x23: 第一个 keyValue(r,7) != 0 的条目
    NGRendition *plain  = nil;   // x21: 第一个 keyValue(r,7) == 0 的条目

    for (NGRendition *r in [index renditions]) {                  // 0xb60c 快速枚举
        if (![[r name] isEqualToString:name])                      // 0xb6b0
            continue;                                              // 0xb6c0

        unsigned short kv = keyValue(r, 7);                        // 0xb6cc (w1 = 7)
        if (kv == theme)                                           // 0xb6d8
            return r;                                              // 0xb710

        if (kv != 0) {                                             // 0xb6f0 csel(ne)
            if (!themed) themed = r;                               // x8 = themed ?: r
        } else {
            if (!plain) plain = r;                                 // x9 = plain ?: r
        }
    }

    return plain ? plain : themed;                                 // 0xb738 csel
}


// ===========================================================================
// @addr 0xb7a8  _createColor
// ---------------------------------------------------------------------------
// CGColorRef createColor(NGRendition *r)
//
// 解析 "RLOC" 颜色块:
//   count 只能 1..5, 长度必须 >= 0x10 + count*8。
//   count == 1 -> 灰度(三分量同值), alpha 1.0
//   count == 2 -> 灰度(三分量同值), alpha 1.0   (见 TODO)
//   count == 3 -> RGB, alpha 1.0
//   count >= 4 -> c[0], c[1], c[3], c[3]        (见 TODO)
// 颜色空间: count < 3 固定用共享的 ExtendedSRGB;
//           count >= 3 按块内 +0x8 的 id (3=P3 4=ExtSRGB 5=ExtLinearSRGB 其它=sRGB)。
// 失败返回 NULL。
// ===========================================================================
CGColorRef createColor(NGRendition *r)
{
    const uint8_t *bytes = [r csi].bytes;                         // 0xb7f0
    uint32_t subOff = *(const uint32_t *)(bytes + 0xa8);           // 0xb800
    uint32_t subLen = *(const uint32_t *)(bytes + 0xb4);           // 0xb804
    const uint8_t *p = bytes + 0xb8 + subOff;                      // 0xb808 + 0xb844
    size_t csiLen    = [[r csi] length];                           // 0xb824

    if ((size_t)(0xb8 + subOff) + subLen > csiLen || subLen < 0x10) // 0xb834..0xb840
        return NULL;                                               // 0xb87c

    if (*(const uint32_t *)p != 0x434f4c52 /* "RLOC" */)            // 0xb848..0xb858
        return NULL;

    uint32_t n = *(const uint32_t *)(p + 0x0c);                     // 0xb85c
    if ((uint32_t)(n - 1) > 4) return NULL;                         // 0xb860 / 0xb868 (仅 1..5)
    if ((uint64_t)n * 8 + 0x10 > subLen) return NULL;               // 0xb86c..0xb878

    double c[5];
    c[0] = *(const double *)(p + 0x10);                             // 0xb8f0
    c[1] = *(const double *)(p + 0x18);                             // 0xb8cc
    c[2] = *(const double *)(p + 0x20);                             // 0xb8dc
    c[3] = *(const double *)(p + 0x28);                             // 0xb8ec

    double comps[4];
    comps[0] = c[0];                                                // 0xb8fc / 0xb93c

    if (n < 3) {
        comps[1] = c[0];                                            // 0xb8fc (stp d2,d2)
        comps[2] = c[0];
        // TODO(未确定): 0xb908 是 `fcsel d0, d0, d1(=1.0), eq` —— n==2 时 alpha = 1.0,
        //   而 n==1 时该值取自**未初始化**的 d0 (n==1 的 0xb8c8 跳过了 0xb8cc 的载入)。
        //   看起来原码 n==2 也直接丢掉了 c[1], 疑似原实现 bug。这里按 1.0 处理。
        comps[3] = 1.0;
        return CGColorCreate(extSRGB(), comps);                      // 0xb92c
    }

    // n >= 3
    comps[1] = c[1];                                                // 0xb940 (stur q0, 低半 = d0)
    // TODO(未确定): 0xb940 写进 comps[2] 的 d1, 在 n>=4 时已被 0xb8ec 覆写成 c[3],
    //   所以 n>=4 时 comps[2] == c[3] (c[2] 被跳过)。n==3 时 comps[2] == c[2]。
    comps[2] = (n == 3) ? c[2] : c[3];
    comps[3] = (n == 3) ? 1.0 : c[3];                               // 0xb944 / 0xb948

    CGColorSpaceRef space;
    switch (*(const uint32_t *)(p + 0x08)) {                        // 0xb938 (w8)
        case 3:  space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);          break; // 0x14840
        case 5:  space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB); break; // 0x14848
        case 4:  space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);       break; // 0x14850
        default: space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);               break; // 0x14858
    }                                                               // 0xb950..0xb990
    CGColorRef color = CGColorCreate(space, comps);                  // 0xb9a0
    CGColorSpaceRelease(space);                                      // 0xb9ac
    return color;
}


// ===========================================================================
// @addr 0xb9e8  _drawContents
// ---------------------------------------------------------------------------
// BOOL drawContents(CGContextRef c,     // x0
//                   id catalog,         // x1
//                   NGRendition *r,     // x2
//                   CGRect frame)       // v0..v3
//
// layout == 0x3f9 或 9:
//     内容在 csi 里 —— 可能是 SVG(私有 CoreSVG), 也可能是 CUIImage
//     (通过 IconServices 的 _themeStore + renditionWithKey:)。
// 其它 layout: 只走后者。
//
// 统一绘制方式(内容都是"左上原点"):
//   SaveGState; Translate(frame.origin.x, CGRectGetMaxY(frame));
//   Scale(...); draw; RestoreGState
// ===========================================================================
BOOL drawContents(CGContextRef c, id catalog, NGRendition *r, CGRect frame)
{
    if ([r layout] == 0x3f9 || [r layout] == 9) {                  // 0xba40..0xba58
        NSData *svgData = rawData(r);                              // 0xba60
        if (!svgData) return NO;                                   // 0xba6c -> 0xbb58

        dispatch_once(&loadSVG_once, ^{ __loadSVG_block_invoke(); }); // 0xba74 / 0xba7c

        if (!pSVGCreate || !pSVGRelease || !pSVGSize || !pSVGDraw)  // 0xba88..0xbab0
            return NO;                                             // 0xbcc0

        void *svg = pSVGCreate(svgData, NULL);                     // 0xbabc (x1 = 0)
        if (!svg) return NO;                                       // 0xbac0 -> 0xbcb8

        CGSize sz = pSVGSize(svg);                                 // 0xbacc (v0 = w, v1 = h)
        BOOL ok = (sz.width > 0.0) && (sz.height > 0.0);            // 0xbad0..0xbae0
        if (ok) {
            CGContextSaveGState(c);                                // 0xbaf4
            CGContextTranslateCTM(c, frame.origin.x, CGRectGetMaxY(frame)); // 0xbb14
            CGContextScaleCTM(c, frame.size.width  / sz.width,
                                 -frame.size.height / sz.height);   // 0xbb2c (fdiv + fneg)
            pSVGDraw(c, svg);                                      // 0xbb3c
            CGContextRestoreGState(c);                              // 0xbb44
        }
        pSVGRelease(svg);                                           // 0xbb50
        return ok;                                                  // 0xbcbc
    }

    // ------------------------------------------------------------------
    // 非 SVG: 用 IconServices 私有 API 取 CGImage 再画 (0xbb60..)
    //   id store         = [catalog _themeStore]
    //   key              = [r key] 尾部再补 8 字节 (increaseLengthBy:8)
    //   id themeRendition= [store renditionWithKey:key.bytes]
    //   CGImageRef img   = [themeRendition unslicedImage]
    // 三个 selector 都用 NSSelectorFromString 动态取, 且调用点套了 @try/@catch
    // (0xbd10 / 0xbd28 的 objc_begin_catch 分支: 异常时把结果置 nil)。
    // ------------------------------------------------------------------
    {
        NSData *key = [r key];                                      // 0xbb78
        NSMutableData *key2 = [key mutableCopy];                     // 0xbb88
        [key2 increaseLengthBy:8];                                   // 0xbba0

        SEL selThemeStore = NSSelectorFromString(@"_themeStore");     // 0xbbac
        id store = ((id (*)(id, SEL))objc_msgSend)(catalog, selThemeStore); // 0xbbb8

        SEL selRenditionWithKey = NSSelectorFromString(@"renditionWithKey:"); // 0xbbd0
        id themeRendition = ((id (*)(id, SEL, void *))objc_msgSend)(
                                store, selRenditionWithKey, key2.bytes);      // 0xbbf0

        SEL selUnslicedImage = NSSelectorFromString(@"unslicedImage");        // 0xbc08
        CGImageRef img = (CGImageRef)((id (*)(id, SEL))objc_msgSend)(
                                themeRendition, selUnslicedImage);            // 0xbc14

        if (!img) return NO;                                          // 0xbc44 -> 0xbcb0

        CGContextSaveGState(c);                                       // 0xbc4c
        CGContextTranslateCTM(c, frame.origin.x, CGRectGetMaxY(frame)); // 0xbc70
        CGContextScaleCTM(c, 1.0, -1.0);                              // 0xbc80
        CGContextDrawImage(c, CGRectMake(0, 0, frame.size.width, frame.size.height),
                           img);                                      // 0xbc9c
        CGContextRestoreGState(c);                                    // 0xbca4
        return YES;                                                   // 0xbca8
    }
}


// ===========================================================================
// @addr 0xb250  ___layerRefs_block_invoke
// ---------------------------------------------------------------------------
// 块签名 (__cstring 0x1007e "v24@?0I8r*12I20",
//   即 void (^)(unsigned int tag, const char *p, unsigned int len))
// block+0x20 = 捕获的 NSMutableArray<NGLayerRef*> (数组先由上一趟 0x3f4 填好对象)
// tag 就是 layout:
//   0x3f4 -> 新建 NGLayerRef 并填 frame/blendMode/opacity/keyList (第一趟)
//   0x3fc -> 回填 lighting / blur / fill
//   0x3fd -> 回填 specular / translucency / shadowStyle / shadowOpacity
// 任何越界都直接 return。
// ===========================================================================
void __layerRefs_block_invoke(void *block, uint32_t tag, const uint8_t *p, uint32_t len)
{
    NSMutableArray *refs = *(NSMutableArray **)((uint8_t *)block + 0x20); // 0xb348 / 0xb3a4 ...
    const uint8_t *end = p + len;                                         // 0xb274

    // ------------------------------------------------------------------
    if (tag == 0x3f4) {                                        // 0xb288: 建对象
        uint32_t count = *(const uint32_t *)p;                 // 0xb290
        if (count == 0) return;                                // 0xb294
        if (len < 0x28) return;                                // 0xb298

        const uint8_t *entry = p + 8;                          // 0xb2a4 (x25)
        const uint8_t *keys  = p + 0x28;                       // 0xb2a0 (x20)

        for (uint32_t i = 1; ; i++) {                          // 0xb2a8 (w26)
            NGLayerRef *layer = [NGLayerRef new];              // 0xb2b8
            [layer setFlags:*(const uint32_t *)entry];         // 0xb2c4
            // 0xb2c8..0xb2e8: 前两个字段按 int32 转, 后两个按 uint32 转
            [layer setFrame:CGRectMake(
                    (double)(int32_t)*(const uint32_t *)(entry + 0x04),
                    (double)(int32_t)*(const uint32_t *)(entry + 0x08),
                    (double)*(const uint32_t *)(entry + 0x0c),
                    (double)*(const uint32_t *)(entry + 0x10))];
            [layer setBlendMode:*(const uint32_t *)(entry + 0x14)]; // 0xb2f8
            [layer setOpacity:*(const float *)(entry + 0x18)];      // 0xb304

            uint32_t keyLen = *(const uint32_t *)(entry + 0x1c);    // 0xb308
            if (keys + keyLen > end) {                              // 0xb310
                objc_release(layer);                                // 0xb588
                return;
            }
            [layer setKeyList:[NSData dataWithBytes:keys length:keyLen]]; // 0xb33c
            [refs addObject:layer];                                  // 0xb350
            objc_release(layer);                                     // 0xb358

            if (i >= count) return;                                  // 0xb35c
            entry += keyLen + 0x20;                                  // 0xb364 / 0xb368
            keys   = entry + 0x20;                                   // 0xb36c
            if (keys > end) return;                                  // 0xb374
        }
    }

    // ------------------------------------------------------------------
    if (tag == 0x3fc) {                                        // 0xb280: lighting / blur / fill
        uint32_t count = *(const uint32_t *)p;                 // 0xb380
        if (count == 0 || len < 0x14) return;                  // 0xb384..0xb38c
        uint32_t idx = 0;                                      // 0xb390 (x20)
        const uint8_t *fill  = p + 0x14;                       // 0xb394 (x21)
        const uint8_t *entry = p + 8;                          // 0xb398 (x25)

        for (;;) {
            uint32_t fillLen = *(const uint32_t *)(entry + 8);          // 0xb3a0
            if ([refs count] <= idx) return;                            // 0xb3ac
            NGLayerRef *layer = [refs objectAtIndexedSubscript:idx];     // 0xb3c0
            [layer setLighting:(*(const uint32_t *)entry & 1)];          // 0xb3d0 / 0xb3d4
            [layer setBlur:*(const float *)(entry + 4)];                 // 0xb400

            if (fillLen != 0) {                                         // 0xb40c
                // 长度用 fillLen-1 (原串含结尾 NUL)
                NSString *s = [[NSString alloc] initWithBytes:fill
                                                      length:fillLen - 1
                                                    encoding:NSUTF8StringEncoding]; // 0xb424
                [[refs objectAtIndexedSubscript:idx] setFill:s];         // 0xb448
                objc_release(s);                                        // 0xb458
            }
            idx++;                                                      // 0xb45c
            if (idx >= count) return;                                   // 0xb460
            entry += fillLen + 0x0c;                                    // 0xb468 / 0xb46c
            fill   = entry + 0x0c;                                      // 0xb470
            if (fill > end) return;                                     // 0xb474
        }
    }

    // ------------------------------------------------------------------
    if (tag == 0x3fd) {                                        // 0xb278: specular / 半透明 / 阴影
        uint32_t count = *(const uint32_t *)p;                 // 0xb480
        if (count == 0) return;                                // 0xb484
        uint32_t idx = 0;                                      // 0xb488 (x20)
        const uint8_t *q = p + 0x1c;                           // 0xb48c (读 [q-0x14])
        if (q > end) return;                                   // 0xb490

        do {
            if ([refs count] <= idx) return;                            // 0xb49c
            uint32_t flags = *(const uint32_t *)(q - 0x14);             // 0xb4a8
            NGLayerRef *layer = [refs objectAtIndexedSubscript:idx];     // 0xb4b4
            [layer setSpecular:(flags & 1)];                            // 0xb4c4 / 0xb4c8
            [layer setTranslucency:*(const float *)(q - 0x10)];         // 0xb4f4
            [layer setShadowStyle:*(const uint32_t *)(q - 0x0c)];       // 0xb520
            [layer setShadowOpacity:*(const float *)(q - 0x08)];        // 0xb54c
            idx++;                                                      // 0xb558
            q += 0x14;                                                  // 0xb55c
        } while (idx != count);                                         // 0xb560
        // 每项 0x14 字节, 但 (q-0x04) 即 entry+0x10 的 4 字节从未被读取。
    }
}


// ===========================================================================
// @addr 0xada8  ___indexFor_block_invoke
// ---------------------------------------------------------------------------
// 块签名 (__cstring 0xfed2 "v24@?0r^v8@16"): void (^)(const void *keyTokens, id chunk)
// block+0x20 = 捕获的 NSMutableArray<NGRendition*> (renditions)
// block+0x28 = 捕获的 tokens.count (NSUInteger)
//
// 对每个 "ISTC" 数据块造一个 NGRendition:
//   key   = 把 keyTokens (u32 数组) 拷成 NSData; 遇到低 16 位为 0 的元素终止,
//           元素个数上限 tokens.count + 4
//   csi   = chunk 本身
//   layout / width / height / pixelFormat / name 来自 ISTC 头
// 非 NSData / 长度 < 0xb8 / magic 不对 -> 丢弃。
// ===========================================================================
void __indexFor_block_invoke(void *block, const uint8_t *keyTokens, NSData *chunk)
{
    NSMutableArray *rends = *(NSMutableArray **)((uint8_t *)block + 0x20); // 0xae3c
    uint64_t limit        = *(const uint64_t *)((uint8_t *)block + 0x28);  // 0xae3c

    if (![chunk isKindOfClass:[NSData class]]) return;             // 0xadec
    if ([chunk length] < 0xb8) return;                             // 0xadfc
    const uint8_t *p = chunk.bytes;                                // 0xae0c
    if (*(const uint32_t *)p != 0x43545349 /* "ISTC" */) return;    // 0xae1c

    uint16_t layout = *(const uint16_t *)(p + 0x24);               // 0xae28
    NGRendition *r = [NGRendition new];                            // 0xae34

    // ---- key: 按 u32 拷贝 token 数组 (0xae40..0xae74) ----
    uint64_t keyLen = 0;
    if (limit + 4 != 0) {                                          // 0xae40 (adds + b.eq)
        uint64_t n = 0;
        const uint8_t *q = keyTokens;                              // 0xae4c
        do {
            uint16_t w = *(const uint16_t *)q;                      // 0xae50 (ldrh, 步长 4)
            q += 4;
            if (w == 0) break;                                      // 0xae54
            n++;                                                    // 0xae58
        } while (limit + 4 != n);                                   // 0xae5c
        keyLen = n * 4;                                             // 0xae68
    }
    [r setKey:[NSData dataWithBytes:keyTokens length:keyLen]];      // 0xae94
    [r setCsi:chunk];                                               // 0xaea8
    [r setLayout:layout];                                           // 0xaeb4
    [r setWidth:*(const uint32_t *)(p + 0x0c)];                     // 0xaec0
    [r setHeight:*(const uint32_t *)(p + 0x10)];                    // 0xaecc
    [r setPixelFormat:*(const uint32_t *)(p + 0x18)];               // 0xaed8

    // ---- name: +0x28 起, 最多 0x80 字节 UTF-8; 空则给 @"" ----
    NSString *name = [[NSString alloc] initWithBytes:p + 0x28
                                             length:strnlen((const char *)p + 0x28, 0x80)
                                           encoding:NSUTF8StringEncoding]; // 0xaf08
    [r setName:(name ? name : @"")];                                // 0xaf24 (CFSTR 0x142c0 = "")
    objc_release(name);                                             // 0xaf2c
    [rends addObject:r];                                            // 0xaf38
    objc_release(r);                                                // 0xaf40
}


// ===========================================================================
// @addr 0xb9c0  ___extSRGB_block_invoke
// ---------------------------------------------------------------------------
// 共享颜色空间惰性初始化的 block 体。
// ===========================================================================
void __extSRGB_block_invoke(void)
{
    extSRGB_cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB); // 0xb9d4 -> 0x18d70
}


// ===========================================================================
// @addr 0xbd44  ___loadSVG_block_invoke
// ---------------------------------------------------------------------------
// 一次性 dlopen 私有 CoreSVG, 取四个函数指针。
// ===========================================================================
void __loadSVG_block_invoke(void)
{
    void *h = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG",
                     RTLD_NOW /*2*/);                            // 0xbd5c
    if (!h) return;                                              // 0xbd60

    pSVGCreate  = dlsym(h, "CGSVGDocumentCreateFromData");       // 0xbd70 -> 0x18d80
    pSVGRelease = dlsym(h, "CGSVGDocumentRelease");              // 0xbd88 -> 0x18d98
    pSVGSize    = dlsym(h, "CGSVGDocumentGetCanvasSize");        // 0xbda0 -> 0x18d88
    pSVGDraw    = dlsym(h, "CGContextDrawSVGDocument");          // 0xbdb8 -> 0x18d90
}


// ===========================================================================
// @addr 0xbdd0  _OUTLINED_FUNCTION_0
// ---------------------------------------------------------------------------
// 编译器把 "dispatch_once(&extSRGB_once, ^{...})" 的外层抽成的 out-of-line
// 片段, drawFill(0x8c4c / 0x8c54) / createColor(0xb9b4) 等处 `b` 过来复用。
// ===========================================================================
void OUTLINED_FUNCTION_0(void)
{
    dispatch_once(&extSRGB_once, &__block_literal_global /* 0x140e0 */); // 0xbde0
}


// 结尾补一句: extSRGB() 的实现就是
//   static CGColorSpaceRef extSRGB(void) { OUTLINED_FUNCTION_0(); return extSRGB_cs; }
