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
  if [[ "$fixture_name" == "10-disable-next" ]]; then
    chmod -x "$(dirname "$0")/20-disabled"
  fi
  if [[ "$fixture_name" == "10-swap-next" ]]; then
    ln -sfn "$VAULTLOCK_SWAP_TARGET" "$VAULTLOCK_SWAP_PATH"
  fi
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

check_not_contains() { # description needle haystack
  if [[ "$3" == *"$2"* ]]; then
    printf 'FAIL %s: unexpectedly found [%s] in [%s]\n' "$1" "$2" "$3"
    fail=1
  else
    printf 'ok   %s\n' "$1"
  fi
}

check_count() { # description expected needle haystack
  local description=$1 expected=$2 needle=$3 haystack=$4 actual
  actual=$(grep -Foc -- "$needle" <<< "$haystack" || true)
  check "$description" "$expected" "$actual"
}

options() {
  "$VL" __options "$@"
}

reject_options() { # description command arguments...
  local description=$1 status output
  shift
  if output=$("$VL" __options "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  check "$description exits with usage status" 64 "$status"
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
check "parse deadline" "$exp" \
  "$(TZ=Europe/Amsterdam "$VL" __parse '2026-08-26 03:00')"
check "parse deadline in UTC" 1787713200 \
  "$(TZ=UTC0 "$VL" __parse '2026-08-26 03:00')"
check "parse deadline in New York" 1787727600 \
  "$(TZ=America/New_York "$VL" __parse '2026-08-26 03:00')"

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
check "duration 10s" "$(( now + 10 ))" "$(deadline "$now" 10s)"
check "duration 90s" "$(( now + 90 ))" "$(deadline "$now" 90s)"
check "duration 1m30s" "$(( now + 90 ))" "$(deadline "$now" 1m30s)"
check "duration 1d4h30m10s" "$(( now + 28 * 3600 + 30 * 60 + 10 ))" \
  "$(deadline "$now" 1d4h30m10s)"
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
reject_deadline "reject zero second duration" "$now" 0s
reject_deadline "reject zero mixed second duration" "$now" 0d0h0m0s
reject_deadline "reject reordered second duration" "$now" 10s1m
reject_deadline "reject repeated second unit" "$now" 1s2s
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

check "default presentation options" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=0\ncolor=auto\noperands=20h' \
  "$(options lock 20h)"
check "short verbose option" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=1\ncolor=auto\noperands=20h' \
  "$(options lock -v 20h)"
check "long verbose option" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=1\ncolor=auto\noperands=' \
  "$(options unlock --verbose)"
check "highest verbosity wins" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=2\ncolor=auto\noperands=20h' \
  "$(options lock -vv --verbose 20h)"
check "long very verbose option" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=2\ncolor=auto\noperands=source' \
  "$(options adopt --very-verbose source)"
check "init accepts presentation options" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=2\ncolor=never\noperands=' \
  "$(options init --color=never -vv)"
check "last colour wins" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=2\ncolor=always\noperands=20h' \
  "$(options lock --very-verbose --color=never --color=always 20h)"
check "single-dash lock operand remains an operand" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=0\ncolor=auto\noperands=-1h' \
  "$(options lock -1h)"
check "single-dash adopt operand remains an operand" \
  $'dry_run=false\nyes=false\nhooks=true\nverbosity=0\ncolor=auto\noperands=-source' \
  "$(options adopt -source)"

reject_options "empty colour" lock --color= 20h
reject_options "unknown colour" lock --color=sometimes 20h
reject_options "separate colour value" lock --color always 20h
reject_options "option after operand" lock 20h -v
reject_options "very verbose option after operand" lock 20h -vv

esc=$'\033'
plain=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_STDOUT_TTY=false VAULTLOCK_TEST_STDERR_TTY=false \
  NO_COLOR='' TERM=xterm-256color "$VL" __colour auto 2>&1)
check "auto colour stays plain through pipes" \
  $'heading\nsuccess\nvaultlock: error' "$plain"

always=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_STDOUT_TTY=false VAULTLOCK_TEST_STDERR_TTY=false \
  NO_COLOR=1 TERM=dumb "$VL" __colour always 2>&1)
check_contains "always colour overrides environment" "${esc}[" "$always"

never=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_STDOUT_TTY=true VAULTLOCK_TEST_STDERR_TTY=true \
  TERM=xterm-256color "$VL" __colour never 2>&1)
check "never colour stays plain" \
  $'heading\nsuccess\nvaultlock: error' "$never"

stdout_only=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_STDOUT_TTY=true VAULTLOCK_TEST_STDERR_TTY=false \
  NO_COLOR='' TERM=xterm-256color "$VL" __colour auto 2>&1)
check_contains "stdout TTY colours heading" "${esc}[1mheading" "$stdout_only"
check_not_contains "plain stderr has no red prefix" \
  "${esc}[31mvaultlock:" "$stdout_only"

stderr_only=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_STDOUT_TTY=false VAULTLOCK_TEST_STDERR_TTY=true \
  NO_COLOR='' TERM=xterm-256color "$VL" __colour auto 2>&1)
check_not_contains "plain stdout has no cyan heading" \
  "${esc}[1mheading" "$stderr_only"
check_contains "stderr TTY colours error prefix" \
  "${esc}[31mvaultlock:" "$stderr_only"

for disabled_environment in term-dumb no-color; do
  if [[ "$disabled_environment" == term-dumb ]]; then
    disabled=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
      VAULTLOCK_TEST_STDOUT_TTY=true VAULTLOCK_TEST_STDERR_TTY=true \
      NO_COLOR='' TERM=dumb "$VL" __colour auto 2>&1)
  else
    disabled=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
      VAULTLOCK_TEST_STDOUT_TTY=true VAULTLOCK_TEST_STDERR_TTY=true \
      NO_COLOR=1 TERM=xterm-256color "$VL" __colour auto 2>&1)
  fi
  check "$disabled_environment disables auto colour" \
    $'heading\nsuccess\nvaultlock: error' "$disabled"
done

empty_no_color=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_STDOUT_TTY=true VAULTLOCK_TEST_STDERR_TTY=true \
  NO_COLOR='' TERM=xterm-256color "$VL" __colour auto 2>&1)
check_contains "empty NO_COLOR permits automatic colour" \
  "${esc}[1mheading" "$empty_no_color"

summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never mixed)
check_contains "summary names command" "Lock vault" "$summary"
check "summary separates heading from fields" '' "$(sed -n '2p' <<< "$summary")"
check_contains "summary names state" \
  "UNLOCKED" "$summary"
check_contains "summary names target" \
  "Target:    lock now" "$summary"
check_contains "summary includes effective deadline" \
  "Unlock at: 2026-" "$summary"
check_not_contains "default summary omits duplicate request" "Requested:" "$summary"
check_not_contains "default summary omits raw epochs" "epoch " "$summary"
check_not_contains "default summary hides raw rounds" "drand round" "$summary"
check_contains "default summary includes relative deadline" "(deadline passed)" "$summary"
summary_columns=$(printf '%s\n' "$summary" | awk '/^  (State|Target|Unlock at):/ { match($0, /: +/); print RSTART + RLENGTH }' | sort -u)
check "summary aligns field values" 14 "$summary_columns"
check_contains "summary lists known hook" \
  "pre-lock [global] /tmp/pre\\ lock" "$summary"
check_contains "summary lists deferred directory" \
  "post-unlock [vault, after mount]" "$summary"
check_not_contains "summary hides actions" "Actions:" "$summary"
check_not_contains "summary hides hook argv" "--phase" "$summary"
check_not_contains "summary hides coordination" \
  "Acquire cooperative operation lock" "$summary"

verbose_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 1 never mixed)
check_contains "verbose dry-run uses Would prefix" \
  "Would: Prepare Time Machine exclusions and snapshots" "$verbose_summary"
check_contains "verbose groups APFS locking" \
  "Would: Lock and verify the APFS volume" "$verbose_summary"
check_count "Time Machine progress prints once" 1 \
  "Prepare Time Machine exclusions and snapshots" "$verbose_summary"
check_contains "verbose summary exposes target round" "target 31805812" "$verbose_summary"
check_not_contains "verbose summary still hides actions" \
  "Actions:" "$verbose_summary"
check_not_contains "verbose summary still hides hook argv" \
  "--phase" "$verbose_summary"

for default_fixture in full_lock full_unlock init adopt unlock_repair \
    secure_noop repair_remove; do
  default_progress=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
    "$VL" __render_output 0 never "$default_fixture")
  case "$default_fixture" in
    full_lock)
      expected_progress=$'Would: Prepare Time Machine\nWould: Unmount vault\nWould: Rotate recovery material\nWould: Encrypt recovery material\nWould: Remove plaintext recovery material\nWould: Lock vault'
      ;;
    full_unlock)
      expected_progress=$'Would: Decrypt recovery material\nWould: Unlock vault\nWould: Ensure vault is mounted\nWould: Verify mounted vault\nWould: Restore recovery material\nWould: Verify unlocked vault'
      ;;
    init)
      expected_progress=$'Would: Prepare vault state\nWould: Create encrypted vault\nWould: Record vault state'
      ;;
    adopt)
      expected_progress=$'Would: Copy source into vault\nWould: Verify copied source\nWould: Replace source with symlink'
      ;;
    unlock_repair)
      expected_progress=$'Would: Prepare vault\nWould: Ensure vault is mounted\nWould: Verify mounted vault\nWould: Restore recovery material\nWould: Verify unlocked vault'
      ;;
    secure_noop) expected_progress='Would: Verify locked vault' ;;
    repair_remove)
      expected_progress='Would: Remove plaintext recovery material'
      ;;
  esac
  check "$default_fixture default progress has ordered unique short labels" \
    "$expected_progress" "$(grep '^Would:' <<< "$default_progress" || true)"
  check_not_contains "$default_fixture default dry-run hides actions" \
    'Actions:' "$default_progress"
  check_not_contains "$default_fixture default dry-run emits no execution arrow" \
    '->' "$default_progress"
done

default_hook_progress=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never hooks)
check_count "default dry-run includes each individual hook" 2 \
  'Would: Run pre-lock [global]' "$default_hook_progress"
check_not_contains "default dry-run hooks hide arguments" \
  '--phase' "$default_hook_progress"

help_status=0
help_output=$("$VL" help 2>&1) || help_status=$?
check "help preserves usage exit status" 64 "$help_status"
check_contains "help describes default short progress" \
  'default                   short progress and the final result' "$help_output"
check_contains "help describes detailed progress" \
  '-v, --verbose             detailed progress and state information' "$help_output"
check_contains "help describes audit presentation" \
  '-vv, --very-verbose        detailed progress, numbered plan, and exact hook arguments' \
  "$help_output"
check_contains "help gives a duration example" \
  'vaultlock lock 20h' "$help_output"
check_contains "help gives a calendar deadline example" \
  'vaultlock lock "09:00 +2d"' "$help_output"

progress_inventory=$'init\toperation_lock_acquire\t<silent>\ninit\toperation_lock_quarantine\t<silent>\ninit\toperation_lock_release\t<silent>\nadopt\toperation_lock_acquire\t<silent>\nadopt\toperation_lock_quarantine\t<silent>\nadopt\toperation_lock_release\t<silent>\nlock\toperation_lock_acquire\t<silent>\nlock\toperation_lock_quarantine\t<silent>\nlock\toperation_lock_release\t<silent>\nunlock\toperation_lock_acquire\t<silent>\nunlock\toperation_lock_quarantine\t<silent>\nunlock\toperation_lock_release\t<silent>\nlock\trepair_verify_plaintext\trepair\tRepair the prerequisite usable vault state\tPrepare vault\nunlock\trepair_verify_plaintext\trepair\tRepair the prerequisite usable vault state\tPrepare vault\nlock\trepair_unlock_apfs\trepair\tRepair the prerequisite usable vault state\tPrepare vault\nunlock\trepair_unlock_apfs\trepair\tRepair the prerequisite usable vault state\tPrepare vault\nlock\trepair_mount\tmount\tEnsure the expected APFS volume is mounted\tEnsure vault is mounted\nunlock\trepair_mount\tmount\tEnsure the expected APFS volume is mounted\tEnsure vault is mounted\nlock\tverify_mount_identity\tmount-identity\tVerify the mounted vault identity\tVerify mounted vault\nunlock\tverify_mount_identity\tmount-identity\tVerify the mounted vault identity\tVerify mounted vault\nlock\thooks_disabled\t<silent>\nunlock\thooks_disabled\t<silent>\nlock\thook\t<silent>\nunlock\thook\t<silent>\nlock\tdeferred_hook_discovery\t<silent>\nunlock\tdeferred_hook_discovery\t<silent>\nlock\ttm_exclude_state\ttime-machine\tPrepare Time Machine exclusions and snapshots\tPrepare Time Machine\nlock\ttm_exclude\ttime-machine\tPrepare Time Machine exclusions and snapshots\tPrepare Time Machine\nlock\ttm_delete_vault_snapshots\ttime-machine\tPrepare Time Machine exclusions and snapshots\tPrepare Time Machine\nlock\ttm_delete_data_snapshots\ttime-machine\tPrepare Time Machine exclusions and snapshots\tPrepare Time Machine\nlock\tunmount_vault\tunmount\tUnmount the vault for locking\tUnmount vault\nlock\tstage_recovery\trecovery-rotation\tRotate recovery material\tRotate recovery material\nlock\trotate_apfs_recovery\trecovery-rotation\tRotate recovery material\tRotate recovery material\nlock\tkeychain_update\trecovery-rotation\tRotate recovery material\tRotate recovery material\nunlock\tkeychain_update\trecovery-restore\tRestore verified recovery material\tRestore recovery material\nlock\ttle_encrypt\ttime-lock\tEncrypt and record time-locked recovery material\tEncrypt recovery material\nlock\ttle_verify_future\ttime-lock\tEncrypt and record time-locked recovery material\tEncrypt recovery material\nlock\tpersist_locked_recovery\ttime-lock\tEncrypt and record time-locked recovery material\tEncrypt recovery material\nlock\tremove_plaintext\trecovery-removal\tEnsure plaintext and keychain recovery material are absent\tRemove plaintext recovery material\nlock\tapfs_lock\tapfs-lock\tLock and verify the APFS volume\tLock vault\nlock\tverify_locked_postconditions\tapfs-lock\tLock and verify the APFS volume\tLock vault\nunlock\ttle_decrypt\ttime-unlock\tDecrypt and verify time-locked recovery material\tDecrypt recovery material\nunlock\tverify_decrypted_hash\ttime-unlock\tDecrypt and verify time-locked recovery material\tDecrypt recovery material\nunlock\tapfs_unlock\tapfs-unlock\tUnlock the expected APFS volume\tUnlock vault\nunlock\tpersist_plaintext\trecovery-restore\tRestore verified recovery material\tRestore recovery material\nunlock\tpersist_unlocked_state\trecovery-restore\tRestore verified recovery material\tRestore recovery material\nlock\tverify_secure_target\tsecure-target\tVerify the secure locked target\tVerify locked vault\nunlock\tverify_unlocked_target\tusable-target\tVerify the usable unlocked target\tVerify unlocked vault\ninit\tinit_prepare_state\tinit-state\tPrepare protected vault state\tPrepare vault state\ninit\tinit_create_volume\tinit-volume\tCreate the encrypted APFS volume\tCreate encrypted vault\ninit\tinit_write_state\tinit-record\tRecord the usable vault state\tRecord vault state\nadopt\tadopt_copy\tadopt-copy\tCopy the source into the vault\tCopy source into vault\nadopt\tadopt_verify\tadopt-verify\tVerify the copied source\tVerify copied source\nadopt\tadopt_replace_source\tadopt-replace\tReplace the source with its vault symlink\tReplace source with symlink'
known_operations=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 "$VL" __known_operations)
known_operation_count=$(printf '%s\n' "$known_operations" \
  | /usr/bin/awk 'NF { count++ } END { print count }')
check "production registry contains all operation IDs" 37 \
  "$known_operation_count"
inventory_ids=$(/usr/bin/awk -F '\t' '!seen[$2]++ { print $2 }' \
  <<< "$progress_inventory")
check "progress inventory derives exactly from production registry" \
  "$known_operations" "$inventory_ids"
while IFS=$'\t' read -r command operation_id expected_group expected_label expected_short_label; do
  progress_mapping_status=0
  if progress_mapping=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
      "$VL" __progress_group "$command" "$operation_id" 2>&1); then
    progress_mapping_status=0
  else
    progress_mapping_status=$?
  fi
  check "progress inventory accepts $command:$operation_id" \
    0 "$progress_mapping_status"
  if [[ "$expected_group" == '<silent>' ]]; then
    check "progress inventory intentionally silences $command:$operation_id" \
      '' "$progress_mapping"
  else
    check "progress inventory maps $command:$operation_id" \
      "$expected_group"$'\t'"$expected_label"$'\t'"$expected_short_label" \
      "$progress_mapping"
  fi
done <<< "$progress_inventory"

unknown_progress_status=0
if VAULTLOCK_TEST_FAKE_SYSTEM=1 \
    "$VL" __progress_group lock unknown_operation >/dev/null 2>&1; then
  unknown_progress_status=0
else
  unknown_progress_status=$?
fi
check "unknown progress operation fails closed" 1 "$unknown_progress_status"

for rejected_progress_pair in nonsense:repair_mount \
    init:tm_exclude_state unlock:tm_exclude_state lock:tle_decrypt; do
  rejected_progress_command=${rejected_progress_pair%%:*}
  rejected_progress_operation=${rejected_progress_pair#*:}
  if rejected_progress_output=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
      "$VL" __progress_group "$rejected_progress_command" \
      "$rejected_progress_operation" 2>&1); then
    rejected_progress_status=0
  else
    rejected_progress_status=$?
  fi
  check "progress mapping rejects $rejected_progress_pair" \
    1 "$rejected_progress_status"
  check_contains "progress mapping names rejected $rejected_progress_pair" \
    "$rejected_progress_pair" "$rejected_progress_output"
done

for progress_fixture in full_lock full_unlock init adopt unlock_repair \
    secure_noop hooks repair_remove; do
  progress_output=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
    "$VL" __render_output 1 never "$progress_fixture" 2>&1 || true)
  check_contains "$progress_fixture renders grouped dry-run progress" \
    "Would:" "$progress_output"
  check_not_contains "$progress_fixture verbose output hides actions" \
    "Actions:" "$progress_output"
done

repair_remove_output=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 1 never repair_remove 2>&1 || true)
check_contains "repair-only removal uses truthful group" \
  "Would: Ensure plaintext and keychain recovery material are absent" \
  "$repair_remove_output"
check_not_contains "repair-only removal avoids time-lock group" \
  "Encrypt and record time-locked recovery material" "$repair_remove_output"

hooks_progress=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 1 never hooks 2>&1 || true)
check_count "multiple hook operations are not generic-deduped" 2 \
  "Would: Run pre-lock [global]" "$hooks_progress"

audit_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 2 never mixed)
check_contains "audit summary includes numbered actions" \
  "Actions:" "$audit_summary"
check_contains "audit summary includes coordination" \
  "Acquire cooperative operation lock" "$audit_summary"
check_contains "audit summary includes exact hook argv" \
  "/tmp/pre\\ lock --phase pre-lock --scope global" "$audit_summary"
check_contains "audit summary includes confirmation detail" \
  "Confirmation:" "$audit_summary"
check_count_text=$(grep -Foc -- 'State:' <<< "$audit_summary" || true)
check "audit summary prints state once" 1 "$check_count_text"

coloured_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 always mixed)
check_contains "summary makes command heading bold" \
  "${esc}[1mLock vault${esc}[0m" "$coloured_summary"
check_contains "summary colours usable state word green" \
  "${esc}[32mUNLOCKED${esc}[0m" "$coloured_summary"
check_contains "summary dims effective deadline label" \
  "${esc}[2mUnlock at:${esc}[0m 2026-" "$coloured_summary"

coloured_progress=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 1 always mixed)
check_contains "progress colours only Would prefix cyan" \
  "${esc}[36mWould:${esc}[0m Prepare Time Machine" "$coloured_progress"
check_not_contains "progress keeps label plain" \
  "${esc}[36mWould: Prepare Time Machine" "$coloured_progress"

default_coloured_progress=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 always full_lock)
check_contains "default progress colours only the Would prefix" \
  "${esc}[36mWould:${esc}[0m Encrypt recovery material" "$default_coloured_progress"
check_not_contains "default progress keeps the short label plain" \
  "${esc}[36mWould: Encrypt recovery material" "$default_coloured_progress"

inconsistent_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never inconsistent)
check_contains "inconsistent summary reports causal error" \
  "INCONSISTENT: recorded locked state disagrees with APFS state" \
  "$inconsistent_summary"

missing_plaintext_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never inconsistent_missing_plaintext)
check_contains "inconsistent unlocked summary names missing plaintext" \
  "INCONSISTENT: plaintext recovery material is missing" \
  "$missing_plaintext_summary"

unmounted_missing_plaintext_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never inconsistent_unmounted_missing_plaintext)
check_contains \
  "inconsistent unmounted unlocked summary names missing plaintext" \
  "INCONSISTENT: plaintext recovery material is missing" \
  "$unmounted_missing_plaintext_summary"

missing_ciphertext_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never inconsistent_missing_ciphertext)
check_contains "inconsistent locked summary names missing ciphertext" \
  "INCONSISTENT: time-lock ciphertext is missing" \
  "$missing_ciphertext_summary"

missing_hash_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never inconsistent_missing_hash)
check_contains "inconsistent locked summary names missing hash" \
  "INCONSISTENT: recovery hash is missing" \
  "$missing_hash_summary"

retained_plaintext_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never inconsistent_retained_plaintext)
check_contains "inconsistent locked summary names retained plaintext" \
  "INCONSISTENT: plaintext recovery material is retained while recorded locked" \
  "$retained_plaintext_summary"

coloured_inconsistency=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 always inconsistent_missing_plaintext)
check_contains "inconsistent summary colours state word red" \
  "${esc}[31mINCONSISTENT${esc}[0m: plaintext recovery material is missing" \
  "$coloured_inconsistency"
check_not_contains "inconsistent summary keeps causal value plain" \
  "${esc}[31minconsistent" "$coloured_inconsistency"

for hook_argv_verbosity in 0 1 2; do
  if hook_argv_builds=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
      "$VL" __hook_argv_builds "$hook_argv_verbosity" 2>&1); then
    if [[ "$hook_argv_verbosity" == 2 ]]; then
      expected_hook_argv_builds=1
    else
      expected_hook_argv_builds=0
    fi
    check "verbosity $hook_argv_verbosity builds hook argv only for audit rendering" \
      "$expected_hook_argv_builds" "$hook_argv_builds"
  else
    printf 'FAIL verbosity %s hook argv build probe: got [%s]\n' \
      "$hook_argv_verbosity" "$hook_argv_builds"
    fail=1
  fi
done

disabled_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never disabled)
check_contains "disabled summary names disabled hooks" \
  "Hooks: disabled" "$disabled_summary"

empty_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never none)
check_contains "empty summary names absent hooks" "Hooks: none" "$empty_summary"

for preserved_fixture in preserved_lock preserved_repair; do
  preserved_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
    "$VL" __render_output 0 never "$preserved_fixture" 2>&1 || true)
  check_contains "$preserved_fixture shows distinct request" \
    'Requested: 2026-' "$preserved_summary"
  check_contains "$preserved_fixture shows effective preserved deadline" \
    'Preserved: 2099-' "$preserved_summary"
  check_count "$preserved_fixture prints effective deadline once" 1 \
    '2099-' "$preserved_summary"
  check_not_contains "$preserved_fixture hides technical request epoch" \
    '1788220800' "$preserved_summary"
  check_not_contains "$preserved_fixture hides technical preserved round" \
    '792731235' "$preserved_summary"
  preserved_verbose=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
    "$VL" __render_output 1 never "$preserved_fixture" 2>&1 || true)
  check_contains "$preserved_fixture verbose includes requested epoch" \
    'Requested epoch: 1788220800' "$preserved_verbose"
  check_contains "$preserved_fixture verbose includes preserved epoch" \
    'Preserved epoch: 4070999040' "$preserved_verbose"
done

equal_deadline_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never preserved_equal_numeric)
check_not_contains "equivalent numeric deadlines omit duplicate request" \
  'Requested:' "$equal_deadline_summary"
equal_timestamp=$(/bin/date -r 1800000000 '+%Y-%m-%d %H:%M:%S %z')
check_count "equivalent numeric deadlines print effective date once" 1 \
  "$equal_timestamp" "$equal_deadline_summary"
equal_deadline_verbose=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 1 never preserved_equal_numeric)
check_contains "numeric equality retains raw requested epoch in verbose output" \
  'Requested epoch: 1800000000' "$equal_deadline_verbose"
check_contains "numeric equality retains raw preserved epoch in verbose output" \
  'Preserved epoch: 1.8E+9' "$equal_deadline_verbose"
invalid_deadline_summary=$(VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  "$VL" __render_output 0 never preserved_invalid_numeric 2>&1)
check_contains "failed normalisation keeps requested deadline visible" \
  "Requested: $equal_timestamp" "$invalid_deadline_summary"
check_contains "failed normalisation keeps preserved deadline visible" \
  'Preserved: epoch 1.8E+999 (local timestamp unavailable)' "$invalid_deadline_summary"

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
check_not_contains "default hook execution avoids a duplicate progress note" \
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

race_state="$hook_test_root/race state"
race_mount="$hook_test_root/race mount"
mkdir -p "$race_state" "$race_mount"
install_hook "$race_state/hooks/post-lock.d/10-disable-next"
install_hook "$race_state/hooks/post-lock.d/20-disabled"
: > "$hook_log"
run_hooks "$race_state" "$race_mount" post-lock UUID-123 disk9s1 \
  2026-08-31T02:00:00+0200 1788134400 314159 true >/dev/null
check "hook disabled after discovery is skipped" \
  "10-disable-next" "$(cut -d'|' -f1 "$hook_log")"

swap_state="$hook_test_root/swap state"
swap_mount="$hook_test_root/swap mount"
mkdir -p "$swap_state/hooks/post-lock.d" "$swap_mount"
install_hook "$swap_state/hooks/post-lock.d/10-swap-next"
install_hook "$swap_state/replacement-target"
ln -s "$TEST_SELF" "$swap_state/hooks/post-lock.d/20-swapped"
: > "$hook_log"
export VAULTLOCK_SWAP_TARGET="$swap_state/replacement-target"
export VAULTLOCK_SWAP_PATH="$swap_state/hooks/post-lock.d/20-swapped"
if swap_output=$(run_hooks "$swap_state" "$swap_mount" post-lock \
    UUID-123 disk9s1 2026-08-31T02:00:00+0200 1788134400 314159 true 2>&1); then
  printf 'FAIL hook target swap after planning is rejected: command succeeded\n'
  fail=1
else
  printf 'ok   hook target swap after planning is rejected\n'
fi
unset VAULTLOCK_SWAP_TARGET VAULTLOCK_SWAP_PATH
check "hook target swap executes no replacement" \
  "10-swap-next" "$(cut -d'|' -f1 "$hook_log")"
check_contains "hook target swap reports plan drift" \
  "planned hook changed before execution" "$swap_output"

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
elif [[ "$output" == "vaultlock: usage: vaultlock unlock [--dry-run] [--no-hooks] [-v|--verbose|-vv|--very-verbose] [--color=auto|always|never]" ]]; then
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

if output=$("$VL" __plan_operation hook 2>&1); then
  printf 'FAIL generic plan append rejects hook ID: command succeeded\n'
  fail=1
elif [[ "$output" == "vaultlock: hook operations require plan_add_hook" ]]; then
  printf 'ok   generic plan append rejects hook ID\n'
else
  printf 'FAIL generic plan append rejects hook ID: got [%s]\n' "$output"
  fail=1
fi

deferred_path=$'/Volumes/vault/hooks\nFORGED PLAN LINE'
quoted_deferred_path=$(printf '%q' "$deferred_path")
if deferred_output=$("$VL" __plan_deferred post-unlock vault "$deferred_path" 2>&1); then
  check_contains "deferred metadata records operation ID" \
    'id=deferred_hook_discovery' "$deferred_output"
  check_contains "deferred metadata records phase" \
    'phase=post-unlock' "$deferred_output"
  check_contains "deferred metadata records scope" \
    'scope=vault' "$deferred_output"
  check_contains "deferred metadata quotes directory" \
    "directory=$quoted_deferred_path" "$deferred_output"
  check_contains "deferred rendering quotes directory" \
    "Defer post-unlock vault hook discovery in $quoted_deferred_path until" \
    "$deferred_output"
  check "deferred control character cannot forge a line" 0 \
    "$(grep -Fxc 'FORGED PLAN LINE' <<< "$deferred_output" || true)"
else
  printf 'FAIL typed deferred metadata helper: got [%s]\n' "$deferred_output"
  fail=1
fi

# Progress bar formatting helpers used by adopt.
progress_format() { # kind value
  VAULTLOCK_TEST_FAKE_SYSTEM=1 "$VL" __progress_format "$@" 2>&1
}
check "progress bytes zero" '0 B' "$(progress_format bytes 0)"
check "progress bytes under a kilobyte" '999 B' "$(progress_format bytes 999)"
check "progress bytes rounds to one decimal" '1.2 MB' \
  "$(progress_format bytes 1234567)"
check "progress bytes rounds half up" '1.3 MB' \
  "$(progress_format bytes 1250000)"
check "progress bytes gigabytes" '86.2 GB' \
  "$(progress_format bytes 86200000000)"
check "progress bytes terabytes" '1.5 TB' \
  "$(progress_format bytes 1500000000000)"
check "progress bytes carries into the next unit" '1.0 GB' \
  "$(progress_format bytes 999950000)"
check "progress duration seconds" '0:59' "$(progress_format duration 59)"
check "progress duration minutes" '4:36' "$(progress_format duration 276)"
check "progress duration hours" '1:02:05' \
  "$(progress_format duration 3725)"
progress_format_status=0
progress_format bytes abc >/dev/null || progress_format_status=$?
check "progress format rejects non-numeric input" 64 \
  "$progress_format_status"

progress_bar() { # done_bytes total_bytes done_count total_count elapsed width label pass current
  VAULTLOCK_TEST_FAKE_SYSTEM=1 "$VL" __progress_bar "$@" 2>&1
}
check "progress bar renders every field" \
  'Verify copied source [########------------]  43%  86.2 GB / 200.1 GB  412.4 MB/s  ETA 4:36  12345/67890  pass 2/6 destination  games/Elden Ring/data.pak' \
  "$(progress_bar 86200000000 200100000000 12345 67890 209 200 \
    'Verify copied source' 'pass 2/6 destination' \
    'games/Elden Ring/data.pak')"
check "progress bar without elapsed time shows no rate" \
  'Copy source into vault [--------------------]   0%  0 B / 200.1 GB  -- B/s  ETA --:--  0/67890  games/a' \
  "$(progress_bar 0 200100000000 0 67890 0 200 'Copy source into vault' '' \
    'games/a')"
check "progress bar counts entries when bytes are unknown" \
  'Restore timestamps [##########----------]  50%  5/10  ETA 0:03' \
  "$(progress_bar 0 0 5 10 3 200 'Restore timestamps' '' '')"
check "progress bar clamps overshoot" \
  'Copy source into vault [####################] 100%  201.0 GB / 200.1 GB  2.0 GB/s  ETA 0:00  67891/67890' \
  "$(progress_bar 201000000000 200100000000 67891 67890 100 200 \
    'Copy source into vault' '' '')"
narrow_bar=$(progress_bar 86200000000 200100000000 12345 67890 209 140 \
  'Verify copied source' 'pass 2/6 destination' \
  'games/Elden Ring/some/very/long/path/to/data.pak')
check "progress bar fits a narrow terminal" 139 "${#narrow_bar}"
check "progress bar keeps the tail of a long path" '.../data.pak' \
  "${narrow_bar##*  }"
check "progress bar drops the path when nothing fits" \
  'Verify copied source [########------------]  43%  86.2 GB / 200.1 GB  412.4 MB/s  ETA 4:36  12345/67890  pass 2/6 destination' \
  "$(progress_bar 86200000000 200100000000 12345 67890 209 130 \
    'Verify copied source' 'pass 2/6 destination' 'games/data.pak')"
check "progress bar sheds counts and rate before its label" \
  'Verify copied source [########------------]  43%  86.2 GB / 200.1 GB  ETA 4:36' \
  "$(progress_bar 86200000000 200100000000 12345 67890 209 80 \
    'Verify copied source' 'pass 2/6 destination' 'games/data.pak')"

# Progress mode resolution mirrors colour: auto needs a stdout terminal.
progress_mode() { # mode
  /bin/bash "$VL" __progress_mode "$@" 2>&1
}
check "auto progress renders on a stdout terminal" 'true 100' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=true \
    COLUMNS=100 TERM=xterm-256color progress_mode auto)"
check "auto progress stays silent through pipes" 'false 100' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=false \
    COLUMNS=100 TERM=xterm-256color progress_mode auto)"
check "auto progress stays silent on a dumb terminal" 'false 100' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=true \
    COLUMNS=100 TERM=dumb progress_mode auto)"
check "always progress ignores the pipe" 'true 100' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=false \
    COLUMNS=100 TERM=dumb progress_mode always)"
check "never progress ignores the terminal" 'false 100' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=true \
    COLUMNS=100 TERM=xterm-256color progress_mode never)"
check "progress width falls back to 80 columns" 'true 80' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=false \
    COLUMNS='' PATH=/nonexistent TERM=xterm-256color progress_mode always)"
check "progress width ignores a non-numeric COLUMNS" 'true 80' \
  "$(VAULTLOCK_TEST_FAKE_SYSTEM=1 VAULTLOCK_TEST_STDOUT_TTY=false \
    COLUMNS=wide PATH=/nonexistent TERM=xterm-256color progress_mode always)"
progress_mode_status=0
VAULTLOCK_TEST_FAKE_SYSTEM=1 progress_mode sometimes >/dev/null \
  || progress_mode_status=$?
check "progress mode rejects unknown values" 64 "$progress_mode_status"

exit "$fail"
