//
//  FGSettingsListController.m
//  FlatGlassPrefs.bundle
//
//  由 FlatGlassPrefs 二进制（169248 字节）反汇编还原。
//  地址对照：0x4000 localized: / 0x418c specifiers / 0x44e4 readMode: / 0x456c writeMode:specifier:
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "../Shared/FGPreferences.h"

@interface FGSettingsListController : PSListController
@end

@implementation FGSettingsListController

// 原 0x4000：手动做本地化，而不是靠 NSBundle 的默认机制。
// 原因：这个 bundle 只有 en.lproj / ru.lproj，且 Settings 进程的
// preferredLanguages 不一定落在 bundle 的 localizations 里，必须显式挑一次。
- (NSString *)localized:(NSString *)key {
    NSBundle *bundle = [NSBundle bundleForClass:[FGSettingsListController class]];

    NSString *language = [[NSBundle preferredLocalizationsFromArray:[bundle localizations]
                                                     forPreferences:[NSLocale preferredLanguages]]
                          firstObject];
    if (!language) language = @"en";

    NSString *lproj = [bundle pathForResource:language ofType:@"lproj"];
    NSBundle *target = lproj ? [NSBundle bundleWithPath:lproj] : bundle;
    return [target localizedStringForKey:key value:nil table:@"FlatGlass"];
}

// 原 0x418c：把 Root.plist 里写死英文的 footer 与 Mode 标题替换成当前语言。
- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }

    for (PSSpecifier *spec in _specifiers) {
        // footerText → 本地化文本（Root.plist 里存的是 key 本身）
        if ([spec propertyForKey:@"footerText"]) {
            [spec setProperty:[self localized:@"footer"] forKey:@"footerText"];
        }

        // Mode 这一行的标题 + 四个选项的标题字典
        if ([[spec propertyForKey:@"key"] isEqualToString:@"Mode"]) {
            [spec setName:[self localized:@"mode"]];
            [spec setTitleDictionary:@{
                @(FGModeRemove)  : [self localized:@"remove"],
                @(FGModeEdge)    : [self localized:@"edge"],
                @(FGModeArtwork) : [self localized:@"artwork"],
                @(FGModeOff)     : [self localized:@"off"],
            }];
        }
    }
    return _specifiers;
}

// 原 0x44e4：读 Mode，越界（<0 或 >3）当 0 处理。
- (id)readMode:(PSSpecifier *)spec {
    return @(FGReadMode());
}

// 原 0x456c：写 Mode 并广播。注意它写的是「只含 Mode 一个键」的新字典，
// 也就是整份 plist 被覆盖——目前 plist 里确实只有这一个键，维护时若要
// 加新键，这里必须改成「读出 → 改 → 写回」。
- (void)writeMode:(id)value specifier:(PSSpecifier *)spec {
    FGMode mode;
    if (!FGDecodePreferenceMode(value, &mode)) return;

    BOOL ok = [@{ FGModeKey: @(mode) } writeToFile:FGPreferencesPath() atomically:YES];
    if (ok) {
        notify_post(FGSettingsChangedNotification);
        return;
    }

    // 写失败：回滚 UI 并弹窗
    [self reloadSpecifier:spec animated:NO];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"FlatGlass"
                                            message:[self localized:@"save_failed"]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
