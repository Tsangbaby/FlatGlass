//
//  Tweak.x
//  FlatGlass — icon agent entry point
//
//  Loaded into iconservicesagent only (the filter plist restricts it, and the
//  constructor double-checks). Order of work matters:
//
//    1. bail out in any other process
//    2. validate and swap the two IconServices methods
//    3. subscribe to the mode notify, and only then
//    4. drop a stale icon cache
//
//  Step 3 must precede 4: without a registered token notify_get_state fails and
//  we would wipe the cache on every launch.
//

#import "FGCommon.h"
#import "FGCompat.h"
#import "FGRender.h"
#import "FGLog.h"
#import "FGWrap.h"
#import "FGDiagnostics.h"

#import <notify.h>

int FGModeToken = 0;

__attribute__((constructor))
static void FlatGlassIconServicesInit(void) {
    FGLogInit();

    // Only the icon rendering agent is ours to touch. SpringBoard has its own
    // tiny tweak; every other process must stay untouched.
    NSString *processName = [NSProcessInfo processInfo].processName;
    if (![processName isEqualToString:@"iconservicesagent"]) {
        return;
    }

    FGDAgentStart();
    FGDAgentRecord(FGD_ENTERED);
    if (!FGInstallHooks()) {
        FGDAgentRecord(FGD_HOOK_REJECTED);
        return;
    }
    FGDAgentRecord(FGD_HOOK_ACCEPTED);

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    int status = notify_register_dispatch(FG_NOTIFY_MODE, &FGModeToken, queue, ^(int token) {
        uint64_t state = 0;
        uint32_t readStatus = notify_get_state(token, &state);
        FGDAgentRecord(FGDReadFlag(readStatus, state, true));
        if (readStatus == NOTIFY_STATUS_OK) {
            FGInvalidateCacheIfNeeded(state, true);
        }
    });

    if (status != NOTIFY_STATUS_OK) {
        FGDAgentRecord(FGD_MODE_REGISTER_FAILED);
        FGModeToken = 0;
        FGLogf(@"notify registration failed: %d", status);
        return;
    }
    FGDAgentRecord(FGD_MODE_REGISTER_OK);

    // Publish time of the first render: if the daemon already set a state we
    // honour it now, otherwise the next notify drives us.
    uint64_t state = 0;
    uint32_t readStatus = notify_get_state(FGModeToken, &state);
    FGDAgentRecord(FGDReadFlag(readStatus, state, false));
    if (readStatus == NOTIFY_STATUS_OK) {
        FGInvalidateCacheIfNeeded(state, false);
    }
}
