//
//  main.m
//  flatglass —— FlatGlass 的辅助守护进程
//
//  launchd 以 /var/jb/usr/libexec/flatglass --watch 常驻（见 layout/Library/LaunchDaemons/）。
//
//  职责（按原二进制还原）：
//    1. 监听 local.lumid.flatglass.settings-changed，读 plist 的 Mode，
//       映射成 notify state = Mode + 1 并广播 local.lumid.flatglass.iconservices-mode。
//       两个 dylib 都靠这条通知决定要不要重渲染 / 重载图标。
//    2. 把 FlatGlass 自己的 SnowBoard 主题目录从 ActiveMenuItems 里摘掉
//       （iOS 26 上走 IconServices 路径，SnowBoard 主题会互相打架）。
//    3. --disable：把 Mode 置成 Off 并清理。
//
//  地址对照（CLI 基址 0x100000000）：
//     0x1000065a4 main          0x100009558 PublishIconServicesMode
//     0x1000066bc WatchMode     0x100006c38 DisableMode
//     0x1000073e4 SpawnRender   0x100007xxx PreviewScan / GlossIcon
//
//  说明：--preview-scan / --gloss-icon（离线批量渲染 SnowBoard 主题 PNG）在
//  原版里依赖一整套 Assets.car（BOMStore）解析器 + CoreSVG + 私有 CoreUI API，
//  逐指令还原稿见 reverse-reference/E_cli.m。本编译版未包含这两条路径。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <notify.h>
#import <unistd.h>
#import <pwd.h>
#import <grp.h>
#import <stdio.h>

static NSString *const kPrefsPath       = @"/var/mobile/Library/Preferences/local.lumid.flatglass.plist";
static NSString *const kSnowBoardPrefs  = @"/var/jb/var/mobile/Library/Preferences/com.spark.snowboardprefs.plist";
static NSString *const kSnowBoardRefresh = @"com.spark.snowboard.refreshNow";
static NSString *const kSettingsChanged = @"local.lumid.flatglass.settings-changed";
static NSString *const kModeNotify      = @"local.lumid.flatglass.iconservices-mode";

static NSString *const kThemeFlat  = @"/var/jb/Library/Themes/FlatGlass.theme";
static NSString *const kThemeGloss = @"/var/jb/Library/Themes/FlatGlass Gloss.theme";
static NSString *const kThemeEdge  = @"/var/jb/Library/Themes/FlatGlass Edge.theme";

static int gModeToken = -1;

#pragma mark - 模式广播

// 原 0x100009558。注意 mode >= 4 一律当 state 1（= Mode 0）。
static void PublishMode(int mode) {
    if (gModeToken == -1) {
        if (notify_register_check(kModeNotify.UTF8String, &gModeToken) != 0) goto fail;
    }
    {
        uint64_t state = (mode >= 4) ? 1 : (uint64_t)(mode + 1);
        uint64_t current = 0;
        if (notify_get_state(gModeToken, &current) != 0) goto fail;
        if (current == state) return;                  // 没变化就别惊动别人
        if (notify_set_state(gModeToken, state) != 0) goto fail;
        if (notify_post(kModeNotify.UTF8String) != 0) goto fail;
    }
    return;
fail:
    fwrite("FlatGlass: failed to publish mode.\n", 1, 35, stderr);
}

static void PublishIconServicesMode(void) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    PublishMode((int)[(NSNumber *)plist[@"Mode"] integerValue]);
}

#pragma mark - 摘掉自己的 SnowBoard 主题

// 原 0x1000066bc 的前半段。原版在常驻前只做"注销"，不会主动注册新主题。
static void UnregisterThemes(void) {
    NSString *ours[3] = {
        [kThemeFlat  stringByResolvingSymlinksInPath],
        [kThemeGloss stringByResolvingSymlinksInPath],
        [kThemeEdge  stringByResolvingSymlinksInPath],
    };

    NSMutableDictionary *prefs =
        [[NSDictionary dictionaryWithContentsOfFile:kSnowBoardPrefs] mutableCopy];
    if (!prefs) prefs = [NSMutableDictionary new];

    id items = prefs[@"ActiveMenuItems"];
    NSArray *list = [items isKindOfClass:[NSArray class]] ? items : @[];

    NSMutableArray *filtered = [NSMutableArray array];
    for (id entry in list) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *resolved = [(NSString *)entry stringByResolvingSymlinksInPath];
        BOOL isOurs = NO;
        for (int i = 0; i < 3; i++) {
            if ([resolved isEqualToString:ours[i]]) { isOurs = YES; break; }
        }
        if (!isOurs) [filtered addObject:entry];
    }

    if ([filtered isEqualToArray:list]) return;

    prefs[@"ActiveMenuItems"] = filtered;
    if (![prefs writeToFile:kSnowBoardPrefs atomically:YES]) {
        fwrite("FlatGlass: failed to unregister old themes.\n", 1, 44, stderr);
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge CFStringRef)kSnowBoardRefresh,
                                        NULL, NULL, true);
}

#pragma mark - 模式

static int WatchMode(void) {
    UnregisterThemes();

    int token = -1;
    if (notify_register_dispatch(kSettingsChanged.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
        (void)t;
        PublishIconServicesMode();
    }) != 0) {
        return 1;
    }

    PublishIconServicesMode();     // 启动时先广播一次，保证状态机同步
    dispatch_main();
    return 0;
}

// 原 0x100006c38。以 root 运行时先降权到 mobile，再改 notify state。
static int DisableMode(void) {
    if (geteuid() == 0) {
        struct passwd *pw = getpwnam("mobile");
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
    if (state == 3) return 0;                     // 已经是 Off
    if (notify_set_state(gModeToken, 3) != 0) return 1;
    if (notify_post(kModeNotify.UTF8String) != 0) return 1;
    return 0;
}

#pragma mark - 入口

int main(int argc, char **argv) {
    @autoreleasepool {
        // 原版无条件 dlopen 两个私有框架（渲染路径要用），这里保持一致
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_NOW);

        const char *arg = (argc > 1) ? argv[1] : "";

        if (strcmp(arg, "--disable") == 0) {
            return DisableMode();
        }
        if (strcmp(arg, "--watch") == 0) {
            return WatchMode();
        }
        if (strcmp(arg, "--preview-scan") == 0 || strcmp(arg, "--gloss-icon") == 0) {
            fwrite("FlatGlass: offline rendering is not part of this build; "
                   "see reverse-reference/E_cli.m\n", 1, 84, stderr);
            return 1;
        }

        // 无参数：直接把当前 plist 的 Mode 广播一次，便于手工调试
        PublishIconServicesMode();
        return 0;
    }
}
