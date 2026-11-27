#ifndef FG_MODE_STORE_H
#define FG_MODE_STORE_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#define FG_MODE_PARENT "/var/lib"
#define FG_MODE_PACKAGE_DIRECTORY "local.lumid.flatglass"
#define FG_MODE_DIRECTORY FG_MODE_PARENT "/" FG_MODE_PACKAGE_DIRECTORY
#define FG_MODE_RECORD "mode.v1"

enum { FG_MODE_KEEP_STATE = -1 };

/* Mode 0 is a real user choice. An unreadable record is not Mode 0. */
static inline int FGStateForModeRead(int status, int mode, bool startup) {
    if (status == 0 && mode >= 0 && mode <= 3) return mode + 1;
    return startup ? 0 : FG_MODE_KEEP_STATE;
}

/* Return 0 on success, otherwise an errno value. Only populate mode on success.
 * The path must be the package's private directory, not a system preference path. */
int FGModeStoreRead(const char *directory, int *mode);
int FGModeStoreWrite(const char *directory, int mode);

#ifdef FG_MODE_STORE_PREPARE
/* Only the root package installer uses this. Never updates an existing node. */
int FGModeStorePrepare(const char *parent, uid_t owner, gid_t group);
#endif

#endif
