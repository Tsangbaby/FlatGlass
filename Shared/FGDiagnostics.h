#ifndef FG_DIAGNOSTICS_H
#define FG_DIAGNOSTICS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Diagnostic-only names. Do not subscribe to the production mode name here:
 * holding an extra token could mask the state-lifetime problem under test. */
#ifndef FGD_PROGRESS
#define FGD_PROGRESS "local.lumid.flatglass.diag.d1.agent-progress"
#endif
#ifndef FGD_TERMINAL
#define FGD_TERMINAL "local.lumid.flatglass.diag.d1.cache-write-failed"
#endif
#ifndef FGD_REPORT_DIRECTORY
#define FGD_REPORT_DIRECTORY "/var/mobile/Library/Preferences"
#endif
#define FGD_REPORT_NAME "FlatGlassDiagnostics-d1.plist"
#define FGD_REPORT_WRITE_LIMIT 64u
#define FGD_UNOBSERVED (-1)
#define FGD_OTHER (-2)

enum {
    FGD_ENTERED              = 1u << 0,
    FGD_HOOK_REJECTED        = 1u << 1,
    FGD_HOOK_ACCEPTED        = 1u << 2,
    FGD_MODE_REGISTER_FAILED = 1u << 3,
    FGD_MODE_REGISTER_OK     = 1u << 4,
    FGD_READ_FAILED           = 1u << 5,
    FGD_READ_0                = 1u << 6,
    FGD_READ_1                = 1u << 7,
    FGD_READ_2                = 1u << 8,
    FGD_READ_3                = 1u << 9,
    FGD_READ_4                = 1u << 10,
    FGD_READ_OTHER            = 1u << 11,
    FGD_READ_SHIFT            = 7,
    FGD_READ_MASK             = ((1u << 12) - 1u) ^ ((1u << 5) - 1u),
    FGD_CACHE_ALREADY         = 1u << 19,
    FGD_CACHE_WRITE_OK        = 1u << 20,
    FGD_CACHE_DIR_UNREADABLE  = 1u << 21,
    FGD_CACHE_SHIFT           = 3,
    FGD_AGENT_FLAGS_MASK      = (1u << 25) - 1u,
};

static inline uint32_t FGDReadFlag(uint32_t status, uint64_t state, bool fromNotification) {
    const uint32_t flag = status != 0 ? FGD_READ_FAILED :
        (state <= 4 ? (FGD_READ_0 << (unsigned)state) : FGD_READ_OTHER);
    return flag << (fromNotification ? FGD_READ_SHIFT : 0);
}

static inline int FGDReadSummary(uint32_t flags, bool fromNotification) {
    const uint32_t reads = (flags >> (fromNotification ? FGD_READ_SHIFT : 0)) & FGD_READ_MASK;
    if (reads & FGD_READ_OTHER) return FGD_OTHER;
    int result = FGD_UNOBSERVED;
    for (unsigned i = 0; i <= 4; ++i) {
        if (!(reads & (FGD_READ_0 << i))) continue;
        if (result != FGD_UNOBSERVED) return FGD_OTHER;
        result = (int)i;
    }
    return result;
}

static inline uint32_t FGDCacheFlag(uint32_t flag, bool fromNotification) {
    return flag << (fromNotification ? FGD_CACHE_SHIFT : 0);
}

static inline int FGDStatus(uint32_t status) { return status <= 255 ? (int)status : FGD_OTHER; }

typedef struct {
    int mode;
    int state;
    int registered;
    int set;
    int cancel;
    int post;
} FGDPublish;

typedef struct {
    uint32_t generation;
    unsigned sequence;
    int watchStatus;
    FGDPublish initial;
    FGDPublish change;
    unsigned changes;
    uint32_t agentFlags;
    uint32_t terminalFlags;
    int agentChannel;
    int terminalChannel;
    bool terminalCacheWriteFailed;
} FGDReport;

void FGDStartDaemon(void);
void FGDRecordPublish(FGDPublish sample, bool fromChange);
void FGDRecordWatch(int status);

void FGDAgentStart(void);
void FGDAgentRecord(uint32_t flags);
void FGDAgentTerminalWriteFailure(uint64_t state, bool fromNotification);

/* Only flatglass owns file I/O. The parameter lets the host test the exact
 * writer in an isolated directory. The runtime passes FGD_REPORT_DIRECTORY. */
bool FGDWriteReport(const char *directory, const FGDReport *report);

#ifdef __cplusplus
}
#endif
#endif
