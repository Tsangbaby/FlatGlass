//
//  FGCompat.m
//  FlatGlass
//

#import "FGCompat.h"
#import "FGCommon.h"
#import "FGLog.h"
#import "FGRender.h"

#import <unistd.h>

IMP FGOriginalResourceImage = NULL;
IMP FGOriginalComposedImage = NULL;

// Mirrors the private cache root used by IconServices on iOS 15+.
static NSString *const kFGCacheRoot =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache"
    @"/Library/Caches/com.apple.IconsCache";

BOOL FGIsImageRenderer(Method m) {
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 4) return NO;

    char ret[32]  = {0};
    char arg2[128] = {0};
    char arg3[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    method_getArgumentType(m, 2, arg2, sizeof(arg2));
    method_getArgumentType(m, 3, arg3, sizeof(arg3));

    if (ret[0] != '@') return NO;

    // The size argument must literally encode as {CGSize=dd}. Comparing the
    // bytes (not the string) matches the original and tolerates the trailing
    // NUL being absent from a short buffer.
    if (memcmp(arg2, "{CGSize=dd}", 11) != 0) return NO;

    return arg3[0] == 'd';
}

void FGInvalidateCacheIfNeeded(uint64_t state) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stampPath = [kFGCacheRoot stringByAppendingPathComponent:@".flatglass-mode"];
    NSString *wanted = [NSString stringWithFormat:@"1:%llu", state];

    NSError *error = nil;
    NSString *current = [NSString stringWithContentsOfFile:stampPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    if ([current isEqualToString:wanted]) {
        FGLogf(@"cache already stamped %@", wanted);
        return;
    }

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:kFGCacheRoot error:&error];
    if (!entries) {
        // Directory may not exist yet on a freshly booted device; creating it
        // through the stamp write below is enough.
        FGLogf(@"icon cache unreadable: %@", error.localizedDescription);
    }

    for (NSString *entry in entries) {
        if ([entry isEqualToString:@".flatglass-mode"]) continue;
        NSString *full = [kFGCacheRoot stringByAppendingPathComponent:entry];
        [fm removeItemAtPath:full error:&error];
    }

    // If the stamp cannot be written the agent would re-render on every launch
    // forever; the original exits so launchd restarts it with a clean slate.
    if (![wanted writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        FGLogf(@"stamp write failed: %@", error.localizedDescription);
        _exit(0);
    }
}

BOOL FGInstallHooks(void) {
    Class imageClass    = objc_getClass("IFImage");
    Class resourceClass = objc_getClass("ISAssetCatalogResource");
    Class compositorClass = objc_getClass("ISCompositor");
    Class appRecipeClass  = objc_getClass("ISiOSAppRecipe");

    if (!imageClass || !resourceClass) {
        NSLog(@"FlatGlass: compatible IconServices methods were not found.");
        return NO;
    }

    // IFImage must be able to wrap a CGImage, otherwise there is nothing to
    // hand back to IconServices.
    if (![imageClass instancesRespondToSelector:@selector(initWithCGImage:scale:)]) {
        NSLog(@"FlatGlass: compatible IconServices methods were not found.");
        return NO;
    }

    SEL imageForSize = @selector(imageForSize:scale:);

    BOOL resourceOK = NO;
    if ([resourceClass instancesRespondToSelector:@selector(catalog)] &&
        [resourceClass instancesRespondToSelector:@selector(imageName)]) {
        Method m = class_getInstanceMethod(resourceClass, imageForSize);
        resourceOK = FGIsImageRenderer(m);
        if (resourceOK) {
            FGOriginalResourceImage = method_getImplementation(m);
            class_replaceMethod(resourceClass, imageForSize,
                                (IMP)FGResourceImage, method_getTypeEncoding(m));
            FGLogf(@"hooked ISAssetCatalogResource");
        }
    }

    BOOL composedOK = NO;
    if (compositorClass && appRecipeClass) {
        Method m = class_getInstanceMethod(compositorClass, imageForSize);
        composedOK = FGIsImageRenderer(m);
        if (composedOK) {
            FGOriginalComposedImage = method_getImplementation(m);
            class_replaceMethod(compositorClass, imageForSize,
                                (IMP)FGComposedImage, method_getTypeEncoding(m));
            FGLogf(@"hooked ISCompositor");
        }
    }

    if (!resourceOK && !composedOK) {
        NSLog(@"FlatGlass: compatible IconServices methods were not found.");
    }
    return resourceOK || composedOK;
}
