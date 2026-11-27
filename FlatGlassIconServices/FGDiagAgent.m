#import "FGDiagnostics.h"
#import <dispatch/dispatch.h>
#import <notify.h>

/* One coalescing source, not one block/IPC operation per callback. The
 * token below keeps only the independent diagnostic name alive. */
static dispatch_source_t progressSource;

void FGDAgentStart(void) {
    @try {
        dispatch_queue_t queue = dispatch_queue_create("fg.diag.agent", DISPATCH_QUEUE_SERIAL);
        if (!queue) return;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, queue);
        if (!source) return;
        __block int token = -1;
        __block uint32_t seen = 0;
        __block uint32_t posted = 0;
        __block unsigned attempts = 0;
        dispatch_source_set_event_handler(source, ^{
            seen |= (uint32_t)dispatch_source_get_data(source) & FGD_AGENT_FLAGS_MASK;
            if (seen == posted || attempts >= FGD_REPORT_WRITE_LIMIT) return;
            ++attempts;
            if (token < 0 && notify_register_check(FGD_PROGRESS, &token) != NOTIFY_STATUS_OK) {
                token = -1;
                return;
            }
            if (notify_set_state(token, seen) == NOTIFY_STATUS_OK &&
                notify_post(FGD_PROGRESS) == NOTIFY_STATUS_OK) posted = seen;
        });
        progressSource = source;
        dispatch_resume(source);
    } @catch (id ignored) { (void)ignored; }
}

void FGDAgentRecord(uint32_t flags) {
    dispatch_source_t source = progressSource;
    if (source) dispatch_source_merge_data(source, flags & FGD_AGENT_FLAGS_MASK);
}

void FGDAgentTerminalWriteFailure(uint64_t state, bool fromNotification) {
    /* The next original instruction exits the process. An async breadcrumb
     * can be lost here. Use a separate channel with the stage and coarse read
     * value, and send the failure independently even if setting state fails.
     * Leave this diagnostic token to normal process teardown. */
    const uint32_t flags = FGD_ENTERED | FGD_HOOK_ACCEPTED | FGD_MODE_REGISTER_OK |
                           FGDReadFlag(NOTIFY_STATUS_OK, state, fromNotification);
    int token = 0;
    if (notify_register_check(FGD_TERMINAL, &token) == NOTIFY_STATUS_OK) {
        (void)notify_set_state(token, flags);
    }
    (void)notify_post(FGD_TERMINAL);
}
