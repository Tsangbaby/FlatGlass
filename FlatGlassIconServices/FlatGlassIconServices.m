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
#import "FGPrivateCalls.h"

int  FGModeToken = -1;
Class FGImageClass = Nil;
Class FGAppRecipeClass = Nil;
Class FGResourceClass = Nil;
IMP  FGOriginalResourceImage = NULL;
IMP  FGOriginalComposedImage = NULL;

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
    @try {
        Method init = class_getInstanceMethod(FGImageClass, @selector(initWithCGImage:scale:));
        if (!FGMethodIs(init, 2, "@", @encode(CGImageRef), @encode(CGFloat))) return nil;
        return [(id<FGPrivateImage>)[FGImageClass alloc] initWithCGImage:img scale:scale];
    } @finally {
        CGImageRelease(img);
    }
}

// 原 0x4224 IsImageRenderer：签名必须严格匹配
static BOOL IsImageRenderer(Method m) {
    return FGMethodIs(m, 2, "@", @encode(CGSize), @encode(CGFloat));
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
    FGRenderDimensions dims;
    if (mode >= 0 && mode != 2 && FGResolveRenderDimensions(size.width, size.height, scale, &dims)) {
        @try {
            id catalog = FGPrivateObject(self, @selector(catalog));
            NSString *name = FGPrivateObject(self, @selector(imageName));
            if (catalog && [name isKindOfClass:[NSString class]] && name.length) {
                SEL sel = @selector(catalogAppearance);
                Method appearanceMethod = FGGetMethod(self, sel);
                uint64_t appearance = 0;
                if (appearanceMethod) {
                    if (FGMethodIs(appearanceMethod, 0, "Q", NULL, NULL) ||
                        FGMethodIs(appearanceMethod, 0, "q", NULL, NULL)) {
                        appearance = ((uint64_t (*)(id, SEL))objc_msgSend)(self, sel);
                    } else {
                        appearance = UINT64_MAX;    // 未知 ABI：交回系统
                    }
                }
                if (appearance <= 2 && FGHasStack(catalog, name)) {
                    CGImageRef img = mode == 1
                        ? NGCreateGlassIconContent(catalog, name, (uint32_t)appearance, dims.pixelSide)
                        : NGCreateFlatIcon(catalog, name, (uint32_t)appearance, dims.pixelSide);
                    id wrapped = FGWrapImage(img, dims.imageScale);
                    if (wrapped) return wrapped;
                }
            }
        } @catch (__unused NSException *e) {
            // 私有实现变更时仍走原渲染路径。
        }
    }
    if (!FGOriginalResourceImage) return nil;
    return ((id (*)(id, SEL, CGSize, double))FGOriginalResourceImage)(self, _cmd, size, scale);
}

// 原 0x48e0 ComposedImage —— ISCompositor 的 -imageForSize:scale:
static id ComposedImage(id self, SEL _cmd, CGSize size, double scale) {
    if (!FGOriginalComposedImage) return nil;
    id<FGPrivateImage> original =
        ((id (*)(id, SEL, CGSize, double))FGOriginalComposedImage)(self, _cmd, size, scale);
    const int mode = FGCurrentMode();
    if (mode != 1 && mode != 3) return original;
    @try {
        if (!FGMethodIs(FGGetMethod(original, @selector(CGImage)), 0, @encode(CGImageRef), NULL, NULL) ||
            !FGMethodIs(FGGetMethod(original, @selector(scale)), 0, @encode(CGFloat), NULL, NULL)) return original;

        id elements = ReadProperty(self, @"elements");
        id first = FGPrivateObject(elements, @selector(firstObject));
        id recipe = ReadProperty(first, @"recipe") ?: ReadProperty(self, @"recipe");
        if (!FGAppRecipeClass || ![recipe isKindOfClass:FGAppRecipeClass]) return original;

        CGImageRef cg = [original CGImage];
        if (!cg) return original;
        size_t side = CGImageGetWidth(cg);
        if (side != CGImageGetHeight(cg) || side > FG_MAX_PIXELS) return original;
        const CGFloat srcScale = [original scale];
        if (!isnormal(srcScale) || srcScale <= 0) return original;
        FGComposedStyle style = FGComposedStyleForMode(mode, mode == 1 && FGHasLayeredPrimaryResource(self));
        CGImageRef out = style == FGRenderGlassed ? NGCreateGlassedImage(cg) : NGCreateRimmedImage(cg);
        return FGWrapImage(out, srcScale) ?: original;
    } @catch (__unused NSException *e) {
        return original;
    }
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

        Method imageInit = class_getInstanceMethod(FGImageClass, @selector(initWithCGImage:scale:));
        BOOL canWrap = FGMethodIs(imageInit, 2, "@", @encode(CGImageRef), @encode(CGFloat));
        BOOL okRes = canWrap && IsImageRenderer(mRes)
                  && FGMethodIs(class_getInstanceMethod(FGResourceClass, @selector(catalog)), 0, "@", NULL, NULL)
                  && FGMethodIs(class_getInstanceMethod(FGResourceClass, @selector(imageName)), 0, "@", NULL, NULL);
        BOOL okCmp = canWrap && FGAppRecipeClass && IsImageRenderer(mCmp);

        if (!okRes && !okCmp) {
            NSLog(@"FlatGlass: compatible IconServices methods were not found.");
            return;
        }

        if (notify_register_dispatch(kModeNotifyName.UTF8String, &FGModeToken,
                                     dispatch_get_main_queue(), ^(__unused int token) {
            InvalidateCache(YES);
        }) != NOTIFY_STATUS_OK) {
            FGModeToken = -1;
            NSLog(@"FlatGlass: mode notification registration failed; using system rendering.");
            return;
        }

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
