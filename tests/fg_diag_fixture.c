#include "FGDiagnostics.h"

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const FGDReport report = {
        .generation = 12345,
        .sequence = 2,
        .watchStatus = 0,
        .initial = {3, 4, 0, 0, 0, 0},
        .change = {1, 2, 0, 0, 0, 7},
        .changes = 1,
        .agentFlags = FGD_ENTERED | FGD_HOOK_ACCEPTED | FGD_MODE_REGISTER_OK | FGDReadFlag(0, 0, false),
        .agentChannel = 0,
        .terminalFlags = FGDReadFlag(0, 2, true),
        .terminalChannel = 0,
        .terminalCacheWriteFailed = true,
    };
    if (FGDReadFlag(12, 2, false) != FGD_READ_FAILED || FGDReadFlag(0, 4, false) != FGD_READ_4 ||
        FGDReadFlag(0, UINT64_MAX, false) != FGD_READ_OTHER ||
        FGDReadSummary(FGDReadFlag(0, 0, false) | FGDReadFlag(0, 4, false), false) != FGD_OTHER ||
        FGDReadSummary(FGDReadFlag(12, 2, true), true) != FGD_UNOBSERVED ||
        FGDReadSummary(FGDReadFlag(0, 2, true), false) != FGD_UNOBSERVED) return 3;
    return FGDWriteReport(argv[1], &report) ? 0 : 4;
}
