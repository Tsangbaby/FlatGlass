#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include "FGModeStore.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const int directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

static int closeWithStatus(int fd, int status) {
    if (close(fd) != 0 && status == 0) return errno;
    return status;
}

static bool isPrivateDirectory(const struct stat *st, uid_t owner) {
    return S_ISDIR(st->st_mode) && st->st_uid == owner && (st->st_mode & 07777) == 0700;
}

static bool isPrivateFile(const struct stat *st, bool openedReader) {
    // An open reader can still complete from the old inode after an atomic
    // replace drops its link count to zero. Never accept a linked alias.
    return S_ISREG(st->st_mode) && st->st_uid == geteuid() &&
           (st->st_nlink == 1 || (openedReader && st->st_nlink == 0)) &&
           (st->st_mode & 07777) == 0600;
}

static int openPrivateDirectory(const char *directory) {
    if (!directory || directory[0] != '/') { errno = EINVAL; return -1; }
    const int fd = open(directory, directoryFlags);
    if (fd < 0) return -1;
    struct stat st;
    int rc = 0;
    if (fstat(fd, &st) != 0) rc = errno;
    else if (!isPrivateDirectory(&st, geteuid())) rc = EPERM;
    if (!rc) return fd;
    close(fd);
    errno = rc;
    return -1;
}

int FGModeStoreRead(const char *directory, int *mode) {
    if (!mode) return EINVAL;
    const int dir = openPrivateDirectory(directory);
    if (dir < 0) return errno;
    const int fd = openat(dir, FG_MODE_RECORD, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int rc = 0;
    int decoded = -1;
    if (fd < 0) rc = errno;
    else {
        struct stat st;
        if (fstat(fd, &st) != 0) rc = errno;
        else if (!isPrivateFile(&st, true)) rc = EPERM;
        else if (st.st_size != 5) rc = EINVAL;
        else {
            char record[6];
            size_t used = 0;
            unsigned retries = 0;
            while (used < sizeof(record)) {
                const ssize_t n = read(fd, record + used, sizeof(record) - used);
                if (n > 0) used += (size_t)n;
                else if (n == 0) break;
                else if (errno != EINTR || ++retries >= 4) { rc = errno; break; }
            }
            if (!rc) {
                if (used != 5 || memcmp(record, "F1:", 3) != 0 || record[4] != '\n' ||
                    record[3] < '0' || record[3] > '3') rc = EINVAL;
                else decoded = record[3] - '0';
            }
        }
        rc = closeWithStatus(fd, rc);
    }
    rc = closeWithStatus(dir, rc);
    if (!rc) *mode = decoded;
    return rc;
}

static int writeRecord(int fd, int mode) {
    const char record[] = {'F', '1', ':', (char)('0' + mode), '\n'};
    size_t used = 0;
    unsigned retries = 0;
    while (used < sizeof(record)) {
        const ssize_t n = write(fd, record + used, sizeof(record) - used);
        if (n > 0) used += (size_t)n;
        else if (n == 0) return EIO;
        else if (errno != EINTR || ++retries >= 4) return errno;
    }
    return fsync(fd) == 0 ? 0 : errno;
}

int FGModeStoreWrite(const char *directory, int mode) {
    if (mode < 0 || mode > 3) return EINVAL;
    const int dir = openPrivateDirectory(directory);
    if (dir < 0) return errno;
    struct stat prior;
    int rc = 0;
    if (fstatat(dir, FG_MODE_RECORD, &prior, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!isPrivateFile(&prior, false)) rc = EPERM;
    } else if (errno != ENOENT) rc = errno;
    if (rc) return closeWithStatus(dir, rc);

    char scratch[48];
    int fd = -1;
    for (unsigned i = 0; i < 32; ++i) {
        snprintf(scratch, sizeof(scratch), ".mode-%ld-%u", (long)getpid(), i);
        fd = openat(dir, scratch, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) return closeWithStatus(dir, errno);
    rc = fchmod(fd, 0600) == 0 ? writeRecord(fd, mode) : errno;
    rc = closeWithStatus(fd, rc);
    if (!rc && renameat(dir, scratch, dir, FG_MODE_RECORD) != 0) rc = errno;
    if (rc) unlinkat(dir, scratch, 0);
    // The complete new record is committed once rename succeeds. Readers see
    // either version, never a truncated value. No writes to a system directory.
    close(dir);
    return rc;
}

#ifdef FG_MODE_STORE_PREPARE
int FGModeStorePrepare(const char *parent, uid_t owner, gid_t group) {
    if (geteuid() != 0 || owner == 0 || group == 0 || !parent || parent[0] != '/') return EPERM;
    const int dir = open(parent, directoryFlags);
    if (dir < 0) return errno;
    struct stat st;
    if (fstat(dir, &st) != 0) return closeWithStatus(dir, errno);
    if (!S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022) != 0) return closeWithStatus(dir, EPERM);

    const char *name = FG_MODE_PACKAGE_DIRECTORY;
    const bool created = mkdirat(dir, name, 0700) == 0;
    if (!created && errno != EEXIST) return closeWithStatus(dir, errno);
    const int entry = openat(dir, name, directoryFlags);
    int rc = 0;
    if (entry < 0) rc = errno;
    else {
        if (fstat(entry, &st) != 0) rc = errno;
        else if (created && (st.st_uid != 0 || !S_ISDIR(st.st_mode))) rc = EPERM;
        else if (!created && (!isPrivateDirectory(&st, owner) || st.st_gid != group)) rc = EPERM;
        else if (created && (fchmod(entry, 0700) != 0 || fchown(entry, owner, group) != 0)) rc = errno;
        rc = closeWithStatus(entry, rc);
    }
    if (created && rc) unlinkat(dir, name, AT_REMOVEDIR);
    return closeWithStatus(dir, rc);
}
#endif
