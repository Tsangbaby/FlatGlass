//
//  main.m
//  flatglass — LaunchDaemon
//
//  The bridge between the settings pane and the renderers. It is the only
//  component that touches the preference plist, and the only one that publishes
//  the notify state the other two read.
//
//  Modes:
//      --watch         stay resident; republish on every settings change
//      --disable       drop the generated themes and clear the published state
//      --preview-scan  walk installed applications and report what can render
//      --gloss-icon    render one icon to a file (used by the settings preview)
//
//  The +1 applied to the preference value is deliberate, see the note in
//  Shared/FGCommon.h.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <libgen.h>
#import <unistd.h>
#import <string.h>

#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#import <roothide.h>
#endif

#import "FGCommon.h"
#import "FGLog.h"
#import "FGDiagnostics.h"

#ifndef FG_INSTALL_PREFIX
#define FG_INSTALL_PREFIX @""
#endif

static NSString *const kThemeFlat  = @"/Library/Themes/FlatGlass.theme";
static NSString *const kThemeGloss = @"/Library/Themes/FlatGlass Gloss.theme";
static NSString *const kThemeEdge  = @"/Library/Themes/FlatGlass Edge.theme";
static NSString *const kSnowBoardPrefs =
    @"/var/mobile/Library/Preferences/com.spark.snowboardprefs.plist";

static NSString *FGInstallPath(NSString *path) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    return jbroot(path);
#else
    return [FG_INSTALL_PREFIX stringByAppendingString:path];
#endif
}

#pragma mark - Icon rendering

// Minimal CUICatalog reader. CoreUI is loaded dynamically so the daemon still
// runs (for --watch) on a device where the private framework moved.
@protocol FGPreviewCatalog <NSObject>
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (id)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale;
- (id)_imageWithName:(NSString *)name scaleFactor:(CGFloat)scale;
@end

@protocol FGPreviewImage <NSObject>
- (CGImageRef)image;
- (CGImageRef)CGImage;
@end

@interface FlatRenderer : NSObject
@property (nonatomic, strong) NSDictionary *catalog;
@property (nonatomic, strong) NSString *path;
- (instancetype)initWithFile:(NSString *)path;
- (CGImageRef)copyRenditionForName:(NSString *)name
                    foregroundOnly:(BOOL)foregroundOnly
                             scale:(CGFloat)scale;
@end

@implementation FlatRenderer {
    id<FGPreviewCatalog> _catalogRef;
}

- (instancetype)initWithFile:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    _path = [path copy];

    static void *coreUI;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        coreUI = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY);
    });
    if (!coreUI) return nil;

    Class catalogClass = objc_getClass("CUICatalog");
    if (!catalogClass) return nil;

    SEL initializer = NSSelectorFromString(@"initWithURL:error:");
    if (![catalogClass instancesRespondToSelector:initializer]) return nil;

    NSError *error = nil;
    @try {
        id<FGPreviewCatalog> catalog = [catalogClass alloc];
        _catalogRef = [catalog initWithURL:[NSURL fileURLWithPath:path] error:&error];
    } @catch (NSException *e) {
        NSLog(@"FlatGlass: cannot open catalog %@: %@", path, e.reason);
        return nil;
    }
    if (!_catalogRef) {
        NSLog(@"FlatGlass: cannot open catalog %@: %@", path, error.localizedDescription);
        return nil;
    }
    return self;
}

- (CGImageRef)copyRenditionForName:(NSString *)name
                    foregroundOnly:(BOOL)foregroundOnly
                             scale:(CGFloat)scale {
    if (!_catalogRef || !name) return NULL;

    @try {
        __attribute__((objc_precise_lifetime)) id<FGPreviewImage> result = nil;
        if ([_catalogRef respondsToSelector:@selector(imageWithName:scaleFactor:)]) {
            result = [_catalogRef imageWithName:name scaleFactor:scale];
        } else if ([_catalogRef respondsToSelector:@selector(_imageWithName:scaleFactor:)]) {
            result = [_catalogRef _imageWithName:name scaleFactor:scale];
        }

        CGImageRef cg = NULL;
        if ([result respondsToSelector:@selector(image)]) {
            cg = [result image];
        } else if ([result respondsToSelector:@selector(CGImage)]) {
            cg = [result CGImage];
        }
        return cg ? CGImageRetain(cg) : NULL;
    } @catch (__unused NSException *e) {
        return NULL;
    }
}

@end

#pragma mark - Helpers

static NSString *FGPreferencePath(void) {
    // The daemon runs as `mobile`, so the plain /var/mobile path resolves.
    return @"/var/mobile/Library/Preferences/local.lumid.flatglass.plist";
}

static NSInteger FGReadMode(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:FGPreferencePath()];
    id value = prefs[@"Mode"];
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : 0;
}

static BOOL FGPublishMode(NSInteger mode, bool fromChange) {
    int token = 0;
    uint32_t registerStatus = notify_register_check(FG_NOTIFY_MODE, &token);
    if (registerStatus != NOTIFY_STATUS_OK) {
        FGDRecordPublish((FGDPublish){mode >= 0 && mode <= 3 ? (int)mode : FGD_OTHER,
                         FGD_UNOBSERVED, FGDStatus(registerStatus), FGD_UNOBSERVED,
                         FGD_UNOBSERVED, FGD_UNOBSERVED}, fromChange);
        return NO;
    }

    // Modes are 0..3; anything else collapses to 1 so a corrupt plist cannot
    // park the consumers in an undefined branch.
    uint64_t normalized = (mode < 0 || mode >= 4) ? 1 : (uint64_t)(mode + 1);
    uint32_t setStatus = notify_set_state(token, normalized);
    BOOL ok = setStatus == NOTIFY_STATUS_OK;
    uint32_t cancelStatus = notify_cancel(token);

    uint32_t postStatus = 0;
    if (ok) postStatus = notify_post(FG_NOTIFY_MODE);
    if (!ok) NSLog(@"FlatGlass: failed to publish mode.");
    FGDRecordPublish((FGDPublish){mode >= 0 && mode <= 3 ? (int)mode : FGD_OTHER,
                     (int)normalized, FGDStatus(registerStatus), FGDStatus(setStatus),
                     FGDStatus(cancelStatus), ok ? FGDStatus(postStatus) : FGD_UNOBSERVED}, fromChange);
    return ok;
}

static void FGRemoveThemeAt(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *theme = FGInstallPath(path);
    if (![fm fileExistsAtPath:theme]) return;
    NSError *error = nil;
    [fm removeItemAtPath:theme error:&error];
    if (error) {
        NSLog(@"FlatGlass: failed to unregister old themes: %@", error.localizedDescription);
    }
}

static NSArray<NSString *> *FGInstalledApplications(void) {
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableArray *roots = [@[@"/var/containers/Bundle/Application", @"/Applications"] mutableCopy];
    NSString *jailbreakApps = FGInstallPath(@"/Applications");
    if (![roots containsObject:jailbreakApps]) [roots addObject:jailbreakApps];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *root in roots) {
        NSError *error = nil;
        NSArray *entries = [fm contentsOfDirectoryAtPath:root error:&error];
        if (!entries) {
            if ([root isEqualToString:roots.firstObject]) {
                NSLog(@"FlatGlass: cannot enumerate applications: %s",
                      error.localizedDescription.UTF8String);
            }
            continue;
        }
        for (NSString *entry in entries) {
            NSString *candidate = [root stringByAppendingPathComponent:entry];
            NSArray *bundleEntries = [fm contentsOfDirectoryAtPath:candidate error:NULL];
            for (NSString *bundle in bundleEntries) {
                if (![bundle hasSuffix:@".app"]) continue;
                [paths addObject:[candidate stringByAppendingPathComponent:bundle]];
            }
        }
    }
    return paths;
}

static BOOL FGValidIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

#pragma mark - Modes

static int FGWatchMode(void) {
    FGDStartDaemon();
    // Publish once at startup so consumers have a state even before the user
    // touches the settings pane.
    FGPublishMode(FGReadMode(), false);

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    int token = 0;
    int status = notify_register_dispatch(FG_NOTIFY_SETTINGS, &token, queue, ^(int t) {
        NSInteger mode = FGReadMode();
        FGPublishMode(mode, true);
        NSLog(@"[FlatGlass] mode published: %ld", (long)mode);

        // SnowBoard integrations regenerate their theme when it is present.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kSnowBoardPrefs]) {
            notify_post("com.spark.snowboard.refreshNow");
        }
    });

    FGDRecordWatch(FGDStatus((uint32_t)status));
    if (status != NOTIFY_STATUS_OK) {
        NSLog(@"FlatGlass: cannot watch settings (%d)", status);
        return 1;
    }

    dispatch_main();
    return 0;
}

static int FGDisableMode(void) {
    FGRemoveThemeAt(kThemeFlat);
    FGRemoveThemeAt(kThemeGloss);
    FGRemoveThemeAt(kThemeEdge);

    // Clearing the state back to 0 makes both consumers fall through to the
    // original IconServices implementation.
    int token = 0;
    if (notify_register_check(FG_NOTIFY_MODE, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, 0);
        notify_post(FG_NOTIFY_MODE);
        notify_cancel(token);
    }
    return 0;
}

static int FGPreviewScanMode(void) {
    NSUInteger rendered = 0, unsupported = 0;

    for (NSString *app in FGInstalledApplications()) {
        NSString *plist = [app stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        NSString *identifier = info[@"CFBundleIdentifier"];

        if (!FGValidIdentifier(identifier)) {
            printf("Skipped %s: no bundle identifier\n", app.UTF8String);
            continue;
        }

        NSString *assets = [app stringByAppendingPathComponent:@"Assets.car"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:assets]) {
            printf("Skipped %s: no Assets.car\n", app.UTF8String);
            continue;
        }

        FlatRenderer *renderer = [[FlatRenderer alloc] initWithFile:assets];
        if (!renderer) {
            printf("Unsupported icon: %s\n", identifier.UTF8String);
            unsupported++;
            continue;
        }

        NSString *iconName = info[@"CFBundleIconName"];
        if (!iconName) {
            NSArray *files = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
            iconName = [files isKindOfClass:[NSArray class]] ? files.lastObject : nil;
        }
        if (!iconName) {
            printf("Unsupported icon: %s\n", identifier.UTF8String);
            unsupported++;
            continue;
        }

        CGImageRef image = [renderer copyRenditionForName:iconName
                                           foregroundOnly:NO
                                                    scale:3.0];
        if (image) {
            printf("%s|%s\n", identifier.UTF8String, iconName.UTF8String);
            CGImageRelease(image);
            rendered++;
        } else {
            printf("Unsupported icon: %s\n", identifier.UTF8String);
            unsupported++;
        }
    }

    printf("\nFlatGlass: %lu rendered, %lu unsupported, %lu changes.\n",
           (unsigned long)rendered, (unsigned long)unsupported, (unsigned long)0);
    return 0;
}

static int FGGlossIconMode(const char *identifier, const char *outputPath) {
    if (!identifier || !outputPath) {
        fprintf(stderr, "usage: flatglass --gloss-icon <bundle id> <out.png>\n");
        return 2;
    }

    NSString *bundleId = @(identifier);
    id workspaceClass = (id)objc_getClass("LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    id workspace = nil;
    if (workspaceClass && [workspaceClass respondsToSelector:defaultSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        workspace = [workspaceClass performSelector:defaultSel];
#pragma clang diagnostic pop
    }

    CGImageRef icon = NULL;
    SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (workspace && [workspace respondsToSelector:iconSel]) {
        NSMethodSignature *sig = [workspace methodSignatureForSelector:iconSel];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setTarget:workspace];
        [invocation setSelector:iconSel];
        NSString *bid = bundleId;
        unsigned int format = 0;
        CGFloat scale = 3.0;
        [invocation setArgument:&bid atIndex:2];
        [invocation setArgument:&format atIndex:3];
        [invocation setArgument:&scale atIndex:4];
        [invocation invoke];

        CGImageRef result = NULL;
        [invocation getReturnValue:&result];
        if (result) icon = CGImageRetain(result);
    }

    if (!icon) {
        fprintf(stderr, "Unsupported icon: %s\n", identifier);
        return 1;
    }

    NSString *out = @(outputPath);
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out],
                                        CFSTR("public.png"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, icon, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(icon);
    return 0;
}

#pragma mark - Entry

int main(int argc, char *argv[]) {
    @autoreleasepool {
        FGLogInit();

        BOOL watch = NO, disable = NO, scan = NO, gloss = NO;
        const char *identifier = NULL, *outputPath = NULL;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--watch") == 0) watch = YES;
            else if (strcmp(argv[i], "--disable") == 0) disable = YES;
            else if (strcmp(argv[i], "--preview-scan") == 0) scan = YES;
            else if (strcmp(argv[i], "--gloss-icon") == 0) {
                gloss = YES;
                if (i + 2 < argc) {
                    identifier = argv[++i];
                    outputPath = argv[++i];
                }
            }
        }

        // Running as root would leave root-owned caches behind, which then
        // break the icon agent. Drop to mobile before touching anything.
        if (getuid() == 0) {
            setuid(501);
            setgid(501);
        }

        if (disable) return FGDisableMode();
        if (scan) return FGPreviewScanMode();
        if (gloss) return FGGlossIconMode(identifier, outputPath);
        if (watch) return FGWatchMode();

        fprintf(stderr,
                "flatglass — FlatGlass daemon\n"
                "  --watch          stay resident, republish on settings change\n"
                "  --disable        remove generated themes and clear the mode\n"
                "  --preview-scan   list apps whose icons can be rendered\n"
                "  --gloss-icon <bundle id> <out.png>\n");
        return 1;
    }
}
