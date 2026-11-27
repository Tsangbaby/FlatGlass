#include "FGModeStore.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 3) return 64;
    const char *cmd = argv[1], *path = argv[2];
    int mode = -42, status;
    if (!strcmp(cmd, "read")) {
        status = FGModeStoreRead(path, &mode);
        printf("%d %d %d %d\n", status, mode, FGStateForModeRead(status, mode, true),
               FGStateForModeRead(status, mode, false));
    } else if (!strcmp(cmd, "write") && argc == 4 && strlen(argv[3]) == 1) {
        printf("%d\n", FGModeStoreWrite(path, argv[3][0] - '0'));
    } else if (!strcmp(cmd, "prepare")) {
        printf("%d\n", FGModeStorePrepare(path, 501, 501));
    } else if (!strcmp(cmd, "writer")) {
        for (int i = 0; i < 120; ++i) if (FGModeStoreWrite(path, i % 4) != 0) return 1;
    } else if (!strcmp(cmd, "reader")) {
        for (int i = 0; i < 4096; ++i) {
            if (FGModeStoreRead(path, &mode) != 0 || mode < 0 || mode > 3) return 1;
        }
    } else return 64;
    return 0;
}
