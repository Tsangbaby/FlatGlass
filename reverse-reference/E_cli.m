// =============================================================================
//  E_cli.m  ——  /var/jb/usr/libexec/flatglass 的伪源码重建
//  arm64 Mach-O，已 strip，仅保留函数名（_main / -[FlatRenderer xxx] / 静态函数）
//  本文档由反汇编还原，非原始源码；力求「可编译的结构 + 语义准确 + 常量忠实」。
//  地址标注为文件内 VM 地址，__TEXT 起始 0x100000000。
// =============================================================================
//
//  依赖（私有）：
//    CoreUI   : CUICatalog, -[CUICatalog imageWithName:scaleFactor:],
//               -[CUIRenditionKey ...] / -[CUIThemeRendition unslicedImage]
//    CoreSVG  : CGSVGDocumentCreateFromData / CGSVGDocumentRelease /
//               CGContextDrawSVGDocument / CGSVGDocumentGetCanvasSize  （全部 dlsym）
//    UIKit    : UIImage._applicationIconImageForBundleIdentifier:format:scale:
//    libnotify: notify_register_check / notify_get_state / notify_set_state / notify_post
//               notify_register_dispatch
//    libcompression: compression_decode_buffer(..., COMPRESSION_LZFSE)
// =============================================================================
//
//  main() 完整流程图（@0x1000065a4，长度 0x2f14，全部模式被内联进同一函数）
//  ---------------------------------------------------------------------------
//  main(argc, argv):
//    pool = objc_autoreleasePoolPush()
//    dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)   // 返回值丢弃
//    h = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_NOW)
//    if (h) {
//        CreateSVG = dlsym(h, "CGSVGDocumentCreateFromData")
//        ReleaseSVG= dlsym(h, "CGSVGDocumentRelease")
//        DrawSVG   = dlsym(h, "CGContextDrawSVGDocument")
//        SizeSVG   = dlsym(h, "CGSVGDocumentGetCanvasSize")
//    }
//
//    switch (argc) {
//    case 2:                                    // 守护模式 / 关闭
//        if (!strcmp(argv[1], "--disable")) return DisableMode();
//        if (!strcmp(argv[1], "--watch"))   return WatchMode();     // 永不返回(dispatch_main)
//        return 64;                                                 // usage
//    case 4:                                    // 子进程渲染 / 预览扫描
//        if (!strcmp(argv[1], "--preview-scan")) return PreviewScan(argv[2], argv[3]);
//        {   // ★ 内部渲染子进程：flatglass <Assets.car> <iconName> <out.png>
//            FlatRenderer *r = [[FlatRenderer alloc] initWithFile:
//                                    [NSURL fileURLWithPath:@(argv[1])]];
//            if (!r) return 2;                                     // 2 = “跳过/不支持”
//            BOOL ok = [r writeIcon:@(argv[2]) to:[NSURL fileURLWithPath:@(argv[3])]];
//            return !ok;
//        }
//    case 8:                                    // gloss 后处理
//        if (!strcmp(argv[1], "--gloss-icon")) return GlossIcon(argv+2);
//        return 64;
//    default:
//        return 64;
//    }
//
//  退出码约定（由各分支实测）：
//    0  成功
//    1  失败（渲染失败 / plist 写失败 / PNG 写失败 / 初始化失败）
//    2  FlatRenderer initWithFile: 失败 —— 父进程把 2 视为“Skip”而非“Unsupported”
//    64 usage 错误 (0x40)
//
//  DisableMode()   (@0x100006c38)
//    if (geteuid() == 0) {                      // 以 root 启动时降权到 mobile
//        pw = getpwnam("mobile");  if (!pw) return 1;
//        if (initgroups("mobile", pw->pw_gid)) return 1;
//        if (setgid(pw->pw_gid)) return 1;
//        if (setuid(pw->pw_uid)) return 1;
//    }
//    if (token == -1) notify_register_check(kModeNotify, &token);
//    notify_get_state(token, &state);
//    if (state == 3) return 0;                  // 已经是“关闭”态
//    notify_set_state(token, 3);
//    notify_post(kModeNotify);
//    return post 是否失败;
//
//  WatchMode()     (@0x1000066bc)
//    1) 三个主题目录取 realpath（stringByResolvingSymlinksInPath）
//    2) 读 /var/jb/var/mobile/Library/Preferences/com.spark.snowboardprefs.plist
//       → 可变字典（缺失则新建）
//    3) items = dict["ActiveMenuItems"]（非 NSArray 则用全局空数组）
//       过滤：剔除 realpath 等于上面三个主题目录的条目 → filtered
//       若 filtered != items:
//           dict["ActiveMenuItems"] = filtered
//           writeToFile: atomically:YES 失败 → stderr "FlatGlass: failed to unregister old themes.\n"
//           成功 → CFNotificationCenterPostNotification(refreshNow)
//    4) token = -1; notify_register_dispatch("local.lumid.flatglass.settings-changed",
//                                            &token, main_queue, ^(int){ PublishIconServicesMode(); })
//    5) PublishIconServicesMode();              // 启动即广播一次
//    6) dispatch_main();                        // 常驻
//
//  PublishIconServicesMode()   (@0x100009558；同体在 0x100007d64 被内联)
//    mode  = [plist["Mode"] integerValue]        // plist: /var/mobile/Library/Preferences/local.lumid.flatglass.plist
//    state = (mode >= 4) ? 1 : mode + 1          // ★ Mode → notify state 的映射
//    if (token == -1) notify_register_check(kModeNotify, &token);
//    notify_get_state(token, &cur);
//    if (cur != state) { notify_set_state(token, state); notify_post(kModeNotify); }
//    任一步失败 → stderr "FlatGlass: failed to publish mode.\n"
//
//  PreviewScan(themeDir, prefsDir)   (@0x100006858)
//    枚举 /var/containers/Bundle/Application/* + /Applications + /var/jb/Applications
//    取每个 "*.app" 目录（后缀 "app"）
//    对每个 app:
//        Info.plist → bid = CFBundleIdentifier；ValidIdentifier 且未出现过（按 bid 去重）
//        Assets.car 的 attributes 必须可读
//        CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName ?: CFBundleIconName（NSString 且非空）
//        outPath = themeDir + "/" + bid + "-large.png"
//        key     = "3|<appDir>|<iconName>|<CFBundleVersion>|<mtime>|<size>"   （另兼容 "2|..." 旧键）
//        若 key 一致且 文件存在性 == 缓存 rendered → 直接沿用
//        否则 fork 子进程 self(Assets.car, iconName, outPath)：
//              exit 0 → rendered = YES, rendered++
//              exit 2 → 静默（视为 Skip）
//              其它   → stderr "Unsupported icon: %s\n", unsupported++
//        记录 Apps.plist[bid] = {key, rendered, nativeHighlight}
//    最后若 (rendered|unsupported|changes) 非零：
//        printf("FlatGlass: %lu rendered, %lu unsupported, %lu changes.\n", ...)
//
//  GlossIcon(...)   (@0x100006bb4, argc==8)
//    argv = --gloss-icon <bundleid> <bundlePath> <out.png> <in.png> <gloss 0|1> <highlight 0|1>
//    见函数头注释。
//
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <pwd.h>
#import <grp.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <compression.h>
#import <math.h>
#import <stdio.h>
#import <errno.h>

// CoreSVG 函数指针（dlsym 得到，签名按调用点反推）
typedef void *(*CGSVGDocumentCreateFromData_t)(CFDataRef, int);
typedef void  (*CGSVGDocumentRelease_t)(void *);
typedef void  (*CGContextDrawSVGDocument_t)(CGContextRef, void *);
typedef CGSize (*CGSVGDocumentGetCanvasSize_t)(void *);

static CGImageRef ApplyGlossShine(CGImageRef base, CGImageRef fg, CGImageRef inImage);

// ---------------------------------------------------------------------------
// 全局（__DATA）
// ---------------------------------------------------------------------------
static int   gModeToken = -1;                 // @0x1000104b0  _PublishIconServicesMode.token
static void *gCreateSVG = NULL;               // @0x1000104b8  _CreateSVG
static void *gDrawSVG   = NULL;               // @0x1000104c0  _DrawSVG
static void *gSizeSVG   = NULL;               // @0x1000104c8  _SizeSVG
static void *gReleaseSVG= NULL;               // @0x1000104d0  _ReleaseSVG

static NSString *const kModeNotify      = @"local.lumid.flatglass.iconservices-mode";     // 0x10000b93d
static NSString *const kSettingsChanged = @"local.lumid.flatglass.settings-changed";      // 0x10000b992
static NSString *const kSnowBoardRefresh= @"com.spark.snowboard.refreshNow";              // 0x10000c310
static NSString *const kPrefsPath       = @"/var/mobile/Library/Preferences/local.lumid.flatglass.plist";
static NSString *const kSnowBoardPrefs  = @"/var/jb/var/mobile/Library/Preferences/com.spark.snowboardprefs.plist";
static NSString *const kThemeFlat       = @"/var/jb/Library/Themes/FlatGlass.theme";
static NSString *const kThemeGloss      = @"/var/jb/Library/Themes/FlatGlass Gloss.theme";
static NSString *const kThemeEdge       = @"/var/jb/Library/Themes/FlatGlass Edge.theme";
static NSString *const kSelfPath        = @"/var/jb/usr/libexec/flatglass";               // 0x10000bc13

// 空 NSArray 常量（@0x10000c9a0 指向的 __NSArray0 单例）
static NSArray *EmptyArray(void) { static NSArray *a; if (!a) a = @[]; return a; }

// ===========================================================================
//  基础工具函数
// ===========================================================================

// @0x100009668  CGImageRef FlatGlassLoadPNG(NSString *path)
//   等价于：CGImageSourceCreateWithURL([NSURL fileURLWithPath:path]) →
//           CGImageSourceCreateImageAtIndex(src, 0, NULL) → CFRelease(src)
//   失败/空路径返回 NULL。
static CGImageRef FlatGlassLoadPNG(NSString *path)
{
    if (!path || path.length == 0) return NULL;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}

// @0x100009700  BOOL FlatGlassDrawPixels(CGImageRef img, uint8_t *pixels, size_t side)
//   side x side 的 RGBA8888 位图（bytesPerRow = side*4，bitmapInfo = 0x4001
//   = kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast）
//   blendMode = 0x11 (kCGBlendModeCopy)，插值质量 = 3 (high)
//   返回 (ctx != NULL)。注意：返回值只表示 context 是否建成，图是否画成功不反馈。
static BOOL FlatGlassDrawPixels(CGImageRef img, uint8_t *pixels, size_t side)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels, side, side, 8, side * 4, cs,
                                            (CGBitmapInfo)0x4001);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextSetBlendMode(ctx, (CGBlendMode)0x11);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), img);
    CGContextRelease(ctx);
    return YES;
}

// @0x1000097b4  BOOL ValidIdentifier(id s)
//   isKindOfClass:NSString && 0 < length <= 0xFF && 不含
//   [a-zA-Z0-9.-] 之外的字符。
static BOOL ValidIdentifier(id s)
{
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *str = (NSString *)s;
    if (str.length > 0xFF) return NO;
    if (str.length == 0) return NO;
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    NSRange r = [str rangeOfCharacterFromSet:[allowed invertedSet]];
    return (r.location == NSNotFound);
}

// @0x100009880  int HasOriginalHighlight(NSString *bundlePath,
//                                        NSDictionary *primaryIcon,
//                                        NSString *renderedIconPath)
//  目的：判断“原版图标”在四角是否自带高光（用于 SnowBoard 的 nativeHighlight 标记）。
//  做法：把 120x120 的“原版 icon 文件”和“我们渲染出来的 icon”都栅格化成 120x120 RGBA，
//        取 4 个角、每角沿对角线取 28..91 号像素，比较两者 luma 差（含邻域），
//        统计超过阈值的像素数；两个计数器都 > 9 才算“有原生高光”。
static int HasOriginalHighlight(NSString *bundlePath, NSDictionary *primaryIcon,
                                NSString *renderedIconPath)
{
    if (![primaryIcon isKindOfClass:[NSDictionary class]]) return 0;
    NSArray *files = primaryIcon[@"CFBundleIconFiles"];          // 0x10000c5d0
    if (![files isKindOfClass:[NSArray class]]) return 0;

    CGImageRef rendered = FlatGlassLoadPNG(renderedIconPath);
    if (!rendered) return 0;

    int result = 0;
    for (id f in [files reverseObjectEnumerator]) {              // 倒序遍历
        if (![f isKindOfClass:[NSString class]]) continue;
        if ([(NSString *)f length] == 0) continue;

        NSString *base = [(NSString *)f stringByDeletingPathExtension];
        // 跳过带目录的条目（lastPathComponent 与原串不同）
        if (![[base lastPathComponent] isEqualToString:base]) continue;

        // 后缀表 @[@"@3x.png", @"@2x.png", @".png"]   (@0x10000c698 字面量)
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @".png"]) {
            NSString *p = [bundlePath stringByAppendingPathComponent:
                              [base stringByAppendingString:suffix]];
            CGImageRef orig = FlatGlassLoadPNG(p);
            if (!orig) continue;

            // 120*120*4 = 0xe100 字节 x2
            NSMutableData *da = [NSMutableData dataWithLength:0xe100];
            NSMutableData *db = [NSMutableData dataWithLength:da.length];
            if (!FlatGlassDrawPixels(orig, (uint8_t *)da.mutableBytes, 0x78)) {
                CGImageRelease(orig);
                continue;
            }
            if (!FlatGlassDrawPixels(rendered, (uint8_t *)db.mutableBytes, 0x78)) {
                CGImageRelease(orig);
                continue;
            }

            const uint8_t *A = (const uint8_t *)da.bytes;   // 原版
            const uint8_t *B = (const uint8_t *)db.bytes;   // 渲染版
            int hit4 = 0, hit8 = 0;                          // w23 / w28

            // 4 个角；每角 w12 从 28 到 91
            for (int corner = 0; corner < 4; corner++) {
                int lhs  = (corner & 1) ? 0x6F : 8;           // 8 / 111
                float thr = (corner & 1) ? 0.10f : 0.05f;     // s9 / s8
                for (int t = 0x1C; t < 0x5C; t++) {
                    int i1 = (corner < 2) ? (t * 120 + (corner & 1))
                                          : ((corner & 1) * 120 + t);
                    if (A[i1 * 4 + 3] < 0xDC) continue;        // alpha < 220 视为透明

                    int i2 = (corner < 2) ? (lhs * 120 + t)
                                          : (t * 120 + lhs);
                    if (A[i2 * 4 + 3] < 0xDC) continue;

                    // luma = 0.2126R + 0.7152G + 0.0722B   (Rec.709)
                    float la1 = (A[i1 * 4] * 0.2126f + A[i1 * 4 + 1] * 0.7152f
                                 + A[i1 * 4 + 2] * 0.0722f) / 255.0f;
                    float la2 = (A[i2 * 4] * 0.2126f + A[i2 * 4 + 1] * 0.7152f
                                 + A[i2 * 4 + 2] * 0.0722f) / 255.0f;
                    float lb1 = (B[i1 * 4] * 0.2126f + B[i1 * 4 + 1] * 0.7152f
                                 + B[i1 * 4 + 2] * 0.0722f) / 255.0f;
                    float lb2 = (B[i2 * 4] * 0.2126f + B[i2 * 4 + 1] * 0.7152f
                                 + B[i2 * 4 + 2] * 0.0722f) / 255.0f;

                    float d = (la1 - la2) - (lb1 - lb2);
                    if (d > thr) {
                        if (corner & 1) hit8++;
                        else            hit4++;
                    }
                }
            }
            CGImageRelease(orig);
            // 两个计数器都必须 > 9（汇编：cmp hit4,#9; ccmp hit8,#9; b.le 继续）
            if (hit4 > 9 && hit8 > 9) {
                result = 1;
                goto done;
            }
        }
    }
done:
    CGImageRelease(rendered);
    return result;
}

// ===========================================================================
//  BOMStore / CUICatalog 解析（_Block / _Variable / _Tree）
//  —— Apple 的 BOM 容器格式；Assets.car 就是一个 BOMStore。
// ===========================================================================

typedef struct { const uint8_t *ptr; size_t len; } Slice;

typedef struct {
    Slice data;      // +0x00 整个文件
    Slice index;     // +0x10 block 索引表
    Slice vars;      // +0x20 变量表
} BOMStore;

// @0x1000094b8  Slice _Block(BOMStore *s, uint32_t index)
//   block 索引表：BE32 count，随后 count 个 {BE32 offset, BE32 length}。
//   offset == 0 表示空 block。
static Slice BOMBlock(BOMStore *s, uint32_t index);

// @0x1000044b0  Slice _Variable(BOMStore *s, NSString *name)
//   变量表：BE32 count，随后若干条 { BE32 blockIndex; U8 nameLen; char name[nameLen]; }
//   逐条线性比对；命中则返回 BOMBlock(s, blockIndex)。
static Slice BOMVariable(BOMStore *s, NSString *name)
{
    if (s->vars.len < 9) return (Slice){0, 0};
    const uint8_t *base = s->vars.ptr;
    size_t off = 4;                                  // 跳过 BE32 count
    while (s->vars.len >= off + 5) {
        uint8_t nameLen = base[off + 4];
        if (s->vars.len - (off + 5) < nameLen) break;
        NSString *n = [[NSString alloc] initWithBytes:base + off + 5
                                               length:strnlen((const char *)base + off + 5, nameLen)
                                             encoding:NSUTF8StringEncoding];
        if ([n isEqualToString:name]) {
            uint32_t idx = (uint32_t)base[off] << 24 | (uint32_t)base[off + 1] << 16
                         | (uint32_t)base[off + 2] << 8 | (uint32_t)base[off + 3];
            return BOMBlock(s, idx);                 // BE32
        }
        off += 5 + nameLen;
    }
    return (Slice){0, 0};
}

// @0x100004614  void _Tree(BOMStore *s, NSString *name,
//                          void (^cb)(const char *key, size_t keyLen,
//                                     const void *val, size_t valLen))
//   name 指向的 block 必须是 "tree" 头：
//     {u32 magic='tree'; u32 ?; BE32 childCount; ...}
//   之后对每个 child block 再展开一层：
//     {BE16 entryCount; BE16 pad; BE16 ?; ...; entry[entryCount] = {BE32 id, BE32 offset}}
//   每个 entry 通过 BOMBlock 取出 (key, value) 两段，回调 cb。
static void BOMTreeWalk(BOMStore *s, NSString *name,
                        void (^cb)(const char *, size_t, const void *, size_t))
{
    Slice v = BOMVariable(s, name);
    if (v.len < 4) return;
    if (*(const uint32_t *)v.ptr != 0x65657274 /* 'tree' */) return;
    if (v.len < 8) return;

    uint32_t count = (uint32_t)v.ptr[8] << 24 | (uint32_t)v.ptr[9] << 16
                   | (uint32_t)v.ptr[10] << 8 | (uint32_t)v.ptr[11];   // BE32 @ +8
    for (uint32_t i = 0; i < count; i++) {
        Slice blk = BOMBlock(s, i);
        if (blk.len < 4 || !blk.ptr) break;
        uint16_t n = (uint16_t)(blk.ptr[0] << 8 | blk.ptr[1]);         // BE16
        if (!n) break;
        if (blk.len < 0xC || (size_t)n * 8 > blk.len - 0xC) break;
        const uint8_t *e = blk.ptr + 0xC;
        for (uint16_t k = 0; k < n; k++, e += 8) {
            uint32_t keyIdx = (uint32_t)e[0] << 24 | (uint32_t)e[1] << 16
                            | (uint32_t)e[2] << 8 | (uint32_t)e[3];    // BE32
            uint32_t valIdx = (uint32_t)e[4] << 24 | (uint32_t)e[5] << 16
                            | (uint32_t)e[6] << 8 | (uint32_t)e[7];    // BE32
            Slice val = BOMBlock(s, valIdx);
            Slice key = BOMBlock(s, keyIdx);
            cb((const char *)key.ptr, key.len, val.ptr, val.len);
        }
    }
}

// block 索引读取：单独放后面是为了让 BOMVariable/BOMTreeWalk 先声明。
static Slice BOMBlock(BOMStore *s, uint32_t index)
{
    // TODO(未确定): 索引表精确布局按 BOM.h（BE32 count + {BE32 off,BE32 len}）；
    //               0x1000094b8 处的实现做了多级越界检查，此处等价简化。
    if (!s->index.ptr || s->index.len < 4) return (Slice){0, 0};
    uint32_t n = (uint32_t)s->index.ptr[0] << 24 | (uint32_t)s->index.ptr[1] << 16
               | (uint32_t)s->index.ptr[2] << 8 | (uint32_t)s->index.ptr[3];
    if (index >= n) return (Slice){0, 0};
    const uint8_t *e = s->index.ptr + 4 + index * 8;
    if ((size_t)(e - s->index.ptr) + 8 > s->index.len) return (Slice){0, 0};
    uint32_t off = (uint32_t)e[0] << 24 | (uint32_t)e[1] << 16 | (uint32_t)e[2] << 8 | (uint32_t)e[3];
    uint32_t len = (uint32_t)e[4] << 24 | (uint32_t)e[5] << 16 | (uint32_t)e[6] << 8 | (uint32_t)e[7];
    if (!off || off > s->data.len || len > s->data.len - off) return (Slice){0, 0};
    return (Slice){ s->data.ptr + off, len };
}

// ===========================================================================
//  FlatRenderer
//  Assets.car 的轻量重实现：不依赖 CUICatalog 的私有渲染器，自己解 RENDITIONS
//  树里的 ISTC 记录（icon stack 指令流），用 CoreGraphics 逐条执行。
// ===========================================================================

// 一条 rendition 头（NSValue 封装，objCType = "{?={?=*Q}SSS}"，共 24 字节）
typedef struct {
    const void *data;       // +0x00  ISTC 记录起点
    size_t      len;        // +0x08
    uint16_t    appearance; // +0x10  0 或 appearance key（与 _light 比对）
    uint16_t    key;        // +0x12  rendition key（reference: 里做匹配）
    uint16_t    facet;      // +0x14  facet 索引（-> _facetNames）
    uint16_t    pad;        // +0x16
} FlatRendition;

@interface FlatRenderer : NSObject {
    NSData            *_assetData;    // +0x08
    id                 _catalog;      // +0x10  CUICatalog*
    uint16_t           _light;        // +0x18  "UIAppearanceLight" 的 key（非对象！）
    NSMutableDictionary *_byIdentifier; // +0x20  @(facet)  -> NSMutableArray<NSValue<FlatRendition>>*
    NSMutableDictionary *_facetNames;   // +0x28  @(facet)  -> NSString
    NSMutableDictionary *_namedFills;   // +0x30  name      -> NSValue<FlatRendition>
    NSMutableDictionary *_stacks;       // +0x38  "xxx.iconstack" -> NSValue<FlatRendition>
}
- (instancetype)initWithFile:(NSURL *)url;
- (FlatRendition)reference:(const void *)data length:(size_t)len;
- (CGColorRef)color:(const void *)data CF_RETURNS_RETAINED;
- (BOOL)fill:(const void *)data context:(CGContextRef)ctx rect:(CGRect)rect;
- (CGImageRef)image:(const FlatRendition *)ref CF_RETURNS_RETAINED;
- (BOOL)draw:(const FlatRendition *)ref context:(CGContextRef)ctx canvas:(CGRect)canvas
       depth:(int)depth foregroundOnly:(BOOL)fg;
- (CGImageRef)copyRendition:(NSString *)name foregroundOnly:(BOOL)fg CF_RETURNS_RETAINED;
- (BOOL)writeIcon:(NSString *)name to:(NSURL *)url;
@end

@implementation FlatRenderer

// ---------------------------------------------------------------------------
// @0x100004000  -[FlatRenderer initWithFile:]
// ---------------------------------------------------------------------------
- (instancetype)initWithFile:(NSURL *)url
{
    self = [super init];
    if (!self) return nil;

    _assetData = [NSData dataWithContentsOfURL:url options:1 error:NULL];   // NSDataReadingMappedIfSafe
    const uint8_t *p = (const uint8_t *)_assetData.bytes;
    size_t len = _assetData.length;

    // 8 字节 magic "BOMStore"
    if (len < 8 || memcmp(p, "BOMStore", 8) != 0) return nil;
    if (len < 0x10) return nil;

    BOMStore store;
    memset(&store, 0, sizeof(store));
    store.data = (Slice){ p, len };

    // 头部（BE32）：+0x10 indexOffset, +0x14 indexLen, +0x18 varsOffset, +0x1c varsLen
    // 注意：0x100004150 起对这两对 (offset,len) 都做了 “len-offset >= minLen” 的范围校验，
    //       任一不成立则该 Slice 置空（=0）。
    {
        uint32_t io = (uint32_t)p[0x10] << 24 | (uint32_t)p[0x11] << 16 | (uint32_t)p[0x12] << 8 | p[0x13];
        uint32_t il = (uint32_t)p[0x14] << 24 | (uint32_t)p[0x15] << 16 | (uint32_t)p[0x16] << 8 | p[0x17];
        if (len >= 0x20 && io && il <= len - io) store.index = (Slice){ p + io, il };

        uint32_t vo = (uint32_t)p[0x18] << 24 | (uint32_t)p[0x19] << 16 | (uint32_t)p[0x1A] << 8 | p[0x1B];
        uint32_t vl = (uint32_t)p[0x1C] << 24 | (uint32_t)p[0x1D] << 16 | (uint32_t)p[0x1E] << 8 | p[0x1F];
        if (len >= 0x20 && vo && vl <= len - vo) store.vars = (Slice){ p + vo, vl };
    }

    // ---- APPEARANCEKEYS: 找出 light 外观的 key ----
    __block uint16_t light = 0;
    BOMTreeWalk(&store, @"APPEARANCEKEYS", ^(const char *k, size_t kl, const void *v, size_t vl) {
        NSString *name = kl ? [[NSString alloc] initWithBytes:k length:strnlen(k, kl)
                                                     encoding:NSUTF8StringEncoding] : nil;
        if (name && [name isEqualToString:@"UIAppearanceLight"]) {           // 0x10000c110
            uint16_t x = 0;
            if (vl >= 2 && v) x = *(const uint16_t *)v;
            light = x;
        }
    });
    _light = light;

    _byIdentifier = [NSMutableDictionary new];
    _facetNames   = [NSMutableDictionary new];
    _namedFills   = [NSMutableDictionary new];
    _stacks       = [NSMutableDictionary new];

    // ---- RENDITIONS: 收集 ISTC 记录 ----
    BOMTreeWalk(&store, @"RENDITIONS", ^(const char *k, size_t kl, const void *v, size_t vl) {
        if (kl < 4 || !k || vl < 0xB8) return;
        const uint8_t *rec = (const uint8_t *)v;

        // 记录头 magic 'ISTC'
        if (*(const uint32_t *)rec != 0x43545349 /* 'ISTC' LE */) return;

        // 从 key 里按固定下标取三个 uint16：appearance / key / facet
        // TODO(未确定): 三个下标来自 block 捕获的 0x28/0x30/0x38/0x40（BOM 变量偏移），
        //               此处以「相对 key 起点、按 2 字节步进」的方式表达。
        uint16_t appearance = 0, rkey = 0, facet = 0;
        // appearance  （对应 0x1000048ec）
        // rkey        （对应 0x100004914）
        // facet       （对应 0x10000493c）
        // —— 实际下标在 block 捕获对象里，见 initWithFile: 的两个 _Tree 调用参数
        //    （此处保留 0 初始化，交由下面的 “!_light 则全收” 逻辑兜底）

        if (appearance && appearance != _light) return;             // 只收 light 外观

        FlatRendition r = { rec, vl, appearance, rkey, facet, 0 };
        NSValue *val = [NSValue value:&r withObjCType:"{?={?=*Q}SSS}"];

        NSNumber *fk = @(facet);
        NSMutableArray *arr = (NSMutableArray *)_byIdentifier[fk];
        if (!arr) { arr = [NSMutableArray new]; _byIdentifier[fk] = arr; }
        [arr addObject:val];

        // 元素类型（uint16 @ rec+0x24）：0x3f1 / 0x3fb / 0x3fd 才登记成“有名资源”
        uint16_t type = *(const uint16_t *)(rec + 0x24);
        if ((type >= 0x3F1 && type <= 0x3FD) &&
            ((1u << (type - 0x3F1)) & 0x1401u)) {                   // 0x1401 = {0x3f1,0x3fb,0x3fd}
            NSString *nm = [[NSString alloc] initWithBytes:rec + 0x28
                                                    length:strnlen((const char *)rec + 0x28, 0x80)
                                                  encoding:NSUTF8StringEncoding];
            if (!nm) return;
            NSMutableDictionary *dst = (type == 0x3FB) ? _stacks : _namedFills;
            if (!dst[nm] || appearance == _light) dst[nm] = val;
        }
    });

    // ---- FACETKEYS: facet 索引 → 名字 ----
    if (_byIdentifier.count) {
        BOMTreeWalk(&store, @"FACETKEYS", ^(const char *k, size_t kl, const void *v, size_t vl) {
            if (!k || !kl) return;
            NSString *name = [[NSString alloc] initWithBytes:k length:strnlen(k, kl)
                                                    encoding:NSUTF8StringEncoding];
            if (!name || vl < 6) return;
            uint16_t n = (uint16_t)(*(const uint8_t *)v << 8 | *((const uint8_t *)v + 1));
            // ↑ 0x100004ba4 读的是 [v+4]、[v+5]（小端拼接），此处按 v+4 取值：
            n = (uint16_t)(*((const uint8_t *)v + 4) | (*((const uint8_t *)v + 5) << 8));
            if (!n) return;
            const uint8_t *e = (const uint8_t *)v + 8;
            for (uint16_t i = 0; i < n; i++, e += 4) {
                if ((size_t)(e - (const uint8_t *)v) + 4 > vl) break;
                uint16_t t = (uint16_t)(e[0] | (e[1] << 8));
                uint16_t idx = (uint16_t)(e[2] | (e[3] << 8));
                if (t == 0x11) _facetNames[@(idx)] = name;
            }
        });
    }

    // ---- CUICatalog（可选；不存在 initWithURL: 就跳过）----
    Class cat = NSClassFromString(@"CUICatalog");                    // 0x10000c170
    if ([cat instancesRespondToSelector:@selector(initWithURL:error:)]) {
        _catalog = [[cat alloc] initWithURL:url error:NULL];
    }
    return self;
}

// ---------------------------------------------------------------------------
// @0x100004c64  - (FlatRendition)reference:(const void *)data length:(size_t)len
//   在 data 里找 4 字节一组的描述符：{u16 type, u16 value}
//     type == 2  → 目标 rendition key（w23）
//     type == 0x11→ appearance（w8，实际未参与比较）
//   然后在 _byIdentifier 全部条目里挑一条 r->key == 目标 key 的；
//   若已有结果且新条目 appearance == _light，则优先替换（light 优先）。
// ---------------------------------------------------------------------------
- (FlatRendition)reference:(const void *)data length:(size_t)len
{
    FlatRendition out;
    memset(&out, 0, sizeof(out));

    uint16_t wantKey = 0;
    if (len >= 4 && data) {
        const uint8_t *p = (const uint8_t *)data;
        size_t off = 0;
        while (off + 4 <= len) {
            uint16_t t = *(const uint16_t *)(p + off);
            if (t == 2)        wantKey = *(const uint16_t *)(p + off + 2);
            else if (t == 0x11) { /* appearance，忽略 */ }
            off += 4;
            if (off > len) break;
        }
    }

    NSArray *all = [_byIdentifier allValues];
    for (NSArray *arr in all) {
        for (NSValue *v in arr) {
            FlatRendition r;
            [v getValue:&r size:sizeof(r)];
            if (r.key != wantKey) continue;
            if (!out.data) { out = r; continue; }
            if (r.appearance == _light) out = r;      // light 外观优先
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// @0x100004e58  - (CGColorRef)color:(const void *)rec
//   记录格式（"LORC" 头）：
//     +0x00 u32 magic 'LORC'
//     +0x04 u32 ?            （未用）
//     +0x08 u32 colorModel   （3 => 用 displayP3，其余 sRGB）
//     +0x0C u32 componentCount（必须 2 或 4）
//     +0x10 f64 components[componentCount]
//   返回 CGColorCreate(space, comps)。
// ---------------------------------------------------------------------------
- (CGColorRef)color:(const void *)rec
{
    if (!rec) return NULL;
    const uint8_t *p = (const uint8_t *)rec;

    if (*(const uint32_t *)p != 0x43524F4C /* 'LORC' */) return NULL;

    uint32_t n = *(const uint32_t *)(p + 0x0C);
    if (n != 2 && n != 4) return NULL;             // 0x100004f40: 只支持 2 或 4 分量

    // 体长（同 FoldBody）：0xB4 处 u32
    size_t bodyLen = *(const uint32_t *)(p + 0xB4);
    if (bodyLen && (size_t)n * 8 > bodyLen - 0x10) return NULL;
    if (!bodyLen && 0x10 + n * 8 > 0xB8) return NULL;

    double comps[8] = {0};
    for (uint32_t i = 0; i < n; i++)
        comps[i] = *(const double *)(p + 0x10 + i * 8);

    CGColorSpaceRef cs;
    if (n == 2)                                        cs = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    else if (((bodyLen ? bodyLen : 0xB8) & ~(size_t)3) == 8) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    else if (*(const uint32_t *)(p + 8) == 3)          cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    else                                               cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    CGColorRef c = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return c;
}

// ---------------------------------------------------------------------------
// @0x100005008  - (BOOL)fill:(const void *)rec context:(CGContextRef)ctx rect:(CGRect)rect
//   'LORC' → 纯色填充；'ARGG' → 渐变填充（stop 名字查 _namedFills 再 color:）。
// ---------------------------------------------------------------------------
- (BOOL)fill:(const void *)rec context:(CGContextRef)ctx rect:(CGRect)rect
{
    if (!rec || !ctx) return NO;
    const uint8_t *p = (const uint8_t *)rec;

    uint32_t magic = *(const uint32_t *)p;
    if (magic == 0x43524F4C /* 'LORC' */) {
        CGColorRef c = [self color:rec];
        if (!c) return NO;
        CGContextSetFillColorWithColor(ctx, c);
        CGContextFillRect(ctx, rect);
        CGColorRelease(c);
        return YES;
    }

    if (magic != 0x47475241 /* 'ARGG' */) return NO;

    // 渐变记录（0x10000512c 起）：
    //   +0x04 u32 stop 数 n（必须 >= 1）
    //   +0x08 u32 渐变方向/类型（必须 <= 1）
    //   +0x20 起 n 个 stop：{ f32 position; u32 nameLen; char name[nameLen] }
    //   name 用来查 _namedFills，再走 -color: 得到 CGColor
    uint32_t n = *(const uint32_t *)(p + 4);
    if (n == 0) return NO;
    uint32_t dir = *(const uint32_t *)(p + 8);
    if (dir > 1) return NO;

    NSMutableArray *colors = [NSMutableArray new];
    double *locs = calloc(n, sizeof(double));
    size_t off = 0x20;
    size_t bodyLen = *(const uint32_t *)(p + 0xB4);       // 折叠体长度（见 FoldBody）
    if (!bodyLen) bodyLen = 0xB8;
    for (uint32_t i = 0; i < n; i++) {
        if (off + 8 > bodyLen) { free(locs); return NO; }
        locs[i] = *(const float *)(p + off);
        off += 8;
        uint32_t nl = *(const uint32_t *)(p + off - 4);   // 0x1000051b0: *(u32*)(x20+x27)
        if (nl == 0 || off + nl > bodyLen) { free(locs); return NO; }
        NSString *name = [[NSString alloc] initWithBytes:p + off length:strnlen((const char *)p + off, nl)
                                                encoding:NSUTF8StringEncoding];
        NSValue *v = name ? (NSValue *)_namedFills[name] : nil;
        if (!v) { free(locs); return NO; }
        FlatRendition fr; [v getValue:&fr size:sizeof(fr)];
        CGColorRef c = [self color:fr.data];
        if (!c) { free(locs); return NO; }
        [colors addObject:(__bridge id)c];
        CGColorRelease(c);
        off += nl;
    }

    if (colors.count == 1) {
        CGContextSetFillColorWithColor(ctx, (__bridge CGColorRef)colors.firstObject);
        CGContextFillRect(ctx, rect);
        free(locs);
        return YES;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locs);
    CGColorSpaceRelease(cs);
    free(locs);
    if (!g) return NO;

    // 端点：默认 rect 顶/底；若记录了起止点则按 stop 位置修正
    CGPoint start = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
    CGPoint end   = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
    CGContextDrawLinearGradient(ctx, g, start, end, 3 /* kCGGradientDrawsAfterEndLocation */);
    CGGradientRelease(g);
    return YES;
}

// ---------------------------------------------------------------------------
// @0x100005468  - (CGImageRef)image:(const FlatRendition *)ref
//   ref->data 若是 'DWAR' 记录且指向 *.svg → CoreSVG 解码 + 缩放渲染；
//   否则用 CUICatalog 的 imageWithName:scaleFactor:1.0 取名（facet 名）后取 .image。
//
//   「折叠体」定位规则（0x100005498..0x1000054f0，image:/fill:/color:/draw: 共用）：
//      off  = 0xB8
//      if (len >= 0xA8 && (len & ~3) != 0xA8)  off = BE32?? 实际为 *(u32*)(p+0xA8) + 0xB8
//      blen = 0
//      if (len >= 0xB4 && (len & ~3) != 0xB4)  blen = *(u32*)(p+0xB4)
//   即：0xA8 处 u32 = 体偏移（相对 0xB8 之后），0xB4 处 u32 = 体长度。
// ---------------------------------------------------------------------------
static BOOL FoldBody(const uint8_t *p, size_t len, const uint8_t **body, size_t *bodyLen)
{
    size_t off = 0xB8;
    if (len >= 0xA8 && (len & ~(size_t)3) != 0xA8) off = (size_t)*(const uint32_t *)(p + 0xA8) + 0xB8;
    size_t blen = 0;
    if (len >= 0xB4 && (len & ~(size_t)3) != 0xB4) blen = *(const uint32_t *)(p + 0xB4);
    if (off > len || blen > len - off) return NO;
    *body = p + off;
    *bodyLen = blen;
    return YES;
}

- (CGImageRef)image:(const FlatRendition *)ref
{
    if (!ref || !ref->data || ref->len < 4) return NULL;
    const uint8_t *p = (const uint8_t *)ref->data;
    size_t len = ref->len;

    const uint8_t *body = p;
    size_t bodyLen = len;
    FoldBody(p, len, &body, &bodyLen);

    if (*(const uint32_t *)body == 0x52415744 /* 'DWAR' */ &&
        gCreateSVG && gDrawSVG && gSizeSVG && gReleaseSVG) {

        // SVG 名（+0x28，最长 0x80）
        NSString *name = nil;
        if (bodyLen >= 0xA8)
            name = [[NSString alloc] initWithBytes:body + 0x28
                                            length:strnlen((const char *)body + 0x28, 0x80)
                                          encoding:NSUTF8StringEncoding];
        if ([name hasSuffix:@".svg"]) {                              // 0x10000c190
            uint32_t rawLen = *(const uint32_t *)(body + 8);         // 解压后大小
            if (rawLen >= 1 && rawLen <= 0x10000) {
                size_t cap = MIN((size_t)rawLen * 16, (size_t)0x10000);
                NSMutableData *buf = [NSMutableData dataWithLength:cap];
                size_t outLen;
                if (*(const uint32_t *)(body + 4) == 0) {            // 未压缩
                    memcpy(buf.mutableBytes, body + 0xC, rawLen);
                    outLen = rawLen;
                } else {
                    outLen = compression_decode_buffer(buf.mutableBytes, cap,
                                                       body + 0xC, bodyLen - 0xC,
                                                       NULL, COMPRESSION_LZFSE);
                }
                // 汇编判定：outLen == 0 或 outLen != cap 都算失败（0x100005754）
                if (outLen == 0 || outLen != cap) {
                    fprintf(stderr, "svg compression failed %zu %zu\n", (size_t)rawLen, bodyLen);
                    return NULL;
                }
                [buf setLength:outLen];

                void *doc = ((CGSVGDocumentCreateFromData_t)gCreateSVG)((__bridge CFDataRef)buf, 0);
                if (!doc) return NULL;
                CGSize sz = ((CGSVGDocumentGetCanvasSize_t)gSizeSVG)(doc);   // v0=w, v1=h
                double w = sz.width, h = sz.height;
                if (w <= 0 || h <= 0) { ((CGSVGDocumentRelease_t)gReleaseSVG)(doc); return NULL; }

                double side = 2.0 * MAX(w, h);
                size_t pw = (size_t)lrint(side * w / MAX(w, h));
                size_t ph = (size_t)lrint(side * h / MAX(w, h));
                if (pw < 1) pw = 1;
                if (ph < 1) ph = 1;

                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, 0, cs, 1);
                CGColorSpaceRelease(cs);
                if (!ctx) { ((CGSVGDocumentRelease_t)gReleaseSVG)(doc); return NULL; }
                CGContextScaleCTM(ctx, (double)pw / w, (double)ph / h);
                ((CGContextDrawSVGDocument_t)gDrawSVG)(ctx, doc);
                ((CGSVGDocumentRelease_t)gReleaseSVG)(doc);
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                CGContextRelease(ctx);
                return img;
            }
        }
        // 落到 catalog 分支
    }

    // ---- CUICatalog 分支 ----
    NSString *facetName = _facetNames[@(ref->facet)];
    if (!facetName) {
        fprintf(stderr, "facet missing %u\n", ref->facet);           // 0x10000b65c
        return NULL;
    }
    id rend = [_catalog imageWithName:facetName scaleFactor:1.0];
    if ([rend respondsToSelector:@selector(image)] && [rend image])
        return CGImageRetain([rend image]);
    return NULL;
}

// ---------------------------------------------------------------------------
// @0x10000589c  - (BOOL)draw:(const FlatRendition *)ref context:(CGContextRef)ctx
//                canvas:(CGRect)canvas depth:(int)depth foregroundOnly:(BOOL)fg
//
//  ref->data 是 ISTC（icon stack）记录：
//    +0x000 ... 头（0xB8 字节；+0xA8 处 u32 为“命令块相对偏移”，
//                 缺失时命令块直接跟在 0xB8 后）
//    +0x0B8 命令块：一串元素，元素之间按 payload 长度顺排
//    元素布局（0x100005b10..0x100005c70 反推）：
//      +0x00 u32  元素 id / 或首元素 type（首元素必须落在 0x51..0xA1）
//      +0x08 u32  frame.x
//      +0x0C u32  frame.y
//      +0x10 u32  frame.w
//      +0x14 u32  frame.h
//      +0x18 u32  blendMode（<= 0x1B 才调用 CGContextSetBlendMode）
//      +0x1C f32  alpha（必须 0..1，否则整条记录作废）
//      +0x20 u32  payloadLen
//      +0x24 ...  payload  → 交给 -reference:length: 解析出 FlatRendition
//    ref 数据的 +0x24 处 u16 是“元素类型”：
//      0x3F1 / 0x3FD → 纯色/渐变元素（走 -fill:context:rect:）
//      0x3FC         → 子组合（递归 draw:，depth+1）
//      其它           → 图像元素（-image: 后 draw，或按 paint 名 clipToMask 再 fill）
//    paint 名以 ".shine" / "_shine" 结尾的元素被跳过（这些正是要被本工具替换的高光层）。
//
//  另外命令块里 id==0x3F4 的条目是一段“可视索引表”：
//      {u32 count; u32 index[count]}，只有列在表里的元素才会被绘制。
// ---------------------------------------------------------------------------
- (BOOL)draw:(const FlatRendition *)ref context:(CGContextRef)ctx canvas:(CGRect)canvas
       depth:(int)depth foregroundOnly:(BOOL)fg
{
    if (!ref || !ref->data) return NO;
    const uint8_t *base = (const uint8_t *)ref->data;
    size_t total = ref->len;

    // ---- 定位命令块 ----
    // 0x1000058f0: 若 (len >= 0xa8 && (len & ~3) != 0xa8) 则取 data+0xa8 的 u32 偏移
    size_t cmdOff = 0;
    if (total >= 0xA8 && (total & ~(size_t)3) != 0xA8)
        cmdOff = *(const uint32_t *)(base + 0xA8);
    if (total < 0xB8) return NO;
    const uint8_t *cmds = base + 0xB8;                 // 命令块起点
    size_t cmdsLen = total - 0xB8;
    (void)cmdOff;

    // ---- 扫出 0x3F4 “可视索引表” ----
    // 0x100005940..0x1000059c4：沿 {u32 id, u32 size} 步进，
    //  size 表示该元素占用字节数；命中 id==0x3f4 即停下。
    const uint8_t *visMap = NULL;
    uint32_t visCount = 0;
    {
        size_t p = 0;
        while (p + 8 <= cmdsLen) {
            uint32_t size = *(const uint32_t *)(cmds + p + 4);
            if (size > cmdsLen - (p + 8)) break;
            if (*(const uint32_t *)(cmds + p) == 0x3F4) {
                visMap = cmds + p + 8;
                visCount = size;                        // 索引表字节长度
                break;
            }
            p += 8 + size;
        }
    }

    // ---- 前置校验（0x1000059d0..0x100005a08）----
    if (cmdsLen < 4) return NO;
    if (depth > 6) return NO;                          // 递归上限 6
    uint32_t firstType = *(const uint32_t *)cmds;
    if ((uint32_t)(firstType - 0x51) > 0x50) return NO; // 0x51..0xA1

    // [sp+0x74] = depth==0 ? fg : NO —— 只有顶层才做“前景模式”过滤
    BOOL skipBackground = (depth == 0) ? fg : NO;

    // ---- 元素遍历 ----
    size_t off = 4;                                     // 0x100005a30: 从 +4 起
    for (size_t idx = 0; ; idx++) {
        if (cmdsLen < off + 0x24) return NO;            // 头都放不下 → 记录损坏
        const uint8_t *elem = cmds + off;

        uint32_t payloadLen = *(const uint32_t *)(elem + 0x20);
        if (payloadLen < 0xC) return NO;
        if (cmdsLen - (off + 0x24) < payloadLen) return NO;
        const uint8_t *payload = elem + 0x24;

        FlatRendition r = [self reference:payload length:payloadLen];
        if (!r.data) {
            fprintf(stderr, "missing reference at %zu / %zu\n", idx, cmdsLen);   // 0x10000b66e
            return NO;
        }

        // alpha 合法性（0x100005b90..0x100005be4）：NaN/Inf/越界 → 整条记录作废
        float alpha = *(const float *)(elem + 0x1C);
        if (!(alpha >= 0.0f) || alpha > 1.0f) return NO;

        // ---- 可视索引表过滤（0x100005b58 / 0x100005de8）----
        if (visMap) {
            if (idx >= *(const uint32_t *)visMap) goto next;
            // 表内第 idx 项；0 表示不画
            // TODO(未确定): 表项为 u16 还是 u32；汇编按 (visCount - 4) 做下标换算
            const uint16_t *tab = (const uint16_t *)(visMap + 4);
            if (tab[idx] == 0) goto next;
        }

        {
            uint32_t fx = *(const uint32_t *)(elem + 0x08);
            uint32_t fy = *(const uint32_t *)(elem + 0x0C);
            uint32_t fw = *(const uint32_t *)(elem + 0x10);
            uint32_t fh = *(const uint32_t *)(elem + 0x14);
            uint32_t blend = *(const uint32_t *)(elem + 0x18);
            uint16_t type  = *(const uint16_t *)((const uint8_t *)r.data + 0x24);

            if (alpha == 0.0f) goto next;               // 0x100005c74

            // 子组合：递归
            if (type == 0x3FC) {
                if (![self draw:&r context:ctx canvas:canvas
                          depth:depth + 1 foregroundOnly:fg])
                    goto fail;
                goto next;
            }

            // 前景模式跳过背景层（0x100005cf4）
            if (skipBackground && (type == 0x3F1 || type == 0x3FD)) goto next;

            CGContextSaveGState(ctx);
            CGContextSetAlpha(ctx, alpha);
            if (blend <= 0x1B) CGContextSetBlendMode(ctx, (CGBlendMode)blend);

            // 纯色 / 渐变：整块填色
            if (type == 0x3FD || type == 0x3F1) {
                BOOL ok = [self fill:&r context:ctx rect:canvas];
                CGContextRestoreGState(ctx);
                if (!ok) goto fail;
                goto next;
            }

            // frame 合法性：宽高都必须在 1..0x2000
            if ((uint32_t)(fw - 1) > 0x1FFF || (uint32_t)(fh - 1) > 0x1FFF) {
                CGContextRestoreGState(ctx);
                goto next;
            }

            // ---- 图像元素 ----
            // 目标矩形：UIKit 原点在左下，frame.y 需翻转为 canvas 顶边起算
            CGRect rect = CGRectMake((CGFloat)fx,
                                     CGRectGetMaxY(canvas) - (CGFloat)fy - (CGFloat)fh,
                                     (CGFloat)fw, (CGFloat)fh);

            NSString *paintName =
                (NSString *)_facetNames[@(r.facet)];            // 0x100005d74
            NSString *lower = [paintName lowercaseString];
            if ([lower hasSuffix:@".shine"] ||                 // 0x10000c1b0
                [lower hasSuffix:@"_shine"]) {                  // 0x10000c1d0
                CGContextRestoreGState(ctx);                    // 高光层：跳过
                goto next;
            }

            CGImageRef img = [self image:&r];                   // 0x100005f14
            if (!img) { CGContextRestoreGState(ctx); goto fail; }

            if (paintName.length) {
                // 用图像 alpha 当裁剪掩膜，再用 paintName 对应的 fill 着色
                CGContextClipToMask(ctx, rect, img);
                NSValue *fv = (NSValue *)_namedFills[paintName];  // 0x100005f8c
                if (!fv) {
                    CGImageRelease(img);
                    CGContextRestoreGState(ctx);
                    goto fail;
                }
                FlatRendition fr;
                [fv getValue:&fr size:sizeof(fr)];
                BOOL ok = [self fill:&fr context:ctx rect:rect];
                CGImageRelease(img);
                CGContextRestoreGState(ctx);
                if (!ok) goto fail;
            } else {
                CGContextDrawImage(ctx, rect, img);             // 0x100006038
                CGImageRelease(img);
                CGContextRestoreGState(ctx);
            }
        }

    next:
        // 0x100005a8c: off = (elem + 0x20) + payloadLen
        off = off + 0x20 + payloadLen;
        if (cmdsLen < off) return NO;
        if (off == cmdsLen) return YES;
    }

fail:
    // 0x100006198..0x10000624c: 打印 "draw failed ..." 后返回 NO
    fprintf(stderr, "draw failed %s type=%u paint=%s frame=%d,%d,%u,%u\n",    // 0x10000b6cc
            "?", 0u, "", 0, 0, 0u, 0u);   // TODO(未确定): 实参为 paint 名/type/frame
    return NO;
}

// ---------------------------------------------------------------------------
// @0x100006280  - (CGImageRef)copyRendition:(NSString *)name foregroundOnly:(BOOL)fg
//   从 _stacks 取 "<name>.iconstack"，按其中的 (w,h) 建 384x384 的 8bpp 灰度上下文，
//   CTM 缩放到 (384/w, 384/h)，递归 draw:，最后 CGBitmapContextCreateImage。
// ---------------------------------------------------------------------------
- (CGImageRef)copyRendition:(NSString *)name foregroundOnly:(BOOL)fg
{
    if (!name.length) return NULL;

    NSValue *v = (NSValue *)_stacks[[name stringByAppendingString:@".iconstack"]];   // 0x10000c1f0
    FlatRendition r;
    memset(&r, 0, sizeof(r));
    [v getValue:&r size:sizeof(r)];

    if (r.len < 0xC) return NULL;
    uint32_t w = *(const uint32_t *)((const uint8_t *)r.data + 0xC);
    uint32_t h = *(const uint32_t *)((const uint8_t *)r.data + 0x10);
    // 1 <= w,h <= 0x1000
    if ((uint32_t)(w - 1) > 0xFFF) return NULL;
    if ((uint32_t)(h - 1) > 0xFFF) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGContextRef ctx = CGBitmapContextCreate(NULL, 0x180, 0x180, 8, 0, cs, 1);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextScaleCTM(ctx, 384.0 / (double)w, 384.0 / (double)h);

    BOOL ok = [self draw:&r context:ctx canvas:CGRectMake(0, 0, w, h)
                   depth:0 foregroundOnly:fg];
    CGImageRef img = ok ? CGBitmapContextCreateImage(ctx) : NULL;
    CGContextRelease(ctx);
    return img;
}

// ---------------------------------------------------------------------------
// @0x100006458  - (BOOL)writeIcon:(NSString *)name to:(NSURL *)url
//   copyRendition:name foregroundOnly:NO → CGImageDestination("public.png") → 写文件
// ---------------------------------------------------------------------------
- (BOOL)writeIcon:(NSString *)name to:(NSURL *)url
{
    CGImageRef img = [self copyRendition:name foregroundOnly:NO];
    if (!img) return NO;

    NSMutableData *data = [NSMutableData new];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);   // 0x10000c210
    if (!dst) { CGImageRelease(img); return NO; }

    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    if (ok) ok = [data writeToURL:url options:1 error:NULL];              // NSDataWritingAtomic
    CFRelease(dst);
    CGImageRelease(img);
    return ok;
}

// ---------------------------------------------------------------------------
// @0x100006544  -[FlatRenderer .cxx_destruct]
// ---------------------------------------------------------------------------
- (void)dealloc
{
    // 汇编里依次 objc_storeStrong(&_stacks, nil) / _namedFills / _facetNames /
    // _byIdentifier / _catalog / _assetData（_light 不是对象，不释放）
    _stacks = nil; _namedFills = nil; _facetNames = nil;
    _byIdentifier = nil; _catalog = nil; _assetData = nil;
}
@end

// ===========================================================================
//  模式函数
// ===========================================================================

// @0x100009558  static void PublishIconServicesMode(void)
//   读取 plist 的 Mode，映射成 notify state 并广播。
static void PublishIconServicesMode(void)
{
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];  // 0x10000c230
    int mode = [(NSNumber *)plist[@"Mode"] integerValue];                          // 0x10000c330

    if (gModeToken == -1) {
        if (notify_register_check(kModeNotify.UTF8String, &gModeToken) != 0) goto fail;
    }

    int state = (mode >= 4) ? 1 : mode + 1;     // ★ Mode → state

    {
        uint64_t cur = 0;
        if (notify_get_state(gModeToken, &cur) != 0) goto fail;
        if (cur == (uint64_t)state) return;      // 没变化
        if (notify_set_state(gModeToken, (uint64_t)state) != 0) goto fail;
        if (notify_post(kModeNotify.UTF8String) != 0) goto fail;
    }
    return;
fail:
    fwrite("FlatGlass: failed to publish mode.\n", 1, 0x23, stderr);   // 0x10000b9c2
}

// PublishMode(int) —— 与上面同体，只是 mode 由参数给（汇编中 0x100007d64 的内联副本）。
static void PublishMode(int mode)
{
    if (gModeToken == -1) {
        if (notify_register_check(kModeNotify.UTF8String, &gModeToken) != 0) goto fail;
    }
    {
        int state = (mode >= 4) ? 1 : mode + 1;
        uint64_t cur = 0;
        if (notify_get_state(gModeToken, &cur) != 0) goto fail;
        if (cur == (uint64_t)state) return;
        if (notify_set_state(gModeToken, (uint64_t)state) != 0) goto fail;
        if (notify_post(kModeNotify.UTF8String) != 0) goto fail;
    }
    return;
fail:
    fwrite("FlatGlass: failed to publish mode.\n", 1, 0x23, stderr);
}

// @0x1000066bc  static int WatchMode(void)   —— 正常情况下不返回
static int WatchMode(void)
{
    NSString *t0 = [kThemeFlat  stringByResolvingSymlinksInPath];
    NSString *t1 = [kThemeGloss stringByResolvingSymlinksInPath];
    NSString *t2 = [kThemeEdge  stringByResolvingSymlinksInPath];

    NSMutableDictionary *prefs =
        [[NSDictionary dictionaryWithContentsOfFile:kSnowBoardPrefs] mutableCopy];
    if (!prefs) prefs = [NSMutableDictionary new];

    id items = prefs[@"ActiveMenuItems"];                     // 0x10000c2d0
    NSArray *list = [items isKindOfClass:[NSArray class]] ? items : EmptyArray();

    NSMutableArray *filtered = [NSMutableArray new];
    for (id s in list) {
        if (![s isKindOfClass:[NSString class]]) continue;
        NSString *r = [(NSString *)s stringByResolvingSymlinksInPath];
        if ([r isEqualToString:t0]) continue;
        if ([r isEqualToString:t1]) continue;
        if ([r isEqualToString:t2]) continue;
        [filtered addObject:s];
    }

    if (![filtered isEqualToArray:list]) {
        prefs[@"ActiveMenuItems"] = filtered;
        (void)prefs[@"Enabled"];                              // 0x100007b78 读后立即 release，疑似无用代码
        if (![prefs writeToFile:kSnowBoardPrefs atomically:YES]) {
            fwrite("FlatGlass: failed to unregister old themes.\n", 1, 0x2C, stderr);  // 0x10000b965
        } else {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)kSnowBoardRefresh, NULL, NULL, true);
        }
    }

    int token = -1;
    if (notify_register_dispatch(kSettingsChanged.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
        (void)t;
        PublishIconServicesMode();                            // @0x100009558
    }) != 0) {
        return 1;
    }

    PublishIconServicesMode();                                // 启动即广播一次（内联副本）
    dispatch_main();
    return 0;
}

// @0x100006c38  static int DisableMode(void)
static int DisableMode(void)
{
    if (geteuid() == 0) {
        struct passwd *pw = getpwnam("mobile");               // 0x10000b824
        if (!pw) return 1;
        if (initgroups("mobile", pw->pw_gid) != 0) return 1;
        if (setgid(pw->pw_gid) != 0) return 1;
        if (setuid(pw->pw_uid) != 0) return 1;
    }

    if (gModeToken == -1) {
        if (notify_register_check(kModeNotify.UTF8String, &gModeToken) != 0) return 1;
    }
    uint64_t state = 0;
    if (notify_get_state(gModeToken, &state) != 0) return 1;
    if (state == 3) return 0;                                  // 已关闭
    if (notify_set_state(gModeToken, 3) != 0) return 1;
    if (notify_post(kModeNotify.UTF8String) != 0) return 1;
    return 0;
}

// 子进程渲染：posix_spawn(self, [self, car, iconName, out]) → waitpid → 退出码
// @0x1000073e4..0x10000751c
static int SpawnRender(NSString *carPath, NSString *iconName, NSString *outPath)
{
    NSArray *args = @[ kSelfPath, carPath, iconName, outPath ];
    const char *argv[9] = {0};
    for (NSUInteger i = 0; i < args.count && i < 8; i++)
        argv[i] = [args[i] fileSystemRepresentation];

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [kSelfPath fileSystemRepresentation], NULL, NULL,
                         (char *const *)argv, NULL);
    if (rc != 0) return -1;

    int status = 0;
    pid_t w;
    do { w = waitpid(pid, &status, 0); } while (w < 0 && errno == EINTR);
    if (w != pid) return -1;
    if (status & 0x7F) return -1;                              // 被信号打死
    return (status >> 8) & 0xFF;
}

// @0x100006858  static int PreviewScan(NSString *themeDir, NSString *prefsDir)
static int PreviewScan(NSString *themeDir, NSString *prefsDir)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;

    NSArray *entries = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application"
                                               error:&err];               // 0x10000c530
    NSMutableArray *dirs = nil;
    if (entries) {
        NSMutableArray *roots = [NSMutableArray arrayWithObject:@"/Applications"];      // 0x10000c550
        [roots addObject:@"/var/jb/Applications"];                                      // 0x10000c570
        for (NSString *e in entries)
            [roots addObject:[@"/var/containers/Bundle/Application" stringByAppendingPathComponent:e]];

        dirs = [NSMutableArray new];
        for (NSString *root in roots) {
            for (NSString *e in [fm contentsOfDirectoryAtPath:root error:NULL]) {
                if ([[e pathExtension] isEqualToString:@"app"])                          // 0x10000c590
                    [dirs addObject:[root stringByAppendingPathComponent:e]];
            }
        }
    } else {
        fprintf(stderr, "Cannot enumerate applications: %s\n",
                err.localizedDescription.UTF8String);                    // 0x10000bb61
        dirs = nil;
    }

    if (!dirs) return 1;
    if (![fm createDirectoryAtPath:themeDir withIntermediateDirectories:YES
                        attributes:nil error:NULL]) return 1;
    if (![fm createDirectoryAtPath:prefsDir withIntermediateDirectories:YES
                        attributes:nil error:NULL]) return 1;

    NSString *appsPlist = [prefsDir stringByAppendingPathComponent:@"Apps.plist"];   // 0x10000c430
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:appsPlist] ?: @{};
    NSMutableDictionary *out = [NSMutableDictionary new];

    NSUInteger rendered = 0, unsupported = 0, changes = 0;

    for (NSString *appDir in dirs) {
        @autoreleasepool {
            NSDictionary *info =
                [NSDictionary dictionaryWithContentsOfFile:
                    [appDir stringByAppendingPathComponent:@"Info.plist"]];   // 0x10000c390
            NSString *bid = info[@"CFBundleIdentifier"];                      // 0x10000c450
            if (!ValidIdentifier(bid)) continue;
            if (out[bid]) continue;                                           // 按 bundleid 去重

            NSString *car = [appDir stringByAppendingPathComponent:@"Assets.car"];  // 0x10000c410
            NSDictionary *attrs = [fm attributesOfItemAtPath:car error:NULL];
            if (!attrs) continue;

            NSDictionary *icons = info[@"CFBundleIcons"];
            if (![icons isKindOfClass:[NSDictionary class]]) icons = nil;
            NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
            if (![primary isKindOfClass:[NSDictionary class]]) primary = nil;
            id iconNameObj = primary[@"CFBundleIconName"] ?: info[@"CFBundleIconName"];
            if (![iconNameObj isKindOfClass:[NSString class]]) continue;
            if ([(NSString *)iconNameObj length] == 0) continue;
            NSString *iconName = iconNameObj;

            NSString *outPath = [themeDir stringByAppendingPathComponent:
                                    [bid stringByAppendingString:@"-large.png"]];   // 0x10000c370
            NSString *key = [NSString stringWithFormat:@"3|%@|%@|%@|%@|%@",         // 0x10000c470
                                appDir, iconName,
                                info[@"CFBundleVersion"],
                                attrs[NSFileModificationDate],
                                attrs[NSFileSize]];

            NSDictionary *cached = old[bid];                                    // @0x1000072ec
            BOOL exists = [fm fileExistsAtPath:outPath];
            BOOL cachedRendered = [cached[@"rendered"] boolValue];               // 0x10000c4f0

            if (exists == cachedRendered) {
                // 文件存在性与缓存一致 → 不必重跑子进程
                if ([cached[@"key"] isEqual:key]) {
                    out[bid] = cached;                                          // 完全一致，直接沿用
                } else {
                    // key 变了（版本/mtime/size）：重建条目
                    out[bid] = @{ @"key": key,
                                  @"rendered": @(exists),
                                  @"nativeHighlight":
                                      @(exists ? HasOriginalHighlight(appDir, primary, outPath) : 0) };
                    if (exists) {
                        // TODO(未确定): 此处汇编会删掉已存在的 png 并把 changes += 删除结果，
                        //               但同时又把 rendered 记为 YES —— 疑为原程序 bug，照抄。
                        changes += [fm removeItemAtPath:outPath error:NULL] ? 1 : 0;
                    }
                }
                continue;
            }

            // ---- 需要重新渲染 ----
            int st = SpawnRender(car, iconName, outPath);
            BOOL ok = (st == 0);
            if (st != 0 && st != 2) {                     // 2 = renderer init 失败 = Skip
                fprintf(stderr, "Unsupported icon: %s\n", bid.UTF8String);   // 0x10000bae0
                unsupported++;
            }
            if (ok) rendered++;

            out[bid] = @{ @"key": key,
                          @"rendered": @(ok),
                          @"nativeHighlight":
                              @(ok ? HasOriginalHighlight(appDir, primary, outPath) : 0) };  // 0x10000c510
            changes++;
        }
    }

    if (![out isEqual:old]) {
        if (![out writeToFile:appsPlist atomically:YES]) return 1;   // @0x100008958
    }
    if (rendered || unsupported || changes) {
        printf("FlatGlass: %lu rendered, %lu unsupported, %lu changes.\n",  // 0x10000bb06
               (unsigned long)rendered, (unsigned long)unsupported, (unsigned long)changes);
    }
    return 0;
}

// ---------------------------------------------------------------------------
//  GlossIcon —— argc==8 的 "--gloss-icon" 模式
//  @0x100006bb4 (入口) / 主体 0x100006ce0..0x100009360
//
//  argv:  [1]="--gloss-icon"
//         [2]=bundleIdentifier
//         [3]=bundlePath         (…/Xxx.app)
//         [4]=out.png            (输出)
//         [5]=in.png             (输入，已渲染的平面图标)
//         [6]="1"/"0"            gloss      —— 是否走“双图层（主题底图 + 前景）”路径
//         [7]="1"/"0"            highlight  —— 是否真正施加高光像素运算
//
//  流程：
//    in = PNG(argv[5]);  in==NULL → return 1
//    if (gloss) {
//        refPath = /var/jb/Library/Themes/FlatGlass.theme/IconBundles/<bid>-large.png
//        ref     = PNG(refPath)                       // 旧主题底图（可能为 nil）
//        iconName = Info.plist[CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName]
//                   ?: Info.plist[CFBundleIconName]
//        fg = [[FlatRenderer alloc] initWithFile:bundle/Assets.car]
//                 copyRendition:iconName foregroundOnly:YES]     // 前景层
//    } else { ref = nil; fg = nil; }
//    base = ref ?: [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:3.0].CGImage
//    if (!highlight) { out = CGImageRetain(base); goto writePNG; }
//    ... 见下面 ApplyGlossShine
// ---------------------------------------------------------------------------
static int GlossIcon(char **argv)
{
    NSString *bid      = [NSString stringWithUTF8String:argv[2]];
    NSString *bundle   = [NSString stringWithUTF8String:argv[3]];
    NSString *outPath  = [NSString stringWithUTF8String:argv[4]];
    NSString *inPath   = [NSString stringWithUTF8String:argv[5]];
    BOOL      gloss    = (strcmp(argv[6], "1") == 0);
    BOOL      highlight= (strcmp(argv[7], "1") == 0);

    CGImageRef inImage = FlatGlassLoadPNG(inPath);
    if (!inImage) return 1;

    CGImageRef refImage = NULL;
    CGImageRef fgImage  = NULL;
    NSString  *iconName = nil;
    NSDictionary *primaryIcon = nil;

    if (gloss) {
        NSString *refPath =
            [kThemeFlat stringByAppendingPathComponent:
                [@"IconBundles" stringByAppendingPathComponent:
                    [bid stringByAppendingString:@"-large.png"]]];          // 0x10000c250/0x10000c350
        refImage = FlatGlassLoadPNG(refPath);                              // [sp+0x108]

        NSDictionary *info =
            [NSDictionary dictionaryWithContentsOfFile:
                [bundle stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *icons = info[@"CFBundleIcons"];
        if (![icons isKindOfClass:[NSDictionary class]]) icons = nil;
        primaryIcon = icons[@"CFBundlePrimaryIcon"];
        if (![primaryIcon isKindOfClass:[NSDictionary class]]) primaryIcon = nil;
        id n = primaryIcon[@"CFBundleIconName"] ?: info[@"CFBundleIconName"];
        if ([n isKindOfClass:[NSString class]]) iconName = n;
    }

    if ([iconName isKindOfClass:[NSString class]] && iconName.length) {
        FlatRenderer *r = [[FlatRenderer alloc] initWithFile:
                              [NSURL fileURLWithPath:
                                  [bundle stringByAppendingPathComponent:@"Assets.car"]]];
        if (r) fgImage = [r copyRendition:iconName foregroundOnly:YES];     // [sp+0x90]
    }

    CGImageRef base = refImage;
    if (!base) {
        UIImage *ui = [UIImage _applicationIconImageForBundleIdentifier:bid
                                                                 format:2
                                                                  scale:3.0];  // 0x100007ee8
        base = ui.CGImage;
    }

    CGImageRef result = NULL;
    if (!highlight || !base) {
        result = CGImageRetain(base);
    } else {
        result = ApplyGlossShine(base, fgImage, inImage);   // 见下
        if (!result) result = CGImageRetain(base);
    }

    // ---- 写 PNG ----
    BOOL ok = NO;
    if (result) {
        NSMutableData *data = [NSMutableData new];
        CGImageDestinationRef dst = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
        if (dst) {
            CGImageDestinationAddImage(dst, result, NULL);
            if (CGImageDestinationFinalize(dst))
                ok = [data writeToFile:outPath options:1 error:NULL];
            CFRelease(dst);
        }
        CGImageRelease(result);
    }

    if (refImage) CGImageRelease(refImage);
    if (inImage)  CGImageRelease(inImage);
    if (fgImage)  CGImageRelease(fgImage);
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------
//  ApplyGlossShine —— GlossIcon 的高光像素流水线
//  @0x100007f20 .. 0x1000091f4（step 1..4）+ 0x100008260..0x100008e9c（shine 掩膜）
//  @0x100008f2c .. 0x10000935c（合成 / 输出）
//
//  常量（全部为 f32，来自 __TEXT.__const 与 movw/movk 立即数）：
//    19600.0 = 140*140   32400.0 = 180*180   180.0   255.0   90.0   82.0   155.0
//    luma 权重 0.2126 / 0.7152 / 0.0722
// ---------------------------------------------------------------------------
static CGImageRef ApplyGlossShine(CGImageRef base, CGImageRef fg, CGImageRef inImage)
{
    const size_t S = 180;                       // 工作分辨率
    const size_t RGBA = S * S * 4;              // 0x1fa40 = 129600
    const size_t MASK = S * S;                  // 0x7e90  = 32400

    NSMutableData *bufA = [NSMutableData dataWithLength:RGBA];   // base 的 RGBA
    NSMutableData *bufB = [NSMutableData dataWithLength:MASK];   // shine 掩膜(8bpp)
    if (!FlatGlassDrawPixels(base, (uint8_t *)bufA.mutableBytes, S)) return NULL;

    NSMutableData *bufC = nil;
    BOOL hasFg = NO;
    if (fg) {
        bufC = [NSMutableData dataWithLength:RGBA];
        hasFg = FlatGlassDrawPixels(fg, (uint8_t *)bufC.mutableBytes, S);
        if (!hasFg) bufC = nil;
    }
    (void)inImage;

    const uint8_t *A = (const uint8_t *)bufA.bytes;
    const uint8_t *C = bufC ? (const uint8_t *)bufC.bytes : NULL;

    // ---- step 1/2: 统计“边缘能量”，决定是否值得打高光 ----
    //  0x100008058..0x1000081f0：以 4 像素为一组，在 (x±?, y±?) 上取最大通道差，
    //  超过 0x30 (48) 的组计数，最后：
    //      t = clamp((count/19600.0 - 0.095) / 0.28, 0, 1);
    //      s = 1 - t*t*(3-2t);                     // smoothstep 的补
    //  s > 0.96 → 认为“太平”，直接返回 base（0x1000087b0）。
    uint32_t edgeCount = 0;
    for (int y = 0x14; y < 0xA0; y++) {
        for (int x = 0; x < 0x88; x += 8) {
            // 两组采样点：p(x, y) 与 p(x+?, y+?)；逐通道取 |a-b| 的最大值
            // TODO(未确定): 采样步长在汇编里是 0x2d0(720B=一行) 的整数倍，具体为
            //               (x, y) / (x+0x2cc?) 两组，此处按“同行 4 通道最大差”等价表达。
            int maxd = 0;
            for (int c = 0; c < 4; c++) {
                int i1 = ((y + 1) * S + x) * 4 + c;
                int i2 = ((y + 2) * S + x + 1) * 4 + c;
                if ((size_t)i2 + 4 >= RGBA) continue;
                int d = abs((int)A[i1] - (int)A[i2]);
                if (C) { int d2 = abs((int)C[i1] - (int)C[i2]); if (d2 > d) d = d2; }
                if (d > maxd) maxd = d;
            }
            if (maxd > 0x30) edgeCount++;
        }
    }
    (void)edgeCount;
    // ↑ 该统计在汇编里是 NEON 展开（uabdl/umax/cmhi/addv），此处保留语义。

    // TODO(未确定): step1 的 count → s 映射，s>0.96 提前返回 base 的分支
    //               （0x1000081f0..0x10000825c）
    float t = ((float)edgeCount / 19600.0f - 0.095f) / 0.28f;
    t = fmaxf(0.0f, fminf(1.0f, t));
    float s = 1.0f - t * t * (3.0f - 2.0f * t);
    if (s > 0.96f) return NULL;                 // 调用方回退为 base

    // ---- step 3: 生成 shine 掩膜（180x180 单通道） ----
    //  0x100008260..0x10000842c：逐像素计算“与邻域的最大亮度差”，写入 bufB。
    //  之后 0x10000842c..0x1000086cc 做 min/max 形态学（内缩 2 或 4 px），
    //  0x1000086e0..0x1000087ac 统计 alpha>=0x80 的像素数，>= 778 (0x30a) 才继续。
    uint8_t *M = (uint8_t *)bufB.mutableBytes;
    const int inset = hasFg ? 2 : 4;             // 0x10000842c: w23 = w28 ? 2 : 4

    for (int y = 0; y < (int)S; y++) {
        for (int x = 0; x < (int)S; x++) {
            int i = (y * S + x) * 4;
            // 参考像素
            int l0 = (A[i] * 53 + A[i+1] * 182 + A[i+2] * 18) / 255;
            int m = 0;
            if (x >= 1 && y >= 1 && x + 1 < (int)S && y + 1 < (int)S) {
                const int nb[4] = { ((y-1)*S + (x-1))*4, ((y-1)*S + (x+1))*4,
                                    ((y+1)*S + (x-1))*4, ((y+1)*S + (x+1))*4 };
                for (int k = 0; k < 4; k++) {
                    int j = nb[k];
                    int l = (A[j] * 53 + A[j+1] * 182 + A[j+2] * 18) / 255;
                    m = MAX(m, abs(l - l0));
                }
            }
            M[y * S + x] = (uint8_t)MIN(255, m * 2);
        }
    }

    // min 滤波（内缩 inset px）→ max 滤波（外扩 inset px）
    //  0x1000084c4..0x100008574 (min) / 0x10000857c..0x1000086cc (max)
    //  TODO(未确定): 边缘按“钳制坐标”处理（汇编里用 csel 夹取，等价于最近边界复制）。
    {
        uint8_t *tmp = calloc(MASK, 1);
        uint8_t *tmp2 = calloc(MASK, 1);
        // min（水平）
        for (int y = 0; y < (int)S; y++)
            for (int x = 0; x < (int)S; x++) {
                uint8_t v = 255;
                int lo = MAX(0, x - inset), hi = MIN((int)S - 1, x + inset);
                for (int k = lo; k <= hi; k++) v = MIN(v, M[y * S + k]);
                tmp[y * S + x] = v;
            }
        // min（垂直）
        for (int x = 0; x < (int)S; x++)
            for (int y = 0; y < (int)S; y++) {
                uint8_t v = 255;
                int lo = MAX(0, y - inset), hi = MIN((int)S - 1, y + inset);
                for (int k = lo; k <= hi; k++) v = MIN(v, tmp[k * S + x]);
                tmp2[y * S + x] = v;
            }
        // max（水平）
        for (int y = 0; y < (int)S; y++)
            for (int x = 0; x < (int)S; x++) {
                uint8_t v = 0;
                int lo = MAX(0, x - inset), hi = MIN((int)S - 1, x + inset);
                for (int k = lo; k <= hi; k++) v = MAX(v, tmp2[y * S + k]);
                tmp[y * S + x] = v;
            }
        // max（垂直）
        for (int x = 0; x < (int)S; x++)
            for (int y = 0; y < (int)S; y++) {
                uint8_t v = 0;
                int lo = MAX(0, y - inset), hi = MIN((int)S - 1, y + inset);
                for (int k = lo; k <= hi; k++) v = MAX(v, tmp[k * S + x]);
                M[y * S + x] = v;
            }
        free(tmp);
        free(tmp2);
    }

    int sum = 0;
    for (size_t i = 0; i < MASK; i++) if (M[i] >= 0x80) sum++;
    if (sum < 0x30A) return NULL;                // < 778 → 不打高光

    // ---- step 4: 高光合成 ----
    //  0x100008b84..0x100008e98 的 3x3 逐像素循环：
    //     e  = smoothstep((min(x+3, 179-x, 179-y, y) - 5) / 12)        // 边缘衰减
    //     A  = smoothstep((x + (-0.48)) / 0.28)                        // 横向位置
    //     g  = clamp((|dy*0.8423 + dx*0.54| / |hypot(dx,dy)|) , 0, 1)  // 梯度方向
    //     tint = 左边缘色 + (右边缘色 - 左边缘色) * smoothstep(...)
    //     out  = src + (255*alpha*0.96 - src) * e * g * ...
    //  细节常量：
    //     -0.095/0.28, -0.48/0.28, -0.68 (1-0.68*t), 0.31/0.025,
    //     0.55/0.18 (方向混合), 0.8423/0.54 (法线投影), 0.96, 0.98, 0.74
    //  此处按语义重写，逐像素公式见注释，未逐条复刻 NEON 指令顺序。
    NSMutableData *out = [NSMutableData dataWithLength:RGBA];
    memcpy(out.mutableBytes, A, RGBA);
    uint8_t *O = (uint8_t *)out.mutableBytes;

    for (int y = 3; y < (int)S - 2; y++) {
        float fy = (float)y / 180.0f;
        float ry = (fy - 0.48f) / 0.28f;
        ry = fmaxf(0.0f, fminf(1.0f, ry));
        float smoothY = ry * ry * (3.0f - 2.0f * ry);
        float rowAmt = (1.0f - 0.68f * smoothY) * 0.31f + 0.025f;

        for (int x = 3; x < (int)S - 2; x++) {
            const uint8_t *px = A + ((y * S + x) * 4);
            if (px[3] < 8) continue;                    // 透明处跳过

            int d = MIN(MIN(x + 3, (int)S - 1 - x), MIN(y, (int)S - 1 - y));
            float e = ((float)(d - 5)) / 12.0f;
            e = fmaxf(0.0f, fminf(1.0f, e));
            float edge = e * e * (3.0f - 2.0f * e);
            if (edge == 0.0f) continue;

            // 局部梯度（±1 px）
            float dx = ((float)A[((y + 1) * S + x + 1) * 4] - (float)A[((y - 1) * S + x - 1) * 4]) / 255.0f;
            float dy = ((float)A[((y + 1) * S + x - 1) * 4] - (float)A[((y - 1) * S + x + 1) * 4]) / 255.0f;
            float n  = hypotf(dx, dy);
            float dir = (n > 0.0f) ? fabsf((dy * 0.8423f + dx * 0.54f) / n) : 0.0f;
            dir = fmaxf(0.0f, fminf(1.0f, n)) * (dir * 0.55f + 0.18f);

            // 边缘色 → 横向渐变
            int iL = ((y * S) + 12) * 4, iR = ((y * S) + 167) * 4;
            float fxF = (float)(x - 3) / 155.0f;
            fxF = fmaxf(0.0f, fminf(1.0f, fxF));
            fxF = fxF * fxF * (3.0f - 2.0f * fxF);

            float amt = edge * dir * rowAmt * s;         // 总强度
            for (int c = 0; c < 3; c++) {
                float src = (float)px[c];
                float tint = (float)A[iL + c] + ((float)A[iR + c] - (float)A[iL + c]) * fxF;
                float lit = src + (tint - src) * amt;
                lit = fminf(255.0f, fmaxf(0.0f, lit));
                O[(y * S + x) * 4 + c] = (uint8_t)lrintf(lit);
            }
            // alpha 保持
        }
    }

    // 180x180 RGBA → CGImage（bitmapInfo 0x4005 = 32Big|noneSkipLast）
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)out);
    CGImageRef img = CGImageCreate(S, S, 8, 32, S * 4, cs, (CGBitmapInfo)0x4005,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return img;
}

// ===========================================================================
//  main
// ===========================================================================
int main(int argc, char **argv)
{
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);   // 0x10000b862
        void *h = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_NOW);
        if (h) {
            gCreateSVG  = dlsym(h, "CGSVGDocumentCreateFromData");   // 0x10000b8d8
            gReleaseSVG = dlsym(h, "CGSVGDocumentRelease");          // 0x10000b8f4
            gDrawSVG    = dlsym(h, "CGContextDrawSVGDocument");      // 0x10000b909
            gSizeSVG    = dlsym(h, "CGSVGDocumentGetCanvasSize");    // 0x10000b922
        }

        switch (argc) {
        case 2:
            if (!strcmp(argv[1], "--disable")) return DisableMode();
            if (!strcmp(argv[1], "--watch"))   return WatchMode();
            return 64;

        case 4: {
            if (!strcmp(argv[1], "--preview-scan"))
                return PreviewScan([NSString stringWithUTF8String:argv[2]],
                                   [NSString stringWithUTF8String:argv[3]]);

            FlatRenderer *r = [[FlatRenderer alloc]
                initWithFile:[NSURL fileURLWithPath:
                    [NSString stringWithUTF8String:argv[1]]]];
            if (!r) return 2;
            BOOL ok = [r writeIcon:[NSString stringWithUTF8String:argv[2]]
                                to:[NSURL fileURLWithPath:
                                    [NSString stringWithUTF8String:argv[3]]]];
            return !ok;
        }

        case 8:
            if (!strcmp(argv[1], "--gloss-icon")) return GlossIcon(argv);
            return 64;

        default:
            return 64;
        }
    }
}

// =============================================================================
//  附：汇编中确认过的 iOS / Apple 私有 API 清单
//    -[CUICatalog initWithURL:error:]                 0x1000046c0 (间接)
//    -[CUICatalog imageWithName:scaleFactor:]         0x100005634
//    -[CUIRenditionKey ...] / rendition.image         0x10000564c (respondsToSelector:"image")
//    +[UIImage _applicationIconImageForBundleIdentifier:format:scale:]   0x100007ee8
//    CGSVGDocumentCreateFromData / CGSVGDocumentRelease /
//    CGContextDrawSVGDocument / CGSVGDocumentGetCanvasSize               dlsym
//    compression_decode_buffer(..., COMPRESSION_LZFSE=0x801)             0x10000574c
//    notify_register_check/get_state/set_state/post/register_dispatch
//    CFNotificationCenterGetDarwinNotifyCenter/PostNotification
// =============================================================================
