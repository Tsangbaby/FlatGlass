#!/bin/sh
# Portable tests of the shared Prefs/daemon mode logic; never contact notifyd.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fg-daemon-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$root/Shared" -x c - -o "$tmp/modes" <<'EOF'
#include "FGPreferences.h"
#include <assert.h>
#include <limits.h>
#include <math.h>
#include <stddef.h>

int main(void) {
    const FGMode modes[] = {FGModeRemove, FGModeEdge, FGModeArtwork, FGModeOff};
    const int values[] = {0, 3, 1, 2};
    const uint64_t states[] = {1, 4, 2, 3};
    for (size_t i = 0; i < sizeof(modes) / sizeof(*modes); ++i) {
        FGMode mode = FGModeRemove;
        assert(FGDecodeMode(values[i], &mode));
        assert(mode == modes[i]);
        assert(FGStateForMode(mode) == states[i]);
    }

    const double invalid[] = {-1, 4, INT_MIN, INT_MAX, (double)INT64_MAX,
                              4294967297.0, 1.5, -0.5, NAN, INFINITY, -INFINITY};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(*invalid); ++i) {
        FGMode mode = FGModeRemove;
        assert(!FGDecodeMode(invalid[i], &mode));
        assert(FGStateForMode(mode) == 1);
    }
    return 0;
}
EOF
"$tmp/modes"
printf '%s\n' 'FlatGlass mode tests passed.'
