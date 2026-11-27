//
//  FGWrap.m
//  FlatGlass
//

#import "FGWrap.h"
#import "FGCatalog.h"
#import "FGCommon.h"
#import "FGCompat.h"
#import "FGLog.h"

#import <dlfcn.h>
#import <objc/runtime.h>

@protocol FGImageWrapping <NSObject>
- (instancetype)initWithCGImage:(CGImageRef)image scale:(CGFloat)scale;
@end

static NSString *FGPrimaryResourceKey(void) {
    static NSString *primaryKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id __unsafe_unretained const *symbol =
            (id __unsafe_unretained const *)dlsym(RTLD_DEFAULT, "kISPrimaryResourceKey");
        id value = symbol ? *symbol : nil;
        primaryKey = [value isKindOfClass:[NSString class]] ? value : @"kISPrimaryResourceKey";
    });
    return primaryKey;
}

id FGWrapImage(CGImageRef image, CGFloat scale) {
    if (!image) return nil;

    Class imageClass = objc_getClass("IFImage");
    if (!imageClass) return nil;

    SEL initializer = @selector(initWithCGImage:scale:);
    if (![imageClass instancesRespondToSelector:initializer]) return nil;

    @try {
        id<FGImageWrapping> instance = [imageClass alloc];
        return [instance initWithCGImage:image scale:scale];
    } @catch (NSException *e) {
        FGLogf(@"IFImage init failed: %@", e.reason);
        return nil;
    }
}

BOOL FGHasLayeredPrimaryResource(id resource) {
    if (!resource || !FGOriginalResourceImage) return NO;

    id provider = nil;
    @try {
        provider = [resource valueForKey:@"resourceProvider"];
    } @catch (__unused NSException *e) {
        return NO;
    }

    SEL named = NSSelectorFromString(@"resourceNamed:");
    if (!provider || ![provider respondsToSelector:named]) return NO;

    id primary = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    @try {
        primary = [provider performSelector:named withObject:FGPrimaryResourceKey()];
    } @catch (__unused NSException *e) {
        return NO;
    }
#pragma clang diagnostic pop

    Class resourceClass = objc_getClass("ISAssetCatalogResource");
    if (!resourceClass || ![primary isKindOfClass:resourceClass]) return NO;

    id catalog = nil;
    NSString *imageName = nil;
    @try {
        catalog = [primary valueForKey:@"catalog"];
        imageName = [primary valueForKey:@"imageName"];
    } @catch (__unused NSException *e) {
        return NO;
    }

    if (!catalog || !imageName.length) return NO;
    return FGCatalogHasStack(primary, imageName);
}
