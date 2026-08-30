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
    if [[ "${1:-}" == "-plist" ]]; then
      plist=true
      shift
    fi
    [[ $# -eq 1 ]] || exit 64
    locked=$(fixture_read locked) || exit 1
    mounted=$(fixture_read mounted) || exit 1
    uuid=$(fixture_read uuid) || exit 1
    device=$(fixture_read device) || exit 1
    fixture_mount_point=$(fixture_read mount_point) || exit 1

    if [[ "$plist" == "true" ]]; then
      printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>' \
        '<key>Locked</key>'
      if [[ "$locked" == "true" ]]; then
        printf '<true/>\n'
      else
        printf '<false/>\n'
      fi
      printf '%s\n' \
        '<key>MountPoint</key>' \
        "<string>$fixture_mount_point</string>" \
        '<key>VolumeUUID</key>' \
        "<string>$uuid</string>" \
        '<key>DeviceIdentifier</key>' \
        "<string>$device</string>" \
        '</dict></plist>'
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

for read_only_utility in jq plutil grep; do
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
}

write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1

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

output=$(run_vaultlock status)
check_contains "status uses injected mount listing" \
  "UNLOCKED (mounted at $mount_point)" "$output"

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
check_contains "mount point matching is literal" \
  "UNLOCKED (not mounted)" "$output"

exit "$fail"
