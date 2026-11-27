#!/bin/sh
# Runs only rewritten copies against inert commands. Optional arguments select
# a staged DEBIAN directory and the expected executable/plist prefix.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
scripts=${1:-"$root/layout/DEBIAN"}
prefix=${2:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FG_MOCK_BIN="$tmp/bin" FG_MOCK_LOG="$tmp/log"
unset FG_SYSTEM_RC FG_USER_RC FG_BOOTSTRAP_RC FG_LOAD_RC FG_DISABLE_RC
mkdir "$FG_MOCK_BIN"

cat > "$FG_MOCK_BIN/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FG_MOCK_LOG"
case "$1 $2" in
  'bootout system/local.lumid.flatglass') exit "${FG_SYSTEM_RC:-1}" ;;
  'bootout user/foreground/local.lumid.flatglass') exit "${FG_USER_RC:-1}" ;;
  'bootstrap system') exit "${FG_BOOTSTRAP_RC:-0}" ;;
  unload\ *) exit 1 ;;
  load\ *) exit "${FG_LOAD_RC:-0}" ;;
  *) exit 97 ;;
esac
EOF
cat > "$FG_MOCK_BIN/mock-flatglass" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FG_MOCK_LOG"
exit "${FG_DISABLE_RC:-0}"
EOF
chmod 0755 "$FG_MOCK_BIN/launchctl" "$FG_MOCK_BIN/mock-flatglass"

for script in postinst prerm; do
  sh -n "$scripts/$script"
  sed -e 's|^PATH=.*|PATH="$FG_MOCK_BIN"|' \
    -e 's|"\$prefix/usr/libexec/flatglass" --disable|mock-flatglass "${prefix}/usr/libexec/flatglass" --disable|' \
    "$scripts/$script" > "$tmp/$script"
  case $(cat "$tmp/$script") in
    *'PATH="$FG_MOCK_BIN"'*) ;;
    *) printf '%s\n' 'Could not isolate launchctl; refusing to run.' >&2; exit 1 ;;
  esac
done
case $(cat "$tmp/prerm") in
  *'if ! mock-flatglass "${prefix}/usr/libexec/flatglass" --disable;'*) ;;
  *) printf '%s\n' 'Could not isolate --disable; refusing to run.' >&2; exit 1 ;;
esac

check() {
  want_rc=$1 want_log=$2
  shift 2
  : > "$FG_MOCK_LOG"
  rc=0
  env "$@" || rc=$?
  [ "$rc" -eq "$want_rc" ] || { printf 'Unexpected exit status: %s (expected %s)\n' "$rc" "$want_rc" >&2; exit 1; }
  if [ -n "$want_log" ]; then
    printf '%s\n' "$want_log" | diff - "$FG_MOCK_LOG"
  else
    [ ! -s "$FG_MOCK_LOG" ]
  fi
}

job="$prefix/Library/LaunchDaemons/local.lumid.flatglass.plist"
stop='launchctl bootout system/local.lumid.flatglass
launchctl bootout user/foreground/local.lumid.flatglass'
oldstop="$stop
launchctl unload $job"
start="launchctl bootstrap system $job"
load="launchctl load $job"
disable="$prefix/usr/libexec/flatglass --disable"

check 0 "$stop
$start" FG_SYSTEM_RC=0 sh "$tmp/postinst" configure
check 0 "$stop
$start" FG_USER_RC=0 sh "$tmp/postinst" abort-remove
check 0 "$oldstop
$start
$load" FG_BOOTSTRAP_RC=1 sh "$tmp/postinst" configure
check 2 "$oldstop
$start
$load" FG_BOOTSTRAP_RC=1 FG_LOAD_RC=2 sh "$tmp/postinst" configure
check 0 '' sh "$tmp/postinst" unrelated
check 0 "$oldstop
$disable" FG_DISABLE_RC=1 sh "$tmp/prerm" remove 2> "$tmp/prerm.stderr"
[ -s "$tmp/prerm.stderr" ]
check 0 "$stop
$disable" FG_SYSTEM_RC=0 sh "$tmp/prerm" deconfigure
check 0 "$oldstop" sh "$tmp/prerm" upgrade
check 0 '' sh "$tmp/prerm"
printf '%s\n' 'FlatGlass package lifecycle mocks passed.'
