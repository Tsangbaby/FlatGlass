#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/flatglass-contour.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# Normal CI invocation: compile the shipping translation unit, no mocks or git.
inc=FlatGlassIconServices
src=$inc/FGContourPaint.c
if [ "$#" -ne 0 ]; then
    if [ "$#" -ne 1 ] || [ "$1" != --against-test1 ]; then
        echo "usage: $0 [--against-test1]" >&2
        exit 2
    fi
    # Optional local A/B with history available. This returns the test status
    # unchanged: expect exit 1 and failing pixel rows, NOT a compiler failure.
    echo 'Negative control: testing b3e9740; expect pixel failures.' >&2
    inc=$tmp
    src=$tmp/test1.c
    python3 - "$tmp" <<'PY'
from pathlib import Path
from subprocess import check_output
import re, sys

out = Path(sys.argv[1])
def legacy(name):
    return check_output(['git', 'show', 'b3e9740:FlatGlassIconServices/' + name], text=True)

# The old .m has CoreGraphics shape creation before its self-contained C tail.
old = legacy('FGIconGlare.m')
tail = old[old.index('void FGEdt('):]
h = legacy('FGInternal.h')
names = ('FGDrawOutline', 'FGDrawChicletHighlights')
protos = [re.search(r'\bvoid\s+' + fn + r'\s*\([^;{}]+\)\s*;', h).group() for fn in names]
(out / 'FGContourPaint.h').write_text('\n'.join(protos) + '\n')
(out / 'test1.c').write_text('#include "FGContourPaint.h"\n#include <math.h>\n'
                             '#include <stdint.h>\n#include <stdlib.h>\ntypedef _Bool BOOL;\n' +
                             '\n'.join(x for x in tail.splitlines() if not x.startswith('#pragma mark')) + '\n')
PY
fi
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -I"$inc" Tests/contour_pixels.c "$src" -lm -o "$tmp/contour-pixels"
"$tmp/contour-pixels"
