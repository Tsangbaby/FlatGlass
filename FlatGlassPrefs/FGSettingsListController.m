//
//  FGSettingsListController.m
//  FlatGlass
//
//  Root.plist drives the whole layout: a PSLinkListCell bound to the "Mode" key
//  through -readMode: and -writeMode:specifier:. Values are NOT in display
//  order — the plist maps them explicitly:
//
//      "Remove Highlights" -> 0
//      "Edge and Artwork"  -> 1
//      "Off"               -> 2
//      "Edge Only"         -> 3
//
// RootHide reads the package-private mode record; the legacy CFPreferences
// domain is consulted only by Settings for one-way migration. In other
// package schemes the original preferences domain remains authoritative.
// Post the wake-up only after a successful commit. The daemon alone publishes
// the renderer state.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

#import "FGCommon.h"
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#import <roothide.h>
#import "FGModeStore.h"
#include <errno.h>
#endif

static BOOL FGReadLegacySelection(NSInteger *mode) {
    CFStringRef domain = (__bridge CFStringRef)FG_PREFS_DOMAIN;
    if (!CFPreferencesAppSynchronize(domain)) return NO;
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Mode"), domain));
    return FGDecodePreferenceMode(value, mode);
}

static BOOL FGDecodePickerSelection(id value, NSInteger *mode) {
    if (FGDecodePreferenceMode(value, mode)) return YES;
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] != 1) return NO;
    const unichar digit = [(NSString *)value characterAtIndex:0];
    if (digit < '0' || digit > '3') return NO;
    *mode = digit - '0';
    return YES;
}

static BOOL FGNotifySettingsChanged(void) {
    uint32_t status = notify_post(FG_NOTIFY_SETTINGS);
    if (status != NOTIFY_STATUS_OK) NSLog(@"FlatGlass: settings notification failed (%u)", status);
    return status == NOTIFY_STATUS_OK;
}

#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
static void FGMigrateLegacySelection(void) {
    const char *directory = jbroot(FG_MODE_DIRECTORY);
    int stored = -1;
    if (FGModeStoreRead(directory, &stored) != ENOENT) return;
    NSInteger legacy = 0;
    if (!FGReadLegacySelection(&legacy)) return;
    const int status = FGModeStoreWrite(directory, (int)legacy);
    if (status == 0) (void)FGNotifySettingsChanged();
    else NSLog(@"FlatGlass: preference migration failed (%d)", status);
}
#endif

@interface FGSettingsListController : PSListController
@end

@implementation FGSettingsListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)readMode:(PSSpecifier *)specifier {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    int mode = -1;
    if (FGModeStoreRead(jbroot(FG_MODE_DIRECTORY), &mode) == 0) return @(mode);
    return @(FGModeOff);
#else
    NSInteger mode = FGModeFlat;
    return FGReadLegacySelection(&mode) ? @(mode) : @(FGModeFlat);
#endif
}

- (void)showModeError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"FlatGlass"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)writeMode:(id)value specifier:(PSSpecifier *)specifier {
    NSInteger mode = 0;
    if (!FGDecodePickerSelection(value, &mode)) return;
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    const int status = FGModeStoreWrite(jbroot(FG_MODE_DIRECTORY), (int)mode);
    if (status != 0) {
        [self showModeError:[NSString stringWithFormat:@"Could not save the selected mode (error %d).", status]];
        return;
    }
#else
    CFPreferencesSetAppValue(CFSTR("Mode"), (__bridge CFNumberRef)@(mode),
                             (__bridge CFStringRef)FG_PREFS_DOMAIN);
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)FG_PREFS_DOMAIN)) {
        [self showModeError:@"Could not save the selected mode."];
        return;
    }
#endif
    if (!FGNotifySettingsChanged())
        [self showModeError:@"The mode is saved, but FlatGlass could not send the update notification."];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"FlatGlass";

    // Footer explains the difference between the two highlight modes; the
    // bundle strings already carry the translations.
    self.navigationItem.rightBarButtonItem = nil;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    FGMigrateLegacySelection();
#endif
    [self reloadSpecifiers];
}

@end
