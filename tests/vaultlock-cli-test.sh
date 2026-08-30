#!/bin/bash
# Isolated CLI tests for vaultlock. All system-facing commands are fixtures.
set -euo pipefail

fixture_command=${0##*/}

if [[ "${VAULTLOCK_TEST_FAKE_SYSTEM:-0}" == "1" \
    && "$fixture_command" != "vaultlock-cli-test.sh" ]]; then
  : "${VAULTLOCK_TEST_ACTION_LOG:?missing action log}"
  : "${VAULTLOCK_TEST_MUTATION_LOG:?missing mutation log}"
  : "${VAULTLOCK_TEST_HOOK_LOG:?missing hook log}"
  : "${VAULTLOCK_TEST_APFS_STATE:?missing APFS state directory}"
  : "${VAULTLOCK_TEST_FAKE_BIN:?missing fake binary directory}"
  : "${VAULTLOCK_MOUNT_POINT:?missing mount point}"

  printf '%q' "$fixture_command" >> "$VAULTLOCK_TEST_ACTION_LOG"
  for fixture_argument in "$@"; do
    printf ' %q' "$fixture_argument" >> "$VAULTLOCK_TEST_ACTION_LOG"
  done
  printf '\n' >> "$VAULTLOCK_TEST_ACTION_LOG"

  case "$fixture_command" in
    diskutil)
      [[ "${1:-}" == "info" ]] \
        || printf '%s\n' "diskutil $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
      ;;
    security|tmutil)
      printf '%s\n' "$fixture_command $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
      ;;
    tle)
      for fixture_argument in "$@"; do
        if [[ "$fixture_argument" == "-o" ]]; then
          printf '%s\n' "tle $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
          break
        fi
      done
      ;;
    sudo|mount-fixture|bash-version-fixture|curl) ;;
    mount) ;;
    *)
      printf '%s\n' "$fixture_command $*" >> "$VAULTLOCK_TEST_HOOK_LOG"
      ;;
  esac

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
mutation_log="$test_root/mutations"
hook_log="$test_root/hooks"
apfs_state="$test_root/apfs"
test_home="$test_root/home"
state_dir="$test_home/.vaultlock"
mount_point="$test_root/Volumes/vault.test"
confirm_device="$test_root/confirm"
mkdir -p "$fake_bin" "$apfs_state" "$state_dir" "$mount_point"
: > "$action_log"
: > "$mutation_log"
: > "$hook_log"
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

check_count() { # description expected needle output
  local description=$1 expected=$2 needle=$3 output=$4 actual
  actual=$(grep -Foc -- "$needle" <<< "$output" || true)
  check "$description" "$expected" "$actual"
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
  VAULTLOCK_TEST_MUTATION_LOG="$mutation_log" \
  VAULTLOCK_TEST_HOOK_LOG="$hook_log" \
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
  VAULTLOCK_TEST_MUTATION_LOG="$mutation_log" \
  VAULTLOCK_TEST_HOOK_LOG="$hook_log" \
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

tree_manifest() { # root
  local root=$1 path relative path_type mode target hash attribute attributes
  local sort_key
  local -i index insert_at
  local LC_ALL=C
  local -a paths

  paths=()
  while IFS= read -r -d '' path; do
    paths+=("$path")
  done < <(/usr/bin/find "$root" -print0)
  for ((index=1; index<${#paths[@]}; index++)); do
    sort_key=${paths[$index]}
    insert_at=$((index - 1))
    while (( insert_at >= 0 )) && [[ "${paths[$insert_at]}" > "$sort_key" ]]; do
      paths[insert_at + 1]=${paths[$insert_at]}
      insert_at=$((insert_at - 1))
    done
    paths[insert_at + 1]=$sort_key
  done

  for path in "${paths[@]}"; do
    if [[ "$path" == "$root" ]]; then
      relative=.
    else
      relative=${path#"$root"/}
    fi
    target=""
    hash=""
    if [[ -L "$path" ]]; then
      path_type="symlink"
      target=$(/usr/bin/readlink "$path")
    elif [[ -f "$path" ]]; then
      path_type="file"
      hash=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/cut -d' ' -f1)
    elif [[ -d "$path" ]]; then
      path_type="directory"
    else
      path_type="other"
    fi
    mode=$(/usr/bin/stat -f '%Lp' "$path")
    attributes=""
    while IFS= read -r attribute; do
      [[ -n "$attribute" ]] || continue
      attributes="$attributes$(printf '%q' "$attribute")="
      attributes="$attributes$(/usr/bin/xattr -px "$attribute" "$path" \
        | /usr/bin/tr -d '[:space:]');"
    done < <(/usr/bin/xattr "$path" 2>/dev/null | LC_ALL=C /usr/bin/sort)
    printf '%q|type=%s|mode=%s|target=%q|sha256=%s|xattrs=%s\n' \
      "$relative" "$path_type" "$mode" "$target" "$hash" "$attributes"
  done
}

check_tree_unchanged() { # description before root
  local description=$1 before=$2 root=$3 after
  after=$(tree_manifest "$root")
  if [[ "$after" == "$before" ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s\n' "$description"
    printf 'before:\n%s\nafter:\n%s\n' "$before" "$after"
    fail=1
  fi
}

check_manifest_changed() { # description before root
  local description=$1 before=$2 root=$3 after
  after=$(tree_manifest "$root")
  if [[ "$after" != "$before" ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: manifest did not change\n' "$description"
    fail=1
  fi
}

check_secret_absent() { # description output secret
  local description=$1 output=$2 secret=$3
  if [[ "$output" != *"$secret"* ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: secret appeared in output\n' "$description"
    fail=1
  fi
}

fake_passphrase='FAKE-PASSPHRASE-DO-NOT-PRINT'
fake_hash='FAKE-HASH-DO-NOT-PRINT'
fake_ciphertext='FAKE-CIPHERTEXT-DO-NOT-PRINT'

manifest_probe="$test_root/manifest-probe"
mkdir -p "$manifest_probe/empty"
: > "$manifest_probe/file"
ln -s file "$manifest_probe/link"
chmod 600 "$manifest_probe/file"
manifest_before=$(tree_manifest "$manifest_probe")
chmod 640 "$manifest_probe/file"
check_manifest_changed "tree manifest detects chmod" \
  "$manifest_before" "$manifest_probe"
manifest_before=$(tree_manifest "$manifest_probe")
mkdir "$manifest_probe/new-empty"
check_manifest_changed "tree manifest detects empty directory creation" \
  "$manifest_before" "$manifest_probe"

write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s\n' "$fake_ciphertext" > "$state_dir/passphrase.tle"
lock_state_before=$(tree_manifest "$state_dir")
lock_apfs_before=$(tree_manifest "$apfs_state")
: > "$action_log"
: > "$mutation_log"
: > "$hook_log"
if lock_plan=$(run_vaultlock lock --dry-run --no-hooks 2:00 +2d 2>&1); then
  lock_status=0
else
  lock_status=$?
fi
check "lock dry-run exits successfully" 0 "$lock_status"
check_line "lock dry-run names target" \
  'Target: locked at the resolved deadline' "$lock_plan"
check_contains "lock dry-run resolves deadline" \
  'Requested deadline: ' "$lock_plan"
check_contains "lock dry-run resolves target round" \
  'Resolved drand round: target ' "$lock_plan"
lock_actions=$(sed -n '/^Actions:$/,/^Confirmation:/p' <<< "$lock_plan")
expected_lock_actions=$(cat <<EOF
Actions:
  1. Verify the existing plaintext recovery material against its stored hash for repair
  2. Unlock the expected APFS volume with the verified existing recovery material for repair
  3. Mount the expected APFS volume at $mount_point for repair
  4. Verify the mounted UUID and device before continuing
  5. Hooks disabled by --no-hooks
  6. Add the vault volume root to Time Machine exclusions
  7. Delete local Time Machine snapshots for the vault
  8. Unmount the vault
  9. Generate and durably stage a new random recovery passphrase
  10. Rotate the APFS volume passphrase, then commit the staged plaintext recovery file
  11. Update the keychain with the rotated recovery material
  12. Encrypt the rotated recovery material for the resolved drand round
  13. Verify the time-lock ciphertext is nonempty and not yet decryptable
  14. Write the recovery hash and durably record the locked deadline and round
  15. Remove plaintext recovery material and its keychain entry
  16. Delete local Time Machine snapshots for the data volume
  17. Lock the APFS volume
  18. Verify APFS encryption, locked state, and failed unauthenticated mounting
Confirmation:
EOF
)
check "lock dry-run ordered actions" "$expected_lock_actions" "$lock_actions"
check "lock dry-run final result" 'Result: no changes made' \
  "$(tail -n 1 <<< "$lock_plan")"
check "lock dry-run audit contains only allowlisted reads" \
  $'diskutil info -plist UUID-123\ncurl -fsS --max-time 10 https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info' \
  "$(< "$action_log")"
check_empty "lock dry-run mutation log" "$mutation_log"
check_empty "lock dry-run hook log" "$hook_log"
check_tree_unchanged "lock dry-run leaves state tree unchanged" \
  "$lock_state_before" "$state_dir"
check_tree_unchanged "lock dry-run leaves APFS fixture unchanged" \
  "$lock_apfs_before" "$apfs_state"
check_secret_absent "lock dry-run hides passphrase" "$lock_plan" "$fake_passphrase"
check_secret_absent "lock dry-run hides hash" "$lock_plan" "$fake_hash"
check_secret_absent "lock dry-run hides ciphertext" "$lock_plan" "$fake_ciphertext"
lock_hook_plan=$(run_vaultlock lock --dry-run 2:00 +2d)
check_contains "lock dry-run types deferred pre-lock hook metadata" \
  "Defer pre-lock vault hook discovery in $(printf '%q' "$mount_point/.vaultlock/hooks/pre-lock.d") until the expected vault is mounted and verified" \
  "$lock_hook_plan"

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
rm -f "$apfs_state/mount_point" "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s\n' "$fake_ciphertext" > "$state_dir/passphrase.tle"
mkdir -p "$state_dir/hooks/pre-unlock.d" "$state_dir/hooks/post-unlock.d"
cp "$TEST_SELF" "$state_dir/hooks/pre-unlock.d/10-pre hook"
cp "$TEST_SELF" "$state_dir/hooks/post-unlock.d/20-post hook"
chmod +x "$state_dir/hooks/pre-unlock.d/10-pre hook" \
  "$state_dir/hooks/post-unlock.d/20-post hook"
unlock_state_before=$(tree_manifest "$state_dir")
unlock_apfs_before=$(tree_manifest "$apfs_state")
: > "$action_log"
: > "$mutation_log"
: > "$hook_log"
if unlock_plan=$(run_vaultlock unlock --dry-run 2>&1); then
  unlock_status=0
else
  unlock_status=$?
fi
check "unlock dry-run exits successfully" 0 "$unlock_status"
check_line "unlock dry-run names target" \
  "Target: unlocked and mounted at $mount_point" "$unlock_plan"
check_contains "unlock dry-run lists pre-unlock hook" \
  "10-pre\\ hook --phase pre-unlock --scope global" "$unlock_plan"
check_contains "unlock dry-run defers unavailable local hooks" \
  "Defer post-unlock vault hook discovery in $(printf '%q' "$mount_point/.vaultlock/hooks/post-unlock.d") until the expected vault is mounted and verified" \
  "$unlock_plan"
check_contains "unlock dry-run lists global post hook after deferred item" \
  "20-post\\ hook --phase post-unlock --scope global" "$unlock_plan"
unlock_order=$(printf '%s\n' "$unlock_plan" \
  | grep -E 'pre-unlock|Decrypt|Verify the decrypted|Unlock the expected|Verify the mounted|Write the verified|Update the keychain|record the unlocked|Defer discovery|post-unlock' \
  || true)
quoted_pre_hook=$(printf '%q' "$state_dir/hooks/pre-unlock.d/10-pre hook")
quoted_post_hook=$(printf '%q' "$state_dir/hooks/post-unlock.d/20-post hook")
quoted_mount_point=$(printf '%q' "$mount_point")
quoted_state_dir=$(printf '%q' "$state_dir")
quoted_state_file=$(printf '%q' "$state_dir/state.json")
expected_unlock_order=$(cat <<EOF
  1. Run hook $quoted_pre_hook --phase pre-unlock --scope global --volume vault --mount-point $quoted_mount_point --volume-uuid UUID-123 --device disk9s1 --state-dir $quoted_state_dir --state-file $quoted_state_file --deadline 2099-01-02T03:04:00+0100 --deadline-epoch 4070999040 --round 792731235 --locked true
  2. Decrypt the stored time-lock ciphertext after its drand round is available
  3. Verify the decrypted recovery material against the stored hash
  4. Unlock the expected APFS volume with the verified recovery material
  5. Verify the mounted UUID and device before continuing
  6. Write the verified plaintext recovery file durably
  7. Update the keychain with the verified recovery material
  8. Durably record the unlocked state
  9. Defer post-unlock vault hook discovery in $(printf '%q' "$mount_point/.vaultlock/hooks/post-unlock.d") until the expected vault is mounted and verified
  10. Run hook $quoted_post_hook --phase post-unlock --scope global --volume vault --mount-point $quoted_mount_point --volume-uuid UUID-123 --device disk9s1 --state-dir $quoted_state_dir --state-file $quoted_state_file --deadline 2099-01-02T03:04:00+0100 --deadline-epoch 4070999040 --round 792731235 --locked false
EOF
)
check "unlock dry-run ordered actions" "$expected_unlock_order" "$unlock_order"
check "unlock dry-run final result" 'Result: no changes made' \
  "$(tail -n 1 <<< "$unlock_plan")"
check "unlock dry-run audit contains only allowlisted reads" \
  $'diskutil info -plist UUID-123\ncurl -fsS --max-time 10 https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info' \
  "$(< "$action_log")"
check_empty "unlock dry-run mutation log" "$mutation_log"
check_empty "unlock dry-run hook log" "$hook_log"
check_tree_unchanged "unlock dry-run leaves state tree unchanged" \
  "$unlock_state_before" "$state_dir"
check_tree_unchanged "unlock dry-run leaves APFS fixture unchanged" \
  "$unlock_apfs_before" "$apfs_state"
check_secret_absent "unlock dry-run hides hash" "$unlock_plan" "$fake_hash"
check_secret_absent "unlock dry-run hides ciphertext" "$unlock_plan" "$fake_ciphertext"
check_secret_absent "unlock dry-run hides passphrase" "$unlock_plan" "$fake_passphrase"

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
rm -f "$apfs_state/mount_point" "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s\n' "$fake_ciphertext" > "$state_dir/passphrase.tle"
secure_lock_plan=$(run_vaultlock lock --dry-run --no-hooks 1h)
check_count "secure lock dry-run disables hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$secure_lock_plan"
check_contains "secure lock retains requested deadline" \
  'Requested deadline: ' "$secure_lock_plan"
check_contains "secure lock retains requested round" \
  'Resolved drand round: target ' "$secure_lock_plan"
check_contains "secure lock preserves existing deadline" \
  'Existing locked deadline preserved: 2099-01-02T03:04:00+0100' \
  "$secure_lock_plan"
check_contains "secure lock preserves existing round" \
  'existing drand round 792731235' "$secure_lock_plan"

write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
rm -f "$state_dir/passphrase.tle" "$apfs_state/mount_point"
repair_unlock_plan=$(run_vaultlock unlock --dry-run)
repair_unlock_order=$(printf '%s\n' "$repair_unlock_plan" \
  | grep -E 'Verify the existing plaintext|Unlock the expected APFS|Mount the expected APFS|Verify the mounted UUID|Verify the unlocked and mounted|Defer post-unlock|post-unlock.d/20-post' \
  || true)
quoted_post_hook=$(printf '%q' "$state_dir/hooks/post-unlock.d/20-post hook")
expected_repair_unlock_order=$(cat <<EOF
  1. Verify the existing plaintext recovery material against its stored hash for repair
  2. Unlock the expected APFS volume with the verified existing recovery material for repair
  3. Mount the expected APFS volume at $mount_point for repair
  4. Verify the mounted UUID and device before continuing
  5. Verify the unlocked and mounted target state
  6. Defer post-unlock vault hook discovery in $(printf '%q' "$mount_point/.vaultlock/hooks/post-unlock.d") until the expected vault is mounted and verified
  7. Run hook $quoted_post_hook --phase post-unlock --scope global --volume vault --mount-point $quoted_mount_point --volume-uuid UUID-123 --device disk9s1 --state-dir $quoted_state_dir --state-file $quoted_state_file --deadline null --deadline-epoch null --round null --locked false
EOF
)
check "recorded-unlocked repair plans target and post hooks in order" \
  "$expected_repair_unlock_order" "$repair_unlock_order"

repair_unlock_no_hooks=$(run_vaultlock unlock --dry-run --no-hooks)
check_count "recorded-unlocked repair disables hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$repair_unlock_no_hooks"
repair_no_hooks_order=$(printf '%s\n' "$repair_unlock_no_hooks" \
  | grep -E 'Verify the existing plaintext|Unlock the expected APFS|Mount the expected APFS|Verify the mounted UUID|Verify the unlocked and mounted|Hooks disabled' \
  || true)
expected_repair_no_hooks_order=$(cat <<EOF
  1. Verify the existing plaintext recovery material against its stored hash for repair
  2. Unlock the expected APFS volume with the verified existing recovery material for repair
  3. Mount the expected APFS volume at $mount_point for repair
  4. Verify the mounted UUID and device before continuing
  5. Verify the unlocked and mounted target state
  6. Hooks disabled by --no-hooks
EOF
)
check "recorded-unlocked repair plans disabled hooks after target" \
  "$expected_repair_no_hooks_order" "$repair_no_hooks_order"

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
rm -f "$state_dir/passphrase.sha256" "$state_dir/passphrase.tle"
usable_unlock_plan=$(run_vaultlock unlock --dry-run --no-hooks)
check_count "usable unlock dry-run disables hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$usable_unlock_plan"
check_contains "usable unlock verifies target" \
  'Verify the unlocked and mounted target state' "$usable_unlock_plan"

write_json_state false null null null UUID-123
write_apfs_state false false UUID-123 disk9s1
printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
rm -f "$state_dir/passphrase.sha256" "$state_dir/passphrase.tle"
unmounted_unlock_plan=$(run_vaultlock unlock --dry-run --no-hooks)
check_count "unmounted unlock repair disables hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$unmounted_unlock_plan"
check_contains "unmounted unlock repair verifies target" \
  'Verify the unlocked and mounted target state' "$unmounted_unlock_plan"

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
rm -f "$apfs_state/mount_point" "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s\n' "$fake_ciphertext" > "$state_dir/passphrase.tle"
locked_unlock_no_hooks=$(run_vaultlock unlock --dry-run --no-hooks)
check_count "recorded-locked unlock disables hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$locked_unlock_no_hooks"

exit "$fail"
