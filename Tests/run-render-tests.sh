#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/flatglass-render.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
"${CC:-clang}" -std=c11 -O2 -Wall -Wextra -Werror Tests/render_policy.c -o "$tmp/render-policy" -lm
"$tmp/render-policy"
