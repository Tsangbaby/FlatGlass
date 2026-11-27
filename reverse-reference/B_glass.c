/*
 * B_glass.c —— FlatGlassIconServices.dylib 玻璃高光/描边绘制链路 C 伪代码还原
 *
 * 目标二进制：flatglass/_unpack/data/var/jb/Library/MobileSubstrate/
 *              DynamicLibraries/FlatGlassIconServices.dylib (arm64e 视作 arm64)
 *
 * 说明
 *  - 所有 "// @addr 0x...." 标注给出对应反汇编区间的起始地址。
 *  - 浮点常量一律写成十进制精确值，并在注释里给出原始常量地址 / 位模式。
 *  - 原二进制里大量像素循环被 clang 自动向量化（ld4/tbl/st3、4/8/16 像素一组），
 *    这里统一还原为语义等价的标量循环，并在注释里说明向量化形态。
 *  - 反汇编里的 fcvtas 是"四舍五入、.5 远离 0"；下文用 lrintf 近似（差别仅在半整数）。
 *  - 未能 100% 确定的点写 "// TODO(未确定): ..."。
 *  - 本文件只描述语义，不负责真实编译（缺头文件、缺 ObjC 运行时声明）。
 *
 * 调用关系（由 _ResourceImage / _ComposedImage 实测）
 *   ResourceImage  0x47b0 -> NGCreateGlassIconContent(0x68cc)
 *                              -> NGCreateGlassIcon(0x68f8)          [同一组参数]
 *                    0x47c8 -> NGCreateFlatIcon(0x60e4)             [非玻璃分支]
 *   ComposedImage  0x4b18 -> NGCreateRimmedImage(0x9324)
 *                  0x4b28 -> NGCreateGlassedImage(0x996c, NULL)
 *   调用方把像素边长夹在 [16.0, 1024.0]（0x4778..0x4794：fmaxnm 16.0,
 *   fminnm 0x4090000000000000 = 1024.0, frintp 向上取整），
 *   所以 0x400 兜底值只会出现在 stack width/height 为 0 的情况下。
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ------------------------------------------------------------------ */
/* 基础类型                                                            */
/* ------------------------------------------------------------------ */
typedef signed char        BOOL_t;
typedef unsigned char      U8;
typedef int32_t            S32;
typedef uint32_t           U32;
typedef int64_t            S64;
typedef size_t             NSUInteger;

typedef void                  *id;          /* ObjC 对象（伪代码用） */
typedef struct NSString        NSString;    /* 不透明类型，仅用于参数标注 */
typedef struct NGCatalogIndex  NGCatalogIndex; /* -[NGCatalogIndex renditions/tokens/...] */
typedef struct CGImage        *CGImageRef;
typedef struct CGContext      *CGContextRef;
typedef struct CGColorSpace   *CGColorSpaceRef;
typedef struct __CFString     *CFStringRef;

/* 伪代码用：把字面量当作 CFStringRef（原码这里是 __CFConstantString 引用） */
#define CFSTR(s) ((CFStringRef)(const void *)(s))

typedef struct { double x, y; }          CGPoint;
typedef struct { double width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
/* CGAffineTransform = { a, b, c, d, tx, ty } 共 6 个 double = 0x30 字节 */
typedef struct { double a, b, c, d, tx, ty; } CGAffineTransform;

/* 外部 CG / libc 原语（地址见反汇编注释） */
extern size_t      CGImageGetWidth(CGImageRef);
extern size_t      CGImageGetHeight(CGImageRef);
extern CGColorSpaceRef CGColorSpaceCreateWithName(CFStringRef);
extern void        CGColorSpaceRelease(CGColorSpaceRef);
extern CGContextRef CGBitmapContextCreate(void *data, size_t w, size_t h,
                                          size_t bpc, size_t bpr,
                                          CGColorSpaceRef cs, U32 bitmapInfo);
extern void        CGContextRelease(CGContextRef);
extern void        CGContextSetInterpolationQuality(CGContextRef, S32 quality);
extern void        CGContextConcatCTM(CGContextRef, const CGAffineTransform *);
extern void        CGContextDrawImage(CGContextRef, CGRect rect, CGImageRef);
extern void       *CGBitmapContextGetData(CGContextRef);
extern size_t      CGBitmapContextGetBytesPerRow(CGContextRef);
extern CGImageRef  CGBitmapContextCreateImage(CGContextRef);
extern CGAffineTransform CGAffineTransformMakeTranslation(double tx, double ty);
extern CGAffineTransform CGAffineTransformScale(CGAffineTransform t,
                                                double sx, double sy);

extern id  objc_retain(id);
extern void objc_release(id);
extern id  objc_retainAutoreleasedReturnValue(id);
extern id  objc_enumerationMutation(id);

/* ObjC 消息发送（这里用普通函数表示 msgSend[sel]） */
extern id     msg_appearances(id);
extern id     msg_objectForKeyedSubscript(id, id);
extern U32    msg_unsignedShortValue(id);
extern S32    msg_width(id);
extern S32    msg_height(id);
extern S32    msg_layout(id);
extern id     msg_name(id);
extern id     msg_csi(id);
extern id     msg_keyList(id);
extern id     msg_renditions(id);
extern CGRect msg_frame(id);
extern float  msg_opacity(id);
extern float  msg_translucency(id);
extern U8     msg_specular(id);
extern U8     msg_lighting(id);
extern S32    msg_shadowStyle(id);
extern float  msg_shadowOpacity(id);
/* NSFastEnumeration: countByEnumeratingWithState:objects:count: */
extern NSUInteger countByEnumeratingWithState(id obj, void *state,
                                              id *stackbuf, NSUInteger len);

typedef struct { unsigned long state; id *itemsPtr; unsigned long *mutationsPtr;
                 unsigned long extra[5]; } NSFastEnumerationState;

/* ------------------------------------------------------------------ */
/* 本模块内其它函数                                                    */
/* ------------------------------------------------------------------ */
CGImageRef NGCreateGlassIcon(id catalog, NSString *stackName,
                             int appearance, size_t px);           /* 0x68f8 */

extern id  indexFor(id catalog);                                   /* 0x53ac */
extern id  findStack(id index, id name, int appearance);           /* 0x5114 */
extern id  resolve(id index, id keyList, U32 variant);             /* 0x7f98 */
extern id  layerRefsOf(id csi);                                    /* 0x7e68 */
extern S32 drawFill(CGContextRef ctx, id index, id name, U32 variant,
                    double x, double y, double w, double h, int flag); /* 0x81e4 */
extern S32 drawNode(CGContextRef ctx, void *drawCtx, id catalog,
                    id index, id rend, U32 variant);               /* 0x64cc */
extern S32 drawElement(CGContextRef ctx, void *drawCtx, id catalog,
                       id index, id rend, id layer, U32 variant,
                       double x, double y, double w, double h);    /* 0x8c60 */

/* IconGlare 借来的绘制原语 -------------------------------------------- */
extern void *IGCreateIconShape(S64 px);                            /* 0xddbc */
extern void  IGDrawChicletHighlights(void *bitmap, void *shape);    /* 0xd0d0 */
extern void  IGDrawOutline(void *bitmap, void *shape, const float *mask,
                           float minLum, float maxLum);            /* 0xd9f4 */
extern void  IGDrawGroup(void *bitmap, const float *srcRGB,
                         const float *srcA, const void *params);   /* 0xbdec */
extern void  blurPlane(float *plane, S64 side, float sigma);       /* 0xbde4 -> 0xcf50 gaussianBlur */
extern void  IGGaussianBlurPublic(float *plane, S64 side, float sigma); /* 0xbde8 -> 0xcf50 */

/* 全局 / 导入符号 ------------------------------------------------------ */
extern U8   gGlassNoEdge;         /* 0x18d68, __DATA, 1 字节 */
extern const CGAffineTransform kCGAffineTransformIdentity;  /* 0x14658 __got */
extern CFStringRef kCGColorSpaceSRGB;                       /* 0x14858 __got */

/* ------------------------------------------------------------------ */
/* 结构体（由反汇编精确推出）                                          */
/* ------------------------------------------------------------------ */

/* IGBitmap: 只有 "边长 + 浮点缓冲" 两个字段，IGDrawGroup / IGDrawChicletHighlights
 * / IGDrawOutline 都按这个布局读取（+0x00 边长，+0x08 数据指针）。
 *   NGCreateGlassIcon      : sp+0x248
 *   NGCreateRimmedImage    : sp+0x010
 *   NGCreateGlassedImage   : sp+0x0d0
 */
typedef struct {
    S64    px;          /* +0x00  (IGDrawGroup 用 ldrsw 读，按 int 使用) */
    float *buf;         /* +0x08  RGB(A) 浮点平面 */
} IGBitmap;

/* IGDrawCtx: 传给 drawFill/drawNode/drawElement 的绘制上下文
 * (NGCreateGlassIcon 中位于 sp+0x258)
 *   +0x00 size_t px                 (0x258)
 *   +0x08 size_t px                 (0x260)
 *   +0x10 CGAffineTransform ctm     (0x268 .. 0x298)
 *   +0x40 CGPoint origin            (0x298)
 *   +0x50 CGSize  size              (0x2a8)
 *   +0x60 BOOL    foregroundOnly    (0x2b8)
 */
typedef struct {
    size_t          px0;
    size_t          px1;
    CGAffineTransform ctm;
    CGPoint         origin;
    CGSize          size;
    BOOL_t          foregroundOnly;
} IGDrawCtx;

/* IGGroupParams: IGDrawGroup 的参数块（共 0x14 字节）
 *   NGCreateGlassIcon    : sp+0x380
 *   NGCreateGlassedImage : sp+0x0bc
 */
typedef struct {
    float   translucency;   /* +0x00 */
    U8      specular;       /* +0x04 */
    U8      hasLighting;    /* +0x05 */
    U8      _pad06[2];      /* +0x06 */
    S32     shadowStyle;    /* +0x08 */
    float   shadowOpacity;  /* +0x0c */
    U8      isBright;       /* +0x10  (测得的最大 HSL 亮度 >= 0.99) */
    U8      _pad11[3];      /* +0x11..0x13 */
} IGGroupParams;

/* ------------------------------------------------------------------ */
/* 数值常量（原始地址 / 位模式见注释）                                 */
/* ------------------------------------------------------------------ */
#define kDefaultSide          0x400      /* 1024: stack width/height 为 0 时的兜底 */
#define kBitmapInfoBGRA8      0x2002u    /* kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst */
#define kInterpQualityHigh    3
#define kMaxChannelF          255.0f     /* 0x437f0000 */
#define kF255D                255.0
#define kOneF                 1.0f
#define kHalfF                0.5f       /* NGCreateGlassIcon 0x6ccc: fmov s8,#0.5 */
#define kCmp99F               0.99f      /* 0x3f7d70a4 */
#define kCmp80F               0.80f      /* 0x3f4ccccd */

/* 版面枚举（NGRendition.layout） */
#define kLayoutFillA          0x3fd      /* 0x68f8 @0x6e3c: 走 drawFill 分支 1 */
#define kLayoutFillB          0x3f1      /* 0x68f8 @0x6e4c: 走 drawFill 分支 2 */
#define kLayoutNode           0x3fc      /* 0x68f8 @0x71c8: 走 drawNode 分支 */

/* ------------------------------------------------------------------ */
/* 常量表                                                              */
/* ------------------------------------------------------------------ */

/* __TEXT,__const 0x10b50 起（Rec.709 亮度系数，本组函数内未直接引用，仅 0x10b98 被
 * NGCreateGlassedImage 用到；见文件末尾注释）
 *   0x10b58 = 0.7152 (G)
 *   0x10b60 = 0.0722 (B)
 *   0x10b68 = 0.2126 (R)
 *   0x10b70 = 0.2
 *   0x10b78 = -0.1
 *   0x10b80 = -0.2
 *   0x10b88 = 0.1
 *   0x10b90 = 0.9
 *   0x10b98 = 0.01        <-- NGCreateGlassedImage @0xa9b4
 */

/* 0x10d00: 4 个角采样点（单位化坐标），每项 2 个 float
 *   idx0 (0.14, 0.14)  idx1 (0.86, 0.14)  idx2 (0.86, 0.86)  idx3 (0.14, 0.86)
 *   0x10d00: 0.14  0x10d04: 0.14
 *   0x10d08: 0.86  0x10d0c: 0.14
 *   0x10d10: 0.86  0x10d14: 0.86
 *   0x10d18: 0.14  0x10d1c: 0.86
 * 注意：load 是 "ldp s2, s1"，即 s2 = [addr] (y 方向系数), s1 = [addr+4] (x 方向系数)。
 */
static const float kCornerFractions[4][2] = {
    { 0.14f, 0.14f },   /* 0x10d00 */
    { 0.86f, 0.14f },   /* 0x10d08 */
    { 0.86f, 0.86f },   /* 0x10d10 */
    { 0.14f, 0.86f },   /* 0x10d18 */
};

/* 0x10c80..0x10cd0: vld4 去交错用 tbl 掩码（把 BGRA 交错字节抽成 4 个平面）
 *   0x10c80 = { 03 ff ff ff | 07 ff ff ff | 0b ff ff ff | 0f ff ff ff }
 *   0x10c90 = { 00 ff ff ff | 01 ff ff ff | 02 ff ff ff | 03 ff ff ff }
 *   0x10ca0 = { 04 .. | 05 .. | 06 .. | 07 .. }
 *   0x10cb0 = { 08 .. | 09 .. | 0a .. | 0b .. }
 *   0x10cc0 = { 0c .. | 0d .. | 0e .. | 0f .. }
 *   0x10cd0 = { 02 ff ff ff | 06 ff ff ff | 0a ff ff ff | 0e ff ff ff }
 */

/* ==================================================================== */
/* 1) NGCreateGlassIconContent  (0x68cc .. 0x68f8, 44 字节)            */
/* ==================================================================== */
// @addr 0x68cc NGCreateGlassIconContent
CGImageRef NGCreateGlassIconContent(id catalog, id stackName, int appearance, size_t px)
{
    CGImageRef img;

    /* 0x68d8: adrp x19,#0x18000 ; 0x68e0: strb #1,[x19,#0xd68]
     * 即 gGlassNoEdge = 1（"不要 chiclet 高光" 开关） */
    gGlassNoEdge = 1;

    /* 0x68e4: bl 0x68f8 —— 参数寄存器 x0..x3 原样透传，不做任何改动 */
    img = NGCreateGlassIcon(catalog, stackName, appearance, px);

    /* 0x68e8: strb wzr,[x19,#0xd68] —— 恢复 gGlassNoEdge = 0 */
    gGlassNoEdge = 0;

    return img;
}

/* ==================================================================== */
/* 2) NGCreateGlassIcon  (0x68f8 .. 0x7e68, 0x1570 字节)               */
/* ==================================================================== */
/*
 * 高层流程
 *   a. 解析 recipe：indexFor(catalog) -> findStack(index,name,appearance)
 *      取 appearance 对应的 variant 号（unsigned short）
 *   b. 从 stack 取 width/height（0 则 1024），建立 IGDrawCtx（含 y 翻转 CTM）
 *   c. 枚举 [stack.csi layerRefs] 里的每一个 NGLayerRef：
 *        - resolve(index, layer.keyList, variant) 得到 NGRendition
 *        - 按 rendition.layout 分三条路：
 *            0x3fd / 0x3f1  → drawFill      （"纯填充"元素）
 *            0x3fc          → drawNode      （节点图元）
 *            其它           → drawElement   （带 frame 的元素）
 *        - 把 BGRA 位图转成 RGB(A) 浮点平面
 *        - 对元素路径：用 IGDrawGroup 做玻璃合成（高光/阴影/半透明）
 *        - 把 alpha 以 1-(1-a)(1-b) 的方式并进覆盖率平面
 *   d. 所有 rendition 画完后：IGCreateIconShape(px)，再
 *        IGDrawChicletHighlights（除非 gGlassNoEdge）、IGDrawOutline
 *   e. 把浮点平面写回 BGRA（A=255）→ CGBitmapContextCreateImage
 */
// @addr 0x68f8 NGCreateGlassIcon
CGImageRef NGCreateGlassIcon(id catalog, NSString *stackName, int appearance, size_t px)
{
    CGImageRef        result      = NULL;   /* x21 */
    id                cat;                  /* x22 */
    NSString         *name;                 /* x23 */
    NGCatalogIndex   *index       = NULL;   /* x28 -> [sp+0x1a0] */
    id                stack       = NULL;   /* x22 -> [sp+0x08] */
    id                layerRefs   = NULL;   /* x22 -> [sp+0x138] */
    U32               variant     = 0;      /* w21, [sp+0x16c] */
    double            W, H;                 /* d8, d9 */
    S64               npix;                 /* x27 = (int)px * (int)px */
    S64               probeStep;            /* x12 = max(ceil(px/64),1) */
    float            *accum       = NULL;   /* [sp+0x250] RGB 累加平面, 3*npix float */
    float            *elemRGB     = NULL;   /* x24, 3*npix float */
    float            *elemA       = NULL;   /* x25, npix float */
    float            *cover       = NULL;   /* x21, npix float (alpha 并集) */
    float             minLum      = 1.0f;   /* s11, 跨 rendition 累计 */
    float             maxLum      = 0.0f;   /* s10, 跨 rendition 累计 */
    BOOL_t            allOK       = 1;      /* [sp+0x1ac] 初值 1 */
    IGBitmap          bmp;                  /* sp+0x248 */
    IGDrawCtx         drawCtx;              /* sp+0x258 */
    void             *shape       = NULL;
    CGAffineTransform tmpCTM;

    cat  = objc_retain(catalog);
    name = objc_retain(stackName);

    if (!cat || !name || px == 0) {
        goto cleanup;                       /* 0x6960..0x6968 -> 0x7e08 */
    }

    /* ---- a. recipe 解析 ------------------------------------------- */
    index = objc_retainAutoreleasedReturnValue(indexFor(cat));            /* 0x6974 */
    stack = objc_retainAutoreleasedReturnValue(findStack(index, name, appearance)); /* 0x698c */
    if (!stack) {                                                          /* 0x699c */
        result = NULL;
        goto cleanup;                       /* -> 0x7c24 -> 0x7df8 */
    }

    /* 0x69a4..0x69c8: 外观键
     *   appearance == 1 -> "UIAppearanceDark"
     *   appearance == 2 -> "ISAppearanceTintable"
     *   否则             -> "UIAppearanceLight" */
    {
        CFStringRef appearanceKey =
            (appearance == 1) ? CFSTR("UIAppearanceDark") :
            (appearance == 2) ? CFSTR("ISAppearanceTintable") :
                                CFSTR("UIAppearanceLight");
        id key     = objc_retain((id)appearanceKey);                       /* 0x69cc */
        id appear  = objc_retainAutoreleasedReturnValue(msg_appearances(index)); /* 0x69d4 */
        id numObj  = objc_retainAutoreleasedReturnValue(
                        msg_objectForKeyedSubscript(appear, key));         /* 0x69ec */
        variant = msg_unsignedShortValue(numObj);                          /* [sp+0x16c] */
        objc_release(key);
        objc_release(numObj);
        objc_release(appear);
    }

    /* ---- b. 尺寸与 IGDrawCtx -------------------------------------- */
    /* 0x6a20: w = [stack width] ?: 0x400 ; 0x6a3c: h = [stack height] ?: 0x400 */
    {
        S32 w = msg_width(stack);
        S32 h;
        W = (double)(w != 0 ? w : kDefaultSide);   /* ucvtf d8 */
        h = msg_height(stack);
        H = (double)(h != 0 ? h : kDefaultSide);   /* ucvtf d9 */
    }

    npix      = (S64)(S32)px * (S64)(S32)px;       /* 0x6a54 smull x27,w20,w20 */
    probeStep = (S64)((S32)px + 63) >> 6;          /* 0x6b94..0x6ba0  ceil(px/64) */
    if (probeStep < 1) probeStep = 1;              /* 0x6ba8 csinc */

    /* DrawCtx（0x258）：身份 CTM -> 之后被替换 */
    drawCtx.px0 = px;
    drawCtx.px1 = px;
    /* 0x6a64..0x6a88: 从 kCGAffineTransformIdentity 拷 0x30 字节到 drawCtx.ctm */
    drawCtx.ctm = kCGAffineTransformIdentity;
    drawCtx.origin.x = 0.0;                        /* 0x6a90 */
    drawCtx.origin.y = 0.0;                        /* 0x6a8c */
    drawCtx.size.width  = W;                       /* 0x6a94 */
    drawCtx.size.height = H;                       /* 0x6a98 */
    drawCtx.foregroundOnly = 0;                    /* 0x6a9c */

    /* 0x6aa4..0x6acc:
     *   tmp = CGAffineTransformMakeTranslation(0, px);
     *   drawCtx.ctm = CGAffineTransformScale(tmp, px/W, -px/H);
     * 即：把 rendition 的 (0..W, 0..H) 映射到 px×px 位图，并把 y 轴翻转。 */
    tmpCTM = CGAffineTransformMakeTranslation(0.0, (double)px);
    drawCtx.ctm = CGAffineTransformScale(tmpCTM,
                                        (double)px / W,
                                        -(double)px / H);

    /* ---- 缓冲区 --------------------------------------------------- */
    accum   = (float *)calloc((size_t)(3 * npix), 4);      /* 0x6ae4 [sp+0x250] */
    elemRGB = (float *)malloc((size_t)(12 * npix));        /* 0x6af0 x24 */
    elemA   = (float *)malloc((size_t)(4  * npix));        /* 0x6afc x25 */
    cover   = (float *)calloc((size_t)npix, 4);            /* 0x6b0c x21 */

    bmp.px  = (S64)px;                             /* [sp+0x248] */
    bmp.buf = accum;                               /* [sp+0x250] */

    /* ---- c. 枚举 layerRefs --------------------------------------- */
    layerRefs = objc_retainAutoreleasedReturnValue(layerRefsOf(msg_csi(stack))); /* 0x6b28..0x6b44 */
    /* [sp+0x138] = layerRefs ；[sp+0x08] = stack */

    {
        NSFastEnumerationState feState;
        id                     batch[16];
        NSUInteger             batchCount;

        /* 0x6b14: movi v0.16b,#0 ; stp q0,q0,[sp+0x200] ; stp q0,q0,[sp+0x220]
         * 清零 NSFastEnumerationState（容量 16 个对象） */
        memset(&feState, 0, sizeof(feState));

        /* 0x6b64 / 0x6d18: countByEnumeratingWithState:objects:count: (count = 16)
         * 第一轮返回 0 就走 0x7c2c（allOK 保持 1，min/max 复位） */
        while ((batchCount = countByEnumeratingWithState(layerRefs, &feState,
                                                         batch, 16)) != 0) {
        for (NSUInteger bi = 0; bi < batchCount; bi++) {
        id      layer = batch[bi];
        id      keyList;
        id      rend;
        S32     layout;
        S32     rendDrawn;                          /* [sp+0x18c] */
        CGContextRef ctx;

        keyList = objc_retainAutoreleasedReturnValue(msg_keyList(layer));      /* 0x6d8c */
        rend    = objc_retainAutoreleasedReturnValue(resolve(index, keyList, variant)); /* 0x6da8 */
        objc_release(keyList);

        if (!rend) {                                 /* 0x6dc4 */
            allOK = 0;                               /* 0x6d3c: str wzr,[sp+0x1ac] */
            goto next_layer;                         /* -> 0x6d40 */
        }

        /* 0x6dcc..0x6dfc: 建 px×px 的 BGRA8 预乘位图 */
        {
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            ctx = CGBitmapContextCreate(NULL, (size_t)px, (size_t)px,
                                        8, 0, cs, kBitmapInfoBGRA8);
            CGColorSpaceRelease(cs);
        }
        if (!ctx) goto skip_draw_setup;              /* 0x6e00 -> 0x6e30 */

        CGContextSetInterpolationQuality(ctx, kInterpQualityHigh);            /* 0x6e0c */
        CGContextConcatCTM(ctx, &drawCtx.ctm);                                 /* 0x6e2c */

skip_draw_setup:
        layout = msg_layout(rend);                   /* 0x6e38 */

        if (layout == kLayoutFillA || layout == kLayoutFillB) {
            /* ================= 分支 1：纯填充 ================= */
            id nm = objc_retainAutoreleasedReturnValue(msg_name(rend));
            /* 0x6e68..0x6e8c:
             *   drawFill(ctx, index, name, variant, 0, 0, W, H, 1)
             *   实参: x0=ctx x1=index x2=name x3=variant
             *         d0=0 d1=0 d2=W d3=H w4=1 */
            rendDrawn = drawFill(ctx, index, nm, variant, 0.0, 0.0, W, H, 1);
            objc_release(nm);
            /* [sp+0x18c] = rendDrawn */

            /* 0x6e9c..0x6fb8: 位图 -> accum 的 RGB 浮点（不除 alpha）
             *   行循环 y=0..px-1；内层 x=0..px-1；
             *   向量化形态：16 像素一组 ld4 + tbl 抽通道 + st3 写回。 */
            {
                U8    *base = (U8 *)CGBitmapContextGetData(ctx);
                size_t bpr  = CGBitmapContextGetBytesPerRow(ctx);
                if ((S32)px >= 1) {
                    for (size_t y = 0; y < (size_t)px; y++) {
                        const U8 *s = base + y * bpr;
                        float    *d = accum + y * (size_t)px * 3;
                        for (size_t x = 0; x < (size_t)px; x++) {
                            d[0] = (float)s[2] / kMaxChannelF;   /* R <- byte2 */
                            d[1] = (float)s[1] / kMaxChannelF;   /* G <- byte1 */
                            d[2] = (float)s[0] / kMaxChannelF;   /* B <- byte0 */
                            s += 4;
                            d += 3;
                        }
                    }
                }
            }

            /* 0x7148..0x7198: 粗糙亮度探针
             *   起点：accum + (px/2)*3 + 2（即 (px/2,0) 像素的 B 分量之后）
             *   像素步长：px * probeStep
             *   迭代次数：px / probeStep  （约 64 次）
             *   亮度 L = (max(r,g,b) + min(r,g,b)) * 0.5
             * 注意：这里只读不写，且步长与计数步长不成比例，属于故意抽样。
             * TODO(未确定): 抽样点为 (px/2,0) 起、按 px*probeStep 像素跨越整个缓冲，
             *               抽样个数 = ceil(px/probeStep)，疑似“粗测整体亮度”启发式。 */
            if ((S32)px >= 1) {
                const float *p   = accum + ((size_t)px / 2) * 3 + 2;
                size_t       step = (size_t)px * (size_t)probeStep * 3; /* 以 float 计 */
                for (size_t i = 0; i < (size_t)px; i += (size_t)probeStep) {
                    float r = p[-2], g = p[-1], b = p[0];
                    float hi = fmaxf(r, fmaxf(g, b));
                    float lo = fminf(r, fminf(g, b));
                    float l  = (hi + lo) * kHalfF;
                    minLum = fminf(minLum, l);
                    maxLum = fmaxf(maxLum, l);
                    p += step;
                }
            }
            /* 0x71a4 -> 0x7c10（填充路径不调用 IGDrawGroup） */
        } else {
            /* ================= 分支 2/3：节点 / 元素 ================= */
            if (layout == kLayoutNode) {
                /* 0x71d0..0x71e8: drawNode(ctx, &drawCtx, cat, index, rend, variant) */
                rendDrawn = drawNode(ctx, &drawCtx, cat, index, rend, variant);
            } else {
                /* 0x71f0..0x7214: rect = [layer frame]；若 frame.size.width > 0
                 * 则再取一次 [layer frame]，否则用 (0,0,W,H)。
                 * 第二次 frame 调用的 d0..d3 直接作为 drawElement 的 x,y,w,h。 */
                CGRect frame;
                if (msg_frame(layer).size.width > 0.0) {
                    frame = msg_frame(layer);
                } else {
                    frame.origin.x = 0.0;
                    frame.origin.y = 0.0;
                    frame.size.width  = W;
                    frame.size.height = H;
                }
                /* 0x7218..0x7230:
                 *   drawElement(ctx, &drawCtx, cat, index, rend, layer, variant,
                 *               frame.x, frame.y, frame.w, frame.h) */
                rendDrawn = drawElement(ctx, &drawCtx, cat, index, rend, layer,
                                        variant,
                                        frame.origin.x, frame.origin.y,
                                        frame.size.width, frame.size.height);
            }
            /* [sp+0x18c] = rendDrawn */

            /* 0x7238..0x73a0: 位图 -> elemRGB（反预乘）+ elemA
             *   a   = byte3 / 255
             *   k   = (a > 0) ? 1/a : 1.0      // 标量路径 a<=0 时给 0，因 RGB=0 结果一致
             *   elemA[i]     = a
             *   elemRGB[i].r = (byte2/255) * k
             *   elemRGB[i].g = (byte1/255) * k
             *   elemRGB[i].b = (byte0/255) * k
             * 向量化形态：16 像素 ld4 + tbl 抽 A / 各通道 + st3。 */
            {
                U8    *base = (U8 *)CGBitmapContextGetData(ctx);
                size_t bpr  = CGBitmapContextGetBytesPerRow(ctx);
                if ((S32)px >= 1) {
                    for (size_t y = 0; y < (size_t)px; y++) {
                        const U8 *s = base + y * bpr;
                        float    *d = elemRGB + y * (size_t)px * 3;
                        float    *a = elemA + y * (size_t)px;
                        for (size_t x = 0; x < (size_t)px; x++) {
                            float av  = (float)s[3] / kMaxChannelF;
                            float inv = (av > 0.0f) ? (1.0f / av) : 1.0f;
                            a[0] = av;
                            d[0] = ((float)s[2] / kMaxChannelF) * inv;
                            d[1] = ((float)s[1] / kMaxChannelF) * inv;
                            d[2] = ((float)s[0] / kMaxChannelF) * inv;
                            s += 4; d += 3; a += 1;
                        }
                    }
                }
            }

            /* ---- 0x797c: rendition 收尾 --------------------------- */
            {
                float opacity = msg_opacity(layer);
                /* 0x7984..0x79b8: opacity < 1.0 且 px!=0 时把 elemA 整片乘上去 */
                if (opacity < 1.0f && px != 0) {
                    size_t n = (size_t)npix;
                    for (size_t i = 0; i < n; i++)
                        elemA[i] *= opacity;
                }

                float translucency = msg_translucency(layer);   /* s12, 0x79c0 */
                U8    specular     = msg_specular(layer);       /* [sp+0x104], 0x79cc */

                /* 0x79d4..0x7ab4: hasLighting
                 *   layout == 0x3fc  -> 枚举 [[rend csi] layerRefs]，任一 lighting 非 0 即 YES
                 *   否则             -> [layer lighting] */
                U8 hasLighting;
                if (layout == kLayoutNode) {
                    id refs = objc_retainAutoreleasedReturnValue(
                                  layerRefsOf(msg_csi(rend)));
                    NSFastEnumerationState ls;
                    id lbatch[16];
                    NSUInteger lcount;
                    hasLighting = 0;
                    memset(&ls, 0, sizeof(ls));      /* 0x79e0: movi v0,#0 ; stp q0,q0,[sp+0x2c0] */
                    if (refs) {
                        while ((lcount = countByEnumeratingWithState(refs, &ls,
                                                                     lbatch, 16)) != 0) {
                            NSUInteger li;
                            for (li = 0; li < lcount; li++) {
                                if (msg_lighting(lbatch[li])) { hasLighting = 1; break; }
                            }
                            if (hasLighting) break;
                        }
                    }
                    objc_release(refs);
                } else {
                    hasLighting = msg_lighting(layer);
                }

                S32   shadowStyle   = msg_shadowStyle(layer);    /* x28, 0x7ac0 */
                float shadowOpacity = msg_shadowOpacity(layer);  /* s0, 0x7ad0 */

                IGGroupParams p;
                /* 0x7ad4: s1 = 0x3f7d70a4 = 0.99f */
                p.translucency  = translucency;                  /* 0x380 */
                p.specular      = specular;                      /* 0x384 */
                p.hasLighting   = hasLighting;                   /* 0x385 */
                p._pad06[0] = p._pad06[1] = 0;                   /* 0x386 */
                p.shadowStyle   = shadowStyle;                   /* 0x388 */
                p.shadowOpacity = shadowOpacity;                 /* 0x38c */
                p.isBright      = (maxLum >= kCmp99F) ? 1 : 0;   /* 0x390 */
                p._pad11[0] = p._pad11[1] = p._pad11[2] = 0;     /* 0x391..0x393 */

                /* 0x7b24: IGDrawGroup(&bmp, elemRGB, elemA, &p)
                 *   bmp.buf = accum（累加平面） */
                IGDrawGroup(&bmp, elemRGB, elemA, &p);

                /* 0x7b28..0x7c0c: 覆盖率并集
                 *   cover[i] = 1 - (1 - cover[i]) * (1 - elemA[i])
                 * 向量化形态：8 个 float 一组 (ldp q / fsub / fmls / stp)。 */
                if (px != 0) {
                    size_t n = (size_t)npix;
                    for (size_t i = 0; i < n; i++) {
                        cover[i] = 1.0f - (1.0f - cover[i]) * (1.0f - elemA[i]);
                    }
                }
            }
        }

        /* 0x7c10: allOK &= rendDrawn ; 释放位图上下文 */
        allOK = allOK && rendDrawn;
        objc_release(rend);
        CGContextRelease(ctx);

next_layer:
        ;
        } /* for bi */
        } /* while batch */
    }

after_layers:
    /* 0x7c3c: 结束枚举，释放 layerRefs */
    objc_release(layerRefs);

    /* ---- d. 形状 / 高光 / 描边 ----------------------------------- */
    shape = IGCreateIconShape((S64)px);                        /* 0x7c48 */
    if (shape) {
        /* 0x7c60: ldrb w8,[0x18d68] (gGlassNoEdge) */
        if (!gGlassNoEdge) {
            IGDrawChicletHighlights(&bmp, shape);              /* 0x7c70 */
        }
        /* 0x7c74..0x7c88: IGDrawOutline(&bmp, shape, cover, minLum, maxLum) */
        IGDrawOutline(&bmp, shape, cover, minLum, maxLum);
    }

    /* ---- e. 浮点平面 -> BGRA ------------------------------------- */
    if (allOK) {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);   /* 0x7ca0 */
        CGContextRef outCtx = CGBitmapContextCreate(NULL, (size_t)px, (size_t)px,
                                                    8, 0, cs, kBitmapInfoBGRA8); /* 0x7cc8 */
        CGColorSpaceRelease(cs);
        {
            U8    *dst = (U8 *)CGBitmapContextGetData(outCtx);       /* 0x7cdc */
            size_t bpr = CGBitmapContextGetBytesPerRow(outCtx);      /* 0x7ce8 */
            if ((S32)px >= 1) {
                for (size_t y = 0; y < (size_t)px; y++) {
                    U8          *o = dst + y * bpr;
                    const float *s = accum + y * (size_t)px * 3;
                    for (size_t x = 0; x < (size_t)px; x++) {
                        /* 0x7d34..0x7d8c：
                         *   clamp(c,0,1)*255 后四舍五入
                         *   o[0] = B(comp2)  o[1] = G(comp1)  o[2] = R(comp0)  o[3] = 255
                         * （这里不写 alpha 以外的通道，A 直接钉 0xff，符合"整枚图标不透明"） */
                        o[0] = (U8)(int)lrintf(fminf(fmaxf(s[2], 0.0f), 1.0f) * kMaxChannelF);
                        o[1] = (U8)(int)lrintf(fminf(fmaxf(s[1], 0.0f), 1.0f) * kMaxChannelF);
                        o[2] = (U8)(int)lrintf(fminf(fmaxf(s[0], 0.0f), 1.0f) * kMaxChannelF);
                        o[3] = 0xff;
                        o += 4; s += 3;
                    }
                }
            }
        }
        result = CGBitmapContextCreateImage(outCtx);              /* 0x7db8 */
        CGContextRelease(outCtx);                                 /* 0x7dc4 */
    } else {
        result = NULL;                                            /* 0x7dcc */
    }

    /* ---- 收尾 ---------------------------------------------------- */
    free(shape);            /* 0x7dd4 */
    free(accum);            /* 0x7ddc */
    free(elemRGB);          /* 0x7de4 */
    free(elemA);            /* 0x7dec */
    free(cover);            /* 0x7df0 */

cleanup:
    objc_release(stack);    /* 0x7df8  (x22, 即 [sp+0x08]) */
    /* TODO(未确定): 0x7dfc 释放的 x28 在收尾时可能是"最后一个 resolve 出来的 rendition"，
     *               也可能是 index（枚举为空时）。原码未清零，含义不唯一。 */
    objc_release(name);     /* 0x7e08 */
    objc_release(cat);      /* 0x7e10 */
    /* 0x7e18..0x7e2c: __stack_chk_guard 校验 */
    return result;
}

/* ==================================================================== */
/* 3) NGCreateRimmedImage  (0x9324 .. 0x996c, 0x648 字节)              */
/* ==================================================================== */
/*
 * "只描边 / Edge Only"：保留源图 alpha 形状，把颜色替换成
 * IGDrawChicletHighlights 写进 RGB 平面的高光，再乘回源 alpha 输出。
 * 不调用 IGDrawGroup（不做玻璃合成），也不检查 gGlassNoEdge。
 */
// @addr 0x9324 NGCreateRimmedImage
CGImageRef NGCreateRimmedImage(CGImageRef src)
{
    size_t        w, h, n, px;
    CGRect        rect;
    CGContextRef  ctx;
    CGImageRef    outImg = NULL;
    U8           *srcData;
    size_t        bpr;
    S64           npix;                    /* x27 */
    float        *rgbPlane = NULL;         /* x25, 3*npix float */
    float        *aPlane   = NULL;         /* x21, npix float */
    IGBitmap      bmp;                     /* sp+0x10 */
    void         *shape;

    if (!src) return NULL;                 /* 0x9324 */

    w = (size_t)CGImageGetWidth(src);      /* 0x935c */
    h = (size_t)CGImageGetHeight(src);     /* 0x9368 */
    n = (w > h) ? w : h;                   /* 0x9370 csel hi */
    if ((S32)n < 8) return NULL;           /* 0x9374 */

    px = n & 0x7fffffffu;                  /* 0x937c */

    /* 0x9380..0x93bc: SRGB + BGRA8 预乘位图 */
    {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, kBitmapInfoBGRA8);
        CGColorSpaceRelease(cs);
    }
    if (!ctx) return NULL;                 /* 0x93c0 -> 0x9830 */

    npix = (S64)(S32)px * (S64)(S32)px;    /* 0x93c4 umull */

    CGContextSetInterpolationQuality(ctx, kInterpQualityHigh);   /* 0x93d0 */
    /* 0x93d4..0x93ec: CGRectMake(0,0,n,n) 后 CGContextDrawImage
     *  —— 目的位图因此带上了源图的 alpha（后续不再写 A 通道） */
    rect.origin.x = 0.0;
    rect.origin.y = 0.0;
    rect.size.width  = (double)n;
    rect.size.height = (double)n;
    CGContextDrawImage(ctx, rect, src);

    srcData = (U8 *)CGBitmapContextGetData(ctx);          /* 0x93f4 */
    bpr     = CGBitmapContextGetBytesPerRow(ctx);         /* 0x9400 */

    /* 0x9408: bmp { px = n, buf = 0 }，buf 稍后填 */
    bmp.px  = (S64)n;
    bmp.buf = NULL;

    rgbPlane = (float *)malloc((size_t)(12 * npix));      /* 0x941c -> x25 */
    aPlane   = (float *)malloc((size_t)(4  * npix));      /* 0x942c -> x21 */
    bmp.buf  = rgbPlane;                                  /* [sp+0x18] */

    /* 0x9434..0x95c0: 位图 -> 浮点
     *   行循环 y=0..px-1，内层 x；向量化 8/16 像素一组。
     *   a   = byte3/255
     *   k   = (a>0) ? 1/a : 0.0
     *   aPlane[i]       = a
     *   rgbPlane[i].r   = (byte2/255)*k
     *   rgbPlane[i].g   = (byte1/255)*k
     *   rgbPlane[i].b   = (byte0/255)*k */
    for (size_t y = 0; y < px; y++) {
        const U8 *s = srcData + y * bpr;
        float    *d = rgbPlane + y * px * 3;
        float    *a = aPlane   + y * px;
        for (size_t x = 0; x < px; x++) {
            float av  = (float)s[3] / kMaxChannelF;
            float inv = (av > 0.0f) ? (1.0f / av) : 0.0f;
            a[0] = av;
            d[0] = ((float)s[2] / kMaxChannelF) * inv;
            d[1] = ((float)s[1] / kMaxChannelF) * inv;
            d[2] = ((float)s[0] / kMaxChannelF) * inv;
            s += 4; d += 3; a += 1;
        }
    }

    /* 0x9838..0x9850: 生成形状并叠加 chiclet 高光（无 gGlassNoEdge 判断） */
    shape = IGCreateIconShape((S64)n);
    if (shape) {
        IGDrawChicletHighlights(&bmp, shape);
    }

    /* 0x9854..0x9908: 浮点 -> BGRA（重新预乘，A 通道保持源图 alpha 不动）
     *   o[1] = R*255*a ; o[0] = G*255*a ; o[-1] = B*255*a
     *   注意：这里**没有**写 o[2] (alpha)，位图里的 A 来自 0x93ec 的 DrawImage。 */
    for (size_t y = 0; y < px; y++) {
        U8          *o = srcData + y * bpr + 1;    /* 从 byte1 起算 */
        const float *s = rgbPlane + y * px * 3;
        const float *a = aPlane   + y * px;
        for (size_t x = 0; x < px; x++) {
            float av = a[0];
            o[1]  = (U8)(int)lrintf(fminf(fmaxf(s[0], 0.0f), 1.0f) * kMaxChannelF * av); /* R */
            o[0]  = (U8)(int)lrintf(fminf(fmaxf(s[1], 0.0f), 1.0f) * kMaxChannelF * av); /* G */
            o[-1] = (U8)(int)lrintf(fminf(fmaxf(s[2], 0.0f), 1.0f) * kMaxChannelF * av); /* B */
            o += 4; s += 3; a += 1;
        }
    }

    outImg = CGBitmapContextCreateImage(ctx);      /* 0x9910 */
    CGContextRelease(ctx);                         /* 0x9918 */
    free(shape);                                   /* 0x9924 */
    free(rgbPlane);                                /* 0x992c */
    free(aPlane);                                  /* 0x9934 */
    return outImg;
}

/* ==================================================================== */
/* 4) NGCreateGlassedImage  (0x996c .. 0xacc4, 0x1358 字节)            */
/* ==================================================================== */
/*
 * 通用"玻璃化"处理（源图 + 可选 out 标志）：
 *   1. 把源图画进 px×px 的 BGRA8 位图，反预乘成 rgb / alpha 两个浮点平面。
 *   2. 用 4 个角部区域（0.14/0.86）统计平均色，做双线性渐变拟合，
 *      再在中央 5%..95% 区域抽样验证：>=80% 像素误差 < 0.12 视为"平滑背景"，
 *      记 smooth=1（用解析渐变），否则 smooth=0（用模糊/修补出的真实背景）。
 *   3. smooth==0 时：4 轮 "mask*RGB 模糊 / mask 模糊 → 相除" 修补
 *      （sigma = px/12，每轮重算 mask：alpha>=0.99 且 |orig-bg|<0.12）。
 *   4. 逐像素生成折射背景色（渐变或修补色），并算边缘因子
 *        d = max|orig-background|（smooth 时 d=(d+0.01)/0.1，否则 (d-0.1)/0.12）
 *        f = smoothstep(clamp(d,0,1)) = x^2*(3-2x)
 *      f>0.01 时输出 out = (orig - bg*(1-f))/f（增强折射），否则 out = orig。
 *   5. 全部 f 的均值 avg：0.01 < avg < 0.85 才算"真的玻璃化了"(ret)。
 *   6. 是则用 IGDrawGroup 处理；否则把原图 rgb 拷回去。
 *   7. IGCreateIconShape + IGDrawChicletHighlights + （ret 时）IGDrawOutline，
 *      最后浮点 -> BGRA（重新预乘，A 保留源图 alpha）。
 */
// @addr 0x996c NGCreateGlassedImage
CGImageRef NGCreateGlassedImage(CGImageRef src, BOOL_t *outGlassed)
{
    size_t        w, h, n, px;
    CGRect        rect;
    CGContextRef  ctx = NULL;
    CGImageRef    outImg = NULL;
    U8           *srcData;
    size_t        bpr;
    S64           npix;                    /* x28 = px*px */
    S64           rgbBytes;                /* [sp+0x40] = 12*npix */
    S64           aBytes;                  /* [sp+0x98] = 4*npix  */
    /* 反汇编里另有 rgbStride = 12*px (x27) 与 aStride = 4*px (x30)，
     * 仅用于向量化循环的指针步进，语义已在下面的标量循环中体现。 */
    float        *rgb       = NULL;        /* x22 反预乘 RGB, 3*npix */
    float        *alpha     = NULL;        /* x23 alpha, npix */
    float        *bg        = NULL;        /* x27 修补/背景 RGB（smooth==0 时） */
    float        *outRGB    = NULL;        /* x21 输出 RGB */
    float        *edgeF     = NULL;        /* x19 输出边缘因子 */
    float        *mask      = NULL;        /* x21 -> [sp+0xb0] 二值 mask */
    float        *tmp1      = NULL;        /* x19 */
    float        *tmp2      = NULL;        /* x26 */
    float        *outBuf    = NULL;        /* [sp+0x08]/[sp+0xd8] 位图缓冲 */
    IGBitmap      bmp;                     /* sp+0xd0 */
    void         *shape     = NULL;
    BOOL_t        smooth    = 0;           /* w26 */
    BOOL_t        didGlass  = 0;           /* w24 */
    float         cornerC[4][3];           /* x29-0xd0, 4 个角 RGB 均值 */
    double        avgEdge;                 /* d20 / npix */
    float         minLum = 1.0f, maxLum = 0.0f;

    if (outGlassed) *outGlassed = 0;                       /* 0x99b4..0x99b8 */
    if (!src) return NULL;                                 /* 0x99bc */

    w = (size_t)CGImageGetWidth(src);                      /* 0x99c4 */
    h = (size_t)CGImageGetHeight(src);                     /* 0x99d0 */
    n = (w > h) ? w : h;                                   /* 0x99d8 */
    if ((S32)n < 0x10) return NULL;                        /* 0x99dc: 少于 16 直接退出 */

    px = n & 0x7fffffffu;                                  /* 0x99e4 */

    /* 0x99e8..0x9a28: SRGB + BGRA8 预乘 */
    {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, kBitmapInfoBGRA8);
        CGColorSpaceRelease(cs);
    }
    if (!ctx) return NULL;                                 /* 0x9a28 -> 0x9e7c */

    npix     = (S64)(S32)px * (S64)(S32)px;                /* 0x9a30 */
    rgbBytes = 12 * npix;                                  /* 0x9a78..0x9a80 */
    aBytes   = 4  * npix;                                  /* 0x9a90..0x9a94 */

    CGContextSetInterpolationQuality(ctx, kInterpQualityHigh);   /* 0x9a3c */
    rect.origin.x = 0.0; rect.origin.y = 0.0;
    rect.size.width = rect.size.height = (double)n;               /* 0x9a40..0x9a58 */
    CGContextDrawImage(ctx, rect, src);

    srcData = (U8 *)CGBitmapContextGetData(ctx);           /* 0x9a60 */
    bpr     = CGBitmapContextGetBytesPerRow(ctx);          /* 0x9a70 */

    rgb   = (float *)malloc((size_t)rgbBytes);             /* 0x9a84 -> x22 */
    alpha = (float *)malloc((size_t)aBytes);               /* 0x9a98 -> x23 */

    /* 0x9aa0..0x9be0: 位图 -> rgb（反预乘）/ alpha
     *   a   = byte3/255 ; k = (a>0) ? 1/a : 0
     *   alpha[i] = a
     *   rgb[i].r/g/b = (byte2/byte1/byte0 / 255) * k
     * 向量化：8/16 像素一组 ld4 + tbl。 */
    for (size_t y = 0; y < px; y++) {
        const U8 *s = srcData + y * bpr;
        float    *d = rgb   + y * px * 3;
        float    *a = alpha + y * px;
        for (size_t x = 0; x < px; x++) {
            float av  = (float)s[3] / kMaxChannelF;
            float inv = (av > 0.0f) ? (1.0f / av) : 0.0f;
            a[0] = av;
            d[0] = ((float)s[2] / kMaxChannelF) * inv;
            d[1] = ((float)s[1] / kMaxChannelF) * inv;
            d[2] = ((float)s[0] / kMaxChannelF) * inv;
            s += 4; d += 3; a += 1;
        }
    }

    /* ---- 2) 4 个角部平均色 --------------------------------------- */
    /* 0x9ec8..0x9fe8
     *   step = max(px/40, 1)                 (0xcccccccd >> 37 = /40)
     *   角块 = 以 (fracX*px, fracY*px) 为中心、半边 step 的方形
     *   只统计 alpha >= 0.99f 的像素
     *   任一角块没有任何不透明像素 -> 直接放弃渐变（跳去 0xa1c4 的修补路径） */
    {
        S32 step = (S32)px / 40;
        if (step < 1) step = 1;

        for (int c = 0; c < 4; c++) {
            /* ldp s2,s1 -> s2 = [addr] (y 系数), s1 = [addr+4] (x 系数) */
            float fy = kCornerFractions[c][0];
            float fx = kCornerFractions[c][1];
            S32   y0 = (S32)(fx * (float)px);       /* 注意：asm 先算 s1(x) 作为 y 游标 */
            S32   x0 = (S32)(fy * (float)px);
            S32   yBeg = y0 - step, yEnd = y0 + step;
            S32   xBeg = x0 - step, xEnd = x0 + step;
            float accR = 0.0f, accG = 0.0f, accB = 0.0f;
            S32   cnt  = 0;

            for (S32 yy = yBeg; yy < yEnd; yy++) {
                if (yy < 0 || yy >= (S32)px) continue;
                for (S32 xx = xBeg; xx < xEnd; xx++) {
                    if (xx < 0 || xx >= (S32)px) continue;
                    size_t i = (size_t)yy * (size_t)px + (size_t)xx;
                    if (alpha[i] < kCmp99F) continue;    /* 0x9fa0 fcmp 0.99 / b.mi */
                    accR += rgb[i * 3 + 0];
                    accG += rgb[i * 3 + 1];
                    accB += rgb[i * 3 + 2];
                    cnt++;
                }
            }
            if (cnt == 0) { smooth = 0; goto do_inpaint; }  /* 0x9fc4 -> 0xa1c4 */
            cornerC[c][0] = accR / (float)cnt;
            cornerC[c][1] = accG / (float)cnt;
            cornerC[c][2] = accB / (float)cnt;
        }
    }

    /* ---- 2b) 双线性拟合验证 ------------------------------------- */
    /* 0x9ff0..0xa1bc
     *   m = (int)(px*0.05f)  (0x3d4ccccd)
     *   若 px-m <= m  -> 放弃渐变
     *   k = (int)(px*0.09f)  (0x3db851ec)
     *   在 [m, px-m) × [m, px-m) 内逐像素与双线性插值比较，
     *   误差 = max(|dr|,|dg|,|db|)，误差 < 0.12f (0x3df5c28f) 记为"匹配"
     *   匹配率 >= 80% (0x3f4ccccd) -> smooth = 1（用渐变）
     *   否则 smooth = 0（去修补路径 0xa1c4） */
    {
        S32 m = (S32)((float)px * 0.05f);
        if ((S32)px - m <= m) { smooth = 0; goto do_inpaint; }

        S32 k = (S32)((float)px * 0.09f);
        S32 lo = m, hiRow = (S32)px - m;
        S32 colLo = k, colHi = (S32)px - k;
        S32 total = 0, match = 0;
        float dRu = cornerC[1][0] - cornerC[0][0];
        float dGu = cornerC[1][1] - cornerC[0][1];
        float dBu = cornerC[1][2] - cornerC[0][2];
        float dRv = cornerC[2][0] - cornerC[3][0];
        float dGv = cornerC[2][1] - cornerC[3][1];
        float dBv = cornerC[2][2] - cornerC[3][2];

        for (S32 yy = lo; yy < hiRow; yy++) {
            float v = (float)yy / (float)((S32)px - 1);
            for (S32 xx = colLo; xx < colHi; xx++) {
                float u = (float)xx / (float)((S32)px - 1);
                size_t i = (size_t)yy * (size_t)px + (size_t)xx;
                float pR = (cornerC[0][0] + dRu * u) +
                           ((cornerC[3][0] + dRv * u) - (cornerC[0][0] + dRu * u)) * v;
                float pG = (cornerC[0][1] + dGu * u) +
                           ((cornerC[3][1] + dGv * u) - (cornerC[0][1] + dGu * u)) * v;
                float pB = (cornerC[0][2] + dBu * u) +
                           ((cornerC[3][2] + dBv * u) - (cornerC[0][2] + dBu * u)) * v;
                float e = fmaxf(fabsf(rgb[i * 3 + 0] - pR),
                                fabsf(rgb[i * 3 + 1] - pG));
                e = fmaxf(e, fabsf(rgb[i * 3 + 2] - pB));
                total++;
                if (e < 0.12f) match++;
            }
        }
        if (total < 1) { smooth = 0; goto do_inpaint; }
        if ((float)total * kCmp80F > (float)match) {
            smooth = 0;
            goto do_inpaint;                       /* 匹配率不足 80% */
        }
        smooth = 1;                                /* 0xa1b8: w26 = 1 */
        bg = NULL;
        goto have_background;                      /* -> 0xa758 */
    }

do_inpaint:
    /* ---- 3) 4 轮 mask 引导的模糊修补 ---------------------------- */
    /* 0xa1c4..0xa754
     *   bg    = malloc(12*npix)
     *   mask  = malloc(4*npix)   [sp+0xb0]
     *   tmp1  = malloc(4*npix)   (x19)
     *   tmp2  = malloc(4*npix)   (x26)
     *   sigma = px / 12.0f       (0xa31c)
     *   初始 mask[i] = (alpha[i] >= 0.99f) ? 1.0f : 0.0f        (0xa20c..0xa2b0)
     *   4 轮（w10 = 0..3，0xa32c 循环）：
     *     1) memcpy(tmp1, mask, aBytes); blurPlane(tmp1, n, sigma)
     *     2) tmp2[i] = rgb[i].r * mask[i];        blurPlane(tmp2, n, sigma)
     *        bg[i].r = (tmp1[i] > 1e-4f) ? tmp2[i]/tmp1[i] : rgb[i].r   (0x38d1b717 = 1e-4)
     *     3) 同理做 G（offset 4）与 B（offset 8）
     *     4) 重算 mask[i] = (alpha[i] >= 0.99f && max|rgb-bg| < 0.12f) ? 1 : 0
     *        (0xa60c..0xa738，向量化 4 像素；标量尾巴 0xa6ec..0xa734)
     */
    bg   = (float *)malloc((size_t)rgbBytes);              /* 0xa1c8 */
    mask = (float *)malloc((size_t)aBytes);                /* 0xa1dc [sp+0xb0] */
    tmp1 = (float *)malloc((size_t)aBytes);                /* 0xa1e8 x19 */
    tmp2 = (float *)malloc((size_t)aBytes);                /* 0xa1f4 x26 */

    for (size_t i = 0; i < (size_t)npix; i++)
        mask[i] = (alpha[i] >= kCmp99F) ? 1.0f : 0.0f;

    {
        float sigma = (float)px / 12.0f;                   /* 0xa31c s8 */
        for (int pass = 0; pass < 4; pass++) {
            /* 通道 c = 0(R) / 1(G) / 2(B)，偏移 4 字节 */
            for (int c = 0; c < 3; c++) {
                memcpy(tmp1, mask, (size_t)aBytes);
                blurPlane(tmp1, (S64)n, sigma);

                for (size_t i = 0; i < (size_t)npix; i++)
                    tmp2[i] = rgb[i * 3 + c] * mask[i];
                blurPlane(tmp2, (S64)n, sigma);

                for (size_t i = 0; i < (size_t)npix; i++)
                    bg[i * 3 + c] = (tmp1[i] > 1e-4f)
                                    ? (tmp2[i] / tmp1[i])
                                    : rgb[i * 3 + c];
            }

            /* 重算 mask：与背景足够接近且不透明的像素算"可继续扩散" */
            for (size_t i = 0; i < (size_t)npix; i++) {
                float e = fabsf(rgb[i * 3 + 0] - bg[i * 3 + 0]);
                e = fmaxf(e, fabsf(rgb[i * 3 + 1] - bg[i * 3 + 1]));
                e = fmaxf(e, fabsf(rgb[i * 3 + 2] - bg[i * 3 + 2]));
                mask[i] = (alpha[i] >= kCmp99F && e < 0.12f) ? 1.0f : 0.0f;
            }
        }
    }
    free(mask);   mask = NULL;      /* 0xa73c */
    free(tmp1);   tmp1 = NULL;      /* 0xa744 */
    free(tmp2);   tmp2 = NULL;      /* 0xa74c */
    smooth = 0;                     /* 0xa754: w26 = 0 */

have_background:
    /* ---- 4) 逐像素：背景色 + 边缘因子 --------------------------- */
    /* 0xa758..0xa9a4
     *   outRGB = malloc(12*npix)   (x21)
     *   edgeF  = calloc(npix,4)    (x19)
     *   u = x/(px-1), v = y/(px-1)
     *   smooth ? 双线性渐变 : bg[i]
     *   f = smoothstep(clamp((max|orig-out| 经过偏移/缩放), 0, 1))
     *      smooth : d = (d + 0.01f) / 0.1f      (0x3c23d70a / 0x3dcccccd)
     *      else   : d = (d - 0.1f)  / 0.12f     (0xbdcccccd / 0x3df5c28f)
     *   f > 0.01f (0x3c23d70a) 时 out = (orig - out*(1-f)) / f（夹到 [0,1]），
     *   否则 out = orig。
     *   avgEdge 累加 f（double），最后 / npix。
     */
    outRGB = (float *)malloc((size_t)rgbBytes);             /* 0xa75c */
    edgeF  = (float *)calloc((size_t)npix, 4);              /* 0xa76c */
    avgEdge = 0.0;

    for (size_t y = 0; y < (size_t)px; y++) {
        float v = (float)y / (float)((S32)px - 1);          /* s29 */
        for (size_t x = 0; x < (size_t)px; x++) {
            size_t i = y * (size_t)px + x;
            float u = (float)x / (float)((S32)px - 1);      /* s8 */
            float br, bgc, bb;
            float f;

            if (smooth) {
                br  = cornerC[0][0] + (cornerC[1][0] - cornerC[0][0]) * u;
                {
                    float t = cornerC[3][0] + (cornerC[2][0] - cornerC[3][0]) * u;
                    br = br + (t - br) * v;
                }
                bgc = cornerC[0][1] + (cornerC[1][1] - cornerC[0][1]) * u;
                {
                    float t = cornerC[3][1] + (cornerC[2][1] - cornerC[3][1]) * u;
                    bgc = bgc + (t - bgc) * v;
                }
                bb  = cornerC[0][2] + (cornerC[1][2] - cornerC[0][2]) * u;
                {
                    float t = cornerC[3][2] + (cornerC[2][2] - cornerC[3][2]) * u;
                    bb = bb + (t - bb) * v;
                }
            } else {
                br  = bg[i * 3 + 0];
                bgc = bg[i * 3 + 1];
                bb  = bg[i * 3 + 2];
            }
            outRGB[i * 3 + 0] = br;
            outRGB[i * 3 + 1] = bgc;
            outRGB[i * 3 + 2] = bb;

            if (alpha[i] >= 0.5f) {                          /* 0xa930 fcmp 0.5 / b.mi */
                float d = fabsf(rgb[i * 3 + 0] - br);
                d = fmaxf(d, fabsf(rgb[i * 3 + 1] - bgc));
                d = fmaxf(d, fabsf(rgb[i * 3 + 2] - bb));
                if (smooth) {
                    d = (d + 0.01f) / 0.1f;
                } else {
                    d = (d - 0.1f) / 0.12f;
                }
                if (d > 1.0f) d = 1.0f;
                if (d < 0.0f) d = 0.0f;
                f = d * d * (3.0f - 2.0f * d);               /* smoothstep, 0xa984..0xa98c */
                edgeF[i] = f;

                if (f > 0.01f) {                             /* 0xa998 b.gt */
                    /* out = (orig - bg*(1-f)) / f，逐通道夹到 [0,1] */
                    outRGB[i * 3 + 0] = (rgb[i * 3 + 0] - br  * (1.0f - f)) / f;
                    outRGB[i * 3 + 1] = (rgb[i * 3 + 1] - bgc * (1.0f - f)) / f;
                    outRGB[i * 3 + 2] = (rgb[i * 3 + 2] - bb  * (1.0f - f)) / f;
                    for (int c = 0; c < 3; c++) {
                        float q = outRGB[i * 3 + c];
                        if (q < 0.0f) q = 0.0f;
                        if (q > 1.0f) q = 1.0f;
                        outRGB[i * 3 + c] = q;
                    }
                } else {
                    outRGB[i * 3 + 0] = rgb[i * 3 + 0];       /* 0xa99c */
                    outRGB[i * 3 + 1] = rgb[i * 3 + 1];
                    outRGB[i * 3 + 2] = rgb[i * 3 + 2];
                }
                avgEdge += (double)f;                         /* 0xa880 fcvt/fadd */
            } else {
                edgeF[i] = 0.0f;                              /* 0xa92c s12 = 0 */
                outRGB[i * 3 + 0] = rgb[i * 3 + 0];
                outRGB[i * 3 + 1] = rgb[i * 3 + 1];
                outRGB[i * 3 + 2] = rgb[i * 3 + 2];
            }
        }
    }

    avgEdge /= (double)npix;                                  /* 0xa9a8..0xa9ac */

    /* 0xa9b0..0xa9d4:
     *   didGlass = (avgEdge > 0.01 && avgEdge < 0.85)
     *   （0x10b98 = 0.01 的 double；0x3feb333333333333 = 0.85） */
    didGlass = (!(avgEdge <= 0.01) && (avgEdge < 0.85)) ? 1 : 0;

    bmp.px  = (S64)n;                                         /* 0x9ec8 [sp+0xd0] */
    outBuf  = (float *)malloc((size_t)rgbBytes);              /* 0x9ed4 [sp+0xd8] */

    if (didGlass) {
        /* ---- 5) 背景亮度统计（只统计 edgeF<=0.1 的区域） -------- */
        /* 0xa9d8..0xaa??：
         *   起点 (px/8, px/8)，行列步长均为 max(px/32,1)，
         *   直到线性下标 >= px - px/8；
         *   只取 edgeF <= 0.1f (0x3dcccccd) 的像素；
         *   统计 HSL 亮度 L=(max+min)/2 的 min/max。
         */
        {
            S32 colStep = (S32)px >> 5;
            if (colStep < 1) colStep = 1;
            S32 start   = (S32)px >> 3;
            size_t limit = (size_t)px - (size_t)((S32)px >> 3);

            minLum = 1.0f;
            maxLum = 0.0f;
            for (size_t idx = (size_t)start * (size_t)px + (size_t)start;
                 idx < limit;
                 idx += (size_t)colStep * (size_t)px + (size_t)colStep) {
                /* TODO(未确定): asm 用的是 idx 线性递增 + 两个独立步长
                 * (行步长 (px/32)*px、列步长 (px/32))，终止条件按线性下标判，
                 * 并非严格二维网格；此处按等价线性推进还原。 */
                if (idx >= (size_t)npix) break;
                if (edgeF[idx] > 0.1f) continue;
                float r = outRGB[idx * 3 + 0];
                float g = outRGB[idx * 3 + 1];
                float b = outRGB[idx * 3 + 2];
                float hi = fmaxf(r, fmaxf(g, b));
                float lo = fminf(r, fminf(g, b));
                float l  = (hi + lo) * kHalfF;
                minLum = fminf(minLum, l);
                maxLum = fmaxf(maxLum, l);
            }

            /* 0xaad8..0xab2c: 参数 + IGDrawGroup
             *   translucency = 0.5f, specular = 1, hasLighting = 1,
             *   shadowStyle = (minLum >= 0.99f) ? 2 : 3,
             *   shadowOpacity = 0.5f,
             *   isBright = (maxLum >= 0.99f) */
            {
                IGGroupParams p;
                p.translucency  = 0.5f;                          /* [sp+0xbc] */
                p.specular      = 1;                             /* [sp+0xc0] */
                p.hasLighting   = 1;                             /* [sp+0xc1] */
                p._pad06[0] = p._pad06[1] = 0;
                p.shadowStyle   = (minLum >= kCmp99F) ? 2 : 3;   /* [sp+0xc4] */
                p.shadowOpacity = 0.5f;                          /* [sp+0xc8] */
                p.isBright      = (maxLum >= kCmp99F) ? 1 : 0;   /* [sp+0xcc] */
                p._pad11[0] = p._pad11[1] = p._pad11[2] = 0;     /* [sp+0xcd..0xcf] */

                bmp.buf = outBuf;
                IGDrawGroup(&bmp, outRGB, edgeF, &p);            /* 0xab2c */
            }
        }
    } else {
        /* 0xaabc..0xab30: 不做玻璃合成，直接沿用原 RGB */
        minLum = 1.0f;
        maxLum = 0.0f;
    }

    /* 0xab34: 释放 outRGB / 临时 */
    free(outRGB); outRGB = NULL;
    /* 0xab3c free(x26)：两种路径下 x26 为 0（已释放或未建），等价空操作 */

    /* ---- 6) 不是玻璃态就把原 RGB 拷进输出缓冲 ------------------- */
    if (!didGlass) {                                            /* 0xab44 tbnz */
        memcpy(outBuf, rgb, (size_t)rgbBytes);                  /* 0xab54 */
    }

    /* ---- 7) 形状 / 高光 / 描边 --------------------------------- */
    shape = IGCreateIconShape((S64)n);                           /* 0xab5c */
    if (shape) {
        bmp.buf = outBuf;
        IGDrawChicletHighlights(&bmp, shape);                    /* 0xab74 */
        if (didGlass) {
            /* 0xab90: IGDrawOutline(&bmp, shape, edgeF, minLum, maxLum)
             *   注意此处 x2 在 didGlass 路径上是 edgeF（未被释放） */
            IGDrawOutline(&bmp, shape, edgeF, minLum, maxLum);
        }
    }

    /* 0xab94..0xac60: 浮点 -> BGRA（重新预乘；A 保留 0x9a58 DrawImage 写入的源 alpha）
     *   o[1] = clamp(out.r)*255*a ; o[0] = clamp(out.g)*255*a ; o[-1] = clamp(out.b)*255*a */
    for (size_t y = 0; y < px; y++) {
        U8          *o = srcData + y * bpr + 1;
        const float *s = outBuf + y * px * 3;
        const float *a = alpha  + y * px;
        for (size_t x = 0; x < px; x++) {
            float av = a[0];
            o[1]  = (U8)(int)lrintf(fminf(fmaxf(s[0], 0.0f), 1.0f) * kMaxChannelF * av);
            o[0]  = (U8)(int)lrintf(fminf(fmaxf(s[1], 0.0f), 1.0f) * kMaxChannelF * av);
            o[-1] = (U8)(int)lrintf(fminf(fmaxf(s[2], 0.0f), 1.0f) * kMaxChannelF * av);
            o += 4; s += 3; a += 1;
        }
    }

    outImg = CGBitmapContextCreateImage(ctx);                     /* 0xac6c */
    CGContextRelease(ctx);                                       /* 0xac78 */
    free(shape);                                                 /* 0xac80 */
    free(outBuf);                                                /* 0xac88 */
    free(rgb);                                                   /* 0xac90 */
    free(alpha);                                                 /* 0xac98 */
    free(edgeF);                                                 /* 0xaca0 */
    free(bg);                                                    /* 0xaca8 */

    if (outGlassed) *outGlassed = didGlass;                      /* 0xacb4: strb w24 */
    return outImg;
}

/* ==================================================================== */
/* 5) _TEXT,__const 0x10b50 .. 0x10b70 常量用途确认                    */
/* ==================================================================== */
// @addr 0x10b50 __TEXT/__const (常量池)
/*
 *   0x10b50 : 00 00 00 c2 00 00 00 00
 *             **不是浮点**。这一 8 字节是被当成 64 位字整体搬运的
 *             block literal 头部 (flags = 0xC2000000, reserved = 0)：
 *               0x5574  indexFor   -> str d0,[sp,#0x18]（栈上的 block literal）
 *               0x7eac  layerRefs  -> str d0,[sp,#0x10]
 *             反汇编写成 "ldr d0" 只是因为编译器复用了 FP 寄存器做 8 字节拷贝。
 *             本文四个函数都不引用它。
 *   0x10b58 : 0.7152  ┐
 *   0x10b60 : 0.0722  ├ Rec.709 亮度系数 (G, B, R)。被 **double** 形式引用：
 *   0x10b68 : 0.2126  ┘   0x63a4 (NGCreateFlatIcon) / 0x880c (drawElement)，
 *                         用于 y = 0.2126R + 0.7152G + 0.0722B。
 *                         本文四个函数不使用。
 *   0x10b70 : 0.2
 *   0x10b78 : -0.1
 *   0x10b80 : -0.2
 *   0x10b88 : 0.1        —— 成对的 ±0.1/±0.2 阈值，供 0x8a08 (drawElement) 一类
 *                          代码做色阶量化；本文函数不使用。
 *   0x10b90 : 0.9        —— 0x8a08 (drawElement) 引用。
 *   0x10b98 : 0.01       —— **唯一被本文函数引用**：NGCreateGlassedImage @0xa9b4
 *                          fcmp d0, d1，即 "avgEdge > 0.01" 的下界判定。
 *
 * 结论：0x10b58..0x10b68 的 Rec.709 系数与本文 4 个函数无关，可忽略；
 *       0x10b50 根本就不是浮点，而是 block literal 的 flags/reserved 字。
 */

/* ==================================================================== */
/* 附：IGDrawGroup / blurPlane 的已知事实（不属本次还原范围，仅作旁证） */
/* ==================================================================== */
/*
 * IGDrawGroup(IGBitmap *bmp, const float *srcRGB, const float *srcA, const IGGroupParams *p)
 *   0xbdec:  ldrsw x22,[x0]        -> px
 *           getenv("IG_STEPS")     -> 默认 0x5df = 1503 步；环境变量给出负值时不改
 *                                    params->shadowStyle；>=0 时把 params->shadowStyle 置 0
 *           ldr x20,[x0,#8]        -> 目标缓冲
 *   p+0x08 = shadowStyle (int)，p+0x0c = shadowOpacity (float)
 *   即：1503 次迭代的 EDT/光照求解器，"IG_STEPS" 可覆盖迭代次数。
 *
 * blurPlane(0xbde4) 是 gaussianBlur(0xcf50) 的 4 字节尾跳转（同 IGGaussianBlurPublic 0xbde8）。
 */
