/* macOS host smoke test of the production diagnostic transport, not a device
 * or private IconServices ABI test. Every role runs in a separate process. */
#import "FGDiagnostics.h"
#import <dispatch/dispatch.h>
#import <string.h>
#import <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "collector") == 0) {
        FGDStartDaemon();
        FGDRecordPublish((FGDPublish){0, 1, 0, 0, 0, 0}, false);
        FGDRecordWatch(0);
        FGDRecordPublish((FGDPublish){3, 4, 0, 0, 0, 0}, true);
        dispatch_main();
    }
    if (strcmp(argv[1], "progress") == 0) {
        FGDAgentStart();
        FGDAgentRecord(FGD_ENTERED | FGD_HOOK_ACCEPTED | FGD_MODE_REGISTER_OK | FGDReadFlag(0, 0, false));
        dispatch_main();
    }
    if (strcmp(argv[1], "terminal") == 0) {
        FGDAgentTerminalWriteFailure(4, true);
        _exit(0);
    }
    return 2;
}
