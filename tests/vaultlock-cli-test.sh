#!/bin/bash
# Isolated CLI tests for vaultlock. All system-facing commands are fixtures.
set -euo pipefail

fixture_command=${0##*/}

if [[ "${VAULTLOCK_TEST_FAKE_SYSTEM:-0}" == "1" \
    && "$fixture_command" != "vaultlock-cli-test.sh" ]]; then
  : "${VAULTLOCK_TEST_ACTION_LOG:?missing action log}"
  : "${VAULTLOCK_TEST_APFS_STATE:?missing APFS state directory}"
  : "${VAULTLOCK_TEST_FAKE_BIN:?missing fake binary directory}"
  : "${VAULTLOCK_MOUNT_POINT:?missing mount point}"

  printf '%q' "$fixture_command" >> "$VAULTLOCK_TEST_ACTION_LOG"
  for fixture_argument in "$@"; do
    printf ' %q' "$fixture_argument" >> "$VAULTLOCK_TEST_ACTION_LOG"
  done
  printf '\n' >> "$VAULTLOCK_TEST_ACTION_LOG"

  fixture_read() { # name
    local fixture_name=$1
    [[ -f "$VAULTLOCK_TEST_APFS_STATE/$fixture_name" ]] || return 1
    printf '%s' "$(< "$VAULTLOCK_TEST_APFS_STATE/$fixture_name")"
  }

  fixture_write() { # name value
    local fixture_name=$1 fixture_value=$2
    printf '%s\n' "$fixture_value" \
      > "$VAULTLOCK_TEST_APFS_STATE/$fixture_name"
  }

  fake_diskutil_info() {
    local plist=false locked mounted uuid device fixture_mount_point
    local plist_mode=normal have_locked=false have_mount_point=false
    local mount_point_type=string
    if [[ "${1:-}" == "-plist" ]]; then
      plist=true
      shift
    fi
    [[ $# -eq 1 ]] || exit 64
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/locked" ]]; then
      have_locked=true
      locked=$(fixture_read locked)
    fi
    mounted=$(fixture_read mounted) || mounted=false
    uuid=$(fixture_read uuid) || exit 1
    device=$(fixture_read device) || exit 1
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/mount_point" ]]; then
      have_mount_point=true
      fixture_mount_point=$(fixture_read mount_point)
    fi
    plist_mode=$(fixture_read plist_mode) || plist_mode=normal
    mount_point_type=$(fixture_read mount_point_type) || mount_point_type=string

    if [[ "$plist" == "true" ]]; then
      if [[ "$plist_mode" == "fail" ]]; then
        printf 'fixture diskutil failure\n' >&2
        exit 1
      fi
      if [[ "$plist_mode" == "malformed" ]]; then
        printf '<not-a-plist>\n'
        exit 0
      fi
      printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>'
      if [[ "$have_locked" == "true" ]]; then
        printf '<key>Locked</key>\n'
        case "$locked" in
          true) printf '<true/>\n' ;;
          false) printf '<false/>\n' ;;
          string:true) printf '<string>true</string>\n' ;;
          string:false) printf '<string>false</string>\n' ;;
          *) printf '<string>%s</string>\n' "$locked" ;;
        esac
      fi
      if [[ "$have_mount_point" == "true" ]]; then
        printf '<key>MountPoint</key>\n'
        if [[ "$mount_point_type" == "string" ]]; then
          printf '<string>%s</string>\n' "$fixture_mount_point"
        else
          printf '<integer>7</integer>\n'
        fi
      fi
      if [[ "$uuid" != "missing" ]]; then
        printf '%s\n' \
          '<key>VolumeUUID</key>' \
          "<string>$uuid</string>"
      fi
      if [[ "$device" != "missing" ]]; then
        printf '%s\n' \
          '<key>DeviceIdentifier</key>' \
          "<string>$device</string>"
      fi
      printf '%s\n' '</dict></plist>'
      exit 0
    fi

    printf '   Volume Name:              vault\n'
    printf '   FileVault:                Yes (Unlocked)\n'
    if [[ "$mounted" == "true" ]]; then
      printf '   Mounted:                  Yes\n'
    else
      printf '   Mounted:                  No\n'
    fi
    exit 0
  }

  case "$fixture_command" in
    diskutil)
      case "${1:-}" in
        info)
          shift
          fake_diskutil_info "$@"
          ;;
        mount)
          [[ $# -eq 2 ]] || exit 64
          [[ "$(fixture_read locked)" == "false" ]] || exit 1
          fixture_write mounted true
          fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
          ;;
        unmount)
          [[ $# -eq 2 ]] || exit 64
          fixture_write mounted false
          fixture_write mount_point ""
          ;;
        apfs)
          case "${2:-}" in
            addVolume)
              fixture_write locked false
              fixture_write mounted true
              fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
              ;;
            changePassphrase)
              ;;
            lockVolume)
              fixture_write locked true
              fixture_write mounted false
              fixture_write mount_point ""
              printf 'Volume locked\n'
              ;;
            unlockVolume)
              fixture_write locked false
              fixture_write mounted true
              fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
              ;;
            *) exit 64 ;;
          esac
          ;;
        *) exit 64 ;;
      esac
      ;;
    sudo)
      [[ $# -gt 0 ]] || exit 64
      nested_command=${1##*/}
      shift
      case "$nested_command" in
        diskutil|security|tle|tmutil|curl|mount)
          "$VAULTLOCK_TEST_FAKE_BIN/$nested_command" "$@"
          ;;
        *) exit 64 ;;
      esac
      ;;
    mount-fixture)
      if [[ "$(fixture_read mounted)" == "true" ]]; then
        printf '/dev/%s on %s (apfs, local, journaled)\n' \
          "$(fixture_read device)" "$(fixture_read mount_point)"
      fi
      ;;
    bash-version-fixture)
      printf '%s\n' "$BASH_VERSION"
      ;;
    mount|security|tle|tmutil|curl)
      ;;
    *)
      # Hook fixtures use the same dispatcher and only record their argv.
      ;;
  esac
  exit 0
fi

VL=${1:-$(cd "$(dirname "$0")/.." && pwd)/bin/vaultlock}
fail=0
test_root=$(mktemp -d "/tmp/vaultlock cli.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
action_log="$test_root/actions"
apfs_state="$test_root/apfs"
test_home="$test_root/home"
state_dir="$test_home/.vaultlock"
mount_point="$test_root/Volumes/vault.test"
confirm_device="$test_root/confirm"
mkdir -p "$fake_bin" "$apfs_state" "$state_dir" "$mount_point"
: > "$action_log"
: > "$confirm_device"

TEST_SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
for fake_command in diskutil security sudo tle tmutil curl mount \
  mount-fixture bash-version-fixture; do
  ln -s "$TEST_SELF" "$fake_bin/$fake_command"
done

for read_only_utility in cat jq plutil grep tr; do
  utility_path=$(command -v "$read_only_utility") \
    || { printf 'missing test utility: %s\n' "$read_only_utility" >&2; exit 1; }
  case "$utility_path" in
    /*) ;;
    *)
      printf 'test utility path is not absolute: %s -> %s\n' \
        "$read_only_utility" "$utility_path" >&2
      exit 1
      ;;
  esac
  ln -s "$utility_path" "$fake_bin/$read_only_utility"
done

# shellcheck disable=SC2329  # Used by later CLI scenarios.
check() { # description expected actual
  local description=$1 expected=$2 actual=$3
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' \
      "$description" "$expected" "$actual"
    fail=1
  fi
}

check_contains() { # description needle haystack
  local description=$1 needle=$2 haystack=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: missing [%s] in [%s]\n' \
      "$description" "$needle" "$haystack"
    fail=1
  fi
}

# shellcheck disable=SC2329  # Used by later CLI scenarios.
check_empty() { # description file
  local description=$1 file=$2
  if [[ ! -s "$file" ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: expected empty file, got [%s]\n' \
      "$description" "$(< "$file")"
    fail=1
  fi
}

check_line() { # description expected output
  local description=$1 expected=$2 output=$3
  if grep -Fqx -- "$expected" <<< "$output"; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: missing line [%s] in [%s]\n' \
      "$description" "$expected" "$output"
    fail=1
  fi
}

record_failure() { # description
  printf 'FAIL %s\n' "$1"
  fail=1
}

run_vaultlock() {
  HOME="$test_home" \
  PATH="$fake_bin" \
  VAULTLOCK_STATE_DIR="$state_dir" \
  VAULTLOCK_MOUNT_POINT="$mount_point" \
  VAULTLOCK_MOUNT_COMMAND="$fake_bin/mount-fixture" \
  VAULTLOCK_CONFIRM_DEVICE="$confirm_device" \
  VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_FAKE_BIN="$fake_bin" \
  VAULTLOCK_TEST_ACTION_LOG="$action_log" \
  VAULTLOCK_TEST_APFS_STATE="$apfs_state" \
    /bin/bash "$VL" "$@"
}

run_detached() {
  /usr/bin/perl -MPOSIX=setsid -e '
    defined(my $pid = fork) or die "fork failed: $!\n";
    if ($pid) {
      waitpid($pid, 0);
      exit($? >> 8);
    }
    setsid() >= 0 or die "setsid failed: $!\n";
    exec @ARGV or die "exec failed: $!\n";
  ' "$@"
}

reject_options() { # description command argv
  local description=$1 command=$2 status
  shift 2
  if run_vaultlock __options "$command" "$@" \
      >"$test_root/options-output" 2>"$test_root/options-error"; then
    record_failure "$description: unexpectedly accepted"
    return
  else
    status=$?
  fi
  check "$description exits with usage status" 64 "$status"
  check_contains "$description reports a parser error" "vaultlock:" \
    "$(< "$test_root/options-error")"
}

write_json_state() { # locked deadline deadline_epoch round uuid
  local locked=$1 deadline=$2 deadline_epoch=$3 round=$4 uuid=$5
  jq -n \
    --argjson locked "$locked" \
    --arg deadline "$deadline" \
    --argjson deadline_epoch "$deadline_epoch" \
    --argjson round "$round" \
    --arg uuid "$uuid" \
    '{locked: $locked, volume_uuid: $uuid, created: "fixture",
      deadline: (if $deadline == "null" then null else $deadline end),
      deadline_epoch: $deadline_epoch, round: $round}' \
    > "$state_dir/state.json"
}

write_apfs_state() { # locked mounted uuid device
  local locked=$1 mounted=$2 uuid=$3 device=$4 fixture_mount_point=""
  if [[ "$mounted" == "true" ]]; then
    fixture_mount_point=$mount_point
  fi
  printf '%s\n' "$locked" > "$apfs_state/locked"
  printf '%s\n' "$mounted" > "$apfs_state/mounted"
  printf '%s\n' "$uuid" > "$apfs_state/uuid"
  printf '%s\n' "$device" > "$apfs_state/device"
  printf '%s\n' "$fixture_mount_point" > "$apfs_state/mount_point"
  printf '%s\n' normal > "$apfs_state/plist_mode"
  printf '%s\n' string > "$apfs_state/mount_point_type"
}

write_recovery_state() { # plaintext ciphertext hash
  local plaintext=$1 ciphertext=$2 hash=$3
  rm -f "$state_dir/passphrase.txt" "$state_dir/passphrase.tle" \
    "$state_dir/passphrase.sha256"
  if [[ "$plaintext" == "true" ]]; then : > "$state_dir/passphrase.txt"; fi
  if [[ "$ciphertext" == "true" ]]; then : > "$state_dir/passphrase.tle"; fi
  if [[ "$hash" == "true" ]]; then : > "$state_dir/passphrase.sha256"; fi
}

assert_status_snapshot() { # description recorded apfs mount recovery assessment
  local description=$1 recorded=$2 apfs=$3 mount=$4 recovery=$5 assessment=$6
  local output status diskutil_calls
  : > "$action_log"
  if output=$(run_vaultlock status 2>&1); then
    status=0
  else
    status=$?
  fi
  check "$description exits successfully" 0 "$status"
  check_line "$description recorded line" "Recorded: $recorded" "$output"
  check_line "$description APFS line" "APFS: $apfs" "$output"
  check_line "$description mount line" "Mount: $mount" "$output"
  check_line "$description recovery line" "Recovery: $recovery" "$output"
  check_line "$description assessment line" "Assessment: $assessment" "$output"
  diskutil_calls=$(grep -c '^diskutil info -plist UUID-123$' \
    "$action_log" || true)
  check "$description reads APFS plist exactly once" 1 "$diskutil_calls"
  check "$description performs no other system operation" \
    'diskutil info -plist UUID-123' "$(< "$action_log")"
}

assert_invalid_snapshot() { # description
  local description=$1 output status
  : > "$action_log"
  if output=$(run_vaultlock status 2>&1); then
    status=0
  else
    status=$?
  fi
  check "$description exits successfully" 0 "$status"
  check_line "$description recorded line" \
    'Recorded: unknown (state file fields are missing or malformed)' "$output"
  check_line "$description APFS line" \
    'APFS: unknown (not inspected: invalid state snapshot)' "$output"
  check_line "$description mount line" \
    "Mount: expected $mount_point, actual unknown" "$output"
  check_line "$description recovery line" \
    'Recovery: plaintext present, ciphertext absent, hash absent' "$output"
  check_line "$description assessment line" \
    'Assessment: inconsistent' "$output"
  check_empty "$description performs no system operation" "$action_log"
}

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_recovery_state true false false

check_contains "harness uses Bash 3.2" "3.2." "$BASH_VERSION"

fake_dispatch_version=$(
  VAULTLOCK_MOUNT_POINT="$mount_point" \
  VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_FAKE_BIN="$fake_bin" \
  VAULTLOCK_TEST_ACTION_LOG="$action_log" \
  VAULTLOCK_TEST_APFS_STATE="$apfs_state" \
    "$fake_bin/bash-version-fixture"
)
check_contains "fake dispatcher uses Bash 3.2" "3.2." \
  "$fake_dispatch_version"

assert_status_snapshot "usable unlocked vault" \
  unlocked \
  'unlocked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  usable

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
rm -f "$apfs_state/mount_point"
write_recovery_state false true true
assert_status_snapshot "securely locked vault" \
  'locked until 2099-01-02T03:04:00+0100' \
  'locked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual not mounted" \
  'plaintext absent, ciphertext present, hash present' \
  'securely locked'
locked_output=$(run_vaultlock status)
check_contains "locked status preserves remaining output" \
  'remaining: ' "$locked_output"
check_contains "locked status preserves target round" \
  'drand round: target 792731235, current ' "$locked_output"
check_line "locked status preserves unlock instruction" \
  'when the deadline passes: vaultlock unlock (needs internet)' "$locked_output"

write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
write_recovery_state true false true
assert_status_snapshot "recorded unlock repair" \
  unlocked \
  'locked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual not mounted" \
  'plaintext present, ciphertext absent, hash present' \
  'repairable: run vaultlock unlock'

write_json_state false null null null UUID-123
write_apfs_state false false UUID-123 disk9s1
write_recovery_state true false false
assert_status_snapshot "unmounted unlock repair" \
  unlocked \
  'unlocked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual not mounted" \
  'plaintext present, ciphertext absent, hash absent' \
  'repairable: run diskutil mount disk9s1'

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state false true UUID-123 disk9s1
write_recovery_state false true true
assert_status_snapshot "recorded locked but APFS unlocked" \
  'locked until 2099-01-02T03:04:00+0100' \
  'unlocked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext absent, ciphertext present, hash present' \
  inconsistent

write_apfs_state true true UUID-123 disk9s1
assert_status_snapshot "APFS locked but mounted" \
  'locked until 2099-01-02T03:04:00+0100' \
  'locked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext absent, ciphertext present, hash present' \
  inconsistent

write_json_state false null null null UUID-123
write_apfs_state false true UUID-OTHER disk9s1
write_recovery_state true false false
assert_status_snapshot "UUID mismatch" \
  unlocked \
  'unknown (volume UUID mismatch: expected UUID-123, actual UUID-OTHER)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_recovery_state false true true
assert_status_snapshot "unlocked missing plaintext" \
  unlocked \
  'unlocked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext absent, ciphertext present, hash present' \
  inconsistent

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_recovery_state false false true
assert_status_snapshot "locked missing ciphertext" \
  'locked until 2099-01-02T03:04:00+0100' \
  'locked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual not mounted" \
  'plaintext absent, ciphertext absent, hash present' \
  inconsistent

write_recovery_state false true false
assert_status_snapshot "locked missing hash" \
  'locked until 2099-01-02T03:04:00+0100' \
  'locked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual not mounted" \
  'plaintext absent, ciphertext present, hash absent' \
  inconsistent

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
printf '%s\n' "$test_root/Volumes/wrong-vault" > "$apfs_state/mount_point"
write_recovery_state true false false
assert_status_snapshot "wrong mount path" \
  unlocked \
  'unlocked (UUID UUID-123, device disk9s1)' \
  "expected $mount_point, actual $test_root/Volumes/wrong-vault" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
printf '%s\n' surprise > "$apfs_state/locked"
write_recovery_state true false false
assert_status_snapshot "malformed APFS Locked" \
  unlocked \
  'unknown (APFS Locked is missing or malformed)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 disk9s1
printf '%s\n' string:false > "$apfs_state/locked"
assert_status_snapshot "wrong-typed false APFS Locked" \
  unlocked \
  'unknown (APFS Locked is missing or malformed)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 disk9s1
printf '%s\n' integer > "$apfs_state/mount_point_type"
assert_status_snapshot "wrong-typed APFS MountPoint" \
  unlocked \
  'unknown (APFS MountPoint is malformed)' \
  "expected $mount_point, actual unknown" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 disk9s1
rm -f "$apfs_state/locked"
assert_status_snapshot "missing APFS Locked" \
  unlocked \
  'unknown (APFS Locked is missing or malformed)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 disk9s1
printf '%s\n' fail > "$apfs_state/plist_mode"
assert_status_snapshot "diskutil inspection failure" \
  unlocked \
  'unknown (diskutil info failed)' \
  "expected $mount_point, actual unknown" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 disk9s1
printf '%s\n' malformed > "$apfs_state/plist_mode"
assert_status_snapshot "malformed APFS property list" \
  unlocked \
  'unknown (APFS property list is malformed)' \
  "expected $mount_point, actual unknown" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true missing disk9s1
assert_status_snapshot "missing APFS VolumeUUID" \
  unlocked \
  'unknown (APFS volume UUID is missing)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 missing
assert_status_snapshot "missing APFS DeviceIdentifier" \
  unlocked \
  'unknown (APFS device identifier is missing or malformed)' \
  "expected $mount_point, actual $mount_point" \
  'plaintext present, ciphertext absent, hash absent' \
  inconsistent

write_apfs_state false true UUID-123 disk9s1
printf '%s\n' '{"locked":"true","volume_uuid":"UUID-123","deadline":null,"deadline_epoch":null,"round":null}' \
  > "$state_dir/state.json"
assert_invalid_snapshot "wrong-typed JSON"

printf '%s\n' '{not-json' > "$state_dir/state.json"
assert_invalid_snapshot "malformed JSON"

write_json_state false null null null UUID-123
chmod 000 "$state_dir/state.json"
: > "$action_log"
if output=$(run_vaultlock status 2>&1); then
  status=0
else
  status=$?
fi
chmod 600 "$state_dir/state.json"
check "unreadable state exits successfully" 0 "$status"
check_line "unreadable state reports boundary failure" \
  'Recorded: unknown (state file is unreadable)' "$output"
check_line "unreadable state is inconsistent" \
  'Assessment: inconsistent' "$output"
check_empty "unreadable state performs no system operation" "$action_log"

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_recovery_state true false false

host_bin="$test_root/host-bin"
mkdir -p "$host_bin"
ln -s "$TEST_SELF" "$host_bin/diskutil"
mv "$fake_bin/diskutil" "$fake_bin/diskutil.fixture"
: > "$action_log"
PATH="$host_bin:$PATH" run_vaultlock status >/dev/null 2>&1 || true
fallback_diskutil_calls=$(grep -c '^diskutil\([[:space:]]\|$\)' \
  "$action_log" || true)
check "omitted fake command cannot fall through to host PATH" \
  0 "$fallback_diskutil_calls"
mv "$fake_bin/diskutil.fixture" "$fake_bin/diskutil"

write_apfs_state false true UUID-123 disk9s1
printf '%s\n' "$test_root/Volumes/vaultXtest" \
  > "$apfs_state/mount_point"
output=$(run_vaultlock status)
check_line "mount point matching is literal" \
  'Assessment: inconsistent' "$output"

check "lock option order" \
  $'dry_run=true\nyes=true\nhooks=false\noperands=2:00 +2d' \
  "$(run_vaultlock __options lock --yes --no-hooks --dry-run 2:00 +2d)"

check "init accepts yes and dry-run" \
  $'dry_run=true\nyes=true\nhooks=true\noperands=' \
  "$(run_vaultlock __options init --yes --dry-run)"
check "lock accepts yes and dry-run" \
  $'dry_run=true\nyes=true\nhooks=true\noperands=20h' \
  "$(run_vaultlock __options lock --dry-run --yes 20h)"
check "adopt accepts dry-run and yes" \
  $'dry_run=true\nyes=true\nhooks=true\noperands=source directory' \
  "$(run_vaultlock __options adopt --dry-run --yes 'source directory')"
check "unlock accepts dry-run and no-hooks" \
  $'dry_run=true\nyes=false\nhooks=false\noperands=' \
  "$(run_vaultlock __options unlock --no-hooks --dry-run)"

reject_options "unlock rejects yes" unlock --yes
reject_options "adopt rejects option after operand" adopt source --dry-run
reject_options "init rejects operands" init extra
reject_options "unlock rejects operands" unlock extra
reject_options "init rejects unknown options" init --unknown
reject_options "adopt rejects extra operands" adopt source extra
reject_options "init rejects no-hooks" init --no-hooks
reject_options "adopt rejects no-hooks" adopt --no-hooks source

check "confirmation accepts y" true \
  "$(run_vaultlock __confirm_response y)"
check "confirmation accepts yes case-insensitively" true \
  "$(run_vaultlock __confirm_response YES)"
check "confirmation rejects empty" false \
  "$(run_vaultlock __confirm_response '')"

missing_confirm_device="$test_root/missing-confirm-device"
if HOME="$test_home" PATH="$fake_bin" \
    VAULTLOCK_CONFIRM_DEVICE="$missing_confirm_device" \
    /bin/bash "$VL" __confirm_plan false false \
      >"$test_root/confirm-output" 2>"$test_root/confirm-error"; then
  record_failure "confirmation without a device must fail"
else
  check_contains "non-interactive confirmation hint" "rerun with --yes" \
    "$(< "$test_root/confirm-error")"
fi

if (
    unset VAULTLOCK_CONFIRM_DEVICE
    PATH="$fake_bin" run_detached \
      /bin/bash "$VL" __confirm_plan false false
  ) >"$test_root/detached-output" 2>"$test_root/detached-error"; then
  record_failure "detached confirmation without a terminal must fail"
else
  check_contains "detached confirmation hint" "rerun with --yes" \
    "$(< "$test_root/detached-error")"
fi

if HOME="$test_home" PATH="$fake_bin" \
    VAULTLOCK_CONFIRM_DEVICE="$missing_confirm_device" \
    /bin/bash "$VL" __confirm_plan true false \
      >"$test_root/confirm-output" 2>"$test_root/confirm-error"; then
  printf 'ok   dry-run bypasses confirmation device\n'
else
  record_failure "dry-run must bypass confirmation device"
fi

if HOME="$test_home" PATH="$fake_bin" \
    VAULTLOCK_CONFIRM_DEVICE="$missing_confirm_device" \
    /bin/bash "$VL" __confirm_plan false true \
      >"$test_root/confirm-output" 2>"$test_root/confirm-error"; then
  printf 'ok   yes bypasses confirmation device\n'
else
  record_failure "yes must bypass confirmation device"
fi

exit "$fail"
