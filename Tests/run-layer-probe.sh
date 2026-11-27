#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo 'run-layer-probe requires macOS Foundation and CoreGraphics' >&2
    exit 2
fi
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/flatglass-layer.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -isysroot "$sdk" -fobjc-arc -fblocks -Wall \
    Tests/layer_probe.m -framework Foundation -framework CoreGraphics \
    -lcompression -o "$tmp/layer-probe"
"$tmp/layer-probe"
