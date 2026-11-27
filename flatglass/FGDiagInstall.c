#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#else
#define _DEFAULT_SOURCE 1
#endif
#include "FGDiagnostics.h"
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#include "FGModeStore.h"
#include <roothide.h>
#include <stdio.h>
#include <string.h>
#endif

#include <errno.h>
#include <grp.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

/* Same mobile identity as the launchd job. Do not open or modify a user
 * directory while privileged; a rejected drop leaves installation alone. */
static bool run_as_mobile(void) {
    const uid_t uid = 501;
    const gid_t group = 501;
    if (geteuid() == 0 && (setgroups(1, &group) != 0 || setgid(group) != 0 || setuid(uid) != 0))
        return false;
    if (getuid() != uid || geteuid() != uid || getgid() != group || getegid() != group)
        return false;
    return true;
}

static int parse_status(const char *s) {
    char *end;
    errno = 0;
    const long n = strtol(s, &end, 10);
    return errno || end == s || *end != '\0' || n < FGD_UNOBSERVED || n > 255 ? FGD_OTHER : (int)n;
}

int main(int argc, char **argv) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    if (argc == 2 && strcmp(argv[1], "--prepare-mode-store") == 0) {
        const int result = FGModeStorePrepare(jbroot(FG_MODE_PARENT), 501, 501);
        if (result) fprintf(stderr, "FlatGlass: private mode directory unavailable (%d)\n", result);
        return result ? 1 : 0;
    }
#endif
    if (argc != 4) return FGD_WRITE_INVALID;
    const int phase = parse_status(argv[1]);
    const int bootstrap = parse_status(argv[2]);
    const int fallback = parse_status(argv[3]);
    if (phase == FGD_OTHER || bootstrap == FGD_OTHER || fallback == FGD_OTHER) return FGD_WRITE_INVALID;
    if (signal(SIGALRM, SIG_DFL) == SIG_ERR) return FGD_WRITE_INVALID;
    alarm(3); /* Never hold up dpkg indefinitely for a diagnostic write. */
    if (!run_as_mobile()) return FGD_WRITE_INVALID;
    umask(0077);
    int result = FGDWriteInstallMarker(FGD_REPORT_DIRECTORY, phase, bootstrap, fallback);
    if (result != FGD_WRITE_OK)
        result = FGDWriteInstallMarker(FGD_PREFERENCES_DIRECTORY, phase, bootstrap, fallback);
    return result;
}
