#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include "FGDiagnostics.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define FGD_XML_LIMIT 4096u

static bool status_allowed(int s) { return s >= FGD_OTHER && s <= 255; }
static bool write_status_allowed(int s) { return s >= FGD_UNOBSERVED && s <= FGD_WRITE_CLOSE; }

static bool publish_allowed(FGDPublish p) {
    return p.mode >= FGD_OTHER && p.mode <= 3 && p.state >= FGD_UNOBSERVED && p.state <= 4 &&
           status_allowed(p.registered) && status_allowed(p.set) &&
           status_allowed(p.cancel) && status_allowed(p.post);
}

#define XML_INT(k) "<key>" k "</key><integer>%d</integer>"
#define XML_UINT(k) "<key>" k "</key><integer>%u</integer>"
#define XML_U32(k) "<key>" k "</key><integer>%" PRIu32 "</integer>"
#define XML_PUBLISH(k) "<key>" k "</key><dict>" \
    XML_INT("mode") XML_INT("state") XML_INT("register") XML_INT("set") XML_INT("cancel") XML_INT("post") "</dict>"

static int render(char *xml, size_t cap, const FGDReport *r) {
    if (r == NULL || r->generation == 0 || r->sequence == 0 || r->sequence > FGD_REPORT_WRITE_LIMIT ||
        r->changes > FGD_REPORT_WRITE_LIMIT || ((r->agentFlags | r->terminalFlags) & ~(uint32_t)FGD_AGENT_FLAGS_MASK) ||
        (r->phase != FGD_PHASE_EARLY && r->phase != FGD_PHASE_COLLECTING) ||
        !write_status_allowed(r->documentsWriteStatus) || !write_status_allowed(r->preferencesWriteStatus) ||
        !status_allowed(r->watchStatus) ||
        !status_allowed(r->agentChannel) || !status_allowed(r->terminalChannel) ||
        !publish_allowed(r->initial) || !publish_allowed(r->change)) return -1;
    const uint32_t flags = r->agentFlags | r->terminalFlags;
    return snprintf(xml, cap,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
        "<key>format</key><integer>2</integer>" XML_U32("generation") XML_UINT("sequence")
        XML_INT("phase") XML_INT("documents_write_status") XML_INT("preferences_write_status")
        XML_INT("watch_status") XML_PUBLISH("initial") XML_PUBLISH("change") XML_UINT("changes")
        XML_U32("agent_flags") XML_INT("agent_channel") XML_INT("startup_read") XML_INT("notification_read")
        XML_INT("terminal_channel") XML_U32("terminal_flags")
        "<key>terminal_cache_write_failed</key><%s/></dict></plist>\n",
        r->generation, r->sequence, r->phase, r->documentsWriteStatus, r->preferencesWriteStatus, r->watchStatus,
        r->initial.mode, r->initial.state, r->initial.registered, r->initial.set, r->initial.cancel, r->initial.post,
        r->change.mode, r->change.state, r->change.registered, r->change.set, r->change.cancel, r->change.post,
        r->changes, r->agentFlags, r->agentChannel, FGDReadSummary(flags, false), FGDReadSummary(flags, true),
        r->terminalChannel, r->terminalFlags,
        r->terminalCacheWriteFailed ? "true" : "false");
}

static bool allowed(const struct stat *st, uid_t owner) {
    return S_ISREG(st->st_mode) && st->st_uid == owner && st->st_nlink == 1 &&
           (st->st_mode & 07777) == 0600;
}

static bool same_node(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static bool write_exact(int fd, const char *data, size_t size) {
    unsigned retries = 0;
    size_t sent = 0;
    while (sent < size) {
        const ssize_t n = write(fd, data + sent, size - sent);
        if (n > 0) sent += (size_t)n;
        else if (n == -1 && errno == EINTR && retries++ < 4) continue;
        else return false;
    }
    return fsync(fd) == 0;
}

static bool check_reopen(int dir, const char *name, uid_t owner, const struct stat *expected,
                         const char *xml, size_t length) {
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return false;
    bool ok = false;
    struct stat st;
    if (fstat(fd, &st) == 0 && allowed(&st, owner) && same_node(&st, expected) &&
        st.st_size == (off_t)length) {
        char received[FGD_XML_LIMIT];
        size_t used = 0;
        unsigned retries = 0;
        while (used < length) {
            const ssize_t n = read(fd, received + used, length - used);
            if (n > 0) used += (size_t)n;
            else if (n == -1 && errno == EINTR && retries++ < 4) continue;
            else break;
        }
        ok = used == length && memcmp(received, xml, length) == 0;
    }
    return close(fd) == 0 && ok;
}

static int write_xml(const char *directory, const char *name, const char *xml, int count) {
    if (!directory || count <= 0 || (size_t)count >= FGD_XML_LIMIT) return FGD_WRITE_INVALID;
    const uid_t owner = geteuid();
    int dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir < 0) return FGD_WRITE_PARENT_OPEN;
    int result = FGD_WRITE_PARENT_IDENTITY;
    int fd = -1;
    struct stat parent, written;
    if (fstat(dir, &parent) != 0 || !S_ISDIR(parent.st_mode) || parent.st_uid != owner) goto out;

    const int flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC;
    result = FGD_WRITE_FILE_OPEN;
    fd = openat(dir, name, flags | O_CREAT | O_EXCL, 0600);
    if (fd < 0 && errno == EEXIST) fd = openat(dir, name, flags);
    if (fd < 0) goto out;
    result = FGD_WRITE_FILE_IDENTITY;
    if (fstat(fd, &written) != 0 || !allowed(&written, owner)) goto out;
    result = FGD_WRITE_LOCK;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) goto out;
    result = FGD_WRITE_FILE_IDENTITY;
    if (fstat(fd, &written) != 0 || !allowed(&written, owner)) goto out;

    /* Bind the write to the validated descriptor, not a replaceable temp
     * pathname. A simultaneous export during a short rewrite may be partial;
     * never treat a partial or unparseable file as an observed empty report. */
    result = FGD_WRITE_TRUNCATE;
    if (ftruncate(fd, 0) != 0) goto out;
    result = FGD_WRITE_CONTENT;
    if (!write_exact(fd, xml, (size_t)count)) {
        (void)ftruncate(fd, 0);
        goto out;
    }
    result = check_reopen(dir, name, owner, &written, xml, (size_t)count) ?
        FGD_WRITE_OK : FGD_WRITE_READBACK;
out:
    if (fd >= 0 && close(fd) != 0 && result == FGD_WRITE_OK) result = FGD_WRITE_CLOSE;
    if (close(dir) != 0 && result == FGD_WRITE_OK) result = FGD_WRITE_CLOSE;
    return result;
}

int FGDWriteReport(const char *directory, const char *name, const FGDReport *report) {
    if (!name || (strcmp(name, FGD_REPORT_NAME) != 0 && strcmp(name, FGD_PREFERENCES_NAME) != 0))
        return FGD_WRITE_INVALID;
    char xml[FGD_XML_LIMIT];
    const int count = render(xml, sizeof(xml), report);
    return write_xml(directory, name, xml, count);
}

int FGDWriteInstallMarker(const char *directory, int phase, int bootstrap, int fallback) {
    const bool entered = phase == FGD_INSTALL_ENTERED && bootstrap == FGD_UNOBSERVED && fallback == FGD_UNOBSERVED;
    const bool complete = phase == FGD_INSTALL_COMPLETE && bootstrap >= 0 && bootstrap <= 255 &&
        (bootstrap == 0 ? fallback == FGD_UNOBSERVED : fallback >= 0 && fallback <= 255);
    if (!entered && !complete) return FGD_WRITE_INVALID;
    char xml[FGD_XML_LIMIT];
    const int count = snprintf(xml, sizeof(xml),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
        "<key>format</key><integer>2</integer>" XML_INT("install_phase")
        XML_INT("bootstrap_status") XML_INT("fallback_status") "</dict></plist>\n",
        phase, bootstrap, fallback);
    return write_xml(directory, FGD_INSTALL_MARKER_NAME, xml, count);
}
