#!/bin/sh
# Native host test. Do not link the tweak, its hook, FGCreate.m or CoreUI.
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo 'run-contour-cg.sh requires macOS and the macOS SDK (not run).' >&2
    exit 1
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src=$root/FlatGlassIconServices
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fg-contour-cg.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)
cc() { xcrun --sdk macosx clang -isysroot "$sdk" -std=gnu11 -O2 -Wall -Wextra -I"$src" "$@"; }
cc -c "$src/FGContourPaint.c" -o "$tmp/paint.o"
cc -fobjc-arc -fblocks -c "$src/FGIconGlare.m" -o "$tmp/shape.o"
cc -fobjc-arc -fblocks -c "$src/FGGlass.m" -o "$tmp/glass.o"
cc -fobjc-arc -fblocks "$root/Tests/contour_coregraphics.m" "$tmp/shape.o" "$tmp/paint.o" "$tmp/glass.o" \
    -framework CoreGraphics -framework Foundation -o "$tmp/contour-cg"
"$tmp/contour-cg"
