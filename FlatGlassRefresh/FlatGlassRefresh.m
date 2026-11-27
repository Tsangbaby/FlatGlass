//
//  FlatGlassRefresh.m
//  FlatGlass — SpringBoard side
//
//  由 FlatGlassRefresh.dylib 反汇编还原。
//  原二进制：32456 字节 __TEXT/__text，45 个本地符号，全部函数名完好。
//  地址对照（原 dylib 基址 0）：
//     0x4000  StartFlatGlassRefresh            (constructor)
//     0x40cc  __StartFlatGlassRefresh_block_invoke      (notify 回调)
//     0x4170  __StartFlatGlassRefresh_block_invoke_2    (真正的刷新逻辑，内联)
//     0x44dc  ObjectValue(id, SEL)             —— 安全 id 取值
//     0x45a4  CallVoid(id, SEL)                —— 安全 void 调用
//     0x4678  RefreshBatch(NSArray *, NSUInteger, int64_t)
//     0x4924  RefreshVisibleIconViews(void)
//
//  职责：SpringBoard 进程内，当 iconservicesagent 插件把新图标渲染完之后，
//  让 SBIconModel 重新加载图标并把可见的 SBIconImageView 重绘。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ── 全局状态（对应原 __DATA 段） ────────────────────────────────────────────
static int      RefreshStatusToken = -1;   // 0xc110
static int      VisibleStatusToken = -1;   // 0xc114
static int64_t  RefreshGeneration  = 0;    // 0xc118 —— 代号，用来作废过期的延迟任务
static int64_t  ReloadedIcons      = 0;    // 0xc120

static NSString *const kModeNotifyName      = @"local.lumid.flatglass.iconservices-mode";
static NSString *const kReloadedNotifyName  = @"local.lumid.flatglass.reloaded-icons";
static NSString *const kRefreshedNotifyName = @"local.lumid.flatglass.refreshed-views";

// ── 安全调用辅助 ───────────────────────────────────────────────────────────
// 原作者在 OS 版本差异上很保守：调用任何私有方法前都先用 runtime 校验
// 「方法存在 + 参数个数 + 返回类型」，校验不过就当没这个方法。
// 这是这套代码能在多个 iOS 版本上不崩的核心原因，维护时不要简化掉。

static id ObjectValue(id object, SEL selector) {
    id result = nil;
    Method m = class_getInstanceMethod(object_getClass(object), selector);
    if (m && method_getNumberOfArguments(m) == 2) {
        char type[16] = {0};
        method_getReturnType(m, type, sizeof(type));
        if (type[0] == '@') {
            result = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
    }
    return result;
}

static void CallVoid(id object, SEL selector) {
    Method m = class_getInstanceMethod(object_getClass(object), selector);
    if (m && method_getNumberOfArguments(m) == 2) {
        char type[16] = {0};
        method_getReturnType(m, type, sizeof(type));
        if (type[0] == 'v') {
            ((void (*)(id, SEL))objc_msgSend)(object, selector);
        }
    }
}

// 原 0x44dc / 0x45a4 里的 objc_autoreleaseReturnValue 说明返回值是 autoreleased，
// ARC 下上面两个函数已经是等价的。

// ── 可见图标视图重绘 ───────────────────────────────────────────────────────
// 原 0x4924。遍历所有 window 的视图树（深度优先，用数组当栈），
// 找到 SBIconImageView 就 clearCachedImages + updateImageAnimated:NO。
static void RefreshVisibleIconViews(void) {
    Class SBIconImageViewClass = objc_getClass("SBIconImageView");
    if (!SBIconImageViewClass) return;

    NSMutableArray *queue = [NSMutableArray array];

    // 先按 windowScene 收集 window（iOS 13+ 的正确做法）
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [queue addObjectsFromArray:[(UIWindowScene *)scene windows]];
        }
    }
    // 拿不到 scene 就退回旧的 windows
    if (queue.count == 0) {
        [queue addObjectsFromArray:[[UIApplication sharedApplication] windows]];
    }

    NSUInteger updated = 0;
    while (queue.count != 0) {
        UIView *view = [queue lastObject];
        [queue removeLastObject];

        if ([view isHidden]) continue;           // 隐藏子树整棵跳过

        [queue addObjectsFromArray:[view subviews]];

        if (![view isKindOfClass:SBIconImageViewClass]) continue;

        @try {
            CallVoid(view, @selector(clearCachedImages));

            // -[SBIconImageView updateImageAnimated:] 是 BOOL 参数
            Method m = class_getInstanceMethod(object_getClass(view), @selector(updateImageAnimated:));
            if (m && method_getNumberOfArguments(m) == 3) {
                char ret[16] = {0};
                method_getReturnType(m, ret, sizeof(ret));
                if (ret[0] == 'v') {
                    char arg[16] = {0};
                    method_getArgumentType(m, 2, arg, sizeof(arg));
                    if (arg[0] == 'B') {
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(view, @selector(updateImageAnimated:), NO);
                        updated++;
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"FlatGlass displayed icon refresh: %@", e.reason);
        }
    }

    if (VisibleStatusToken != -1) {
        notify_set_state(VisibleStatusToken, (uint64_t)updated);
    }
}

// ── 分批 reload，避免主线程卡死 ────────────────────────────────────────────
// 原 0x4678。每批 4 个图标，批间延迟 0.4s；每批结束都检查 RefreshGeneration，
// 一旦有新的模式变更就把旧的批次链整体作废。
static void RefreshBatch(NSArray *icons, NSUInteger start, int64_t generation);

static void RefreshBatch(NSArray *icons, NSUInteger start, int64_t generation) {
    if (generation != RefreshGeneration) return;
    if (start >= icons.count) return;

    NSUInteger end = start + 4;
    if (end > icons.count) end = icons.count;

    for (NSUInteger i = start; i < end; i++) {
        id icon = icons[i];
        @try {
            Method m = class_getInstanceMethod(object_getClass(icon), @selector(reloadIconImage));
            if (m && method_getNumberOfArguments(m) == 2) {
                char ret[16] = {0};
                method_getReturnType(m, ret, sizeof(ret));
                if (ret[0] == 'v') {
                    ((void (*)(id, SEL))objc_msgSend)(icon, @selector(reloadIconImage));
                    ReloadedIcons++;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"FlatGlass icon reload: %@", e.reason);
        }
    }

    if (end < icons.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RefreshBatch(icons, end, generation);
        });
    } else {
        // 全部 reload 完再统一重绘可见视图，避免闪烁
        [UIView performWithoutAnimation:^{
            RefreshVisibleIconViews();
        }];
        if (RefreshStatusToken != -1) {
            notify_set_state(RefreshStatusToken, (uint64_t)ReloadedIcons);
        }
    }
}

// ── 入口 ───────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void StartFlatGlassRefresh(void) {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        if (![processName isEqualToString:@"SpringBoard"]) return;

        notify_register_check(kReloadedNotifyName.UTF8String,  &RefreshStatusToken);
        notify_register_check(kRefreshedNotifyName.UTF8String, &VisibleStatusToken);

        int token = 0;
        notify_register_dispatch(kModeNotifyName.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            if (notify_get_state(t, &state) != 0) return;
            if (state - 1 > 3) return;           // 只接受 1..4（= Mode 0..3 再 +1）

            const int64_t generation = ++RefreshGeneration;

            // 等 2 秒：iconservicesagent 那边刚被 exit(0) 重启，图还没渲完
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != RefreshGeneration) return;

                @try {
                    id controller = ObjectValue(objc_getClass("SBIconController"),
                                                @selector(sharedInstance));
                    id iconManager = ObjectValue(controller, @selector(iconManager));
                    id model = ObjectValue(iconManager, @selector(iconModel));
                    if (!model) model = ObjectValue(controller, @selector(model));

                    // 校验 -enumerateLeafIconsUsingBlock: 的形态
                    SEL enumSel = @selector(enumerateLeafIconsUsingBlock:);
                    Method enumMethod = class_getInstanceMethod(object_getClass(model), enumSel);
                    if (!enumMethod
                        || method_getNumberOfArguments(enumMethod) != 3) return;
                    char enumRet[16] = {0};
                    method_getReturnType(enumMethod, enumRet, sizeof(enumRet));
                    if (enumRet[0] != 'v') return;
                    char enumArg[16] = {0};
                    method_getArgumentType(enumMethod, 2, enumArg, sizeof(enumArg));
                    if (enumArg[0] != '@' || enumArg[1] != '?') return;

                    // 先清图标缓存
                    id imageCache = ObjectValue(iconManager, @selector(iconImageCache));
                    CallVoid(imageCache, @selector(purgeAllCachedImages));

                    id folderCache = ObjectValue(iconManager, @selector(folderIconImageCache));
                    SEL folderSel = @selector(purgeAllCachedImages);
                    Method folderMethod = class_getInstanceMethod(object_getClass(folderCache),
                                                                 @selector(purgeAllCachedFolderImages));
                    if (folderMethod
                        && method_getNumberOfArguments(folderMethod) == 2) {
                        char fr[16] = {0};
                        method_getReturnType(folderMethod, fr, sizeof(fr));
                        if (fr[0] == 'v') folderSel = @selector(purgeAllCachedFolderImages);
                    }
                    CallVoid(folderCache, folderSel);

                    // 收集所有叶子图标
                    NSMutableArray *icons = [NSMutableArray array];
                    ((void (*)(id, SEL, void (^)(id)))objc_msgSend)(model, enumSel, ^(id icon) {
                        if (icon) [icons addObject:icon];
                    });

                    ReloadedIcons = 0;
                    if (icons.count) {
                        RefreshBatch(icons, 0, generation);
                    } else {
                        [UIView performWithoutAnimation:^{
                            RefreshVisibleIconViews();
                        }];
                    }
                } @catch (NSException *e) {
                    NSLog(@"FlatGlass Home Screen refresh: %@", e.reason);
                }
            });
        });
    }
}
