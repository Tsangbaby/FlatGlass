#import "FGDiagnostics.h"
#import <dispatch/dispatch.h>
#import <notify.h>
#import <pthread.h>
#import <stdlib.h>
#import <syslog.h>

#define FGD_EMPTY { FGD_UNOBSERVED, FGD_UNOBSERVED, FGD_UNOBSERVED, FGD_UNOBSERVED, FGD_UNOBSERVED, FGD_UNOBSERVED }
static pthread_mutex_t reportLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t reportSource;
static FGDReport report = {
    .phase = FGD_PHASE_EARLY,
    .documentsWriteStatus = FGD_UNOBSERVED,
    .preferencesWriteStatus = FGD_UNOBSERVED,
    .watchStatus = FGD_UNOBSERVED,
    .initial = FGD_EMPTY,
    .change = FGD_EMPTY,
    .agentChannel = FGD_UNOBSERVED,
    .terminalChannel = FGD_UNOBSERVED,
};

/* Called only on the diagnostic queue. No report I/O under reportLock, and
 * neither destination's failure prevents attempting the other. */
static void writeSnapshot(void) {
    pthread_mutex_lock(&reportLock);
    if (report.sequence >= FGD_REPORT_WRITE_LIMIT) {
        pthread_mutex_unlock(&reportLock);
        return;
    }
    FGDReport snapshot = report;
    snapshot.sequence = ++report.sequence;
    pthread_mutex_unlock(&reportLock);

    const int documents = FGDWriteReport(FGD_REPORT_DIRECTORY, FGD_REPORT_NAME, &snapshot);
    const int preferences = FGDWriteReport(FGD_PREFERENCES_DIRECTORY, FGD_PREFERENCES_NAME, &snapshot);
    if (snapshot.sequence != 1) return;

    /* Retain the first attempt for each destination. Re-publish it once, not
     * recursively: these fields describe the first pass, not this rewrite. */
    pthread_mutex_lock(&reportLock);
    report.documentsWriteStatus = snapshot.documentsWriteStatus = documents;
    report.preferencesWriteStatus = snapshot.preferencesWriteStatus = preferences;
    pthread_mutex_unlock(&reportLock);
    if (documents == FGD_WRITE_OK)
        (void)FGDWriteReport(FGD_REPORT_DIRECTORY, FGD_REPORT_NAME, &snapshot);
    if (preferences == FGD_WRITE_OK)
        (void)FGDWriteReport(FGD_PREFERENCES_DIRECTORY, FGD_PREFERENCES_NAME, &snapshot);
    if (documents != FGD_WRITE_OK && preferences != FGD_WRITE_OK)
        syslog(LOG_NOTICE, "FlatGlass diagnostic: both initial report writes unavailable (%d, %d)", documents, preferences);
}

static void queueReport(void) {
    dispatch_source_t source = reportSource;
    if (source) dispatch_source_merge_data(source, 1);
}

static void readAgent(int token, bool terminalEvent) {
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK || state > FGD_AGENT_FLAGS_MASK) state = 0;
    pthread_mutex_lock(&reportLock);
    bool changed;
    if (terminalEvent) {
        changed = !report.terminalCacheWriteFailed || (report.terminalFlags | (uint32_t)state) != report.terminalFlags;
        report.terminalCacheWriteFailed = true;
        report.terminalFlags |= (uint32_t)state;
    } else {
        changed = (report.agentFlags | (uint32_t)state) != report.agentFlags;
        report.agentFlags |= (uint32_t)state;
    }
    pthread_mutex_unlock(&reportLock);
    if (changed) queueReport();
}

void FGDStartDaemon(void) {
    @try {
        dispatch_queue_t queue = dispatch_queue_create("fg.diag.report", DISPATCH_QUEUE_SERIAL);
        if (!queue) return;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, queue);
        if (!source) return;
        uint32_t generation = arc4random();
        report.generation = generation ? generation : 1;
        dispatch_source_set_event_handler(source, ^{ writeSnapshot(); });
        reportSource = source;
        dispatch_resume(source);
        dispatch_async(queue, ^{
            writeSnapshot();
            int progress = 0, terminal = 0;
            uint32_t terminalStatus = notify_register_dispatch(FGD_TERMINAL, &terminal, queue, ^(int token) {
                readAgent(token, true);
            });
            uint32_t progressStatus = notify_register_dispatch(FGD_PROGRESS, &progress, queue, ^(int token) {
                readAgent(token, false);
            });
            pthread_mutex_lock(&reportLock);
            report.phase = FGD_PHASE_COLLECTING;
            report.agentChannel = FGDStatus(progressStatus);
            report.terminalChannel = FGDStatus(terminalStatus);
            pthread_mutex_unlock(&reportLock);
            if (progressStatus == NOTIFY_STATUS_OK) readAgent(progress, false);
            queueReport();
        });
    } @catch (id ignored) { (void)ignored; }
}

void FGDRecordPublish(FGDPublish sample, bool fromChange) {
    bool accepted = false;
    pthread_mutex_lock(&reportLock);
    if (fromChange && report.changes < FGD_REPORT_WRITE_LIMIT) {
        report.change = sample;
        ++report.changes;
        accepted = true;
    } else if (!fromChange) {
        report.initial = sample;
        accepted = true;
    }
    pthread_mutex_unlock(&reportLock);
    if (accepted) queueReport();
}

void FGDRecordWatch(int status) {
    pthread_mutex_lock(&reportLock);
    report.watchStatus = status;
    pthread_mutex_unlock(&reportLock);
    queueReport();
}
