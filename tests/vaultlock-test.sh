#!/usr/bin/env bash
# Unit tests for vaultlock's pure helpers. Run: ~/bin/vaultlock-test.sh
set -euo pipefail

VL=${1:-$HOME/bin/vaultlock}
fail=0

if [[ "${VAULTLOCK_DISKUTIL_FIXTURE:-0}" == "1" && "${0##*/}" == "diskutil" ]]; then
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    "<key>VolumeUUID</key><string>$VAULTLOCK_TEST_MOUNT_UUID</string>" \
    "<key>DeviceIdentifier</key><string>$VAULTLOCK_TEST_MOUNT_DEVICE</string>" \
    '</dict></plist>'
  exit 0
fi

if [[ "${VAULTLOCK_HOOK_FIXTURE:-0}" == "1" ]]; then
    if [[ ${VAULTLOCK_EXPECT_GLOBIGNORE+x} ]]; then
        [[ ${GLOBIGNORE-} == "$VAULTLOCK_EXPECT_GLOBIGNORE" ]] || exit 8
        export -p GLOBIGNORE >/dev/null 2>&1 || exit 8
    fi
    fixture_name=$(basename "$0")
  printf '%s|cwd=%s|argc=%s' "$fixture_name" "$PWD" "$#" >> "$VAULTLOCK_TEST_LOG"
  for fixture_arg in "$@"; do
    printf '|<%s>' "$fixture_arg" >> "$VAULTLOCK_TEST_LOG"
  done
  printf '\n' >> "$VAULTLOCK_TEST_LOG"
  [[ "$fixture_name" != *fail* ]] || exit 7
  exit 0
fi

TEST_SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

check() { # desc want got
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

epoch() {
  TZ=Europe/Amsterdam /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s
}

deadline() {
  TZ=Europe/Amsterdam "$VL" __deadline "$@"
}

reject_deadline() { # desc now expression...
  local desc=$1 now=$2
  shift 2
  if deadline "$now" "$@" >/dev/null 2>&1; then
    printf 'FAIL %s: unexpectedly accepted [%s]\n' "$desc" "$*"
    fail=1
  else
    printf 'ok   %s\n' "$desc"
  fi
}

check_contains() { # desc needle haystack
  if [[ "$3" == *"$2"* ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: missing [%s] in [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

install_hook() {
  local hook_path=$1
  mkdir -p "$(dirname "$hook_path")"
  cp "$TEST_SELF" "$hook_path"
  chmod +x "$hook_path"
}

run_hooks() { # state mount phase uuid device deadline epoch round locked
  local hook_state=$1 hook_mount=$2
  shift 2
  PATH="$diskutil_fixture_dir:$PATH" \
  VAULTLOCK_STATE_DIR="$hook_state" \
  VAULTLOCK_MOUNT_POINT="$hook_mount" \
  VAULTLOCK_TEST_LOG="$hook_log" \
  VAULTLOCK_HOOK_FIXTURE=1 \
  VAULTLOCK_DISKUTIL_FIXTURE=1 \
  VAULTLOCK_TEST_MOUNT_UUID=$2 \
  VAULTLOCK_TEST_MOUNT_DEVICE=$3 \
    "$VL" __hooks "$@"
}

run_hooks_with_identity() { # actual_uuid actual_device state mount phase context...
  local actual_uuid=$1 actual_device=$2 hook_state=$3 hook_mount=$4
  shift 4
  PATH="$diskutil_fixture_dir:$PATH" \
  VAULTLOCK_STATE_DIR="$hook_state" \
  VAULTLOCK_MOUNT_POINT="$hook_mount" \
  VAULTLOCK_TEST_LOG="$hook_log" \
  VAULTLOCK_HOOK_FIXTURE=1 \
  VAULTLOCK_DISKUTIL_FIXTURE=1 \
  VAULTLOCK_TEST_MOUNT_UUID="$actual_uuid" \
  VAULTLOCK_TEST_MOUNT_DEVICE="$actual_device" \
    "$VL" __hooks "$@"
}

run_hooks_with_shell_option() { # option state mount phase context...
  local option=$1 hook_state=$2 hook_mount=$3
  shift 3
  local -a shell_args
  if [[ "$option" == "noglob" ]]; then
    shell_args=(-f)
  else
    shell_args=(-O "$option")
  fi
  PATH="$diskutil_fixture_dir:$PATH" \
  VAULTLOCK_STATE_DIR="$hook_state" \
  VAULTLOCK_MOUNT_POINT="$hook_mount" \
  VAULTLOCK_TEST_LOG="$hook_log" \
  VAULTLOCK_HOOK_FIXTURE=1 \
  VAULTLOCK_DISKUTIL_FIXTURE=1 \
  VAULTLOCK_TEST_MOUNT_UUID=$2 \
  VAULTLOCK_TEST_MOUNT_DEVICE=$3 \
    /bin/bash "${shell_args[@]}" "$VL" __hooks "$@"
}

# Beacon for round r is emitted at genesis + (r-1)*period (genesis 1692803367, period 3).
check "round at genesis"    1 "$("$VL" __round 1692803367)"
check "round genesis+1"     2 "$("$VL" __round 1692803368)"
check "round genesis+3"     2 "$("$VL" __round 1692803370)"
check "round genesis+4"     3 "$("$VL" __round 1692803371)"

exp=$(epoch '2026-08-26 03:00:00')
check "parse deadline" "$exp" "$("$VL" __parse '2026-08-26 03:00')"

if "$VL" __parse 'not-a-date' >/dev/null 2>&1; then
  printf 'FAIL parse rejects garbage\n'; fail=1
else
  printf 'ok   parse rejects garbage\n'
fi

now=$(epoch '2026-08-29 10:15:30')
check "duration 20h" "$(( now + 20 * 3600 ))" "$(deadline "$now" 20h)"
check "duration 1d4h" "$(( now + 28 * 3600 ))" "$(deadline "$now" 1d4h)"
check "duration 1h30m" "$(( now + 90 * 60 ))" "$(deadline "$now" 1h30m)"
check "duration 90m" "$(( now + 90 * 60 ))" "$(deadline "$now" 90m)"
now=$(epoch '2026-03-28 12:00:00')
check "duration day is 86400 seconds across DST" "$(( now + 86400 ))" "$(deadline "$now" 1d)"

now=$(epoch '2026-08-29 00:30:00')
check "clock later today" "$(epoch '2026-08-29 01:00:00')" "$(deadline "$now" 1:00)"
check "clock accepts padded hour" "$(epoch '2026-08-29 01:00:00')" "$(deadline "$now" 01:00)"
now=$(epoch '2026-08-29 01:30:00')
check "clock tomorrow after passing" "$(epoch '2026-08-30 01:00:00')" "$(deadline "$now" 1:00)"
now=$(epoch '2026-08-29 01:00:00')
check "clock tomorrow at exact deadline" "$(epoch '2026-08-30 01:00:00')" "$(deadline "$now" 1:00)"

now=$(epoch '2026-08-29 10:15:30')
check "clock plus calendar days" "$(epoch '2026-08-31 02:00:00')" "$(deadline "$now" 2:00 +2d)"
check "quoted clock plus calendar days" "$(epoch '2026-08-31 02:00:00')" \
  "$(deadline "$now" '2:00 +2d')"
check "absolute seconds are zero" "$(epoch '2026-09-03 02:00:00')" \
  "$(deadline "$now" '2026-09-03 02:00')"

now=$(epoch '2026-03-29 00:30:00')
check "clock skips spring gap" "$(epoch '2026-03-30 02:00:00')" "$(deadline "$now" 2:00)"
now=$(epoch '2026-03-28 12:00:00')
reject_deadline "combined rejects spring gap" "$now" 2:00 +1d
reject_deadline "absolute rejects spring gap" "$now" '2026-03-29 02:00'

fall_first=$(epoch '2026-10-25 02:00:00')
fall_second=$(( fall_first + 3600 ))
check "clock chooses first fall occurrence" "$fall_first" \
  "$(deadline "$(( fall_first - 60 ))" 2:00)"
check "clock chooses second fall occurrence" "$fall_second" \
  "$(deadline "$(( fall_first + 1800 ))" 2:00)"
now=$(epoch '2026-10-24 12:00:00')
check "combined chooses first fall occurrence" "$fall_first" "$(deadline "$now" 2:00 +1d)"
check "absolute chooses first fall occurrence" "$fall_first" \
  "$(deadline "$now" '2026-10-25 02:00')"

now=$(epoch '2026-08-29 10:15:30')
reject_deadline "reject clock hour" "$now" 24:00
reject_deadline "reject clock minute" "$now" 1:60
reject_deadline "reject zero duration" "$now" 0h
reject_deadline "reject zero mixed duration" "$now" 0d0h0m
reject_deadline "reject negative duration" "$now" -1h
reject_deadline "reject decimal duration" "$now" 1.5h
reject_deadline "reject reordered duration" "$now" 4h1d
reject_deadline "reject repeated duration unit" "$now" 1h2h
reject_deadline "reject unsupported duration unit" "$now" 1w
reject_deadline "reject non-day combined offset" "$now" 2:00 +4h
reject_deadline "reject zero combined offset" "$now" 2:00 +0d
reject_deadline "reject trailing text" "$now" 1h garbage
reject_deadline "reject oversized duration" "$now" 1000000000d
reject_deadline "reject past absolute deadline" "$now" '2026-08-28 10:15'

hook_test_root=$(mktemp -d "/tmp/vaultlock hooks.XXXXXX")
trap 'rm -rf "$hook_test_root"' EXIT
hook_state="$hook_test_root/global state"
hook_mount="$hook_test_root/mounted vault"
hook_log="$hook_test_root/hook log"
diskutil_fixture_dir="$hook_test_root/fixture bin"
mkdir -p "$hook_state" "$hook_mount" "$diskutil_fixture_dir"
ln -s "$TEST_SELF" "$diskutil_fixture_dir/diskutil"

install_hook "$hook_state/pre-lock.sh"
install_hook "$hook_state/hooks/pre-lock.d/10-global first"
install_hook "$hook_state/hooks/pre-lock.d/20-global-second"
ln -s "$TEST_SELF" "$hook_state/hooks/pre-lock.d/30-global-link"
cp "$TEST_SELF" "$hook_state/hooks/pre-lock.d/40-not-executable"
chmod -x "$hook_state/hooks/pre-lock.d/40-not-executable"
install_hook "$hook_state/hooks/pre-lock.d/.hidden"
install_hook "$hook_mount/.vaultlock/hooks/pre-lock.d/10-local"

hook_output=$(run_hooks "$hook_state" "$hook_mount" pre-lock UUID-123 disk9s1 \
  2026-08-31T02:00:00+0200 1788134400 314159 false)
hook_order=$(cut -d'|' -f1 "$hook_log" | paste -sd, -)
check "pre-lock scope and filename order" \
  "pre-lock.sh,10-global first,20-global-second,30-global-link,10-local" "$hook_order"
first_hook=$(sed -n '1p' "$hook_log")
expected_first="pre-lock.sh|cwd=$PWD|argc=24|<--phase>|<pre-lock>|<--scope>|<global>|<--volume>|<vault>|<--mount-point>|<$hook_mount>|<--volume-uuid>|<UUID-123>|<--device>|<disk9s1>|<--state-dir>|<$hook_state>|<--state-file>|<$hook_state/state.json>|<--deadline>|<2026-08-31T02:00:00+0200>|<--deadline-epoch>|<1788134400>|<--round>|<314159>|<--locked>|<false>"
check "hook receives exact named argv" "$expected_first" "$first_hook"
last_hook=$(tail -n 1 "$hook_log")
check_contains "vault hook receives vault scope" \
  '|<--scope>|<vault>|' "$last_hook"
check_contains "runner announces hook path" \
  "running pre-lock global hook: $hook_state/pre-lock.sh" "$hook_output"

: > "$hook_log"
run_hooks_with_shell_option dotglob "$hook_state" "$hook_mount" pre-lock \
  UUID-123 disk9s1 2026-08-31T02:00:00+0200 1788134400 314159 false >/dev/null
hook_order=$(cut -d'|' -f1 "$hook_log" | paste -sd, -)
check "dotglob cannot enable hidden hooks" \
  "pre-lock.sh,10-global first,20-global-second,30-global-link,10-local" "$hook_order"

: > "$hook_log"
run_hooks_with_shell_option noglob "$hook_state" "$hook_mount" pre-lock \
  UUID-123 disk9s1 2026-08-31T02:00:00+0200 1788134400 314159 false >/dev/null
hook_order=$(cut -d'|' -f1 "$hook_log" | paste -sd, -)
check "noglob cannot disable hook discovery" \
    "pre-lock.sh,10-global first,20-global-second,30-global-link,10-local" "$hook_order"

: > "$hook_log"
if globignore_output=$( \
    PATH="$diskutil_fixture_dir:$PATH" \
    GLOBIGNORE=20-global-second \
    VAULTLOCK_EXPECT_GLOBIGNORE=20-global-second \
    VAULTLOCK_STATE_DIR="$hook_state" \
    VAULTLOCK_MOUNT_POINT="$hook_mount" \
    VAULTLOCK_TEST_LOG="$hook_log" \
    VAULTLOCK_HOOK_FIXTURE=1 \
    VAULTLOCK_DISKUTIL_FIXTURE=1 \
    VAULTLOCK_TEST_MOUNT_UUID=UUID-123 \
    VAULTLOCK_TEST_MOUNT_DEVICE=disk9s1 \
    /bin/bash "$VL" __hooks pre-lock UUID-123 disk9s1 \
        2026-08-31T02:00:00+0200 1788134400 314159 false 2>&1
); then
    hook_order=$(cut -d'|' -f1 "$hook_log" | paste -sd, -)
    check "exported GLOBIGNORE is restored before hooks" \
        "pre-lock.sh,10-global first,20-global-second,30-global-link,10-local" \
        "$hook_order"
else
    printf 'FAIL exported GLOBIGNORE is restored before hooks: got [%s]\n' \
        "$globignore_output"
    fail=1
fi

post_state="$hook_test_root/post state"
post_mount="$hook_test_root/post mount"
mkdir -p "$post_state" "$post_mount"
install_hook "$post_mount/.vaultlock/hooks/post-unlock.d/10-local"
install_hook "$post_state/hooks/post-unlock.d/10-global"
: > "$hook_log"
run_hooks "$post_state" "$post_mount" post-unlock UUID-123 disk9s1 \
  2026-08-31T02:00:00+0200 1788134400 314159 false >/dev/null
hook_order=$(cut -d'|' -f1 "$hook_log" | paste -sd, -)
check "post-unlock local wraps global" "10-local,10-global" "$hook_order"

install_hook "$post_state/hooks/post-lock.d/10-global"
install_hook "$post_mount/.vaultlock/hooks/post-lock.d/10-local-never"
: > "$hook_log"
run_hooks "$post_state" "$post_mount" post-lock UUID-123 disk9s1 \
  2026-08-31T02:00:00+0200 1788134400 314159 true >/dev/null
check "post-lock is global only" "10-global" "$(cut -d'|' -f1 "$hook_log")"
check_contains "post-lock receives locked state" '|<--locked>|<true>' "$(cat "$hook_log")"

install_hook "$post_state/hooks/pre-unlock.d/10-global"
install_hook "$post_mount/.vaultlock/hooks/pre-unlock.d/10-local-never"
: > "$hook_log"
run_hooks "$post_state" "$post_mount" pre-unlock UUID-123 disk9s1 \
  2026-08-31T02:00:00+0200 1788134400 314159 true >/dev/null
check "pre-unlock is global only" "10-global" "$(cut -d'|' -f1 "$hook_log")"

empty_state="$hook_test_root/empty state"
empty_mount="$hook_test_root/empty mount"
mkdir -p "$empty_state" "$empty_mount"
: > "$hook_log"
run_hooks "$empty_state" "$empty_mount" post-lock UUID-123 disk9s1 \
  2026-08-31T02:00:00+0200 1788134400 314159 true >/dev/null
check "missing hook directories are a no-op" "" "$(cat "$hook_log")"
: > "$hook_log"
if failglob_output=$(run_hooks_with_shell_option failglob "$empty_state" \
    "$empty_mount" post-lock UUID-123 disk9s1 \
    2026-08-31T02:00:00+0200 1788134400 314159 true 2>&1); then
  printf 'ok   failglob cannot break empty hook directories\n'
else
  printf 'FAIL failglob cannot break empty hook directories: got [%s]\n' "$failglob_output"
  fail=1
fi

identity_state="$hook_test_root/identity state"
identity_mount="$hook_test_root/identity mount"
mkdir -p "$identity_state" "$identity_mount"
install_hook "$identity_state/hooks/pre-lock.d/10-global-never"
install_hook "$identity_mount/.vaultlock/hooks/pre-lock.d/10-local-never"
install_hook "$identity_mount/.vaultlock/hooks/post-unlock.d/10-local-never"
: > "$hook_log"
if identity_output=$(run_hooks_with_identity IMPOSTOR-UUID disk8s1 \
    "$identity_state" "$identity_mount" pre-lock UUID-123 disk9s1 \
    2026-08-31T02:00:00+0200 1788134400 314159 false 2>&1); then
  printf 'FAIL pre-lock rejects mount identity mismatch: command succeeded\n'
  fail=1
else
  printf 'ok   pre-lock rejects mount identity mismatch\n'
fi
check "pre-lock mismatch runs no hooks" "" "$(cat "$hook_log")"
check_contains "pre-lock mismatch reports identities" \
  "mount identity mismatch at $identity_mount" "$identity_output"

: > "$hook_log"
if identity_output=$(run_hooks_with_identity IMPOSTOR-UUID disk8s1 \
    "$identity_state" "$identity_mount" post-unlock UUID-123 disk9s1 \
    2026-08-31T02:00:00+0200 1788134400 314159 false 2>&1); then
  printf 'FAIL post-unlock rejects mount identity mismatch: command succeeded\n'
  fail=1
else
  printf 'ok   post-unlock rejects mount identity mismatch\n'
fi
check "post-unlock mismatch runs no hooks" "" "$(cat "$hook_log")"

pre_fail_state="$hook_test_root/pre fail state"
pre_fail_mount="$hook_test_root/pre fail mount"
mkdir -p "$pre_fail_state" "$pre_fail_mount"
install_hook "$pre_fail_state/hooks/pre-lock.d/10-fail"
install_hook "$pre_fail_state/hooks/pre-lock.d/20-later"
install_hook "$pre_fail_mount/.vaultlock/hooks/pre-lock.d/10-local-never"
: > "$hook_log"
if pre_fail_output=$(run_hooks "$pre_fail_state" "$pre_fail_mount" pre-lock \
    UUID-123 disk9s1 2026-08-31T02:00:00+0200 1788134400 314159 false 2>&1); then
  printf 'FAIL pre-hook failure returns nonzero\n'
  fail=1
else
  printf 'ok   pre-hook failure returns nonzero\n'
fi
check "pre-hook failure stops later hooks" "10-fail" "$(cut -d'|' -f1 "$hook_log")"
check_contains "pre-hook failure identifies hook" \
  "pre-lock global hook failed with exit 7: $pre_fail_state/hooks/pre-lock.d/10-fail" \
  "$pre_fail_output"

post_fail_state="$hook_test_root/post fail state"
post_fail_mount="$hook_test_root/post fail mount"
mkdir -p "$post_fail_state" "$post_fail_mount"
install_hook "$post_fail_mount/.vaultlock/hooks/post-unlock.d/10-fail"
install_hook "$post_fail_mount/.vaultlock/hooks/post-unlock.d/20-later"
install_hook "$post_fail_state/hooks/post-unlock.d/10-global-fail"
install_hook "$post_fail_state/hooks/post-unlock.d/20-global-later"
: > "$hook_log"
if post_fail_output=$(run_hooks "$post_fail_state" "$post_fail_mount" post-unlock \
    UUID-123 disk9s1 2026-08-31T02:00:00+0200 1788134400 314159 false 2>&1); then
  printf 'FAIL post-hook failure returns nonzero\n'
  fail=1
else
  printf 'ok   post-hook failure returns nonzero\n'
fi
hook_order=$(cut -d'|' -f1 "$hook_log" | paste -sd, -)
check "post-hook failure runs all hooks" \
  "10-fail,20-later,10-global-fail,20-global-later" "$hook_order"
check_contains "post-hook failure identifies vault hook" \
  "post-unlock vault hook failed with exit 7" "$post_fail_output"
check_contains "post-hook failure identifies global hook" \
  "post-unlock global hook failed with exit 7" "$post_fail_output"

state_probe_dir=$(mktemp -d /tmp/vaultlock-test-state.XXXXXX)
if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" lock not-a-deadline 2>&1); then
  printf 'FAIL lock rejects deadline before state: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: cannot resolve 'not-a-deadline'"* ]]; then
  printf 'ok   lock rejects deadline before state\n'
else
  printf 'FAIL lock rejects deadline before state: got [%s]\n' "$output"
  fail=1
fi

if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" lock --no-hooks not-a-deadline 2>&1); then
  printf 'FAIL lock accepts --no-hooks before deadline: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: cannot resolve 'not-a-deadline'"* ]]; then
  printf 'ok   lock accepts --no-hooks before deadline\n'
else
  printf 'FAIL lock accepts --no-hooks before deadline: got [%s]\n' "$output"
  fail=1
fi

if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" lock --bogus 1h 2>&1); then
  printf 'FAIL lock rejects unknown option: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: unknown lock option: --bogus" ]]; then
  printf 'ok   lock rejects unknown option\n'
else
  printf 'FAIL lock rejects unknown option: got [%s]\n' "$output"
  fail=1
fi

if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" lock --no-hooks --bogus 2>&1); then
  printf 'FAIL lock rejects option after --no-hooks: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: unknown lock option: --bogus" ]]; then
  printf 'ok   lock rejects option after --no-hooks\n'
else
  printf 'FAIL lock rejects option after --no-hooks: got [%s]\n' "$output"
  fail=1
fi

if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" unlock --no-hooks 2>&1); then
  printf 'FAIL unlock accepts --no-hooks: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: no state" ]]; then
  printf 'ok   unlock accepts --no-hooks\n'
else
  printf 'FAIL unlock accepts --no-hooks: got [%s]\n' "$output"
  fail=1
fi

if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" unlock extra 2>&1); then
  printf 'FAIL unlock rejects extra argument: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: usage: vaultlock unlock [--no-hooks]" ]]; then
  printf 'ok   unlock rejects extra argument\n'
else
  printf 'FAIL unlock rejects extra argument: got [%s]\n' "$output"
  fail=1
fi


if output=$(VAULTLOCK_STATE_DIR="$state_probe_dir" "$VL" unlock --no-hooks --bogus 2>&1); then
  printf 'FAIL unlock rejects option after --no-hooks: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: unknown unlock option: --bogus" ]]; then
  printf 'ok   unlock rejects option after --no-hooks\n'
else
  printf 'FAIL unlock rejects option after --no-hooks: got [%s]\n' "$output"
  fail=1
fi
rmdir "$state_probe_dir"

if output=$("$VL" __plan_operation definitely-unknown 2>&1); then
  printf 'FAIL plan rejects unknown operation ID: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: unknown plan operation ID: definitely-unknown" ]]; then
  printf 'ok   plan rejects unknown operation ID\n'
else
  printf 'FAIL plan rejects unknown operation ID: got [%s]\n' "$output"
  fail=1
fi

exit "$fail"
