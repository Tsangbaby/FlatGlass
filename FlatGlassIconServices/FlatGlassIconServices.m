//
//  FlatGlassIconServices.m
//  注入 iconservicesagent 的钩子层。
//
//  地址对照（原 dylib 基址 0）：
//     0x4000   StartFlatGlassIconServices
//     0x4224   IsImageRenderer
//     0x4308   notify block
//     0x4310   InvalidateCache
//     0x462c   ResourceImage
//     0x48e0   ComposedImage
//     0x4bec   WrapImage
//     0x4c88   ReadProperty
//

#import "FGInternal.h"
#import <math.h>
#include <string.h>

int  FGModeToken = -1;
Class FGImageClass = Nil;
Class FGAppRecipeClass = Nil;
Class FGResourceClass = Nil;
IMP  FGOriginalResourceImage = NULL;
IMP  FGOriginalComposedImage = NULL;
BOOL FGGNoEdge = NO;

void (*FGLog)(NSString *message) = NULL;

static NSString *const kICSCacheDir =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache";
static NSString *const kModeMarkerName  = @".flatglass-mode";
static NSString *const kModeNotifyName  = @"local.lumid.flatglass.iconservices-mode";

#pragma mark - 工具

// 原 0x4c88 ReadProperty：KVC 取值，抛异常就当没有。
static id ReadProperty(id object, NSString *key) {
    if (!object) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

// 原 0x4bec WrapImage
id FGWrapImage(CGImageRef img, double scale) {
    if (!img) return nil;
    if (!FGImageClass) { CGImageRelease(img); return nil; }
    id out = [[FGImageClass alloc] initWithCGImage:img scale:scale];
    CGImageRelease(img);
    return out;
}

// 原 0x4224 IsImageRenderer：签名必须严格匹配
//   - (id)imageForSize:(CGSize)size scale:(CGFloat)scale
static BOOL IsImageRenderer(Method m) {
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 4) return NO;
    char ret[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != '@') return NO;
    char arg2[128] = {0};
    method_getArgumentType(m, 2, arg2, sizeof(arg2));
    if (strcmp(arg2, "{CGSize=dd}") != 0) return NO;
    char arg3[32] = {0};
    method_getArgumentType(m, 3, arg3, sizeof(arg3));
    if (arg3[0] != 'd') return NO;
    return YES;
}

// 当前模式：notify state 1..4 -> Mode 0..3；其它一律 -1
int FGCurrentMode(void) {
    if (FGModeToken == -1) return -1;
    uint64_t state = 0;
    if (notify_get_state(FGModeToken, &state) != 0) return -1;
    if (state - 1 > 3) return -1;
    return (int)(state - 1);
}

#pragma mark - 缓存失效

// 原 0x4310 InvalidateCache
//
// force = YES 时，一旦标记文件被成功改写就 exit(0) 主动结束 iconservicesagent，
// 让 launchd 拉起一个干净的进程 —— 这是"图标真的会变"的关键一步。
static void InvalidateCache(BOOL force) {
    const int mode = FGCurrentMode();
    if (mode < 0) return;

    NSString *markerPath = [kICSCacheDir stringByAppendingPathComponent:kModeMarkerName];
    NSString *content    = [NSString stringWithFormat:@"1:%ld", (long)mode];
    NSString *existing   = [NSString stringWithContentsOfFile:markerPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];

    if ([existing isEqualToString:content]) return;   // 已经完全一致，什么都不用做

    if (!existing) {
        // 没有标记文件：只有当"本来就不该有"（Off）或 state 非法时才跳过
        uint64_t state = 0;
        if (notify_get_state(FGModeToken, &state) != 0) return;
        if (state == 3) return;                       // state 3 == Mode 2 == Off
        if (state - 5 < (uint64_t)-4) return;         // state < 1
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries  = [fm contentsOfDirectoryAtPath:kICSCacheDir error:NULL];
    if (!entries && ![fm fileExistsAtPath:kICSCacheDir]) return;

    for (NSString *entry in entries) {
        if ([entry isEqualToString:kModeMarkerName]) continue;
        NSString *path = [kICSCacheDir stringByAppendingPathComponent:entry];
        if (![fm removeItemAtPath:path error:NULL]) break;
    }

    BOOL wrote = [content writeToFile:markerPath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:NULL];
    if (force && wrote) {
        exit(0);       // 主动退出，让系统重新拉起 agent 并重建图标缓存
    }
}

#pragma mark - 两个替换实现

// 原 0x462c ResourceImage —— ISAssetCatalogResource 的 -imageForSize:scale:
static id ResourceImage(id self, SEL _cmd, CGSize size, double scale) {
    const int mode = FGCurrentMode();

    // 模式无效 / Off / 尺寸异常，一律交回系统
    if (mode < 0 || mode == 2) goto passthrough;
    if (!isnormal(size.width) || !isnormal(size.height) || !isnormal(scale)) goto passthrough;
    if (size.width <= 0 || size.height <= 0 || scale <= 0) goto passthrough;

    {
        id catalog = [self catalog];
        NSString *name = [self imageName];
        uint32_t appearance = 0;
        if ([self respondsToSelector:@selector(catalogAppearance)]) {
            appearance = (uint32_t)[self catalogAppearance];
        }
        if (appearance > 2) goto passthrough;
        if (!catalog || name.length == 0) goto passthrough;
        if (!FGHasStack(catalog, name)) goto passthrough;

        double side = fmax(size.width, size.height) * scale;
        uint32_t px = (uint32_t)ceil(side);
        if (px < FG_MIN_PIXELS) px = FG_MIN_PIXELS;
        if (px > FG_MAX_PIXELS) px = FG_MAX_PIXELS;

        CGImageRef img = (mode == 1)
            ? NGCreateGlassIconContent(catalog, name, appearance, px)
            : NGCreateFlatIcon(catalog, name, appearance, px);

        id wrapped = FGWrapImage(img, (double)px / scale);
        if (wrapped) return wrapped;
    }

passthrough:
    if (!FGOriginalResourceImage) return nil;
    return ((id (*)(id, SEL, CGSize, double))FGOriginalResourceImage)(self, _cmd, size, scale);
}

// 原 0x48e0 ComposedImage —— ISCompositor 的 -imageForSize:scale:
static id ComposedImage(id self, SEL _cmd, CGSize size, double scale) {
    id original = ((id (*)(id, SEL, CGSize, double))FGOriginalComposedImage)(self, _cmd, size, scale);

    const int mode = FGCurrentMode();
    if (mode < 0 || (mode & 1) == 0) return original;      // 只处理 1 / 3
    if (![original respondsToSelector:@selector(CGImage)] ||
        ![original respondsToSelector:@selector(scale)]) return original;

    id elements = ReadProperty(self, @"elements");
    id first = [elements respondsToSelector:@selector(firstObject)] ? [elements firstObject] : nil;
    id recipe = ReadProperty(first, @"recipe") ?: ReadProperty(self, @"recipe");
    if (!FGAppRecipeClass || ![recipe isKindOfClass:FGAppRecipeClass]) return original;

    CGImageRef cg = [original CGImage];
    if (!cg) return original;
    if (CGImageGetWidth(cg) != CGImageGetHeight(cg)) return original;
    if (CGImageGetWidth(cg) > 1024) return original;

    const double srcScale = [original scale];
    CGImageRef out = (mode == 1 && FGHasLayeredPrimaryResource(self))
        ? NGCreateRimmedImage(cg)
        : NGCreateGlassedImage(cg, 0);

    id wrapped = FGWrapImage(out, srcScale);
    return wrapped ?: original;
}

#pragma mark - 入口

__attribute__((constructor))
static void StartFlatGlassIconServices(void) {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"iconservicesagent"]) return;

        FGImageClass      = objc_getClass("IFImage");
        FGAppRecipeClass  = objc_getClass("ISiOSAppRecipe");
        FGResourceClass   = objc_getClass("ISAssetCatalogResource");
        Class compositor  = objc_getClass("ISCompositor");

        Method mRes = FGResourceClass
            ? class_getInstanceMethod(FGResourceClass, @selector(imageForSize:scale:)) : NULL;
        Method mCmp = compositor
            ? class_getInstanceMethod(compositor, @selector(imageForSize:scale:)) : NULL;

        BOOL okRes = IsImageRenderer(mRes)
                  && [FGResourceClass instancesRespondToSelector:@selector(catalog)]
                  && [FGResourceClass instancesRespondToSelector:@selector(imageName)]
                  && [FGImageClass instancesRespondToSelector:@selector(initWithCGImage:scale:)];
        BOOL okCmp = FGAppRecipeClass && IsImageRenderer(mCmp);

        if (!okRes && !okCmp) {
            NSLog(@"FlatGlass: compatible IconServices methods were not found.");
            return;
        }

        notify_register_dispatch(kModeNotifyName.UTF8String, &FGModeToken,
                                 dispatch_get_main_queue(), ^(int token) {
            InvalidateCache(YES);
        });

        if (okRes) {
            FGOriginalResourceImage = method_getImplementation(mRes);
            class_replaceMethod(FGResourceClass, @selector(imageForSize:scale:),
                                (IMP)ResourceImage, method_getTypeEncoding(mRes));
        }
        if (okCmp) {
            FGOriginalComposedImage = method_getImplementation(mCmp);
            class_replaceMethod(compositor, @selector(imageForSize:scale:),
                                (IMP)ComposedImage, method_getTypeEncoding(mCmp));
        }

        InvalidateCache(NO);
    }
}
