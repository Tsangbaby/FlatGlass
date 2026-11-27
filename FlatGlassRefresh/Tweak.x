//
//  Tweak.x
//  FlatGlass — SpringBoard refresh helper
//
//  The icon agent can only rebuild images that are requested again. Once it has
//  re-rendered and cleared the on-disk cache, something still has to ask
//  SpringBoard to throw away the icon views it is already showing. That is this
//  component, and it is deliberately tiny:
//
//      notify received
//        └─ wait 2s (let the agent finish writing its cache)
//           └─ walk SBIconController's visible icon views
//              └─ reload in batches of 4, 25 ms apart
//
//  Batching matters. Reloading every icon at once on a full Home Screen stalls
//  SpringBoard long enough to drop a frame during the springboard animation.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>

#import "FGCommon.h"
#import "FGLog.h"

static int RefreshStatusToken = 0;
static int VisibleStatusToken = 0;
static NSUInteger RefreshGeneration = 0;
static NSMutableArray *ReloadedIcons = nil;

static const NSTimeInterval kFGRefreshDelay = 2.0;
static const NSUInteger kFGBatchSize = 4;
static const NSTimeInterval kFGBatchInterval = 0.025;

#pragma mark - Runtime helpers

// Both helpers exist because SpringBoard's private headers are not available at
// build time and we refuse to hard-link against them.
static id ObjectValue(id object, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    @try {
        return [object performSelector:sel];
    } @catch (__unused NSException *e) {
        return nil;
    }
#pragma clang diagnostic pop
}

static BOOL CallVoid(id object, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:sel]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    @try {
        [object performSelector:sel];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
#pragma clang diagnostic pop
}

#pragma mark - Icon reload

static void RefreshBatch(NSArray *iconViews, NSUInteger offset, NSUInteger generation) {
    if (generation != RefreshGeneration) return;   // superseded by a newer refresh
    if (offset >= iconViews.count) return;

    NSUInteger end = MIN(offset + kFGBatchSize, iconViews.count);

    [UIView performWithoutAnimation:^{
        for (NSUInteger i = offset; i < end; i++) {
            id view = iconViews[i];
            if (!CallVoid(view, @"_reloadIconImage")) {
                CallVoid(view, @"reloadIconImage");
            }
        }
    }];

    if (end < iconViews.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kFGBatchInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RefreshBatch(iconViews, end, generation);
        });
    } else {
        FGLogf(@"icon reload: %lu views", (unsigned long)iconViews.count);
    }
}

static void RefreshVisibleIconViews(void) {
    Class controllerClass = objc_getClass("SBIconController");
    Class imageViewClass = objc_getClass("SBIconImageView");
    if (!controllerClass || !imageViewClass) return;

    id controller = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([controllerClass respondsToSelector:shared]) {
        controller = [controllerClass performSelector:shared];
    }
#pragma clang diagnostic pop
    if (!controller) return;

    // Collect every visible SBIconImageView: window -> subviews, recursive.
    NSMutableArray *views = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray array];

    NSArray *windows = ObjectValue([UIApplication sharedApplication], @"windows");
    if ([windows isKindOfClass:[NSArray class]]) {
        [queue addObjectsFromArray:windows];
    }

    while (queue.count > 0) {
        id view = queue.lastObject;
        [queue removeLastObject];

        if ([view isKindOfClass:imageViewClass] && [view isKindOfClass:[UIView class]]) {
            BOOL hidden = [(UIView *)view isHidden];
            if (!hidden) [views addObject:view];
        }

        NSArray *subviews = ObjectValue(view, @"subviews");
        if ([subviews isKindOfClass:[NSArray class]]) {
            [queue addObjectsFromArray:subviews];
        }
    }

    RefreshGeneration++;
    NSUInteger generation = RefreshGeneration;

    if (views.count == 0) {
        FGLogf(@"displayed icon refresh: nothing visible");
        return;
    }

    FGLogf(@"displayed icon refresh: %lu views", (unsigned long)views.count);
    RefreshBatch(views, 0, generation);
}

#pragma mark - Notify

__attribute__((constructor))
static void StartFlatGlassRefresh(void) {
    FGLogInit();

    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        return;
    }

    ReloadedIcons = [NSMutableArray array];

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    // The agent publishes this once it has re-rendered; the delay below gives
    // it room to finish writing the cache before we force a reload.
    notify_register_dispatch(FG_NOTIFY_MODE, &RefreshStatusToken, queue, ^(int token) {
        uint64_t state = 0;
        if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kFGRefreshDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RefreshVisibleIconViews();
            notify_set_state(RefreshStatusToken, state);
            notify_post("local.lumid.flatglass.refreshed-views");
        });
    });

    // A manual poke from the daemon (used by `flatglass --refresh`) skips the
    // delay and reloads immediately.
    notify_register_dispatch("local.lumid.flatglass.reloaded-icons",
                             &VisibleStatusToken, queue, ^(int token) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RefreshVisibleIconViews();
        });
    });
}
