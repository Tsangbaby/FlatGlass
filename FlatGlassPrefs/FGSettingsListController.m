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
//  Writing a value has to do three things, in this order:
//    1. persist it in the domain the daemon reads
//    2. post settings-changed so the daemon republishes the notify state
//    3. nothing else — the daemon owns the state, we never set it directly
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

#import "FGCommon.h"

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
    CFPreferencesAppSynchronize((__bridge CFStringRef)FG_PREFS_DOMAIN);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Mode"),
                                                        (__bridge CFStringRef)FG_PREFS_DOMAIN);
    NSInteger mode = 0;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &mode);
        }
        CFRelease(value);
    }
    if (mode < 0 || mode > 3) mode = 0;

    // PSSpecifier consumers expect an NSNumber or a string; number is fine for
    // a PSLinkListCell with numeric validValues.
    return @(mode);
}

- (void)writeMode:(id)value specifier:(PSSpecifier *)specifier {
    NSInteger mode = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    if (mode < 0 || mode > 3) mode = 0;

    CFPreferencesSetAppValue(CFSTR("Mode"), (__bridge CFNumberRef)@(mode),
                             (__bridge CFStringRef)FG_PREFS_DOMAIN);
    BOOL saved = CFPreferencesAppSynchronize((__bridge CFStringRef)FG_PREFS_DOMAIN);

    if (!saved) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"FlatGlass"
                                                message:@"Could not save the selected mode."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // The daemon listens for this and is the only publisher of the render mode.
    notify_post(FG_NOTIFY_SETTINGS);
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
    // Re-read in case the value changed while the pane was backgrounded.
    [self reloadSpecifiers];
}

@end
