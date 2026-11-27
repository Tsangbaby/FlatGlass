//
//  main.m
//  flatglass —— FlatGlass 的辅助守护进程
//
//  --watch：注销 FlatGlass 自己的 SnowBoard 主题并监听设置变更，
//  读出 Mode，以 Mode + 1 为 state 广播给 IconServices 和刷新组件。
//  --disable：只发布 Off 的 state，不改写保存的 Mode。
//  离线渲染路径未实现（参见 reverse-reference/E_cli.m）。
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>
#include <stdio.h>
#include <string.h>
#include <sysexits.h>
#import "../Shared/FGPreferences.h"

static NSString *const kSnowBoardRefresh = @"com.spark.snowboard.refreshNow";
static int gModeToken = -1;
static BOOL gModePostPending = NO;

#pragma mark - 模式广播

static BOOL PublishMode(FGMode mode) {
    if (gModeToken == -1) {
        int token = -1;
        if (notify_register_check(FGModeNotification, &token) != NOTIFY_STATUS_OK) goto fail;
        gModeToken = token;
    }

    uint64_t state = FGStateForMode(mode);
    uint64_t current = 0;
    if (notify_get_state(gModeToken, &current) != NOTIFY_STATUS_OK) goto fail;
    if (current != state) {
        if (notify_set_state(gModeToken, state) != NOTIFY_STATUS_OK) goto fail;
        gModePostPending = YES;
    }
    // A previous failed post still needs a signal even if get_state now matches.
    if (gModePostPending) {
        if (notify_post(FGModeNotification) != NOTIFY_STATUS_OK) goto fail;
        gModePostPending = NO;
    }
    return YES;

fail:
    fputs("FlatGlass: failed to publish mode.\n", stderr);
    return NO;
}

#pragma mark - 摘掉自己的 SnowBoard 主题

static NSString *CanonicalSnowBoardItemPath(NSString *entry) {
#if defined(FG_ROOTHIDE) && FG_ROOTHIDE
    // RootHide 配置也可保存相对于 jbroot 的绝对路径；已经解析的路径不再转一次。
    if ([entry hasPrefix:@"/Library/Themes/"]) entry = FGJailPath(entry);
#endif
    return [entry stringByResolvingSymlinksInPath];
}

// 原版在常驻前只做注销，不主动注册新主题。
static void UnregisterThemes(void) {
    NSString *path = FGJailPath(@"/var/mobile/Library/Preferences/com.spark.snowboardprefs.plist");
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    id items = prefs[@"ActiveMenuItems"];
    if (![items isKindOfClass:[NSArray class]]) return;

    NSArray *ours = @[
        [FGJailPath(@"/Library/Themes/FlatGlass.theme") stringByResolvingSymlinksInPath],
        [FGJailPath(@"/Library/Themes/FlatGlass Gloss.theme") stringByResolvingSymlinksInPath],
        [FGJailPath(@"/Library/Themes/FlatGlass Edge.theme") stringByResolvingSymlinksInPath],
    ];
    NSMutableArray *filtered = [NSMutableArray array];
    for (id entry in items) {
        if ([entry isKindOfClass:[NSString class]] &&
            [ours containsObject:CanonicalSnowBoardItemPath(entry)]) continue;
        [filtered addObject:entry];
    }
    if (filtered.count == [items count]) return;

    prefs[@"ActiveMenuItems"] = filtered;
    if (![prefs writeToFile:path atomically:YES]) {
        fputs("FlatGlass: failed to unregister old themes.\n", stderr);
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
    if (notify_register_dispatch(FGSettingsChangedNotification, &token,
                                 dispatch_get_main_queue(), ^(int t) {
        (void)t;
        @autoreleasepool {
            (void)PublishMode(FGReadMode());         // 事件失败只产生日志
        }
    }) != NOTIFY_STATUS_OK) {
        fputs("FlatGlass: failed to watch settings.\n", stderr);
        return 1;
    }

    if (!PublishMode(FGReadMode())) {               // 首发失败：不进入常驻循环
        (void)notify_cancel(token);
        return 1;
    }
    dispatch_main();
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
    return PublishMode(FGModeOff) ? 0 : 1;         // state 3；不读写偏好或主题
}

#pragma mark - 入口

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--disable") == 0) return DisableMode();
        if (argc == 2 && strcmp(argv[1], "--watch") == 0) return WatchMode();

        if (argc > 1 && (strcmp(argv[1], "--preview-scan") == 0 ||
                         strcmp(argv[1], "--gloss-icon") == 0 ||
                         (argc == 4 && argv[1][0] != '-'))) {
            fputs("FlatGlass: offline rendering is not part of this build.\n", stderr);
        } else {
            fputs("usage: flatglass --watch | --disable\n", stderr);
        }
        return EX_USAGE;
    }
}
