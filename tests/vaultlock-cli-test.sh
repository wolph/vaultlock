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
  if [[ -n "${VAULTLOCK_TEST_GNU_PATH_DIR:-}" \
      && "${0%/*}" == "$VAULTLOCK_TEST_GNU_PATH_DIR" \
      && ( "$fixture_command" == "find" || "$fixture_command" == "stat" ) ]]; then
    : > "$VAULTLOCK_TEST_APFS_STATE/gnu_path_tool_called"
    printf '%s: unsupported BSD option\n' "$fixture_command" >&2
    exit 64
  fi
  : "${VAULTLOCK_TEST_FAKE_BIN:?missing fake binary directory}"
  : "${VAULTLOCK_MOUNT_POINT:?missing mount point}"

  printf '%q' "$fixture_command" >> "$VAULTLOCK_TEST_ACTION_LOG"
  for fixture_argument in "$@"; do
    printf ' %q' "$fixture_argument" >> "$VAULTLOCK_TEST_ACTION_LOG"
  done
  printf '\n' >> "$VAULTLOCK_TEST_ACTION_LOG"

  case "$fixture_command" in
    diskutil)
      if [[ "${1:-}" != "info" \
          && ! ( "${1:-}" == "apfs" && "${2:-}" == "list" ) ]]; then
        printf '%s\n' "diskutil $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
      fi
      ;;
  security|tmutil|ditto|mv|ln|rm|rmdir|mkdir|chmod|mktemp)
    if [[ " $* " != *"$HOME/.vaultlock-operation"* ]]; then
      printf '%s\n' "$fixture_command $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
    fi
      ;;
    tle)
      for fixture_argument in "$@"; do
        if [[ "$fixture_argument" == "-o" ]]; then
          printf '%s\n' "tle $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
          break
        fi
      done
      ;;
    sudo|mount-fixture|bash-version-fixture|curl|head|base64) ;;
    mount|dirname|basename|stat|find|wc|readlink) ;;
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

  fixture_replace_cleanup_state() { # target
    local fixture_target=$1 fixture_replacement
    fixture_replacement=${fixture_target%/*}/.cleanup-replacement
    /usr/bin/stat -f '%d:%i' "$fixture_target" \
      > "$VAULTLOCK_TEST_APFS_STATE/cleanup_original_identity"
    printf '%s\n' '{"unowned":"cleanup replacement"}' \
      > "$fixture_replacement"
    /bin/mv -f "$fixture_replacement" "$fixture_target"
    /usr/bin/stat -f '%d:%i' "$fixture_target" \
      > "$VAULTLOCK_TEST_APFS_STATE/cleanup_replacement_identity"
  }

  fake_diskutil_info() {
    local plist=false locked mounted uuid device fixture_mount_point
    local fixture_target
    local plist_mode=normal have_locked=false have_mount_point=false
    local mount_point_type=string
    if [[ "${1:-}" == "-plist" ]]; then
      plist=true
      shift
    fi
    [[ $# -eq 1 ]] || exit 64
    fixture_target=$1
    [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_diskutil_info" ]] || exit 1
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/locked" ]]; then
      have_locked=true
      locked=$(fixture_read locked)
    fi
    mounted=$(fixture_read mounted) || mounted=false
    if [[ "$fixture_target" == "$VAULTLOCK_MOUNT_POINT" \
        && "$mounted" != "true" ]]; then
      exit 1
    fi
    uuid=$(fixture_read uuid) || exit 1
    device=$(fixture_read device) || exit 1
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/mount_point" ]]; then
      have_mount_point=true
      fixture_mount_point=$(fixture_read mount_point)
    fi
    plist_mode=$(fixture_read plist_mode) || plist_mode=normal
    mount_point_type=$(fixture_read mount_point_type) || mount_point_type=string
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/race_state_temp_symlink" \
        && "$fixture_target" == "$VAULTLOCK_MOUNT_POINT" \
        && "$uuid" == "UUID-INIT" ]]; then
      /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/state_redirect_target" \
        "$VAULTLOCK_STATE_DIR/state.json.tmp.$PPID" 2>/dev/null || true
      /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/state_redirect_target" \
        "$VAULTLOCK_STATE_DIR/state.json" 2>/dev/null || true
    fi

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
        '<plist version="1.0"><dict>' \
        '<key>VolumeName</key><string>vault</string>'
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
      if [[ "$fixture_target" == "UUID-INIT" \
          && -f "$VAULTLOCK_STATE_DIR/state.json" ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/final_info_complete"
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/overwrite_state_after_final_info" ]]; then
          /usr/bin/stat -f '%d:%i' "$VAULTLOCK_STATE_DIR/state.json" \
            > "$VAULTLOCK_TEST_APFS_STATE/state_inode_before_rewrite"
          printf '%s\n' \
            '{"locked":false,"volume_uuid":"UUID-INIT","created":"rewritten","deadline":null,"deadline_epoch":null,"round":null}' \
            > "$VAULTLOCK_STATE_DIR/state.json"
          /usr/bin/stat -f '%d:%i' "$VAULTLOCK_STATE_DIR/state.json" \
            > "$VAULTLOCK_TEST_APFS_STATE/state_inode_after_rewrite"
          /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/overwrite_state_after_final_info"
        fi
      fi
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
            list)
              [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_apfs_list" ]] || exit 1
              fixture_apfs_list_mode=$(fixture_read apfs_list_mode) \
                || fixture_apfs_list_mode=normal
              printf '%s\n' \
                '<?xml version="1.0" encoding="UTF-8"?>' \
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
              case "$fixture_apfs_list_mode" in
                empty)
                  printf '%s\n' '<plist version="1.0"><dict/></plist>'
                  ;;
                incomplete)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key>' \
                    '<array><dict/></array></dict></plist>'
                  ;;
                missing_identity)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array>' \
                    '<dict><key>Name</key><string>vault</string></dict>' \
                    '</array></dict></array></dict></plist>'
                  ;;
                empty_record)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array><dict/></array>' \
                    '</dict></array></dict></plist>'
                  ;;
                scalar_record)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array><string>invalid</string></array>' \
                    '</dict></array></dict></plist>'
                  ;;
                mistyped_name)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array><dict>' \
                    '<key>Name</key><integer>7</integer>' \
                    '<key>VolumeUUID</key><string>UUID-OTHER</string>' \
                    '<key>DeviceIdentifier</key><string>disk7s9</string>' \
                    '</dict></array></dict></array></dict></plist>'
                  ;;
                mistyped_uuid)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array><dict>' \
                    '<key>Name</key><string>other</string>' \
                    '<key>VolumeUUID</key><integer>7</integer>' \
                    '<key>DeviceIdentifier</key><string>disk7s9</string>' \
                    '</dict></array></dict></array></dict></plist>'
                  ;;
                mistyped_device)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array><dict>' \
                    '<key>Name</key><string>other</string>' \
                    '<key>VolumeUUID</key><string>UUID-OTHER</string>' \
                    '<key>DeviceIdentifier</key><integer>7</integer>' \
                    '</dict></array></dict></array></dict></plist>'
                  ;;
                valid_unrelated)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array><dict>' \
                    '<key>Name</key><string>other</string>' \
                    '<key>VolumeUUID</key><string>UUID-OTHER</string>' \
                    '<key>DeviceIdentifier</key><string>disk7s9</string>' \
                    '</dict></array></dict></array></dict></plist>'
                  ;;
                normal)
                  printf '%s\n' \
                    '<plist version="1.0"><dict><key>Containers</key><array><dict>' \
                    '<key>Volumes</key><array>'
                  if [[ -f "$VAULTLOCK_TEST_APFS_STATE/locked" ]]; then
                    printf '%s\n' \
                      '<dict><key>Name</key><string>vault</string>' \
                      "<key>VolumeUUID</key><string>$(fixture_read uuid)</string>" \
                      "<key>DeviceIdentifier</key><string>$(fixture_read device)</string></dict>"
                  fi
                  printf '%s\n' '</array></dict></array></dict></plist>'
                  ;;
                *) exit 64 ;;
              esac
              if [[ -f "$VAULTLOCK_TEST_APFS_STATE/confirmation_race_kind" ]]; then
                fixture_race_kind=$(< "$VAULTLOCK_TEST_APFS_STATE/confirmation_race_kind")
                case "$fixture_race_kind" in
                  state)
                    printf 'introduced state\n' > "$VAULTLOCK_STATE_DIR/state.json"
                    ;;
                  recovery)
                    printf 'recovery sentinel\n' \
                      > "$VAULTLOCK_TEST_APFS_STATE/passphrase_redirect_target"
                    /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/passphrase_redirect_target" \
                      "$VAULTLOCK_STATE_DIR/passphrase.txt"
                    ;;
                  volume)
                    fixture_write locked false
                    fixture_write mounted false
                    fixture_write uuid UUID-RACE
                    fixture_write device disk7s2
                    fixture_write mount_point ""
                    fixture_write mount_point_type string
                    fixture_write plist_mode normal
                    ;;
                  *) exit 64 ;;
                esac
                /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/confirmation_race_kind"
              fi
              ;;
            addVolume)
              IFS= read -r fixture_passphrase || [[ -n "$fixture_passphrase" ]]
              [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_add_volume" ]] || exit 1
              fixture_write locked false
              fixture_write mounted true
              fixture_write uuid UUID-INIT
              fixture_write device disk8s1
              fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
              fixture_write mount_point_type string
              fixture_write plist_mode normal
              if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_final_uuid" ]]; then
                fixture_write uuid missing
              fi
            if [[ " $* " == *" -plist "* ]]; then
              : > "$VAULTLOCK_TEST_APFS_STATE/unsupported_add_volume_plist"
              printf '%s\n' \
                '<?xml version="1.0" encoding="UTF-8"?>' \
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
                '<plist version="1.0"><dict>' \
                '<key>VolumeUUID</key><string>UUID-INIT</string>' \
                '<key>DeviceIdentifier</key><string>disk8s1</string>' \
                '</dict></plist>'
            else
              fixture_add_output_mode=$(fixture_read add_output_mode) \
                || fixture_add_output_mode=normal
              case "$fixture_add_output_mode" in
                normal)
                  printf '%s\n' 'Disk from APFS operation: disk8s1'
                  ;;
                ambiguous)
                  printf '%s\n' \
                    'Disk from APFS operation: disk8s1' \
                    'Disk from APFS operation: disk9s1'
                  ;;
                malformed)
                  printf '%s\n' 'Disk from APFS operation: /dev/disk8s1'
                  ;;
                zero_disk)
                  printf '%s\n' 'Disk from APFS operation: disk0s1'
                  ;;
                zero_slice)
                  printf '%s\n' 'Disk from APFS operation: disk8s0'
                  ;;
                suffix)
                  printf '%s\n' 'Disk from APFS operation: disk8s1suffix'
                  ;;
                letters)
                  printf '%s\n' 'Disk from APFS operation: diskBAD'
                  ;;
                *) exit 64 ;;
              esac
            fi
            if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_identity_after_add" ]]; then
              fixture_write uuid UUID-AFTER-ADD-SWAP
              fixture_write device disk8s2
            fi
            : > "$VAULTLOCK_TEST_APFS_STATE/add_volume_complete"
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
    security)
      [[ "${1:-}" == "-i" && $# -eq 1 ]] || exit 64
      IFS= read -r fixture_security_command || exit 1
      [[ "$fixture_security_command" == add-generic-password\ * ]] || exit 64
      if /usr/bin/find "$VAULTLOCK_STATE_DIR" -maxdepth 1 \
          -name '.security-output.*' -print -quit | grep -q .; then
        : > "$VAULTLOCK_TEST_APFS_STATE/security_output_artifact_seen"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/echo_security_error" ]]; then
        printf '%s\n' "$fixture_security_command"
        printf '%s\n' "$fixture_security_command" >&2
        exit 1
      fi
      [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_keychain" ]] || exit 1
      : > "$VAULTLOCK_TEST_APFS_STATE/keychain_marker"
      ;;
    head)
      [[ "$*" == "-c 32 /dev/urandom" ]] || exit 64
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/race_passphrase_symlink" ]]; then
        /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/passphrase_redirect_target" \
          "$VAULTLOCK_STATE_DIR/passphrase.txt" 2>/dev/null || true
      fi
      printf 'Task6SecretOnlyInStdinChannel!!!'
      ;;
    base64) /usr/bin/base64 "$@" ;;
    ditto)
      fixture_ditto_source=""
      fixture_ditto_destination=""
      for fixture_argument in "$@"; do
        fixture_ditto_source=$fixture_ditto_destination
        fixture_ditto_destination=$fixture_argument
      done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_ditto" ]]; then
        fixture_ditto_signal=$(< "$VAULTLOCK_TEST_APFS_STATE/signal_ditto")
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/signal_ditto"
        /bin/kill -s "$fixture_ditto_signal" "$PPID"
        exit 0
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/hold_ditto" \
          && ! -f "$VAULTLOCK_TEST_APFS_STATE/held_ditto_pid" ]]; then
        printf '%s\n' "$PPID" \
          > "$VAULTLOCK_TEST_APFS_STATE/held_ditto_pid"
        : > "$VAULTLOCK_TEST_APFS_STATE/ditto_entered"
        while [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/release_ditto" ]]; do
          /bin/sleep 0.01
        done
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/hold_ditto" \
          "$VAULTLOCK_TEST_APFS_STATE/held_ditto_pid"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_ditto" ]]; then
        /bin/mkdir -p "$fixture_ditto_destination"
        printf 'partial\n' > "$fixture_ditto_destination/partial-copy"
        exit 1
      fi
      /usr/bin/ditto "$@" || exit 1
      if [[ -n "${DITTONORSRC:-}" ]]; then
        /usr/bin/xattr -c "$fixture_ditto_destination/subdirectory/file"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_mtime" ]]; then
        /usr/bin/touch -t 202001020304 \
          "$fixture_ditto_destination/subdirectory/file"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_flags" ]]; then
        /usr/bin/chflags nohidden "$fixture_ditto_destination/subdirectory/file"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_xattrs" ]]; then
        /usr/bin/xattr -c "$fixture_ditto_destination/subdirectory/file"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/break_copy_hardlink" ]]; then
        /bin/cp -p "$fixture_ditto_destination/subdirectory/file" \
          "$fixture_ditto_destination/subdirectory/broken-link"
        /bin/mv "$fixture_ditto_destination/subdirectory/broken-link" \
          "$fixture_ditto_destination/subdirectory/hardlink"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/rename_copy_trailing_newline" ]]; then
        /bin/mv "$fixture_ditto_destination/"$'trailing\n' \
          "$fixture_ditto_destination/trailing"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/modify_source_after_copy" ]]; then
        printf 'modified after copy\n' \
          > "$fixture_ditto_source/subdirectory/file"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/modify_source_after_copy"
      fi
      [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/add_copy_entry" ]] \
        || printf 'extra\n' > "$fixture_ditto_destination/extra-copy-entry"
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_mount_uuid_after_copy" ]]; then
        fixture_write uuid UUID-SWAPPED
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_mount_device_after_copy" ]]; then
        fixture_write device disk99s9
      fi
      : > "$VAULTLOCK_TEST_APFS_STATE/copy_complete"
      ;;
    dirname) /usr/bin/dirname "$@" ;;
    basename) /usr/bin/basename "$@" ;;
    stat)
      fixture_stat_path=""
      for fixture_argument in "$@"; do fixture_stat_path=$fixture_argument; done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_operation_lock_identity_once" \
          && "$fixture_stat_path" == "$HOME/.vaultlock-operation.lock" \
          && " $* " == *" %d:%i "* ]]; then
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/fail_operation_lock_identity_once"
        exit 1
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_backup_manifest" \
          && "$fixture_stat_path" == *.vaultlock-backup/* \
          && " $* " == *" %d:%i:%Lp:%u:%g:%z:%.9Fm:%.9FB:%f:%r:%l "* ]]; then
        fixture_manifest_signal=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_backup_manifest")
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_backup_manifest"
        /bin/kill -s "$fixture_manifest_signal" \
          "$VAULTLOCK_TEST_PROCESS_PID"
        /usr/bin/stat "$@"
      elif [[ ( -f "$VAULTLOCK_TEST_APFS_STATE/normalize_copy_directory_metadata" \
          || -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_birthtime" ) \
        && "$fixture_stat_path" == "$VAULTLOCK_MOUNT_POINT"/* \
        && -d "$fixture_stat_path" \
        && "${1:-}" == "-f" \
        && "${2:-}" == '%d:%i:%Lp:%u:%g:%z:%.9Fm:%.9FB:%f:%r:%l' ]]; then
        fixture_directory_metadata=$(/usr/bin/stat "$@") || exit 1
        IFS=: read -r fixture_device fixture_inode fixture_mode fixture_uid \
          fixture_gid fixture_size fixture_mtime fixture_birthtime fixture_flags \
          fixture_rdev fixture_nlink <<< "$fixture_directory_metadata"
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/normalize_copy_directory_metadata" ]] \
          || { fixture_size=999; fixture_rdev=999; }
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_birthtime" ]] \
          || fixture_birthtime=1.000000000
        printf '%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n' \
          "$fixture_device" "$fixture_inode" "$fixture_mode" "$fixture_uid" \
          "$fixture_gid" "$fixture_size" "$fixture_mtime" \
          "$fixture_birthtime" "$fixture_flags" "$fixture_rdev" \
          "$fixture_nlink"
        exit 0
      fi
      if [[ ( -f "$VAULTLOCK_TEST_APFS_STATE/source_compressed_flags" \
            || -f "$VAULTLOCK_TEST_APFS_STATE/source_immutable_flags" \
            || -f "$VAULTLOCK_TEST_APFS_STATE/source_append_flags" ) \
          && "$fixture_stat_path" != "$VAULTLOCK_MOUNT_POINT"/* \
          && "${1:-}" == "-f" \
          && "${2:-}" == '%d:%i:%Lp:%u:%g:%z:%.9Fm:%.9FB:%f:%r:%l' ]]; then
        fixture_flag_metadata=$(/usr/bin/stat "$@") || exit 1
        IFS=: read -r fixture_device fixture_inode fixture_mode fixture_uid \
          fixture_gid fixture_size fixture_mtime fixture_ctime fixture_flags \
          fixture_rdev fixture_nlink <<< "$fixture_flag_metadata"
        fixture_flags=32
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/source_immutable_flags" ]] \
          || fixture_flags=2
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/source_append_flags" ]] \
          || fixture_flags=4
        printf '%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n' \
          "$fixture_device" "$fixture_inode" "$fixture_mode" "$fixture_uid" \
          "$fixture_gid" "$fixture_size" "$fixture_mtime" "$fixture_ctime" \
          "$fixture_flags" "$fixture_rdev" "$fixture_nlink"
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_owner_metadata" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/copy_complete" \
          && "$fixture_stat_path" == "$VAULTLOCK_MOUNT_POINT"/* \
          && "${1:-}" == "-f" \
          && "${2:-}" == '%d:%i:%Lp:%u:%g:%z:%.9Fm:%.9FB:%f:%r:%l' ]]; then
        fixture_owner_metadata=$(/usr/bin/stat "$@") || exit 1
        IFS=: read -r fixture_device fixture_inode fixture_mode fixture_uid \
          fixture_gid fixture_size fixture_mtime fixture_ctime fixture_flags \
          fixture_rdev fixture_nlink <<< "$fixture_owner_metadata"
        printf '%s:%s:%s:999:%s:%s:%s:%s:%s:%s:%s\n' \
          "$fixture_device" "$fixture_inode" "$fixture_mode" "$fixture_gid" \
          "$fixture_size" "$fixture_mtime" "$fixture_ctime" "$fixture_flags" \
          "$fixture_rdev" "$fixture_nlink"
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/foreign_device_after_backup_quarantine" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/adopt_backup_quarantined" \
          && "$fixture_stat_path" == *.vaultlock-quarantine.*/backup/subdirectory/file ]]; then
        if [[ "${1:-}" == "-f" && "${2:-}" == "%d" ]]; then
          printf '999\n'
        elif [[ "${1:-}" == "-f" \
            && "${2:-}" == '%d:%i:%Lp:%u:%g:%z:%.9Fm:%.9FB:%f:%r:%l' ]]; then
          fixture_foreign_metadata=$(/usr/bin/stat "$@") || exit 1
          printf '999:%s\n' "${fixture_foreign_metadata#*:}"
        else
          /usr/bin/stat "$@"
        fi
      elif [[ "$fixture_stat_path" == "$VAULTLOCK_STATE_DIR/state.json" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/overwrite_state_after_install_identity" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/state_link_installed" ]]; then
        /usr/bin/stat "$@" || exit 1
        /usr/bin/stat -f '%d:%i' "$VAULTLOCK_STATE_DIR/state.json" \
          > "$VAULTLOCK_TEST_APFS_STATE/state_install_inode_before_rewrite"
        printf '%s\n' \
          '{"locked":false,"volume_uuid":"UUID-INIT","created":"rewritten-before-installed-digest","deadline":null,"deadline_epoch":null,"round":null}' \
          > "$VAULTLOCK_STATE_DIR/state.json"
        /usr/bin/stat -f '%d:%i' "$VAULTLOCK_STATE_DIR/state.json" \
          > "$VAULTLOCK_TEST_APFS_STATE/state_install_inode_after_rewrite"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/overwrite_state_after_install_identity"
      elif [[ "$fixture_stat_path" == "$VAULTLOCK_STATE_DIR/passphrase.txt" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/recovery_boundary_race" ]]; then
        /usr/bin/stat "$@" || exit 1
        fixture_recovery_race=$(< "$VAULTLOCK_TEST_APFS_STATE/recovery_boundary_race")
        case "$fixture_recovery_race" in
          modify)
            printf 'modified recovery\n' > "$fixture_stat_path"
            ;;
          replace)
            /bin/rm -f "$fixture_stat_path"
            printf 'replacement recovery\n' > "$fixture_stat_path"
            ;;
          volume)
            fixture_write locked false
            fixture_write mounted false
            fixture_write uuid UUID-AFTER-PREPARE
            fixture_write device disk7s4
            fixture_write mount_point ""
            fixture_write mount_point_type string
            fixture_write plist_mode normal
            ;;
          *) exit 64 ;;
        esac
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/recovery_boundary_race"
      elif [[ "$fixture_stat_path" == "$VAULTLOCK_STATE_DIR/passphrase.txt" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/write_state_recovery_race" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/add_volume_complete" ]]; then
        /usr/bin/stat "$@" || exit 1
        fixture_recovery_race=$(< "$VAULTLOCK_TEST_APFS_STATE/write_state_recovery_race")
        case "$fixture_recovery_race" in
          modify)
            printf 'modified after volume creation\n' > "$fixture_stat_path"
            ;;
          replace)
            /bin/rm -f "$fixture_stat_path"
            printf 'replacement after volume creation\n' > "$fixture_stat_path"
            ;;
          *) exit 64 ;;
        esac
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/write_state_recovery_race"
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_backup_identity" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/adopt_link_move_failed" \
          && "$fixture_stat_path" == *.vaultlock-backup* ]]; then
        printf '997:997\n'
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_restored_identity" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/rollback_moved" \
          && "$fixture_stat_path" != "$VAULTLOCK_MOUNT_POINT"/* \
          && "$fixture_stat_path" != "$HOME/.vaultlock-operation.lock" \
          && "$fixture_stat_path" != "$HOME/.vaultlock-operation.lock/owner" ]]; then
        printf '996:996\n'
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/named_source_identity_swap" \
          && "$fixture_stat_path" \
            == "$(< "$VAULTLOCK_TEST_APFS_STATE/named_source_identity_swap")" \
          && "${1:-}" == "-f" && "${2:-}" == "%d:%i" ]]; then
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/named_source_identity_swap"
        printf '999:999\n'
      elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/named_destination_identity_swap" \
          && "$fixture_stat_path" \
            == "$(< "$VAULTLOCK_TEST_APFS_STATE/named_destination_identity_swap")" \
          && "${1:-}" == "-f" && "${2:-}" == "%d:%i" ]]; then
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/named_destination_identity_swap"
        printf '998:998\n'
      else
        /usr/bin/stat "$@"
      fi
      ;;
    ls)
      fixture_ls_path=""
      for fixture_argument in "$@"; do fixture_ls_path=$fixture_argument; done
      /bin/ls "$@" || exit 1
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/drop_copy_acl" \
          && " $* " == *" -ldnePB "* \
          && "$fixture_ls_path" != "$VAULTLOCK_MOUNT_POINT"/* ]]; then
        printf ' 0: user:501 allow read\n'
      fi
      ;;
    find)
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/count_directory_traversals" \
        && " $* " == *" -depth "* \
        && " $* " == *" -type d "* ]]; then
        fixture_directory_traversals=0
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/directory_traversal_count" ]] \
          || fixture_directory_traversals=$(< \
            "$VAULTLOCK_TEST_APFS_STATE/directory_traversal_count")
        fixture_directory_traversals=$((fixture_directory_traversals + 1))
        fixture_write directory_traversal_count "$fixture_directory_traversals"
        [[ "$fixture_directory_traversals" -le 3 ]] || exit 70
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_cleanup" \
          && " $* " == *" -exec /bin/rm "* ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/insert_directory_after_file_cleanup" \
          && " $* " == *" -exec /bin/rmdir "* \
          && "${1:-}" == *.vaultlock-quarantine.*/backup ]]; then
        /bin/mkdir "$1/inserted-after-file-cleanup"
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/insert_directory_after_file_cleanup"
      fi
      /usr/bin/find "$@"
      ;;
    wc) /usr/bin/wc "$@" ;;
    readlink)
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_link_verification" \
          && "${1:-}" != *.vaultlock-* ]]; then
        printf '%s\n' "$VAULTLOCK_MOUNT_POINT/wrong-target"
      else
        /usr/bin/readlink "$@"
      fi
      ;;
    mv)
      fixture_mv_source=""
      fixture_mv_destination=""
      for fixture_argument in "$@"; do
        fixture_mv_source=$fixture_mv_destination
        fixture_mv_destination=$fixture_argument
      done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/make_quarantine_nonprivate_before_move" \
          && "$fixture_mv_source" == "$VAULTLOCK_STATE_DIR/state.json" \
          && "$fixture_mv_destination" == "$VAULTLOCK_STATE_DIR"/.state-quarantine.*/state.json ]]; then
        /bin/chmod 755 "${fixture_mv_destination%/*}"
        : > "$VAULTLOCK_TEST_APFS_STATE/quarantine_made_nonprivate"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/make_quarantine_nonprivate_before_move"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/replace_source_entry_before_backup_move" \
          && "$fixture_mv_source" != "$VAULTLOCK_MOUNT_POINT"/* \
          && "$fixture_mv_destination" == *.vaultlock-backup ]]; then
        /bin/rm -f "$fixture_mv_source/subdirectory/file"
        printf 'same count replacement\n' \
          > "$fixture_mv_source/subdirectory/replacement"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/replace_source_entry_before_backup_move"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_backup_move" \
          && "$fixture_mv_destination" == *.vaultlock-backup \
          && "$fixture_mv_source" == "${fixture_mv_destination%.vaultlock-backup}" ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_link_move" \
          && "$fixture_mv_source" == *.vaultlock-link \
          && "$fixture_mv_destination" == "${fixture_mv_source%.vaultlock-link}" ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/adopt_link_move_failed"
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/race_source_symlink_on_link_move_failure" ]]; then
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/unowned-link-target" \
            "$fixture_mv_destination"
          /bin/rm -f \
            "$VAULTLOCK_TEST_APFS_STATE/race_source_symlink_on_link_move_failure"
        fi
        exit 1
      fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_rollback_move" \
      && "$fixture_mv_source" == *.vaultlock-backup/* \
      && "$fixture_mv_destination" == "${fixture_mv_source%/*/*}" ]]; then
        exit 1
      fi
      /bin/mv "$@" || exit 1
      if [[ "$fixture_mv_destination" == *.vaultlock-quarantine.*/backup ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/adopt_backup_quarantined"
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_backup_at_quarantine_boundary" ]]; then
          /bin/mkdir "$fixture_mv_destination.replacement"
          printf 'unowned replacement\n' \
            > "$fixture_mv_destination.replacement/replacement"
          /bin/mv "$fixture_mv_destination" \
            "${fixture_mv_destination%/*}/owned-backup"
          /bin/mv "$fixture_mv_destination.replacement" \
            "$fixture_mv_destination"
          /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/swap_backup_at_quarantine_boundary"
        fi
      fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_restored_identity" \
      && "$fixture_mv_source" == *.vaultlock-backup/* \
      && "$fixture_mv_destination" == "${fixture_mv_source%/*/*}" ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/rollback_moved"
      fi
      ;;
  ln)
    fixture_ln_destination=""
    for fixture_argument in "$@"; do fixture_ln_destination=$fixture_argument; done
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_operation_lock_owner_install" \
      && "$fixture_ln_destination" == "$HOME/.vaultlock-operation.lock/owner" ]]; then
      exit 1
    fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_ln" \
      && "$fixture_ln_destination" != "$HOME/.vaultlock-operation.lock/owner" ]]; then
      exit 1
      fi
      /bin/ln "$@"
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_staged_link_creation" \
          && "$fixture_ln_destination" == *.vaultlock-link ]]; then
        fixture_creation_signal=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_staged_link_creation")
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_staged_link_creation"
        /bin/kill -s "$fixture_creation_signal" \
          "$VAULTLOCK_TEST_PROCESS_PID"
      fi
      if [[ "$fixture_ln_destination" == "$VAULTLOCK_STATE_DIR/state.json" ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/state_link_installed"
      fi
      ;;
    rm)
      fixture_rm_path=""
      for fixture_argument in "$@"; do fixture_rm_path=$fixture_argument; done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_operation_lock_release" \
          && "$fixture_rm_path" == "$HOME/.vaultlock-operation.lock/owner" ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_cleanup" \
          && " $* " == *" -rf "* ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_init_state_cleanup" \
          && ( "$fixture_rm_path" == "$VAULTLOCK_STATE_DIR/state.json" \
            || "$fixture_rm_path" == "$VAULTLOCK_STATE_DIR"/.state-quarantine.*/state.json ) ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_staged_link_cleanup" \
          && "$fixture_rm_path" == *.vaultlock-link ]]; then
        exit 1
      fi
      /bin/rm "$@" || exit 1
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_operation_owner_unlink" \
          && "$fixture_rm_path" == "$HOME/.vaultlock-operation.lock/owner" ]]; then
        fixture_release_signal=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/signal_operation_owner_unlink")
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/signal_operation_owner_unlink"
        /bin/kill -s "$fixture_release_signal" \
          "$VAULTLOCK_TEST_PROCESS_PID"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/modify_recovery_after_state" \
          && " $* " == *"/.state."* ]]; then
        printf 'post-state recovery modification\n' \
          > "$VAULTLOCK_STATE_DIR/passphrase.txt"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/modify_recovery_after_state"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_identity_after_state" \
          && " $* " == *"/.state."* ]]; then
        fixture_write uuid UUID-AFTER-STATE-SWAP
        fixture_write device disk8s3
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/swap_identity_after_state"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_state_inode_after_state" \
          && " $* " == *"/.state."* ]]; then
        /bin/cp "$VAULTLOCK_STATE_DIR/state.json" \
          "$VAULTLOCK_TEST_APFS_STATE/swapped_state_copy"
        /bin/rm -f "$VAULTLOCK_STATE_DIR/state.json"
        /bin/cp "$VAULTLOCK_TEST_APFS_STATE/swapped_state_copy" \
          "$VAULTLOCK_STATE_DIR/state.json"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/swapped_state_copy"
        /usr/bin/stat -f '%d:%i' "$VAULTLOCK_STATE_DIR/state.json" \
          > "$VAULTLOCK_TEST_APFS_STATE/swapped_state_identity"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/swap_state_inode_after_state"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/remove_state_after_state" \
          && " $* " == *"/.state."* ]]; then
        /bin/rm -f "$VAULTLOCK_STATE_DIR/state.json"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/remove_state_after_state"
      fi
      ;;
    rmdir)
      fixture_rmdir_path=""
      for fixture_argument in "$@"; do fixture_rmdir_path=$fixture_argument; done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/insert_directory_after_file_cleanup" \
          && "$fixture_rmdir_path" == *.vaultlock-quarantine.*/backup* ]]; then
        /bin/mkdir \
          "${fixture_rmdir_path%%/backup*}/backup/inserted-after-file-cleanup"
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/insert_directory_after_file_cleanup"
      fi
      /bin/rmdir "$@"
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_operation_directory_remove" \
          && "$fixture_rmdir_path" == "$HOME/.vaultlock-operation.lock" ]]; then
        fixture_release_signal=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/signal_operation_directory_remove")
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/signal_operation_directory_remove"
        /bin/kill -s "$fixture_release_signal" \
          "$VAULTLOCK_TEST_PROCESS_PID"
      fi
      ;;
    mkdir)
      /bin/mkdir "$@" || exit 1
      fixture_mkdir_path=""
      for fixture_argument in "$@"; do fixture_mkdir_path=$fixture_argument; done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_operation_lock_mkdir" \
          && "$fixture_mkdir_path" == "$HOME/.vaultlock-operation.lock" ]]; then
        fixture_mkdir_signal=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/signal_operation_lock_mkdir")
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/signal_operation_lock_mkdir"
        /bin/kill -s "$fixture_mkdir_signal" "$PPID"
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_reservation_creation" \
          && "$fixture_mkdir_path" == *.vaultlock-backup ]]; then
        fixture_creation_signal=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_reservation_creation")
        /bin/rm -f \
          "$VAULTLOCK_TEST_APFS_STATE/signal_adopt_reservation_creation"
        /bin/kill -s "$fixture_creation_signal" \
          "$VAULTLOCK_TEST_PROCESS_PID"
      fi
      ;;
    chmod)
      fixture_chmod_mode=${1:-}
      fixture_chmod_path=""
      for fixture_argument in "$@"; do fixture_chmod_path=$fixture_argument; done
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_recovery_acl_removal" \
          && "$fixture_chmod_mode" == "-N" \
          && "$fixture_chmod_path" == "$VAULTLOCK_STATE_DIR"/.passphrase.* ]]; then
        exit 1
      fi
      /bin/chmod "$@"
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/quarantine_made_nonprivate" \
          && "$fixture_chmod_mode" == "700" \
          && "$fixture_chmod_path" == "$VAULTLOCK_STATE_DIR"/.state-quarantine.* ]]; then
        /usr/bin/stat -f '%Lp' "$fixture_chmod_path" \
          > "$VAULTLOCK_TEST_APFS_STATE/quarantine_reprotected_mode"
        /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/quarantine_made_nonprivate"
      fi
      ;;
  mktemp)
    fixture_mktemp_path=$(/usr/bin/mktemp "$@") || exit 1
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/inherit_recovery_acl" \
      && "$fixture_mktemp_path" == "$VAULTLOCK_STATE_DIR/.passphrase."* ]]; then
      /bin/chmod +a 'everyone allow read' "$fixture_mktemp_path" || exit 1
    fi
    printf '%s\n' "$fixture_mktemp_path"
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/signal_operation_owner_mktemp" \
      && "$fixture_mktemp_path" == "$HOME/.vaultlock-operation.lock/.owner."* ]]; then
      /bin/kill -TERM "$PPID"
    fi
    ;;
    ps)
      [[ "${1:-}" == "-p" && "${2:-}" =~ ^[0-9]+$ \
        && "${3:-}" == "-o" && "${4:-}" == "lstart=" \
        && $# -eq 4 ]] || exit 64
      [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/ps_ambiguous" ]] || exit 2
      [[ "${2:-}" != "999999" ]] || exit 1
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/ps_timezone_sensitive" ]]; then
        case "${TZ:-}" in
          UTC0) printf 'Sun Aug 30 10:00:00 2026\n' ;;
          Pacific/Honolulu) printf 'Sat Aug 29 20:00:00 2026\n' ;;
          Europe/Amsterdam) printf 'Sun Aug 30 12:00:00 2026\n' ;;
          *) printf 'Sun Aug 30 10:00:00 2026\n' ;;
        esac
      else
        printf 'Sun Aug 30 10:00:00 2026\n'
      fi
      ;;
    openssl)
      [[ "$*" == "rand -hex 32" ]] || exit 64
      if [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/token_generated" ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/token_generated"
        printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
      elif [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/token_generated_twice" ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/token_generated_twice"
        printf 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'
      else
        printf 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\n'
      fi
      ;;
    transition-fixture)
      fixture_transition=${1:-}
      fixture_subject=${2:-}
      fixture_transition_marker=$VAULTLOCK_TEST_APFS_STATE/transition_$fixture_transition
      [[ -f "$fixture_transition_marker" ]] || exit 0
      fixture_transition_action=$(< "$fixture_transition_marker")
      case "$fixture_transition_action" in
      signal_HUP|signal_INT|signal_TERM)
        fixture_transition_signal=${fixture_transition_action#signal_}
        /bin/kill -s "$fixture_transition_signal" "$PPID"
        ;;
        adopt_source_identity_swap)
          printf '%s\n' "$fixture_subject" \
            > "$VAULTLOCK_TEST_APFS_STATE/named_source_identity_swap"
          ;;
        adopt_destination_identity_swap)
          printf '%s\n' "$fixture_subject" \
            > "$VAULTLOCK_TEST_APFS_STATE/named_destination_identity_swap"
          ;;
        init_state_identity_swap)
          fixture_replace_cleanup_state "$fixture_subject"
          ;;
        init_state_create)
          printf '{"introduced":"plan drift"}\n' \
            > "$VAULTLOCK_STATE_DIR/state.json"
          ;;
        adopt_state_dir_move_into_source)
          /bin/mv "$VAULTLOCK_STATE_DIR" \
            "$fixture_subject/.vaultlock"
          /bin/ln -s "$fixture_subject/.vaultlock" \
            "$VAULTLOCK_STATE_DIR"
          ;;
      owner_identity_swap)
        /bin/mv "$fixture_subject" "$fixture_subject.pre-transition"
        printf 'version=1\npid=broken\n' > "$fixture_subject"
        /bin/chmod 600 "$fixture_subject"
        ;;
      state_equivalent_inode_swap)
        /bin/cp "$VAULTLOCK_STATE_DIR/state.json" \
          "$VAULTLOCK_TEST_APFS_STATE/state-equivalent-copy"
        /bin/rm "$VAULTLOCK_STATE_DIR/state.json"
        /bin/mv "$VAULTLOCK_TEST_APFS_STATE/state-equivalent-copy" \
          "$VAULTLOCK_STATE_DIR/state.json"
        ;;
      adopt_mount_uuid_swap)
        fixture_write uuid UUID-POST-BACKUP-SWAP
        ;;
      adopt_mount_device_swap)
        fixture_write device disk99s9
        ;;
      adopt_backup_path_file_create)
        printf 'foreign backup file\n' > "$fixture_subject"
        ;;
      adopt_backup_path_directory_create)
        /bin/mkdir "$fixture_subject"
        printf 'foreign backup directory\n' > "$fixture_subject/foreign"
        ;;
      adopt_installed_source_identity_swap)
        /bin/mv "$fixture_subject" "$fixture_subject.pre-transition"
        printf 'foreign source entry\n' > "$fixture_subject"
        ;;
        adopt_backup_identity_swap)
          /bin/mv "$fixture_subject" "$fixture_subject.pre-transition"
          /usr/bin/ditto "$fixture_subject.pre-transition" "$fixture_subject"
          ;;
        adopt_staged_identity_swap)
          fixture_staged_target=$(/usr/bin/readlink "$fixture_subject") \
            || exit 1
          /bin/mv "$fixture_subject" "$fixture_subject.pre-transition"
          /bin/ln -s "$fixture_staged_target" "$fixture_subject"
          ;;
        *) exit 64 ;;
      esac
      /bin/rm -f "$fixture_transition_marker"
      ;;
    mount|tle|tmutil|curl)
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
gnu_bin="$test_root/gnu-bin"
action_log="$test_root/actions"
mutation_log="$test_root/mutations"
hook_log="$test_root/hooks"
apfs_state="$test_root/apfs"
test_home="$test_root/home"
state_dir="$test_home/.vaultlock"
mount_point="$test_root/Volumes/vault.test"
confirm_device="$test_root/confirm"
mkdir -p "$fake_bin" "$gnu_bin" "$apfs_state" "$state_dir" "$mount_point"
: > "$action_log"
: > "$mutation_log"
: > "$hook_log"
: > "$confirm_device"

TEST_SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
for fake_command in diskutil security sudo tle tmutil curl mount head base64 \
  ditto dirname basename stat find ls wc readlink mv ln rm rmdir mkdir chmod \
  mktemp ps openssl transition-fixture \
  mount-fixture bash-version-fixture; do
  ln -s "$TEST_SELF" "$fake_bin/$fake_command"
done
ln -s "$TEST_SELF" "$gnu_bin/find"
ln -s "$TEST_SELF" "$gnu_bin/stat"

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
  VAULTLOCK_TEST_DITTO="$fake_bin/ditto" \
  VAULTLOCK_TEST_BSD_FIND="$fake_bin/find" \
  VAULTLOCK_TEST_BSD_LS="$fake_bin/ls" \
  VAULTLOCK_TEST_BSD_STAT="$fake_bin/stat" \
  VAULTLOCK_TEST_PS="$fake_bin/ps" \
  VAULTLOCK_TEST_OPENSSL="$fake_bin/openssl" \
  VAULTLOCK_TEST_MKDIR="$fake_bin/mkdir" \
  VAULTLOCK_TEST_MKTEMP="$fake_bin/mktemp" \
  VAULTLOCK_TEST_LN="$fake_bin/ln" \
  VAULTLOCK_TEST_MV="$fake_bin/mv" \
  VAULTLOCK_TEST_RM="$fake_bin/rm" \
  VAULTLOCK_TEST_RMDIR="$fake_bin/rmdir" \
  VAULTLOCK_TEST_CHMOD="$fake_bin/chmod" \
  VAULTLOCK_TEST_TRANSITION="$fake_bin/transition-fixture" \
  VAULTLOCK_TEST_ACTION_LOG="$action_log" \
  VAULTLOCK_TEST_MUTATION_LOG="$mutation_log" \
  VAULTLOCK_TEST_HOOK_LOG="$hook_log" \
  VAULTLOCK_TEST_APFS_STATE="$apfs_state" \
  /bin/bash "$VL" "$@"
}

start_vaultlock_background() { # output command...
  local output=$1
  shift
  /usr/bin/env \
    "HOME=$test_home" \
    "PATH=$fake_bin" \
    "VAULTLOCK_STATE_DIR=$state_dir" \
    "VAULTLOCK_MOUNT_POINT=$mount_point" \
    "VAULTLOCK_MOUNT_COMMAND=$fake_bin/mount-fixture" \
    "VAULTLOCK_CONFIRM_DEVICE=$confirm_device" \
    "VAULTLOCK_TEST_FAKE_SYSTEM=1" \
    "VAULTLOCK_TEST_FAKE_BIN=$fake_bin" \
    "VAULTLOCK_TEST_DITTO=$fake_bin/ditto" \
    "VAULTLOCK_TEST_BSD_FIND=$fake_bin/find" \
    "VAULTLOCK_TEST_BSD_LS=$fake_bin/ls" \
    "VAULTLOCK_TEST_BSD_STAT=$fake_bin/stat" \
    "VAULTLOCK_TEST_PS=$fake_bin/ps" \
    "VAULTLOCK_TEST_OPENSSL=$fake_bin/openssl" \
    "VAULTLOCK_TEST_MKDIR=$fake_bin/mkdir" \
    "VAULTLOCK_TEST_MKTEMP=$fake_bin/mktemp" \
    "VAULTLOCK_TEST_LN=$fake_bin/ln" \
    "VAULTLOCK_TEST_MV=$fake_bin/mv" \
    "VAULTLOCK_TEST_RM=$fake_bin/rm" \
    "VAULTLOCK_TEST_RMDIR=$fake_bin/rmdir" \
    "VAULTLOCK_TEST_CHMOD=$fake_bin/chmod" \
    "VAULTLOCK_TEST_TRANSITION=$fake_bin/transition-fixture" \
    "VAULTLOCK_TEST_ACTION_LOG=$action_log" \
    "VAULTLOCK_TEST_MUTATION_LOG=$mutation_log" \
    "VAULTLOCK_TEST_HOOK_LOG=$hook_log" \
    "VAULTLOCK_TEST_APFS_STATE=$apfs_state" \
    /bin/bash "$VL" "$@" > "$output" 2>&1 &
  BACKGROUND_VAULTLOCK_PID=$!
}

wait_for_fixture() { # path
  local path=$1 attempts=0
  while [[ ! -e "$path" && "$attempts" -lt 500 ]]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  [[ -e "$path" ]]
}

run_vaultlock_with_gnu_path() {
  HOME="$test_home" \
  PATH="$gnu_bin:$fake_bin" \
  VAULTLOCK_STATE_DIR="$state_dir" \
  VAULTLOCK_MOUNT_POINT="$mount_point" \
  VAULTLOCK_MOUNT_COMMAND="$fake_bin/mount-fixture" \
  VAULTLOCK_CONFIRM_DEVICE="$confirm_device" \
  VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_FAKE_BIN="$fake_bin" \
  VAULTLOCK_TEST_DITTO="$fake_bin/ditto" \
  VAULTLOCK_TEST_GNU_PATH_DIR="$gnu_bin" \
  VAULTLOCK_TEST_BSD_FIND="$fake_bin/find" \
  VAULTLOCK_TEST_BSD_LS="$fake_bin/ls" \
  VAULTLOCK_TEST_BSD_STAT="$fake_bin/stat" \
  VAULTLOCK_TEST_PS="$fake_bin/ps" \
  VAULTLOCK_TEST_OPENSSL="$fake_bin/openssl" \
  VAULTLOCK_TEST_MKDIR="$fake_bin/mkdir" \
  VAULTLOCK_TEST_MKTEMP="$fake_bin/mktemp" \
  VAULTLOCK_TEST_LN="$fake_bin/ln" \
  VAULTLOCK_TEST_MV="$fake_bin/mv" \
  VAULTLOCK_TEST_RM="$fake_bin/rm" \
  VAULTLOCK_TEST_RMDIR="$fake_bin/rmdir" \
  VAULTLOCK_TEST_CHMOD="$fake_bin/chmod" \
  VAULTLOCK_TEST_TRANSITION="$fake_bin/transition-fixture" \
  VAULTLOCK_TEST_ACTION_LOG="$action_log" \
  VAULTLOCK_TEST_MUTATION_LOG="$mutation_log" \
  VAULTLOCK_TEST_HOOK_LOG="$hook_log" \
  VAULTLOCK_TEST_APFS_STATE="$apfs_state" \
  /bin/bash "$VL" "$@"
}

run_vaultlock_with_stdin() { # input command...
  local input=$1
  shift
  printf '%s\n' "$input" | HOME="$test_home" \
  PATH="$fake_bin" \
  VAULTLOCK_STATE_DIR="$state_dir" \
  VAULTLOCK_MOUNT_POINT="$mount_point" \
  VAULTLOCK_MOUNT_COMMAND="$fake_bin/mount-fixture" \
  VAULTLOCK_CONFIRM_DEVICE="$confirm_device" \
  VAULTLOCK_TEST_FAKE_SYSTEM=1 \
  VAULTLOCK_TEST_FAKE_BIN="$fake_bin" \
  VAULTLOCK_TEST_DITTO="$fake_bin/ditto" \
  VAULTLOCK_TEST_BSD_FIND="$fake_bin/find" \
  VAULTLOCK_TEST_BSD_LS="$fake_bin/ls" \
  VAULTLOCK_TEST_BSD_STAT="$fake_bin/stat" \
  VAULTLOCK_TEST_PS="$fake_bin/ps" \
  VAULTLOCK_TEST_OPENSSL="$fake_bin/openssl" \
  VAULTLOCK_TEST_MKDIR="$fake_bin/mkdir" \
  VAULTLOCK_TEST_MKTEMP="$fake_bin/mktemp" \
  VAULTLOCK_TEST_LN="$fake_bin/ln" \
  VAULTLOCK_TEST_MV="$fake_bin/mv" \
  VAULTLOCK_TEST_RM="$fake_bin/rm" \
  VAULTLOCK_TEST_RMDIR="$fake_bin/rmdir" \
  VAULTLOCK_TEST_CHMOD="$fake_bin/chmod" \
  VAULTLOCK_TEST_TRANSITION="$fake_bin/transition-fixture" \
  VAULTLOCK_TEST_ACTION_LOG="$action_log" \
  VAULTLOCK_TEST_MUTATION_LOG="$mutation_log" \
  VAULTLOCK_TEST_HOOK_LOG="$hook_log" \
  VAULTLOCK_TEST_APFS_STATE="$apfs_state" \
  /bin/bash "$VL" "$@"
}

run_vaultlock_tty_yes() {
  { /bin/sleep 0.2; printf 'yes\n'; /bin/sleep 0.1; } \
    | /usr/bin/script -q /dev/null /usr/bin/env \
    "HOME=$test_home" \
    "PATH=$fake_bin" \
    "VAULTLOCK_STATE_DIR=$state_dir" \
    "VAULTLOCK_MOUNT_POINT=$mount_point" \
    "VAULTLOCK_MOUNT_COMMAND=$fake_bin/mount-fixture" \
    "VAULTLOCK_CONFIRM_DEVICE=/dev/tty" \
    "VAULTLOCK_TEST_FAKE_SYSTEM=1" \
    "VAULTLOCK_TEST_FAKE_BIN=$fake_bin" \
    "VAULTLOCK_TEST_DITTO=$fake_bin/ditto" \
    "VAULTLOCK_TEST_BSD_FIND=$fake_bin/find" \
    "VAULTLOCK_TEST_BSD_LS=$fake_bin/ls" \
    "VAULTLOCK_TEST_BSD_STAT=$fake_bin/stat" \
    "VAULTLOCK_TEST_PS=$fake_bin/ps" \
    "VAULTLOCK_TEST_OPENSSL=$fake_bin/openssl" \
    "VAULTLOCK_TEST_MKDIR=$fake_bin/mkdir" \
    "VAULTLOCK_TEST_MKTEMP=$fake_bin/mktemp" \
    "VAULTLOCK_TEST_LN=$fake_bin/ln" \
    "VAULTLOCK_TEST_MV=$fake_bin/mv" \
    "VAULTLOCK_TEST_RM=$fake_bin/rm" \
    "VAULTLOCK_TEST_RMDIR=$fake_bin/rmdir" \
    "VAULTLOCK_TEST_CHMOD=$fake_bin/chmod" \
    "VAULTLOCK_TEST_TRANSITION=$fake_bin/transition-fixture" \
    "VAULTLOCK_TEST_ACTION_LOG=$action_log" \
    "VAULTLOCK_TEST_MUTATION_LOG=$mutation_log" \
    "VAULTLOCK_TEST_HOOK_LOG=$hook_log" \
    "VAULTLOCK_TEST_APFS_STATE=$apfs_state" \
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

operation_lock_dir=$test_home/.vaultlock-operation.lock
fake_process_start='Sun Aug 30 10:00:00 2026'
fake_operation_token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

create_operation_lock() { # pid start command token
  /bin/mkdir -m 700 "$operation_lock_dir"
  printf 'version=1\npid=%s\nstart=%s\ncommand=%s\ntoken=%s\n' \
    "$1" "$2" "$3" "$4" > "$operation_lock_dir/owner"
  /bin/chmod 600 "$operation_lock_dir/owner"
}

clear_operation_locks() {
  local path
  for path in "$operation_lock_dir" "$operation_lock_dir".quarantine.*; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    /bin/rm -f "$path/owner" "$path/owner.pre-transition"
    /bin/rmdir "$path"
  done
}

reset_operation_lock_fixture() {
  clear_operation_locks
  /bin/rm -f "$apfs_state/token_generated" \
    "$apfs_state/token_generated_twice" \
    "$apfs_state/ps_ambiguous" \
    "$apfs_state/ps_timezone_sensitive" \
    "$apfs_state/signal_ditto" \
    "$apfs_state/signal_operation_lock_mkdir" \
    "$apfs_state/signal_operation_owner_mktemp" \
    "$apfs_state/signal_operation_owner_unlink" \
    "$apfs_state/signal_operation_directory_remove" \
    "$apfs_state/signal_adopt_staged_link_creation" \
    "$apfs_state/signal_adopt_reservation_creation" \
    "$apfs_state/fail_operation_lock_identity_once" \
    "$apfs_state/fail_operation_lock_owner_install" \
    "$apfs_state/fail_operation_lock_release" \
    "$apfs_state/hold_ditto" \
    "$apfs_state/held_ditto_pid" \
    "$apfs_state/ditto_entered" \
    "$apfs_state/release_ditto" \
    "$apfs_state"/transition_*
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
  local sort_key stat_metadata acl
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
    stat_metadata=$(/usr/bin/stat -f \
      'uid=%u|gid=%g|mtime=%m|flags=%Sf' "$path")
    acl=$(/bin/ls -ldeb "$path" 2>/dev/null | /usr/bin/sed -n '2,$p')
    attributes=""
    while IFS= read -r attribute; do
      [[ -n "$attribute" ]] || continue
      attributes="$attributes$(printf '%q' "$attribute")="
      attributes="$attributes$(/usr/bin/xattr -px "$attribute" "$path" \
        | /usr/bin/tr -d '[:space:]');"
    done < <(/usr/bin/xattr "$path" 2>/dev/null | LC_ALL=C /usr/bin/sort)
    printf '%q|type=%s|mode=%s|%s|target=%q|sha256=%s|acl=%q|xattrs=%s\n' \
      "$relative" "$path_type" "$mode" "$stat_metadata" "$target" \
      "$hash" "$acl" "$attributes"
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

normalize_domain_plan_actions() {
  /usr/bin/awk '
    /Acquire cooperative operation lock/ { next }
    /Conditionally quarantine a verified stale operation lock/ { next }
    /Release cooperative operation lock/ { next }
    /^  [0-9]+[.] / {
      sub(/^  [0-9]+[.] /, "")
      count += 1
      printf "  %d. %s\n", count, $0
      next
    }
    { print }
  '
}

check_plan_coordination() { # description plan
  local description=$1 plan=$2
  check_contains "$description plans operation-lock acquisition" \
    "Acquire cooperative operation lock at $operation_lock_dir" "$plan"
  check_contains "$description plans verified stale-lock quarantine" \
    "Conditionally quarantine a verified stale operation lock" "$plan"
  check_contains "$description plans operation-lock release" \
    "Release cooperative operation lock" "$plan"
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
/usr/bin/touch -t 202001020304 "$manifest_probe/file"
check_manifest_changed "tree manifest detects touch" \
  "$manifest_before" "$manifest_probe"
manifest_before=$(tree_manifest "$manifest_probe")
mkdir "$manifest_probe/new-empty"
check_manifest_changed "tree manifest detects empty directory creation" \
  "$manifest_before" "$manifest_probe"
manifest_metadata=$(tree_manifest "$manifest_probe")
check_contains "tree manifest records uid" '|uid=' "$manifest_metadata"
check_contains "tree manifest records gid" '|gid=' "$manifest_metadata"
check_contains "tree manifest records mtime" '|mtime=' "$manifest_metadata"
check_contains "tree manifest records file flags" '|flags=' "$manifest_metadata"
check_contains "tree manifest records ACL representation" \
  '|acl=' "$manifest_metadata"

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
check_plan_coordination "lock dry-run" "$lock_plan"
lock_actions=$(sed -n '/^Actions:$/,/^Confirmation:/p' <<< "$lock_plan" \
  | normalize_domain_plan_actions)
expected_lock_actions=$(cat <<EOF | normalize_domain_plan_actions
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
check_plan_coordination "unlock dry-run" "$unlock_plan"
unlock_order=$(printf '%s\n' "$unlock_plan" \
  | grep -E 'pre-unlock|Decrypt|Verify the decrypted|Unlock the expected|Verify the mounted|Write the verified|Update the keychain|record the unlocked|Defer discovery|post-unlock|cooperative operation lock' \
  | normalize_domain_plan_actions \
  || true)
quoted_pre_hook=$(printf '%q' "$state_dir/hooks/pre-unlock.d/10-pre hook")
quoted_post_hook=$(printf '%q' "$state_dir/hooks/post-unlock.d/20-post hook")
quoted_mount_point=$(printf '%q' "$mount_point")
quoted_state_dir=$(printf '%q' "$state_dir")
quoted_state_file=$(printf '%q' "$state_dir/state.json")
expected_unlock_order=$(cat <<EOF | normalize_domain_plan_actions
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
  | normalize_domain_plan_actions \
  || true)
quoted_post_hook=$(printf '%q' "$state_dir/hooks/post-unlock.d/20-post hook")
expected_repair_unlock_order=$(cat <<EOF | normalize_domain_plan_actions
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
  | normalize_domain_plan_actions \
  || true)
expected_repair_no_hooks_order=$(cat <<EOF | normalize_domain_plan_actions
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
check_count "usable unlock no-hooks reports disabled hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$usable_unlock_plan"
check_contains "usable unlock verifies target" \
  'Verify the unlocked and mounted target state' "$usable_unlock_plan"
usable_unlock_hooks_plan=$(run_vaultlock unlock --dry-run)
check_count "usable unlock plans no hook execution" 0 \
  'Run hook ' "$usable_unlock_hooks_plan"
check_count "usable unlock plans no deferred hook discovery" 0 \
  'hook discovery' "$usable_unlock_hooks_plan"

write_json_state false null null null UUID-123
write_apfs_state false false UUID-123 disk9s1
printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
rm -f "$state_dir/passphrase.sha256" "$state_dir/passphrase.tle"
unmounted_unlock_plan=$(run_vaultlock unlock --dry-run --no-hooks)
check_count "unmounted unlock no-hooks reports disabled hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$unmounted_unlock_plan"
check_contains "unmounted unlock repair verifies target" \
  'Verify the unlocked and mounted target state' "$unmounted_unlock_plan"
unmounted_unlock_hooks_plan=$(run_vaultlock unlock --dry-run)
check_count "unmounted unlock repair plans no hook execution" 0 \
  'Run hook ' "$unmounted_unlock_hooks_plan"
check_count "unmounted unlock repair plans no deferred hook discovery" 0 \
  'hook discovery' "$unmounted_unlock_hooks_plan"

write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
rm -f "$apfs_state/mount_point" "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s\n' "$fake_ciphertext" > "$state_dir/passphrase.tle"
locked_unlock_no_hooks=$(run_vaultlock unlock --dry-run --no-hooks)
check_count "recorded-locked unlock disables hooks exactly once" 1 \
  'Hooks disabled by --no-hooks' "$locked_unlock_no_hooks"

# Init and adopt use the same typed planner as lock and unlock.
rm -f "$state_dir/state.json" "$state_dir/passphrase.txt" \
  "$state_dir/passphrase.sha256" "$state_dir/passphrase.tle" \
  "$apfs_state/locked" "$apfs_state/mounted" "$apfs_state/uuid" \
  "$apfs_state/device" "$apfs_state/mount_point"
: > "$action_log"
: > "$mutation_log"

for init_preflight_command in security sudo head base64 mktemp; do
  mv "$fake_bin/$init_preflight_command" \
    "$fake_bin/$init_preflight_command.missing"
  : > "$mutation_log"
  if init_preflight_output=$(run_vaultlock init --dry-run 2>&1); then
    record_failure "init preflights missing $init_preflight_command"
  else
    check_contains "init missing $init_preflight_command reports dependency" \
      "$init_preflight_command is required" "$init_preflight_output"
  fi
  check_count "init missing $init_preflight_command renders no plan" 0 \
    'Vaultlock plan:' "$init_preflight_output"
  check_empty "init missing $init_preflight_command performs no mutation" \
    "$mutation_log"
  mv "$fake_bin/$init_preflight_command.missing" \
    "$fake_bin/$init_preflight_command"
done

: > "$mutation_log"
if unsafe_user_output=$(USER='unsafe user' run_vaultlock init --dry-run 2>&1); then
  record_failure "init preflights unsafe USER"
else
  check_contains "init unsafe USER reports token" \
    'USER is missing or unsafe' "$unsafe_user_output"
fi
check_count "init unsafe USER renders no plan" 0 \
  'Vaultlock plan:' "$unsafe_user_output"
check_empty "init unsafe USER performs no mutation" "$mutation_log"

: > "$mutation_log"
if unsafe_service_output=$(VAULTLOCK_VOLUME='unsafe volume' \
    run_vaultlock init --dry-run 2>&1); then
  record_failure "init preflights unsafe keychain service"
else
  check_contains "init unsafe keychain service reports token" \
    'keychain service is unsafe' "$unsafe_service_output"
fi
check_count "init unsafe service renders no plan" 0 \
  'Vaultlock plan:' "$unsafe_service_output"
check_empty "init unsafe service performs no mutation" "$mutation_log"

rm -f "$apfs_state/keychain_marker"
if keychain_helper_output=$(run_vaultlock_with_stdin QUJDRA== \
    __keychain_store 2>&1); then
  :
else
  record_failure "generic keychain helper works without init globals"
fi
[[ -f "$apfs_state/keychain_marker" ]] \
  || record_failure "generic keychain helper reaches security stdin path"
check_count "generic keychain helper exposes no init identity error" 0 \
  'state directory identity' "$keychain_helper_output"
rm -f "$apfs_state/keychain_marker"
: > "$mutation_log"

init_plan=$(run_vaultlock init --dry-run)
check_plan_coordination "init dry-run" "$init_plan"
init_actions=$(printf '%s\n' "$init_plan" | grep -E '^  [0-9]+\. ' \
  | normalize_domain_plan_actions || true)
expected_init_actions=$(cat <<'EOF' | normalize_domain_plan_actions
  1. Prepare protected state and generate recovery material
  2. Store recovery material in the keychain and create the encrypted APFS volume
  3. Discover the new volume identity and write initial unlocked state
EOF
)
check "init dry-run ordered actions" "$expected_init_actions" "$init_actions"
check_line "init dry-run reports inspected absent state" \
  'Recorded: absent (init preflight)' "$init_plan"
check_line "init dry-run reports inspected absent APFS volume" \
  'APFS: absent (no volume named vault)' "$init_plan"
check_line "init dry-run reports absent mount" \
  "Mount: expected $mount_point, actual not mounted" "$init_plan"
check_line "init dry-run requires confirmation" \
  '  Required before normal execution changes the vault' "$init_plan"
check "init dry-run final result" 'Result: no changes made' \
  "$(printf '%s\n' "$init_plan" | tail -1)"
check_empty "init dry-run mutation log" "$mutation_log"
[[ ! -e "$state_dir/state.json" && ! -e "$state_dir/passphrase.txt" ]] \
  || record_failure "init dry-run leaves state absent"

: > "$mutation_log"
if init_declined=$(run_vaultlock init 2>&1); then
  record_failure "init decline exits nonzero"
else
  check_contains "init decline reports cancellation" \
    'cancelled, no changes made' "$init_declined"
fi
check_contains "init decline renders full plan" \
  'Discover the new volume identity and write initial unlocked state' \
  "$init_declined"
check "init decline plan matches dry-run" \
  "$(printf '%s\n' "$init_plan" | sed '$d')" \
  "$(printf '%s\n' "$init_declined" | sed '$d')"
check_empty "init decline mutation log" "$mutation_log"
[[ ! -e "$state_dir/state.json" && ! -e "$state_dir/passphrase.txt" ]] \
  || record_failure "init decline leaves state absent"

: > "$action_log"
: > "$mutation_log"
init_success=$(run_vaultlock init --yes 2>&1)
check_contains "init yes reports result" 'Result: created encrypted volume vault' \
  "$init_success"
check "init yes writes unlocked UUID" UUID-INIT \
  "$(jq -r '.volume_uuid' "$state_dir/state.json")"
check "init yes writes unlocked state" false \
  "$(jq -r '.locked' "$state_dir/state.json")"
[[ ! -e "$apfs_state/unsupported_add_volume_plist" ]] \
  || record_failure "init addVolume avoids unsupported -plist option"
init_add_volume_actions=$(grep 'diskutil apfs addVolume' "$action_log")
check_count "init addVolume command omits unsupported -plist option" 0 \
  ' -plist' "$init_add_volume_actions"
check_contains "init verifies created device through supported plist info" \
  'diskutil info -plist disk8s1' "$(< "$action_log")"
[[ -s "$state_dir/passphrase.txt" ]] \
  || record_failure "init yes preserves protected plaintext recovery"
[[ -f "$apfs_state/keychain_marker" ]] \
  || record_failure "init yes stores keychain item through fake stdin"
check_contains "init invokes only security interactive mode" 'security -i' \
  "$(< "$action_log")"
check_count "init never passes keychain secret in argv" 0 \
  'security add-generic-password' "$(< "$action_log")"
generated_secret=$(< "$state_dir/passphrase.txt")
check_count "init secret absent from output" 0 "$generated_secret" "$init_success"
check_count "init secret absent from audit" 0 "$generated_secret" "$(< "$action_log")"
check_count "init secret absent from mutations" 0 "$generated_secret" "$(< "$mutation_log")"
check_count "init secret absent from hooks" 0 "$generated_secret" "$(< "$hook_log")"

write_json_state false null null null UUID-INIT
write_apfs_state false true UUID-INIT disk8s1
adopt_source="$test_root/source directory"
mkdir -p "$adopt_source"
printf 'payload\n' > "$adopt_source/file with spaces"
adopt_source_resolved="$(cd -P "$(dirname "$adopt_source")" && pwd -P)/$(basename "$adopt_source")"

mv "$fake_bin/ditto" "$fake_bin/ditto.missing"
: > "$mutation_log"
if adopt_ditto_preflight_output=$(run_vaultlock adopt --dry-run \
    "$adopt_source" 2>&1); then
  record_failure "adopt preflights missing ditto"
else
  check_contains "adopt missing ditto reports dependency" \
    'ditto is required' "$adopt_ditto_preflight_output"
fi
check_count "adopt missing ditto renders no plan" 0 \
  'Vaultlock plan:' "$adopt_ditto_preflight_output"
check_empty "adopt missing ditto performs no mutation" "$mutation_log"
mv "$fake_bin/ditto.missing" "$fake_bin/ditto"

rm -f "$apfs_state/gnu_path_tool_called"
if gnu_path_adopt_output=$(run_vaultlock_with_gnu_path adopt --dry-run \
    "$adopt_source" 2>&1); then
  :
else
  record_failure "adopt uses explicit BSD find and stat: ${gnu_path_adopt_output//$'\n'/ | }"
fi
[[ ! -e "$apfs_state/gnu_path_tool_called" ]] \
  || record_failure "adopt bypasses incompatible PATH find and stat"

: > "$mutation_log"
adopt_plan=$(run_vaultlock adopt --dry-run "$adopt_source")
check_plan_coordination "adopt dry-run" "$adopt_plan"
check_contains "adopt dry-run plans copy" \
  "Copy $adopt_source_resolved to $mount_point/source directory" "$adopt_plan"
check_contains "adopt dry-run plans verification" \
  'Verify copied data, source identity, and mounted vault identity' "$adopt_plan"
check_contains "adopt dry-run plans staged replacement" \
  "Replace $adopt_source_resolved with a verified symlink using a staged backup" \
  "$adopt_plan"
check_empty "adopt dry-run mutation log" "$mutation_log"
[[ -d "$adopt_source" && ! -L "$adopt_source" ]] \
  || record_failure "adopt dry-run preserves source directory"

: > "$mutation_log"
if adopt_declined=$(run_vaultlock adopt "$adopt_source" 2>&1); then
  record_failure "adopt decline exits nonzero"
else
  check_contains "adopt decline reports cancellation" \
    'cancelled, no changes made' "$adopt_declined"
fi
check_contains "adopt decline renders staged replacement" \
  'with a verified symlink using a staged backup' "$adopt_declined"
check "adopt decline plan matches dry-run" \
  "$(printf '%s\n' "$adopt_plan" | sed '$d')" \
  "$(printf '%s\n' "$adopt_declined" | sed '$d')"
check_empty "adopt decline mutation log" "$mutation_log"
[[ -d "$adopt_source" && ! -L "$adopt_source" ]] \
  || record_failure "adopt decline preserves source directory"

: > "$mutation_log"
if adopt_success=$(run_vaultlock adopt --yes "$adopt_source" 2>&1); then
  :
else
  record_failure "adopt yes exits successfully: ${adopt_success//$'\n'/ | }"
fi
check_contains "adopt yes reports result" 'Result: adopted' "$adopt_success"
[[ -L "$adopt_source_resolved" ]] \
  || record_failure "adopt yes replaces source with symlink"
check "adopt yes symlink target" "$mount_point/source directory" \
  "$(readlink "$adopt_source_resolved")"
check "adopt yes preserves copied payload" payload \
  "$(< "$mount_point/source directory/file with spaces")"
check_count "adopt yes leaves no backup" 0 '.vaultlock-backup.' \
  "$(find "$(dirname "$adopt_source_resolved")" -maxdepth 1 -print)"

reset_adopt_fixture() {
  : > "$mutation_log"
  : > "$action_log"
  : > "$hook_log"
  rm -f "$apfs_state/fail_ditto" "$apfs_state/add_copy_entry" \
    "$apfs_state/modify_source_after_copy" \
    "$apfs_state/drop_copy_mtime" "$apfs_state/drop_copy_flags" \
    "$apfs_state/drop_copy_xattrs" "$apfs_state/drop_copy_owner_metadata" \
    "$apfs_state/drop_copy_acl" "$apfs_state/break_copy_hardlink" \
    "$apfs_state/normalize_copy_directory_metadata" \
    "$apfs_state/drop_copy_birthtime" \
    "$apfs_state/count_directory_traversals" \
    "$apfs_state/directory_traversal_count" \
    "$apfs_state/rename_copy_trailing_newline" \
    "$apfs_state/source_compressed_flags" \
    "$apfs_state/source_immutable_flags" \
    "$apfs_state/source_append_flags" \
    "$apfs_state/replace_source_entry_before_backup_move" \
    "$apfs_state/foreign_device_after_backup_quarantine" \
    "$apfs_state/swap_backup_at_quarantine_boundary" \
    "$apfs_state/adopt_backup_quarantined" \
    "$apfs_state/insert_directory_after_file_cleanup" \
    "$apfs_state/fail_staged_link_cleanup" \
    "$apfs_state/swap_mount_uuid_after_copy" \
    "$apfs_state/swap_mount_device_after_copy" \
    "$apfs_state/transition_adopt_copy_before_source_identity_check" \
    "$apfs_state/transition_adopt_verify_before_destination_identity_check" \
    "$apfs_state/named_source_identity_swap" \
    "$apfs_state/named_destination_identity_swap" \
    "$apfs_state/fail_ln" \
    "$apfs_state/swap_backup_identity" "$apfs_state/adopt_link_move_failed" \
    "$apfs_state/race_source_symlink_on_link_move_failure" \
    "$apfs_state/swap_restored_identity" "$apfs_state/rollback_moved" \
    "$apfs_state/fail_link_verification" \
    "$apfs_state/fail_backup_move" "$apfs_state/fail_link_move" \
    "$apfs_state/fail_rollback_move" "$apfs_state/fail_cleanup" \
    "$apfs_state/copy_complete" \
    "$apfs_state/signal_adopt_backup_manifest" \
    "$apfs_state/signal_adopt_staged_link_creation" \
    "$apfs_state/signal_adopt_reservation_creation" \
    "$apfs_state/gnu_path_tool_called"
  write_json_state false null null null UUID-INIT
  write_apfs_state false true UUID-INIT disk8s1
  printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
  rm -f "$state_dir/passphrase.tle" "$state_dir/passphrase.sha256"
}

new_adopt_source() { # name
  local case_source="$test_root/$1"
  rm -rf -- "${case_source:?}" "${mount_point:?}/$1"
  mkdir -p "$case_source/subdirectory"
  printf 'payload\n' > "$case_source/subdirectory/file"
  printf '%s\n' "$case_source"
}

expect_adopt_failure_preserves_source() { # description source expected
  local description=$1 source=$2 expected=$3 output before_identity before_manifest
  before_identity=$(/usr/bin/stat -f '%d:%i' "$source")
  before_manifest=$(tree_manifest "$source")
  if output=$(run_vaultlock adopt --yes "$source" 2>&1); then
    record_failure "$description exits nonzero"
  else
    check_contains "$description reports cause" "$expected" "$output"
  fi
  [[ -d "$source" && ! -L "$source" ]] \
    || record_failure "$description preserves real source"
  check "$description preserves source identity" "$before_identity" \
    "$(/usr/bin/stat -f '%d:%i' "$source")"
  check "$description preserves payload manifest" "$before_manifest" \
    "$(tree_manifest "$source")"
}

reset_adopt_fixture
staged_link_collision_source=$(new_adopt_source staged-link-collision)
ln -s "$test_root/missing-staged-target" \
  "$staged_link_collision_source.vaultlock-link"
expect_adopt_failure_preserves_source "adopt preflights staged link collision" \
  "$staged_link_collision_source" 'staging path already exists'
check_empty "adopt staged link collision copies nothing" "$mutation_log"

reset_adopt_fixture
backup_collision_source=$(new_adopt_source backup-collision)
mkdir -p "$backup_collision_source.vaultlock-backup"
expect_adopt_failure_preserves_source "adopt preflights backup collision" \
  "$backup_collision_source" 'backup path already exists'
check_empty "adopt backup collision copies nothing" "$mutation_log"

reset_adopt_fixture
destination_file_source=$(new_adopt_source destination-file)
printf 'occupied\n' > "$mount_point/destination-file"
expect_adopt_failure_preserves_source "adopt rejects destination file" \
  "$destination_file_source" 'already exists'

reset_adopt_fixture
destination_directory_source=$(new_adopt_source destination-directory)
mkdir -p "$mount_point/destination-directory"
expect_adopt_failure_preserves_source "adopt rejects destination directory" \
  "$destination_directory_source" 'already exists'

reset_adopt_fixture
dangling_destination_source=$(new_adopt_source dangling-destination)
ln -s "$test_root/missing-target" "$mount_point/dangling-destination"
expect_adopt_failure_preserves_source "adopt rejects dangling destination" \
  "$dangling_destination_source" 'already exists'

reset_adopt_fixture
symlink_target=$(new_adopt_source symlink-target)
symlink_source="$test_root/source-leaf-symlink"
ln -s "$symlink_target" "$symlink_source"
if source_symlink_output=$(run_vaultlock adopt --dry-run "$symlink_source" 2>&1); then
  record_failure "adopt rejects source leaf symlink"
else
  check_contains "adopt source symlink reports real-directory requirement" \
    'is not a real directory' "$source_symlink_output"
fi

if empty_source_output=$(run_vaultlock adopt --dry-run '' 2>&1); then
  record_failure "adopt rejects empty source"
else
  check_contains "adopt empty source reports boundary" 'must not be empty or root' \
    "$empty_source_output"
fi
if root_source_output=$(run_vaultlock adopt --dry-run / 2>&1); then
  record_failure "adopt rejects root source"
else
  check_contains "adopt root source reports boundary" 'must not be empty or root' \
    "$root_source_output"
fi
if mount_root_output=$(run_vaultlock adopt --dry-run "$mount_point" 2>&1); then
  record_failure "adopt rejects exact mount root"
else
  check_contains "adopt mount root reports already on vault" 'already on the vault' \
    "$mount_root_output"
fi
mkdir -p "$mount_point/already-there"
if mount_descendant_output=$(run_vaultlock adopt --dry-run \
    "$mount_point/already-there" 2>&1); then
  record_failure "adopt rejects mount descendant"
else
  check_contains "adopt mount descendant reports already on vault" \
    'already on the vault' "$mount_descendant_output"
fi
control_source=$'control\nsource'
if control_output=$(run_vaultlock adopt --dry-run "$control_source" 2>&1); then
  record_failure "adopt rejects control characters"
else
  check_contains "adopt control character reports boundary" \
    'contains control characters' "$control_output"
fi

reset_adopt_fixture
copy_failure_source=$(new_adopt_source copy-failure)
: > "$apfs_state/fail_ditto"
expect_adopt_failure_preserves_source "adopt copy failure" \
  "$copy_failure_source" 'copy failed'
[[ -d "$mount_point/copy-failure" ]] \
  || record_failure "adopt copy failure leaves explicit partial copy"

reset_adopt_fixture
count_failure_source=$(new_adopt_source count-failure)
: > "$apfs_state/add_copy_entry"
expect_adopt_failure_preserves_source "adopt count mismatch" \
  "$count_failure_source" 'copy verification failed'

expect_adopt_manifest_loss() { # description source
  local description=$1 source=$2 output
  if output=$(run_vaultlock adopt --yes "$source" 2>&1); then
    record_failure "$description"
  else
    check_contains "$description reports copy verification" \
      'copy verification failed' "$output"
  fi
}

reset_adopt_fixture
dittonorsrc_source=$(new_adopt_source dittonorsrc-sabotage)
/usr/bin/xattr -wx com.apple.ResourceFork 000102 \
  "$dittonorsrc_source/subdirectory/file"
if dittonorsrc_output=$(DITTONORSRC=1 run_vaultlock adopt --yes \
    "$dittonorsrc_source" 2>&1); then
  :
else
  record_failure "adopt unsets inherited DITTONORSRC: ${dittonorsrc_output//$'\n'/ | }"
fi
dittonorsrc_resource_fork=$(/usr/bin/xattr -px com.apple.ResourceFork \
  "$mount_point/dittonorsrc-sabotage/subdirectory/file" 2>/dev/null \
  | tr -d '[:space:]') || dittonorsrc_resource_fork=""
check "adopt preserves resource fork with inherited DITTONORSRC" 000102 \
  "$dittonorsrc_resource_fork"

expect_adopt_precopy_manifest_refusal() { # description marker source
  local description=$1 marker=$2 source=$3 output
  [[ "$marker" == "-" ]] || : > "$apfs_state/$marker"
  if output=$(run_vaultlock adopt --yes "$source" 2>&1); then
    record_failure "$description"
  else
    check_contains "$description reports manifest refusal" \
      'cannot create stable source manifest' "$output"
  fi
  [[ ! -e "$apfs_state/copy_complete" \
      && ! -e "$mount_point/${source##*/}" ]] \
    || record_failure "$description copies nothing"
}

reset_adopt_fixture
compressed_flags_source=$(new_adopt_source compressed-flags)
expect_adopt_precopy_manifest_refusal "adopt rejects compressed source flags" \
  source_compressed_flags "$compressed_flags_source"

reset_adopt_fixture
immutable_flags_source=$(new_adopt_source immutable-flags)
expect_adopt_precopy_manifest_refusal "adopt rejects immutable source flags" \
  source_immutable_flags "$immutable_flags_source"

reset_adopt_fixture
append_flags_source=$(new_adopt_source append-flags)
expect_adopt_precopy_manifest_refusal "adopt rejects append-only source flags" \
  source_append_flags "$append_flags_source"

reset_adopt_fixture
external_hardlink_source=$(new_adopt_source external-hardlink)
/bin/ln "$external_hardlink_source/subdirectory/file" \
  "$test_root/external-hardlink-entry"
expect_adopt_precopy_manifest_refusal \
  "adopt rejects hardlinks outside the source tree" - \
  "$external_hardlink_source"

reset_adopt_fixture
trailing_newline_source=$(new_adopt_source trailing-newline-loss)
printf 'trailing newline path\n' > "$trailing_newline_source/"$'trailing\n'
: > "$apfs_state/rename_copy_trailing_newline"
expect_adopt_manifest_loss "adopt rejects copied trailing-newline path loss" \
  "$trailing_newline_source"

reset_adopt_fixture
mtime_loss_source=$(new_adopt_source mtime-loss)
: > "$apfs_state/drop_copy_mtime"
expect_adopt_manifest_loss "adopt rejects copied mtime loss" \
  "$mtime_loss_source"

reset_adopt_fixture
flags_loss_source=$(new_adopt_source flags-loss)
/usr/bin/chflags hidden "$flags_loss_source/subdirectory/file"
: > "$apfs_state/drop_copy_flags"
expect_adopt_manifest_loss "adopt rejects copied file flags loss" \
  "$flags_loss_source"

reset_adopt_fixture
xattr_loss_source=$(new_adopt_source xattr-loss)
/usr/bin/xattr -wx com.apple.ResourceFork 000102 \
  "$xattr_loss_source/subdirectory/file"
: > "$apfs_state/drop_copy_xattrs"
expect_adopt_manifest_loss "adopt rejects copied xattr loss" \
  "$xattr_loss_source"

reset_adopt_fixture
owner_loss_source=$(new_adopt_source owner-loss)
: > "$apfs_state/drop_copy_owner_metadata"
expect_adopt_manifest_loss "adopt rejects copied owner loss" \
  "$owner_loss_source"

reset_adopt_fixture
acl_loss_source=$(new_adopt_source acl-loss)
: > "$apfs_state/drop_copy_acl"
expect_adopt_manifest_loss "adopt rejects copied ACL loss" \
  "$acl_loss_source"

reset_adopt_fixture
hardlink_loss_source=$(new_adopt_source hardlink-loss)
/bin/ln "$hardlink_loss_source/subdirectory/file" \
  "$hardlink_loss_source/subdirectory/hardlink"
: > "$apfs_state/break_copy_hardlink"
expect_adopt_manifest_loss "adopt rejects copied hardlink topology loss" \
  "$hardlink_loss_source"

reset_adopt_fixture
source_content_change_source=$(new_adopt_source source-content-change)
: > "$apfs_state/modify_source_after_copy"
if source_content_change_output=$(run_vaultlock adopt --yes \
    "$source_content_change_source" 2>&1); then
  record_failure "adopt rejects source content change after copy"
else
  check_contains "adopt source content change reports manifest" \
    'source manifest changed after copy' "$source_content_change_output"
fi
[[ -d "$source_content_change_source" \
    && ! -L "$source_content_change_source" ]] \
  || record_failure "adopt source content change preserves source directory"

reset_adopt_fixture
same_count_replace_source=$(new_adopt_source same-count-replace)
: > "$apfs_state/replace_source_entry_before_backup_move"
if same_count_replace_output=$(run_vaultlock adopt --yes \
    "$same_count_replace_source" 2>&1); then
  record_failure "adopt rejects same-count replacement before backup move"
else
  check_contains "adopt same-count replacement reports retained backup" \
    'backup retained at' "$same_count_replace_output"
fi
same_count_backup_count=$(find "$test_root" -maxdepth 1 -type d \
  -name 'same-count-replace.vaultlock-backup*' | wc -l | tr -d ' ')
check "adopt same-count replacement retains backup" 1 \
  "$same_count_backup_count"

reset_adopt_fixture
source_swap_source=$(new_adopt_source source-swap)
printf 'adopt_source_identity_swap\n' \
  > "$apfs_state/transition_adopt_copy_before_source_identity_check"
expect_adopt_failure_preserves_source "adopt source identity swap" \
  "$source_swap_source" 'source identity changed'

reset_adopt_fixture
destination_swap_source=$(new_adopt_source destination-swap)
printf 'adopt_destination_identity_swap\n' \
  > "$apfs_state/transition_adopt_verify_before_destination_identity_check"
expect_adopt_failure_preserves_source "adopt destination identity swap" \
  "$destination_swap_source" 'destination identity changed'

reset_adopt_fixture
mount_uuid_swap_source=$(new_adopt_source mount-uuid-swap)
: > "$apfs_state/swap_mount_uuid_after_copy"
expect_adopt_failure_preserves_source "adopt mount UUID swap" \
  "$mount_uuid_swap_source" 'mounted vault identity changed'

reset_adopt_fixture
mount_device_swap_source=$(new_adopt_source mount-device-swap)
: > "$apfs_state/swap_mount_device_after_copy"
expect_adopt_failure_preserves_source "adopt mount device swap" \
  "$mount_device_swap_source" 'mounted vault identity changed'

reset_adopt_fixture
link_failure_source=$(new_adopt_source link-failure)
: > "$apfs_state/fail_ln"
expect_adopt_failure_preserves_source "adopt staged link failure" \
  "$link_failure_source" 'cannot stage replacement symlink'

reset_adopt_fixture
link_move_failure_source=$(new_adopt_source link-move-failure)
: > "$apfs_state/fail_link_move"
expect_adopt_failure_preserves_source "adopt link move rollback" \
  "$link_move_failure_source" 'original source restored'

reset_adopt_fixture
rollback_symlink_race_source=$(new_adopt_source rollback-symlink-race)
: > "$apfs_state/fail_link_move"
: > "$apfs_state/race_source_symlink_on_link_move_failure"
if rollback_symlink_race_output=$(run_vaultlock adopt --yes \
    "$rollback_symlink_race_source" 2>&1); then
  record_failure "adopt rollback refuses unowned source symlink"
else
  check_contains "adopt rollback race reports unverified source entry" \
    "unverified source entry retained at $rollback_symlink_race_source" \
    "$rollback_symlink_race_output"
  check_contains "adopt rollback race reports retained backup" \
    "backup retained at $rollback_symlink_race_source.vaultlock-backup" \
    "$rollback_symlink_race_output"
fi
[[ -L "$rollback_symlink_race_source" \
    && "$(readlink "$rollback_symlink_race_source")" \
      == "$apfs_state/unowned-link-target" \
    && -d "$rollback_symlink_race_source.vaultlock-backup" ]] \
  || record_failure "adopt rollback race retains replacement and backup"

reset_adopt_fixture
rollback_cleanup_source=$(new_adopt_source rollback-cleanup-reporting)
: > "$apfs_state/fail_link_move"
: > "$apfs_state/fail_staged_link_cleanup"
if rollback_cleanup_output=$(run_vaultlock adopt --yes \
    "$rollback_cleanup_source" 2>&1); then
  record_failure "adopt rollback cleanup failure exits nonzero"
else
  check_contains "adopt rollback cleanup reports restored source" \
    'original source restored' "$rollback_cleanup_output"
  check_contains "adopt rollback cleanup reports retained staged link" \
    "$rollback_cleanup_source.vaultlock-link" "$rollback_cleanup_output"
  check_count "adopt rollback cleanup omits absent backup claim" 0 \
    "data remains at $rollback_cleanup_source.vaultlock-backup" \
    "$rollback_cleanup_output"
fi
[[ -d "$rollback_cleanup_source" && ! -L "$rollback_cleanup_source" \
    && -L "$rollback_cleanup_source.vaultlock-link" \
    && ! -e "$rollback_cleanup_source.vaultlock-backup" ]] \
  || record_failure "adopt rollback cleanup retains actual restored locations"

reset_adopt_fixture
staged_cleanup_failure_source=$(new_adopt_source staged-cleanup-failure)
: > "$apfs_state/fail_backup_move"
: > "$apfs_state/fail_staged_link_cleanup"
if staged_cleanup_failure_output=$(run_vaultlock adopt --yes \
    "$staged_cleanup_failure_source" 2>&1); then
  record_failure "adopt staged-link cleanup failure exits nonzero"
else
  check_contains "adopt staged-link cleanup reports retained path" \
    "$staged_cleanup_failure_source.vaultlock-link" \
    "$staged_cleanup_failure_output"
fi
[[ -L "$staged_cleanup_failure_source.vaultlock-link" ]] \
  || record_failure "adopt staged-link cleanup retains failed link"

reset_adopt_fixture
cleanup_failure_source=$(new_adopt_source cleanup-failure)
: > "$apfs_state/fail_cleanup"
if cleanup_failure_output=$(run_vaultlock adopt --yes \
    "$cleanup_failure_source" 2>&1); then
  record_failure "adopt cleanup failure exits nonzero"
else
  check_contains "adopt cleanup failure reports retained quarantine" \
    'quarantine retained at' "$cleanup_failure_output"
fi
[[ -L "$cleanup_failure_source" ]] \
  || record_failure "adopt cleanup failure preserves installed symlink"
cleanup_backup_count=$(find "$test_root" -maxdepth 1 -type d \
  -name 'cleanup-failure.vaultlock-quarantine.*' | wc -l | tr -d ' ')
check "adopt cleanup failure retains one quarantine" 1 "$cleanup_backup_count"

reset_adopt_fixture
directory_insertion_source=$(new_adopt_source directory-insertion)
: > "$apfs_state/insert_directory_after_file_cleanup"
if directory_insertion_output=$(run_vaultlock adopt --yes \
    "$directory_insertion_source" 2>&1); then
  record_failure "adopt rejects directory insertion after file cleanup"
else
  check_contains "adopt directory insertion reports quarantine" \
    'quarantine retained at' "$directory_insertion_output"
fi
directory_insertion_quarantine=$(find "$test_root" -maxdepth 1 -type d \
  -name 'directory-insertion.vaultlock-quarantine.*' -print -quit)
[[ -n "$directory_insertion_quarantine" \
    && -d "$directory_insertion_quarantine/backup/inserted-after-file-cleanup" ]] \
  || record_failure "adopt directory insertion retains unexpected directory"

reset_adopt_fixture
foreign_device_source=$(new_adopt_source foreign-device)
: > "$apfs_state/foreign_device_after_backup_quarantine"
if foreign_device_output=$(run_vaultlock adopt --yes \
    "$foreign_device_source" 2>&1); then
  record_failure "adopt refuses foreign-device backup deletion"
else
  check_contains "adopt foreign-device cleanup reports quarantine" \
    'quarantine retained at' "$foreign_device_output"
fi
foreign_device_quarantine_count=$(find "$test_root" -maxdepth 1 -type d \
  -name 'foreign-device.vaultlock-quarantine.*' | wc -l | tr -d ' ')
check "adopt foreign-device cleanup retains quarantine" 1 \
  "$foreign_device_quarantine_count"

reset_adopt_fixture
backup_boundary_source=$(new_adopt_source backup-boundary-race)
: > "$apfs_state/swap_backup_at_quarantine_boundary"
if backup_boundary_output=$(run_vaultlock adopt --yes \
    "$backup_boundary_source" 2>&1); then
  record_failure "adopt rejects backup replacement at deletion boundary"
else
  check_contains "adopt backup boundary race reports quarantine" \
    'quarantine retained at' "$backup_boundary_output"
fi
backup_boundary_quarantine=$(find "$test_root" -maxdepth 1 -type d \
  -name 'backup-boundary-race.vaultlock-quarantine.*' -print -quit)
[[ -n "$backup_boundary_quarantine" \
    && -d "$backup_boundary_quarantine/owned-backup" \
    && -d "$backup_boundary_quarantine/backup" ]] \
  || record_failure "adopt backup boundary race retains both directories"

reset_adopt_fixture
backup_move_failure_source=$(new_adopt_source backup-move-failure)
: > "$apfs_state/fail_backup_move"
expect_adopt_failure_preserves_source "adopt backup move failure" \
  "$backup_move_failure_source" 'source remains unchanged'

reset_adopt_fixture
rollback_failure_source=$(new_adopt_source rollback-failure)
: > "$apfs_state/fail_link_move"
: > "$apfs_state/fail_rollback_move"
if rollback_failure_output=$(run_vaultlock adopt --yes \
    "$rollback_failure_source" 2>&1); then
  record_failure "adopt rollback failure exits nonzero"
else
  check_contains "adopt rollback failure reports backup" \
    'data remains at' "$rollback_failure_output"
fi
rollback_backup_count=$(find "$test_root" -maxdepth 1 -type d \
  -name 'rollback-failure.vaultlock-backup*' | wc -l | tr -d ' ')
check "adopt rollback failure retains one backup" 1 "$rollback_backup_count"

reset_adopt_fixture
backup_identity_swap_source=$(new_adopt_source backup-identity-swap)
: > "$apfs_state/fail_link_move"
: > "$apfs_state/swap_backup_identity"
if backup_identity_swap_output=$(run_vaultlock adopt --yes \
    "$backup_identity_swap_source" 2>&1); then
  record_failure "adopt backup identity swap exits nonzero"
else
  check_contains "adopt backup identity swap reports retained backup" \
    'backup retained at' "$backup_identity_swap_output"
fi
backup_identity_swap_count=$(find "$test_root" -maxdepth 1 -type d \
  -name 'backup-identity-swap.vaultlock-backup*' | wc -l | tr -d ' ')
check "adopt backup identity swap retains backup" 1 \
  "$backup_identity_swap_count"

reset_adopt_fixture
restored_identity_swap_source=$(new_adopt_source restored-identity-swap)
: > "$apfs_state/fail_link_move"
: > "$apfs_state/swap_restored_identity"
if restored_identity_swap_output=$(run_vaultlock adopt --yes \
    "$restored_identity_swap_source" 2>&1); then
  record_failure "adopt post-move identity mismatch exits nonzero"
else
  check_contains "adopt post-move identity mismatch reports retained backup" \
    'backup retained at' "$restored_identity_swap_output"
fi
restored_identity_backup_count=$(find "$test_root" -maxdepth 1 -type d \
  -name 'restored-identity-swap.vaultlock-backup*' | wc -l | tr -d ' ')
check "adopt post-move identity mismatch restores backup name" 1 \
  "$restored_identity_backup_count"

reset_adopt_fixture
link_verification_source=$(new_adopt_source link-verification-failure)
link_verification_identity=$(/usr/bin/stat -f '%d:%i' "$link_verification_source")
link_verification_manifest=$(tree_manifest "$link_verification_source")
: > "$apfs_state/fail_link_verification"
if link_verification_output=$(run_vaultlock adopt --yes \
    "$link_verification_source" 2>&1); then
  record_failure "adopt link verification failure exits nonzero"
else
  check_contains "adopt link verification failure reports rollback" \
    'original source restored' "$link_verification_output"
fi
check "adopt link verification rollback preserves source identity" \
  "$link_verification_identity" \
  "$(/usr/bin/stat -f '%d:%i' "$link_verification_source")"
check "adopt link verification rollback preserves payload manifest" \
  "$link_verification_manifest" "$(tree_manifest "$link_verification_source")"

reset_adopt_fixture
noninteractive_adopt_source=$(new_adopt_source noninteractive-adopt)
mv "$confirm_device" "$confirm_device.saved"
if noninteractive_adopt_output=$(run_vaultlock adopt \
    "$noninteractive_adopt_source" 2>&1); then
  record_failure "adopt noninteractive confirmation exits nonzero"
else
  check_contains "adopt noninteractive confirmation reports yes hint" \
    'rerun with --yes' "$noninteractive_adopt_output"
  check_contains "adopt noninteractive confirmation renders full plan" \
    'with a verified symlink using a staged backup' \
    "$noninteractive_adopt_output"
fi
mv "$confirm_device.saved" "$confirm_device"
[[ -d "$noninteractive_adopt_source" && ! -L "$noninteractive_adopt_source" ]] \
  || record_failure "adopt noninteractive confirmation preserves source"

reset_init_fixture() {
  local stale_quarantine
  for stale_quarantine in "$state_dir"/.state-quarantine.*; do
    [[ -d "$stale_quarantine" && ! -L "$stale_quarantine" ]] || continue
    rm -f "$stale_quarantine/state.json" \
      "$stale_quarantine/.cleanup-replacement"
    rmdir "$stale_quarantine"
  done
  rm -f "$state_dir/state.json" "$state_dir"/state.json.tmp.* \
    "$state_dir"/.passphrase.* "$state_dir"/.state.* \
    "$state_dir"/.security-output.* \
    "$state_dir/passphrase.txt" "$state_dir/passphrase-new.txt" \
    "$state_dir/passphrase.tle" "$state_dir/passphrase.sha256" \
    "$apfs_state/locked" "$apfs_state/mounted" "$apfs_state/uuid" \
    "$apfs_state/device" "$apfs_state/mount_point" \
    "$apfs_state/mount_point_type" "$apfs_state/plist_mode" \
    "$apfs_state/keychain_marker" "$apfs_state/fail_keychain" \
    "$apfs_state/fail_add_volume" "$apfs_state/fail_final_uuid"
  /bin/chmod -N "$state_dir"
  rm -f "$apfs_state/fail_diskutil_info" "$apfs_state/fail_apfs_list" \
    "$apfs_state/echo_security_error" \
    "$apfs_state/race_passphrase_symlink" \
    "$apfs_state/race_state_temp_symlink" \
    "$apfs_state/passphrase_redirect_target" \
    "$apfs_state/state_redirect_target"
  rm -f "$apfs_state/confirmation_race_kind"
  rm -f "$apfs_state/apfs_list_mode" \
    "$apfs_state/add_output_mode" \
    "$apfs_state/add_volume_complete" \
    "$apfs_state/recovery_boundary_race" \
    "$apfs_state/write_state_recovery_race" \
    "$apfs_state/modify_recovery_after_state" \
    "$apfs_state/swap_identity_after_state" \
    "$apfs_state/swap_state_inode_after_state" \
    "$apfs_state/swapped_state_identity" \
    "$apfs_state/remove_state_after_state" \
    "$apfs_state/fail_init_state_cleanup" \
    "$apfs_state/overwrite_state_after_install_identity" \
    "$apfs_state/state_link_installed" \
    "$apfs_state/state_install_inode_before_rewrite" \
    "$apfs_state/state_install_inode_after_rewrite" \
    "$apfs_state/overwrite_state_after_final_info" \
    "$apfs_state/final_info_complete" \
    "$apfs_state/state_inode_before_rewrite" \
    "$apfs_state/state_inode_after_rewrite" \
    "$apfs_state/transition_init_cleanup_before_state_quarantine_move" \
    "$apfs_state/transition_init_cleanup_after_state_quarantine_move" \
    "$apfs_state/make_quarantine_nonprivate_before_move" \
    "$apfs_state/quarantine_made_nonprivate" \
    "$apfs_state/quarantine_reprotected_mode" \
    "$apfs_state/cleanup_original_identity" \
    "$apfs_state/cleanup_replacement_identity" \
    "$apfs_state/security_output_artifact_seen" \
    "$apfs_state/inherit_recovery_acl" \
    "$apfs_state/fail_recovery_acl_removal" \
    "$apfs_state/swap_identity_after_add" \
    "$apfs_state/unsupported_add_volume_plist"
  : > "$action_log"
  : > "$mutation_log"
  : > "$hook_log"
}

run_init_confirmation_race() { # race_kind
  printf '%s\n' "$1" > "$apfs_state/confirmation_race_kind"
  if INIT_RACE_OUTPUT=$(run_vaultlock_tty_yes init 2>&1); then
    INIT_RACE_STATUS=0
  else
    INIT_RACE_STATUS=$?
  fi
}

reset_init_fixture
: > "$apfs_state/fail_apfs_list"
if inspection_failure_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects APFS inspection failure"
else
  check_contains "init APFS inspection failure reports inspection" \
    'cannot inspect APFS volumes' "$inspection_failure_output"
fi
check_empty "init APFS inspection failure performs no mutation" "$mutation_log"

reset_init_fixture
printf 'empty\n' > "$apfs_state/apfs_list_mode"
if empty_apfs_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects syntactically valid empty APFS plist"
else
  check_contains "init empty APFS plist reports invalid schema" \
    'invalid APFS list schema' "$empty_apfs_output"
fi
check_empty "init empty APFS plist performs no mutation" "$mutation_log"

reset_init_fixture
printf 'incomplete\n' > "$apfs_state/apfs_list_mode"
if incomplete_apfs_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects structurally incomplete APFS plist"
else
  check_contains "init incomplete APFS plist reports invalid schema" \
    'invalid APFS list schema' "$incomplete_apfs_output"
fi
check_empty "init incomplete APFS plist performs no mutation" "$mutation_log"

reset_init_fixture
printf 'missing_identity\n' > "$apfs_state/apfs_list_mode"
if missing_identity_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects vault record missing identity"
else
  check_contains "init missing volume identity reports invalid record" \
    'vault volume record missing UUID or device' "$missing_identity_output"
fi
check_empty "init missing volume identity performs no mutation" "$mutation_log"

for invalid_record_mode in empty_record scalar_record mistyped_name \
    mistyped_uuid mistyped_device; do
  reset_init_fixture
  printf '%s\n' "$invalid_record_mode" > "$apfs_state/apfs_list_mode"
  if invalid_record_output=$(run_vaultlock init --dry-run 2>&1); then
    record_failure "init rejects ${invalid_record_mode} APFS volume record"
  else
    check_contains "init ${invalid_record_mode} record reports invalid schema" \
      'invalid APFS list schema' "$invalid_record_output"
  fi
  check_empty "init ${invalid_record_mode} record performs no mutation" \
    "$mutation_log"
done

reset_init_fixture
printf 'valid_unrelated\n' > "$apfs_state/apfs_list_mode"
if ! valid_unrelated_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init accepts valid unrelated APFS volume record: $valid_unrelated_output"
fi
check_empty "init valid unrelated record performs no mutation" "$mutation_log"

reset_init_fixture
write_apfs_state false false UUID-UNMOUNTED disk7s3
if unmounted_conflict_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects unmounted existing volume"
else
  check_contains "init unmounted volume reports conflict" \
    'volume vault already exists' "$unmounted_conflict_output"
fi
check_empty "init unmounted volume performs no mutation" "$mutation_log"

reset_init_fixture
run_init_confirmation_race state
check "init revalidates state introduced at confirmation" 1 \
  "$((INIT_RACE_STATUS != 0))"
check_contains "init confirmation state race reports conflict" \
  'state already exists' "$INIT_RACE_OUTPUT"
check_empty "init confirmation state race performs no mutation" "$mutation_log"

reset_init_fixture
run_init_confirmation_race recovery
check "init revalidates recovery introduced at confirmation" 1 \
  "$((INIT_RACE_STATUS != 0))"
check_contains "init confirmation recovery race reports conflict" \
  'recovery artifacts already exist' "$INIT_RACE_OUTPUT"
check "init confirmation recovery race does not overwrite redirect" \
  'recovery sentinel' "$(< "$apfs_state/passphrase_redirect_target")"
check_empty "init confirmation recovery race performs no mutation" "$mutation_log"

reset_init_fixture
run_init_confirmation_race volume
check "init revalidates volume introduced at confirmation" 1 \
  "$((INIT_RACE_STATUS != 0))"
check_contains "init confirmation volume race reports conflict" \
  'volume vault already exists' "$INIT_RACE_OUTPUT"
check_empty "init confirmation volume race performs no mutation" "$mutation_log"

reset_init_fixture
printf 'modify\n' > "$apfs_state/recovery_boundary_race"
if recovery_modify_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects recovery content change between operations"
else
  check_contains "init recovery content race reports boundary change" \
    'installed recovery material changed before volume creation' \
    "$recovery_modify_output"
fi
[[ ! -e "$apfs_state/keychain_marker" && ! -e "$apfs_state/locked" ]] \
  || record_failure "init recovery content race stops before keychain and APFS"

reset_init_fixture
printf 'replace\n' > "$apfs_state/recovery_boundary_race"
if recovery_replace_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects recovery identity change between operations"
else
  check_contains "init recovery identity race reports boundary change" \
    'installed recovery material changed before volume creation' \
    "$recovery_replace_output"
fi
[[ ! -e "$apfs_state/keychain_marker" && ! -e "$apfs_state/locked" ]] \
  || record_failure "init recovery identity race stops before keychain and APFS"

reset_init_fixture
printf 'volume\n' > "$apfs_state/recovery_boundary_race"
if post_prepare_conflict_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects conflict introduced after recovery prep"
else
  check_contains "init post-prepare conflict reports existing volume" \
    'volume vault already exists' "$post_prepare_conflict_output"
fi
[[ ! -e "$apfs_state/keychain_marker" ]] \
  || record_failure "init post-prepare conflict stops before keychain"
check_count "init post-prepare conflict does not add volume" 0 \
  'diskutil apfs addVolume' "$(< "$mutation_log")"

for write_recovery_race in modify replace; do
  reset_init_fixture
  printf '%s\n' "$write_recovery_race" \
    > "$apfs_state/write_state_recovery_race"
  if write_recovery_output=$(run_vaultlock init --yes 2>&1); then
    record_failure "init rejects ${write_recovery_race} recovery race before state"
  else
    check_contains "init ${write_recovery_race} recovery race reports boundary change" \
      'installed recovery material changed before state creation' \
      "$write_recovery_output"
  fi
  [[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
      && -e "$apfs_state/locked" ]] \
    || record_failure "init ${write_recovery_race} recovery race stops before state mutation"
done

reset_init_fixture
printf 'passphrase sentinel\n' > "$apfs_state/passphrase_redirect_target"
: > "$apfs_state/race_passphrase_symlink"
if passphrase_race_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init passphrase symlink race exits nonzero"
else
  check_contains "init passphrase symlink race reports exclusive creation" \
    'recovery path appeared during initialization' "$passphrase_race_output"
fi
check "init passphrase symlink race does not overwrite redirect" \
  'passphrase sentinel' "$(< "$apfs_state/passphrase_redirect_target")"
[[ ! -e "$apfs_state/keychain_marker" && ! -e "$apfs_state/locked" ]] \
  || record_failure "init passphrase symlink race stops before keychain and APFS"

reset_init_fixture
printf 'state sentinel\n' > "$apfs_state/state_redirect_target"
: > "$apfs_state/race_state_temp_symlink"
if state_race_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init state staging symlink race exits nonzero"
else
  check_contains "init state staging symlink race reports exclusive creation" \
    'state staging path is unsafe' "$state_race_output"
fi
check "init state staging symlink race does not overwrite redirect" \
  'state sentinel' "$(< "$apfs_state/state_redirect_target")"
[[ -L "$state_dir/state.json" ]] \
  || record_failure "init state staging symlink race preserves untrusted collision"

reset_init_fixture
: > "$apfs_state/echo_security_error"
if security_echo_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init security echo failure exits nonzero"
else
  check_contains "init security echo failure reports generic keychain error" \
    'keychain storage failed' "$security_echo_output"
fi
security_echo_secret=$(< "$state_dir/passphrase.txt")
check_count "init security echo failure hides secret in output" 0 \
  "$security_echo_secret" "$security_echo_output"
check_count "init security echo failure hides secret in logs" 0 \
  "$security_echo_secret" "$(< "$action_log")$(< "$mutation_log")$(< "$hook_log")"
[[ ! -e "$apfs_state/security_output_artifact_seen" ]] \
  || record_failure "init security echo creates crash-persistent output artifact"
security_hidden_count=$(find "$state_dir" -maxdepth 1 \
  -name '.security-output.*' | wc -l | tr -d ' ')
check "init security echo leaves no hidden output artifact" 0 \
  "$security_hidden_count"
check_count "init security echo secret absent from state manifest" 0 \
  "$security_echo_secret" "$(tree_manifest "$state_dir")"

reset_init_fixture
: > "$apfs_state/modify_recovery_after_state"
if final_recovery_race_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init final verification rejects modified recovery"
else
  check_contains "init final recovery race reports verification failure" \
    'installed recovery material changed before final verification' \
    "$final_recovery_race_output"
fi
check_count "init final recovery race does not report success" 0 \
  'Result: created encrypted volume' "$final_recovery_race_output"
[[ ! -e "$state_dir/state.json" && ! -L "$state_dir/state.json" ]] \
  || record_failure "init final recovery race removes owned state"

reset_init_fixture
: > "$apfs_state/modify_recovery_after_state"
: > "$apfs_state/remove_state_after_state"
if absent_state_cleanup_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects final recovery change with already absent state"
else
  check_contains "init absent-state cleanup reports recovery change" \
    'installed recovery material changed before final verification' \
    "$absent_state_cleanup_output"
fi
check_count "init absent-state cleanup does not claim retained state" 0 \
  'installed state retained' "$absent_state_cleanup_output"
[[ ! -e "$state_dir/state.json" && ! -L "$state_dir/state.json" ]] \
  || record_failure "init absent-state cleanup leaves state absent"

reset_init_fixture
: > "$apfs_state/modify_recovery_after_state"
: > "$apfs_state/fail_init_state_cleanup"
if failed_state_cleanup_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects final recovery change when state cleanup fails"
else
  check_contains "init state cleanup failure reports deletion failure" \
    'installed state removal failed after ownership was proven' \
    "$failed_state_cleanup_output"
fi
failed_cleanup_retained_state=$(find "$state_dir" -type f \
  -path "$state_dir/.state-quarantine.*/state.json" -print -quit)
[[ -n "$failed_cleanup_retained_state" \
    && -f "$failed_cleanup_retained_state" \
    && ! -L "$failed_cleanup_retained_state" ]] \
  || record_failure "init state cleanup failure retains owned state"
check_contains "init state cleanup failure reports retained path" \
  "$failed_cleanup_retained_state" "$failed_state_cleanup_output"
check_count "init state cleanup failure does not report success" 0 \
  'Result: created encrypted volume' "$failed_state_cleanup_output"

reset_init_fixture
: > "$apfs_state/modify_recovery_after_state"
: > "$apfs_state/make_quarantine_nonprivate_before_move"
if nonprivate_quarantine_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects nonprivate state quarantine"
else
  check_contains "init nonprivate quarantine preserves primary failure" \
    'installed recovery material changed before final verification' \
    "$nonprivate_quarantine_output"
fi
quarantine_reprotected_mode=""
if [[ -f "$apfs_state/quarantine_reprotected_mode" ]]; then
  quarantine_reprotected_mode=$(< "$apfs_state/quarantine_reprotected_mode")
fi
check "init nonprivate quarantine is reprotected before cleanup" 700 \
  "$quarantine_reprotected_mode"
nonprivate_quarantine_count=$(find "$state_dir" -type d \
  -name '.state-quarantine.*' | wc -l | tr -d ' ')
check "init nonprivate quarantine cleanup removes quarantine" 0 \
  "$nonprivate_quarantine_count"
[[ ! -e "$state_dir/state.json" && ! -L "$state_dir/state.json" ]] \
  || record_failure "init nonprivate quarantine cleanup removes owned state"

reset_init_fixture
: > "$apfs_state/swap_identity_after_add"
if identity_swap_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects identity swap after addVolume"
else
  check_contains "init identity swap reports created identity mismatch" \
    'created APFS identity changed before state creation' \
    "$identity_swap_output"
fi
[[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
    && -e "$apfs_state/locked" ]] \
  || record_failure "init identity swap preserves recovery and orphan volume"
check "init identity swap preserves orphan UUID" UUID-AFTER-ADD-SWAP \
  "$(< "$apfs_state/uuid")"
check "init identity swap preserves orphan device" disk8s2 \
  "$(< "$apfs_state/device")"
check_count "init identity swap does not report success" 0 \
  'Result: created encrypted volume' "$identity_swap_output"

for add_output_mode in ambiguous malformed zero_disk zero_slice suffix letters; do
  reset_init_fixture
  printf '%s\n' "$add_output_mode" > "$apfs_state/add_output_mode"
  if add_output_failure=$(run_vaultlock init --yes 2>&1); then
    record_failure "init rejects ${add_output_mode} addVolume device output"
  else
    check_contains "init ${add_output_mode} addVolume output reports identity failure" \
      'APFS volume creation returned no unique device' \
      "$add_output_failure"
  fi
  [[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
      && -e "$apfs_state/locked" ]] \
    || record_failure "init ${add_output_mode} output preserves recovery and orphan volume"
done

reset_init_fixture
: > "$apfs_state/swap_identity_after_state"
if late_identity_swap_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects identity swap after state installation"
else
  check_contains "init late identity swap reports final verification failure" \
    'created vault failed usable-target verification' \
    "$late_identity_swap_output"
fi
[[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
    && -e "$apfs_state/locked" ]] \
  || record_failure "init late identity swap removes owned state and preserves orphan"
check_count "init late identity swap does not report success" 0 \
  'Result: created encrypted volume' "$late_identity_swap_output"

reset_init_fixture
: > "$apfs_state/swap_state_inode_after_state"
if state_inode_swap_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects identical-content state inode swap"
else
  check_contains "init state inode swap reports identity change" \
    'installed state identity changed before final verification' \
    "$state_inode_swap_output"
fi
[[ -f "$state_dir/state.json" && ! -L "$state_dir/state.json" ]] \
  || record_failure "init state inode swap preserves replacement file"
check "init state inode swap preserves replacement identity" \
  "$(< "$apfs_state/swapped_state_identity")" \
  "$(/usr/bin/stat -f '%d:%i' "$state_dir/state.json")"
check "init state inode swap preserves equivalent UUID content" UUID-INIT \
  "$(jq -r '.volume_uuid' "$state_dir/state.json")"
check_count "init state inode swap does not report success" 0 \
  'Result: created encrypted volume' "$state_inode_swap_output"

reset_init_fixture
: > "$apfs_state/overwrite_state_after_install_identity"
if state_install_content_race_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects in-place rewrite before installed digest"
else
  check_contains "init installed-digest rewrite reports content change" \
    'installed state content changed during installation' \
    "$state_install_content_race_output"
  check_contains "init installed-digest rewrite reports retained state path" \
    "$state_dir/state.json" "$state_install_content_race_output"
fi
check "init installed-digest rewrite preserves inode during race" \
  "$(< "$apfs_state/state_install_inode_before_rewrite")" \
  "$(< "$apfs_state/state_install_inode_after_rewrite")"
check "init installed-digest rewrite retains altered state" \
  rewritten-before-installed-digest \
  "$(jq -r '.created' "$state_dir/state.json")"
check_count "init installed-digest rewrite does not report success" 0 \
  'Result: created encrypted volume' "$state_install_content_race_output"

reset_init_fixture
: > "$apfs_state/overwrite_state_after_final_info"
if state_content_race_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects in-place state rewrite after final APFS info"
else
  check_contains "init in-place state rewrite reports content change" \
    'installed state content changed before final verification' \
    "$state_content_race_output"
fi
check "init in-place rewrite preserves inode during race" \
  "$(< "$apfs_state/state_inode_before_rewrite")" \
  "$(< "$apfs_state/state_inode_after_rewrite")"
[[ -f "$state_dir/state.json" && ! -L "$state_dir/state.json" ]] \
  || record_failure "init in-place state rewrite retains changed state safely"
check_contains "init in-place state rewrite reports retained path" \
  "$state_dir/state.json" "$state_content_race_output"
check_count "init in-place state rewrite does not report success" 0 \
  'Result: created encrypted volume' "$state_content_race_output"

for cleanup_swap_phase in before after; do
  reset_init_fixture
  : > "$apfs_state/swap_identity_after_state"
  printf 'init_state_identity_swap\n' \
    > "$apfs_state/transition_init_cleanup_${cleanup_swap_phase}_state_quarantine_move"
  if cleanup_swap_output=$(run_vaultlock init --yes 2>&1); then
    record_failure "init rejects state swap ${cleanup_swap_phase} quarantine move"
  else
    check_contains "init ${cleanup_swap_phase}-move swap reports retained path" \
      "$state_dir/state.json" "$cleanup_swap_output"
  fi
  if [[ -f "$state_dir/state.json" && ! -L "$state_dir/state.json" ]]; then
    check "init ${cleanup_swap_phase}-move swap preserves replacement content" \
      '{"unowned":"cleanup replacement"}' \
      "$(< "$state_dir/state.json")"
    check "init ${cleanup_swap_phase}-move swap preserves replacement identity" \
      "$(< "$apfs_state/cleanup_replacement_identity")" \
      "$(/usr/bin/stat -f '%d:%i' "$state_dir/state.json")"
    [[ "$(< "$apfs_state/cleanup_original_identity")" \
        != "$(< "$apfs_state/cleanup_replacement_identity")" ]] \
      || record_failure "init ${cleanup_swap_phase}-move fixture replaces inode"
  else
    record_failure "init ${cleanup_swap_phase}-move swap preserves replacement"
  fi
  check_count "init ${cleanup_swap_phase}-move swap does not report success" 0 \
    'Result: created encrypted volume' "$cleanup_swap_output"
done

reset_init_fixture
printf '{}\n' > "$state_dir/state.json"
if existing_state_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects existing state"
else
  check_contains "init existing state reports conflict" 'state already exists' \
    "$existing_state_output"
fi
check_empty "init existing state performs no mutation" "$mutation_log"

reset_init_fixture
write_apfs_state false true UUID-CONFLICT disk7s1
if conflicting_volume_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects conflicting volume"
else
  check_contains "init conflicting volume reports conflict" 'already exists' \
    "$conflicting_volume_output"
fi
check_empty "init conflicting volume performs no mutation" "$mutation_log"

reset_init_fixture
printf 'old-recovery\n' > "$state_dir/passphrase.txt"
if existing_artifact_output=$(run_vaultlock init --dry-run 2>&1); then
  record_failure "init rejects preexisting recovery artifact"
else
  check_contains "init recovery artifact reports conflict" \
    'recovery artifacts already exist' "$existing_artifact_output"
fi
check_empty "init recovery artifact performs no mutation" "$mutation_log"

for hidden_family in passphrase state security-output; do
  reset_init_fixture
  hidden_artifact="$state_dir/.${hidden_family}.leftover"
  hidden_sentinel="hidden ${hidden_family} sentinel"
  printf '%s\n' "$hidden_sentinel" > "$hidden_artifact"
  if hidden_artifact_output=$(run_vaultlock init --dry-run 2>&1); then
    record_failure "init rejects hidden ${hidden_family} leftover"
  else
    check_contains "init hidden ${hidden_family} leftover reports artifact" \
      "unexpected init artifact exists: $hidden_artifact" \
      "$hidden_artifact_output"
  fi
  check "init hidden ${hidden_family} leftover remains unchanged" \
    "$hidden_sentinel" "$(< "$hidden_artifact")"
  check_empty "init hidden ${hidden_family} leftover performs no mutation" \
    "$mutation_log"
done

reset_init_fixture
: > "$apfs_state/fail_keychain"
if keychain_failure_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init keychain failure exits nonzero"
else
  check_contains "init keychain failure reports protected recovery" \
    'protected recovery material remains' "$keychain_failure_output"
fi
[[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
    && ! -e "$apfs_state/locked" ]] \
  || record_failure "init keychain failure preserves recovery without fake state"
keychain_failure_secret=$(< "$state_dir/passphrase.txt")
check_count "init keychain failure hides secret in output" 0 \
  "$keychain_failure_secret" "$keychain_failure_output"
check_count "init keychain failure hides secret in logs" 0 \
  "$keychain_failure_secret" "$(< "$action_log")$(< "$mutation_log")$(< "$hook_log")"

reset_init_fixture
: > "$apfs_state/fail_add_volume"
if add_failure_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init addVolume failure exits nonzero"
else
  check_contains "init addVolume failure reports protected recovery" \
    'protected recovery material remains' "$add_failure_output"
fi
[[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
    && ! -e "$apfs_state/locked" ]] \
  || record_failure "init addVolume failure preserves recovery without fake state"

reset_init_fixture
: > "$apfs_state/fail_final_uuid"
if uuid_failure_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init final UUID failure exits nonzero"
else
  check_contains "init final UUID failure reports protected recovery" \
    'cannot discover final APFS identity' "$uuid_failure_output"
fi
[[ -s "$state_dir/passphrase.txt" && ! -e "$state_dir/state.json" \
    && -e "$apfs_state/locked" ]] \
  || record_failure "init final UUID failure preserves recovery and orphan volume"

reset_init_fixture
mv "$confirm_device" "$confirm_device.saved"
if missing_confirmation_output=$(run_vaultlock init 2>&1); then
  record_failure "init missing confirmation device exits nonzero"
else
  check_contains "init missing confirmation device reports yes hint" \
    'rerun with --yes' "$missing_confirmation_output"
  check_contains "init missing confirmation device renders full plan" \
    'Discover the new volume identity and write initial unlocked state' \
    "$missing_confirmation_output"
fi
mv "$confirm_device.saved" "$confirm_device"
check_empty "init missing confirmation device performs no mutation" "$mutation_log"

# Cooperative operation lock and post-confirmation plan convergence.
reset_operation_lock_fixture
reset_init_fixture
run_vaultlock init --dry-run >/dev/null
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "init dry-run creates no operation lock"
[[ ! -e "$apfs_state/token_generated" ]] \
  || record_failure "init dry-run generates no operation token"

reset_operation_lock_fixture
reset_adopt_fixture
declined_lock_source=$(new_adopt_source operation-lock-declined)
if run_vaultlock adopt "$declined_lock_source" >/dev/null 2>&1; then
  record_failure "adopt operation-lock decline exits nonzero"
fi
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "adopt decline creates no operation lock"
[[ ! -e "$apfs_state/token_generated" ]] \
  || record_failure "adopt decline generates no operation token"

for locked_command in init adopt; do
  reset_operation_lock_fixture
  if [[ "$locked_command" == "init" ]]; then
    reset_init_fixture
    locked_arguments=(init --yes)
  else
    reset_adopt_fixture
    locked_source=$(new_adopt_source operation-lock-live)
    locked_arguments=(adopt --yes "$locked_source")
  fi
  create_operation_lock 12345 "$fake_process_start" adopt "$fake_operation_token"
  if live_lock_output=$(run_vaultlock "${locked_arguments[@]}" 2>&1); then
    record_failure "$locked_command refuses live cooperative operation lock"
  else
    check_contains "$locked_command live lock reports owner" \
      'operation lock is held by live' "$live_lock_output"
  fi
  check_empty "$locked_command live lock stops before domain mutation" \
    "$mutation_log"
done

reset_operation_lock_fixture
reset_adopt_fixture
stale_lock_source=$(new_adopt_source operation-lock-stale)
create_operation_lock 999999 "$fake_process_start" adopt "$fake_operation_token"
if stale_lock_output=$(run_vaultlock adopt --yes "$stale_lock_source" 2>&1); then
  :
else
  record_failure "adopt replaces verified stale operation lock: $stale_lock_output"
fi
stale_lock_quarantine_count=$(find "$test_home" -maxdepth 1 -type d \
  -name '.vaultlock-operation.lock.quarantine.*' | wc -l | tr -d ' ')
check "adopt retains one verified stale operation lock" 1 \
  "$stale_lock_quarantine_count"
check_contains "adopt reports retained stale operation lock" \
  '.vaultlock-operation.lock.quarantine.' "$stale_lock_output"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "adopt releases replacement operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
malformed_lock_source=$(new_adopt_source operation-lock-malformed)
create_operation_lock 12345 "$fake_process_start" adopt "$fake_operation_token"
printf 'version=1\npid=broken\n' > "$operation_lock_dir/owner"
/bin/chmod 600 "$operation_lock_dir/owner"
if malformed_lock_output=$(run_vaultlock adopt --yes \
    "$malformed_lock_source" 2>&1); then
  record_failure "adopt rejects malformed operation lock owner"
else
  check_contains "adopt malformed operation lock fails closed" \
    'malformed operation lock owner' "$malformed_lock_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt preserves malformed operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
ambiguous_lock_source=$(new_adopt_source operation-lock-ambiguous)
create_operation_lock 12345 "$fake_process_start" adopt "$fake_operation_token"
: > "$apfs_state/ps_ambiguous"
if ambiguous_lock_output=$(run_vaultlock adopt --yes \
    "$ambiguous_lock_source" 2>&1); then
  record_failure "adopt rejects ambiguous operation lock process probe"
else
  check_contains "adopt ambiguous process probe fails closed" \
    'cannot safely classify operation lock owner' "$ambiguous_lock_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt preserves ambiguously owned operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
swapped_lock_source=$(new_adopt_source operation-lock-owner-swap)
create_operation_lock 999999 "$fake_process_start" adopt "$fake_operation_token"
printf 'owner_identity_swap\n' \
  > "$apfs_state/transition_operation_lock_final_check"
if swapped_lock_output=$(run_vaultlock adopt --yes \
    "$swapped_lock_source" 2>&1); then
  record_failure "adopt rejects operation lock owner identity swap"
else
  check_contains "adopt operation lock owner swap fails closed" \
    'operation lock changed during final verification' "$swapped_lock_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt preserves swapped operation lock"

reset_operation_lock_fixture
reset_init_fixture
printf 'init_state_create\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if init_drift_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init rejects post-acquisition plan drift"
else
  check_contains "init reports post-acquisition plan drift" \
    'plan changed after operation lock acquisition' "$init_drift_output"
fi
check_count "init plan drift stops before APFS mutation" 0 \
  'diskutil apfs addVolume' "$(< "$mutation_log")"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "init plan drift releases operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
adopt_drift_source=$(new_adopt_source operation-lock-plan-drift)
printf 'adopt_source_identity_swap\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if adopt_drift_output=$(run_vaultlock adopt --yes \
    "$adopt_drift_source" 2>&1); then
  record_failure "adopt rejects identical-content source identity plan drift"
else
  check_contains "adopt reports source identity plan drift" \
    'plan changed after operation lock acquisition' "$adopt_drift_output"
fi
check_count "adopt plan drift stops before copy" 0 'ditto ' \
  "$(< "$mutation_log")"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "adopt plan drift releases operation lock"

reset_operation_lock_fixture
reset_init_fixture
if operation_lock_init_success=$(run_vaultlock init --yes 2>&1); then
  :
else
  record_failure "successful init with operation lock: $operation_lock_init_success"
fi
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "successful init releases operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
operation_lock_adopt_source=$(new_adopt_source operation-lock-success)
if operation_lock_adopt_success=$(run_vaultlock adopt --yes \
    "$operation_lock_adopt_source" 2>&1); then
  :
else
  record_failure "successful adopt with operation lock: $operation_lock_adopt_success"
fi
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "successful adopt releases operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
operation_lock_failure_source=$(new_adopt_source operation-lock-domain-failure)
: > "$apfs_state/fail_ditto"
if operation_lock_failure_output=$(run_vaultlock adopt --yes \
    "$operation_lock_failure_source" 2>&1); then
  record_failure \
    "adopt domain failure exits nonzero with operation lock: $operation_lock_failure_output"
fi
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "adopt domain failure releases operation lock"

reset_operation_lock_fixture
reset_adopt_fixture
operation_lock_release_source=$(new_adopt_source operation-lock-release-failure)
: > "$apfs_state/fail_operation_lock_release"
if release_failure_output=$(run_vaultlock adopt --yes \
    "$operation_lock_release_source" 2>&1); then
  record_failure "adopt operation lock release failure exits nonzero"
else
  check_contains "adopt operation lock release failure reports retained lock" \
    "$operation_lock_dir" "$release_failure_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt operation lock release failure retains lock"

for signal_case in TERM:143 HUP:129 INT:130; do
  reset_operation_lock_fixture
  reset_adopt_fixture
  operation_signal=${signal_case%%:*}
  operation_signal_status=${signal_case##*:}
  operation_signal_source=$(new_adopt_source \
    "operation-lock-signal-${operation_signal}")
  printf '%s\n' "$operation_signal" > "$apfs_state/signal_ditto"
  if operation_signal_output=$(run_vaultlock adopt --yes \
      "$operation_signal_source" 2>&1); then
    operation_signal_actual=0
  else
    operation_signal_actual=$?
  fi
  : "$operation_signal_output"
  check "adopt $operation_signal preserves signal exit status" \
    "$operation_signal_status" "$operation_signal_actual"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "adopt $operation_signal releases operation lock"
done

reset_operation_lock_fixture
reset_adopt_fixture
operation_first_source=$(new_adopt_source operation-lock-first)
operation_second_source=$(new_adopt_source operation-lock-second)
: > "$apfs_state/hold_ditto"
operation_first_output="$test_root/operation-first.out"
start_vaultlock_background "$operation_first_output" adopt --yes \
  "$operation_first_source"
operation_first_pid=$BACKGROUND_VAULTLOCK_PID
if ! wait_for_fixture "$apfs_state/ditto_entered"; then
  record_failure "first concurrent adopt reaches ditto"
fi
operation_second_output="$test_root/operation-second.out"
start_vaultlock_background "$operation_second_output" adopt --yes \
  "$operation_second_source"
operation_second_pid=$BACKGROUND_VAULTLOCK_PID
/bin/sleep 0.2
if /bin/kill -0 "$operation_second_pid" 2>/dev/null; then
  : > "$apfs_state/release_ditto"
fi
if wait "$operation_second_pid"; then
  operation_second_status=0
else
  operation_second_status=$?
fi
if [[ "$operation_second_status" -eq 0 ]]; then
  record_failure "second concurrent adopt is refused"
else
  operation_second_text=$(< "$operation_second_output")
  check_contains "second concurrent adopt reports live owner" \
    'operation lock is held by live' "$operation_second_text"
fi
check_count "only one concurrent adopt reaches ditto" 1 'ditto ' \
  "$(< "$mutation_log")"
[[ -e "$apfs_state/release_ditto" ]] \
  || : > "$apfs_state/release_ditto"
if wait "$operation_first_pid"; then
  :
else
  record_failure "first concurrent adopt completes after release"
fi
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "concurrent adopt releases operation lock"

reset_operation_lock_fixture

reset_adopt_fixture
normalized_directory_source=$(new_adopt_source adopt-directory-normalization)
: > "$apfs_state/normalize_copy_directory_metadata"
if normalized_directory_output=$(run_vaultlock adopt --yes \
    "$normalized_directory_source" 2>&1); then
  check_contains "adopt normalizes directory size and rdev" \
    'Result: adopted' "$normalized_directory_output"
else
  record_failure "adopt normalizes directory size and rdev"
fi

reset_adopt_fixture
birthtime_source=$(new_adopt_source adopt-directory-birthtime)
: > "$apfs_state/drop_copy_birthtime"
if birthtime_output=$(run_vaultlock adopt --yes "$birthtime_source" 2>&1); then
  record_failure "adopt detects copied directory birthtime loss"
else
  check_contains "adopt reports directory birthtime mismatch" \
    'copy verification failed' "$birthtime_output"
fi

reset_adopt_fixture
symlink_timestamp_source=$(new_adopt_source adopt-symlink-timestamps)
symlink_timestamp_path=$symlink_timestamp_source/timestamp-link
/bin/ln -s subdirectory/file "$symlink_timestamp_path"
/usr/bin/touch -c -h -a -d '2026-08-28T09:08:07.123456789Z' \
  "$symlink_timestamp_path"
/usr/bin/touch -c -h -m -d '2026-08-27T06:05:04.987654321Z' \
  "$symlink_timestamp_path"
expected_symlink_timestamps=$(/usr/bin/stat -f '%.9Fa:%.9Fm:%.9FB' -- \
  "$symlink_timestamp_path")
if symlink_timestamp_output=$(run_vaultlock adopt --yes \
    "$symlink_timestamp_source" 2>&1); then
  check "adopt preserves exact symlink atime mtime birthtime" \
    "$expected_symlink_timestamps" \
    "$(/usr/bin/stat -f '%.9Fa:%.9Fm:%.9FB' -- \
      "$mount_point/adopt-symlink-timestamps/timestamp-link")"
else
  record_failure \
    "adopt preserves exact symlink timestamps: $symlink_timestamp_output"
fi

reset_adopt_fixture
large_directory_source=$(new_adopt_source adopt-large-directory-skeleton)
large_directory_path=$large_directory_source
for large_directory_index in {1..16}; do
  large_directory_path=$large_directory_path/d$large_directory_index
  mkdir "$large_directory_path"
done
printf 'deep payload\n' > "$large_directory_path/deep-file"
: > "$apfs_state/count_directory_traversals"
if large_directory_output=$(run_vaultlock adopt --yes \
    "$large_directory_source" 2>&1); then
  :
else
  record_failure \
    "adopt cleans deterministic 16-directory skeleton: $large_directory_output"
fi
large_directory_traversals=$(< "$apfs_state/directory_traversal_count")
if [[ "$large_directory_traversals" -le 3 ]]; then
  printf 'ok   adopt directory cleanup uses bounded traversals\n'
else
  record_failure "adopt directory cleanup uses bounded traversals: $large_directory_traversals"
fi

reset_adopt_fixture
rollback_order_source=$(new_adopt_source adopt-rollback-verification-order)
: > "$apfs_state/fail_link_verification"
printf 'adopt_backup_identity_swap\n' \
  > "$apfs_state/transition_adopt_rollback_before_source_link_move"
if rollback_order_output=$(run_vaultlock adopt --yes \
    "$rollback_order_source" 2>&1); then
  record_failure "adopt rollback rejects replaced backup"
else
  check_contains "adopt rollback reports unverified backup" \
    'unverified backup retained' "$rollback_order_output"
fi
[[ -L "$rollback_order_source" ]] \
  || record_failure "adopt verifies backup before moving installed source link"

reset_adopt_fixture
staged_reporting_source=$(new_adopt_source adopt-staged-reporting)
: > "$apfs_state/fail_link_move"
: > "$apfs_state/fail_staged_link_cleanup"
printf 'adopt_staged_identity_swap\n' \
  > "$apfs_state/transition_adopt_reporting_before_staged_classification"
if staged_reporting_output=$(run_vaultlock adopt --yes \
    "$staged_reporting_source" 2>&1); then
  record_failure "adopt staged ownership reporting fixture exits nonzero"
else
  check_contains "adopt reports unverified staged path by ownership" \
    'unverified staged path retained' "$staged_reporting_output"
fi

reset_adopt_fixture
xattr_escape_source=$(new_adopt_source adopt-xattr-escapes)
xattr_escape_file=$xattr_escape_source/subdirectory/file
xattr_newline_name=$'vaultlock.newline\nname'
xattr_backslash_name='vaultlock.backslash\cname'
/usr/bin/xattr -w "$xattr_newline_name" newline-value "$xattr_escape_file"
/usr/bin/xattr -w "$xattr_backslash_name" backslash-value "$xattr_escape_file"
if xattr_escape_output=$(run_vaultlock adopt --yes \
    "$xattr_escape_source" 2>&1); then
  :
else
  record_failure "adopt preserves escaped xattr names: $xattr_escape_output"
fi
check "adopt newline xattr oracle" newline-value \
  "$(/usr/bin/xattr -p "$xattr_newline_name" \
    "$mount_point/adopt-xattr-escapes/subdirectory/file")"
check "adopt backslash xattr oracle" backslash-value \
  "$(/usr/bin/xattr -p "$xattr_backslash_name" \
  "$mount_point/adopt-xattr-escapes/subdirectory/file")"

reset_operation_lock_fixture
reset_init_fixture
/bin/rm -rf -- "${state_dir:?}"
if absent_state_plan=$(run_vaultlock init --dry-run 2>&1); then
  check_contains "init absent state directory renders full plan" \
    'Prepare protected state and generate recovery material' "$absent_state_plan"
else
  record_failure "init absent state directory dry-run succeeds: $absent_state_plan"
fi
[[ ! -e "$state_dir" && ! -L "$state_dir" ]] \
  || record_failure "init absent state directory dry-run does not create state"
printf 'n\n' > "$confirm_device"
if absent_state_decline=$(run_vaultlock init 2>&1); then
  record_failure "init absent state directory decline exits nonzero"
else
  check_contains "init absent state directory normal planning succeeds" \
    'cancelled, no changes made' "$absent_state_decline"
fi
[[ ! -e "$state_dir" && ! -L "$state_dir" ]] \
  || record_failure "init absent state directory decline does not create state"
/bin/mkdir -p "$state_dir"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/signal_operation_owner_mktemp"
if partial_lock_signal_output=$(run_vaultlock init --yes 2>&1); then
  partial_lock_signal_status=0
else
  partial_lock_signal_status=$?
fi
: "$partial_lock_signal_output"
check "init owner-temp signal preserves TERM status" 143 \
  "$partial_lock_signal_status"
[[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
  || record_failure "init owner-temp signal removes partial lock directory"
partial_owner_temp_count=$(find "$test_home" -maxdepth 1 \
  -name '.vaultlock-operation.owner.*' | wc -l | tr -d ' ')
check "init owner-temp signal removes staging file" 0 \
  "$partial_owner_temp_count"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/fail_operation_lock_owner_install"
if partial_lock_link_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init owner-record install failure exits nonzero"
else
  check_contains "init owner-record install failure reports primary cause" \
    'cannot install operation lock owner record' "$partial_lock_link_output"
fi
[[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
  || record_failure "init owner-record install failure removes partial lock directory"
partial_owner_temp_count=$(find "$test_home" -maxdepth 1 \
  -name '.vaultlock-operation.owner.*' | wc -l | tr -d ' ')
check "init owner-record install failure removes staging file" 0 \
  "$partial_owner_temp_count"

reset_operation_lock_fixture
reset_adopt_fixture
malformed_start_source=$(new_adopt_source operation-lock-malformed-start)
create_operation_lock 999999 garbage adopt "$fake_operation_token"
if malformed_start_output=$(run_vaultlock adopt --yes \
  "$malformed_start_source" 2>&1); then
  record_failure "adopt rejects malformed operation lock start"
else
  check_contains "adopt malformed start fails closed" \
    'malformed operation lock owner' "$malformed_start_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt preserves malformed-start operation lock"
malformed_start_quarantine_count=$(find "$test_home" -maxdepth 1 -type d \
  -name '.vaultlock-operation.lock.quarantine.*' | wc -l | tr -d ' ')
check "adopt does not quarantine malformed-start lock" 0 \
  "$malformed_start_quarantine_count"

reset_operation_lock_fixture
reset_adopt_fixture
stale_moved_owner_source=$(new_adopt_source operation-lock-moved-owner-swap)
create_operation_lock 999999 "$fake_process_start" adopt "$fake_operation_token"
printf 'owner_identity_swap\n' \
  > "$apfs_state/transition_operation_lock_after_quarantine_move"
if stale_moved_owner_output=$(run_vaultlock adopt --yes \
  "$stale_moved_owner_source" 2>&1); then
  record_failure "adopt rejects stale lock owner swap after quarantine move"
else
  check_contains "adopt stale moved-owner swap fails closed" \
    'stale operation lock quarantine changed' "$stale_moved_owner_output"
fi
check_empty "adopt stale moved-owner swap stops before domain mutation" \
  "$mutation_log"
stale_moved_quarantine_count=$(find "$test_home" -maxdepth 1 -type d \
  -name '.vaultlock-operation.lock.quarantine.*' | wc -l | tr -d ' ')
check "adopt retains unverifiable stale lock quarantine" 1 \
  "$stale_moved_quarantine_count"

reset_operation_lock_fixture
reset_adopt_fixture
state_inode_source=$(new_adopt_source adopt-state-inode-drift)
state_inode_before=$(/usr/bin/stat -f '%d:%i' "$state_dir/state.json")
printf 'state_equivalent_inode_swap\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if state_inode_output=$(run_vaultlock adopt --yes "$state_inode_source" 2>&1); then
  record_failure "adopt rejects equivalent-content state inode drift"
else
  check_contains "adopt reports state inode plan drift" \
    'plan changed after operation lock acquisition' "$state_inode_output"
fi
state_inode_after=$(/usr/bin/stat -f '%d:%i' "$state_dir/state.json")
[[ "$state_inode_after" != "$state_inode_before" ]] \
  || record_failure "adopt state inode drift fixture replaces inode"
[[ -d "$state_inode_source" && ! -L "$state_inode_source" ]] \
  || record_failure "adopt state inode drift preserves source"
check_empty "adopt state inode drift stops before domain mutation" "$mutation_log"

for post_backup_case in destination:adopt_destination_identity_swap \
  mount-uuid:adopt_mount_uuid_swap mount-device:adopt_mount_device_swap; do
  reset_operation_lock_fixture
  reset_adopt_fixture
  post_backup_name=${post_backup_case%%:*}
  post_backup_action=${post_backup_case#*:}
  post_backup_source=$(new_adopt_source "adopt-post-backup-$post_backup_name")
  printf '%s\n' "$post_backup_action" \
    > "$apfs_state/transition_adopt_after_backup_verified"
  if post_backup_output=$(run_vaultlock adopt --yes \
    "$post_backup_source" 2>&1); then
    record_failure "adopt rolls back post-backup $post_backup_name drift"
  else
    check_contains "adopt reports post-backup $post_backup_name rollback" \
      'original source restored' "$post_backup_output"
  fi
  [[ -d "$post_backup_source" && ! -L "$post_backup_source" \
    && -f "$post_backup_source/subdirectory/file" ]] \
    || record_failure "adopt restores source after post-backup $post_backup_name drift"
done

for backup_collision_kind in file directory; do
  reset_operation_lock_fixture
  reset_adopt_fixture
  backup_collision_source=$(new_adopt_source \
    "adopt-backup-appears-$backup_collision_kind")
  backup_collision_path=$backup_collision_source.vaultlock-backup
  printf 'adopt_backup_path_%s_create\n' "$backup_collision_kind" \
    > "$apfs_state/transition_adopt_before_backup_move"
  if backup_collision_output=$(run_vaultlock adopt --yes \
    "$backup_collision_source" 2>&1); then
    record_failure "adopt rejects appearing backup $backup_collision_kind"
  else
    check_contains "adopt appearing backup $backup_collision_kind fails closed" \
      'source backup path changed before move' "$backup_collision_output"
  fi
  [[ -d "$backup_collision_source" && ! -L "$backup_collision_source" \
    && -f "$backup_collision_source/subdirectory/file" ]] \
    || record_failure "adopt appearing backup $backup_collision_kind preserves source"
  if [[ "$backup_collision_kind" == file ]]; then
    check "adopt preserves appearing backup file" 'foreign backup file' \
      "$(< "$backup_collision_path")"
  else
    check "adopt preserves appearing backup directory" \
      'foreign backup directory' "$(< "$backup_collision_path/foreign")"
  fi
  /bin/rm -rf -- "${backup_collision_path:?}"
done

reset_operation_lock_fixture
reset_adopt_fixture
source_reporting_source=$(new_adopt_source adopt-source-reporting)
: > "$apfs_state/fail_link_verification"
printf 'adopt_backup_identity_swap\n' \
  > "$apfs_state/transition_adopt_rollback_before_source_link_move"
printf 'adopt_installed_source_identity_swap\n' \
  > "$apfs_state/transition_adopt_reporting_before_source_classification"
if source_reporting_output=$(run_vaultlock adopt --yes \
  "$source_reporting_source" 2>&1); then
  record_failure "adopt source ownership reporting fixture exits nonzero"
else
  check_contains "adopt reports unverified source entry by ownership" \
    'unverified source entry retained' "$source_reporting_output"
fi

reset_adopt_fixture
xattr_trailing_source=$(new_adopt_source adopt-xattr-trailing-newlines)
xattr_trailing_file=$xattr_trailing_source/subdirectory/file
xattr_one_trailing_name=$'vaultlock.one-trailing\n'
xattr_two_trailing_name=$'vaultlock.two-trailing\n\n'
xattr_mixed_trailing_name=$'vaultlock.backslash\\name\n'
/usr/bin/xattr -w "$xattr_one_trailing_name" one-value "$xattr_trailing_file"
/usr/bin/xattr -w "$xattr_two_trailing_name" two-value "$xattr_trailing_file"
/usr/bin/xattr -w "$xattr_mixed_trailing_name" mixed-value "$xattr_trailing_file"
if xattr_trailing_output=$(run_vaultlock adopt --yes \
  "$xattr_trailing_source" 2>&1); then
  :
else
  record_failure "adopt preserves trailing-newline xattr names: $xattr_trailing_output"
fi
check "adopt one-trailing-newline xattr oracle" one-value \
  "$(/usr/bin/xattr -p "$xattr_one_trailing_name" \
  "$mount_point/adopt-xattr-trailing-newlines/subdirectory/file")"
check "adopt two-trailing-newline xattr oracle" two-value \
  "$(/usr/bin/xattr -p "$xattr_two_trailing_name" \
  "$mount_point/adopt-xattr-trailing-newlines/subdirectory/file")"
check "adopt mixed-backslash-trailing-newline xattr oracle" mixed-value \
  "$(/usr/bin/xattr -p "$xattr_mixed_trailing_name" \
  "$mount_point/adopt-xattr-trailing-newlines/subdirectory/file")"

# Re-review regressions: lock creation, process starts, ACLs, and adopt signals.
reset_operation_lock_fixture
reset_init_fixture
printf 'HUP\n' > "$apfs_state/signal_operation_lock_mkdir"
if lock_mkdir_signal_output=$(run_vaultlock init --yes 2>&1); then
  lock_mkdir_signal_status=0
else
  lock_mkdir_signal_status=$?
fi
: "$lock_mkdir_signal_output"
check "init lock-directory signal preserves HUP status" 129 \
  "$lock_mkdir_signal_status"
[[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
  || record_failure "init lock-directory signal removes identified partial lock"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/fail_operation_lock_identity_once"
if lock_identity_failure_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init lock identity capture failure exits nonzero"
else
  check_contains "init lock identity capture failure reports cause" \
    'cannot capture partial operation lock identity' \
    "$lock_identity_failure_output"
fi
[[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
  || record_failure "init lock identity capture failure removes identified directory"

for valid_process_start in 'Tue Feb 29 12:34:56 2028' \
    'Sun Aug  9 10:00:00 2026'; do
  if run_vaultlock __process_start_valid "$valid_process_start" \
      >/dev/null 2>&1; then
    valid_process_start_status=0
  else
    valid_process_start_status=$?
  fi
  check "process start accepts normalized [$valid_process_start]" 0 \
    "$valid_process_start_status"
done

invalid_process_starts=(
  'Xxx Yyy 99 99:99:99 9999'
  'Mon Feb 30 10:00:00 2026'
  'Sun Aug 30 24:00:00 2026'
  'Sun Aug 30 10:60:00 2026'
  'Sun Aug 30 10:00:60 2026'
  $'Sun\tAug 30 10:00:00 2026'
)
for invalid_process_start in "${invalid_process_starts[@]}"; do
  if run_vaultlock __process_start_valid "$invalid_process_start" \
      >/dev/null 2>&1; then
    invalid_process_start_status=0
  else
    invalid_process_start_status=$?
  fi
  check "process start rejects malformed [$invalid_process_start]" 1 \
    "$invalid_process_start_status"
done

reset_operation_lock_fixture
reset_adopt_fixture
calendar_malformed_source=$(new_adopt_source operation-lock-calendar-malformed)
create_operation_lock 999999 'Mon Feb 30 10:00:00 2026' adopt \
  "$fake_operation_token"
if calendar_malformed_output=$(run_vaultlock adopt --yes \
    "$calendar_malformed_source" 2>&1); then
  record_failure "adopt rejects impossible calendar in operation owner"
else
  check_contains "adopt impossible calendar fails closed" \
    'malformed operation lock owner' "$calendar_malformed_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt preserves impossible-calendar operation lock"

reset_operation_lock_fixture
reset_init_fixture
/bin/chmod +a \
  'everyone allow read,file_inherit,directory_inherit' "$state_dir"
if inherited_state_acl_output=$(run_vaultlock init --yes 2>&1); then
  :
else
  record_failure "init removes inherited state ACL: $inherited_state_acl_output"
fi
state_acl_count=$(/bin/ls -ldeB "$state_dir" \
  | /usr/bin/sed -n '2,$p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
recovery_acl_count=$(/bin/ls -ldeB "$state_dir/passphrase.txt" \
  | /usr/bin/sed -n '2,$p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
check "init removes state directory ACL" 0 "$state_acl_count"
check "init removes inherited final recovery ACL" 0 "$recovery_acl_count"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/inherit_recovery_acl"
if inherited_recovery_acl_output=$(run_vaultlock init --yes 2>&1); then
  :
else
  record_failure \
    "init removes recovery staging ACL: $inherited_recovery_acl_output"
fi
recovery_acl_count=$(/bin/ls -ldeB "$state_dir/passphrase.txt" \
  | /usr/bin/sed -n '2,$p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
check "init removes recovery staging ACL before installation" 0 \
  "$recovery_acl_count"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/inherit_recovery_acl"
: > "$apfs_state/fail_recovery_acl_removal"
if recovery_acl_failure_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init recovery ACL removal failure exits nonzero"
else
  check_contains "init recovery ACL removal failure reports cause" \
    'cannot remove recovery staging ACL' "$recovery_acl_failure_output"
fi
check_count "init recovery ACL failure reaches no keychain or APFS mutation" 0 \
  'diskutil apfs addVolume' "$recovery_acl_failure_output$(< "$mutation_log")"
check_count "init recovery ACL failure leaks no generated secret" 0 \
  'Task6SecretOnlyInStdinChannel' \
  "$recovery_acl_failure_output$(< "$action_log")$(< "$mutation_log")$(< "$hook_log")"

for adopt_signal_case in \
    after-backup:HUP:129:transition \
    during-manifest:TERM:143:manifest \
    after-link:INT:130:transition; do
  reset_operation_lock_fixture
  reset_adopt_fixture
  adopt_signal_name=${adopt_signal_case%%:*}
  adopt_signal_rest=${adopt_signal_case#*:}
  adopt_signal_name_value=${adopt_signal_rest%%:*}
  adopt_signal_rest=${adopt_signal_rest#*:}
  adopt_signal_expected=${adopt_signal_rest%%:*}
  adopt_signal_fixture=${adopt_signal_rest##*:}
  adopt_transaction_source=$(new_adopt_source \
    "adopt-signal-$adopt_signal_name")
  case "$adopt_signal_name" in
    after-backup)
      printf 'signal_%s\n' "$adopt_signal_name_value" \
        > "$apfs_state/transition_adopt_after_backup_move"
      ;;
    during-manifest)
      printf '%s\n' "$adopt_signal_name_value" \
        > "$apfs_state/signal_adopt_backup_manifest"
      ;;
    after-link)
      printf 'signal_%s\n' "$adopt_signal_name_value" \
        > "$apfs_state/transition_adopt_after_installed_link_verified"
      ;;
  esac
  : "$adopt_signal_fixture"
  if adopt_transaction_signal_output=$(run_vaultlock adopt --yes \
      "$adopt_transaction_source" 2>&1); then
    adopt_transaction_signal_status=0
  else
    adopt_transaction_signal_status=$?
  fi
  check "adopt $adopt_signal_name preserves $adopt_signal_name_value status" \
    "$adopt_signal_expected" "$adopt_transaction_signal_status"
  check_contains "adopt $adopt_signal_name reports interruption" \
    "adopt interrupted by $adopt_signal_name_value" \
    "$adopt_transaction_signal_output"
  check_contains "adopt $adopt_signal_name reports restored source" \
    'original source restored at' "$adopt_transaction_signal_output"
  [[ -d "$adopt_transaction_source" \
      && ! -L "$adopt_transaction_source" \
      && -f "$adopt_transaction_source/subdirectory/file" ]] \
    || record_failure "adopt $adopt_signal_name restores original source"
  [[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
    || record_failure "adopt $adopt_signal_name releases operation lock"
  /bin/rm -rf -- "${adopt_transaction_source:?}" \
    "${adopt_transaction_source:?}.vaultlock-backup" \
    "${adopt_transaction_source:?}.vaultlock-link" \
    "${mount_point:?}/adopt-signal-$adopt_signal_name"
done

# Final review regressions: reserved paths, timezone identity, and signal gaps.
reset_operation_lock_fixture
reset_adopt_fixture
/bin/ln -s "$test_home" "$test_root/home-alias"
for reserved_adopt_case in \
    "state-dir:$state_dir" \
    "home-parent:$test_home" \
    "canonical-alias:$test_root/home-alias/.vaultlock"; do
  reserved_adopt_name=${reserved_adopt_case%%:*}
  reserved_adopt_path=${reserved_adopt_case#*:}
  if reserved_adopt_output=$(run_vaultlock adopt --dry-run \
      "$reserved_adopt_path" 2>&1); then
    record_failure "adopt rejects reserved $reserved_adopt_name source"
  else
    check_contains "adopt reserved $reserved_adopt_name reports cause" \
      'contains reserved vaultlock control path' "$reserved_adopt_output"
  fi
done
/bin/rm -f "$test_root/home-alias"

reset_operation_lock_fixture
reset_adopt_fixture
reserved_drift_source=$(new_adopt_source adopt-reserved-post-lock-drift)
: > "$apfs_state/fail_ditto"
printf 'adopt_state_dir_move_into_source\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if reserved_drift_output=$(run_vaultlock adopt --yes \
    "$reserved_drift_source" 2>&1); then
  record_failure "adopt rejects reserved relationship drift after operation lock"
else
  check_contains "adopt reserved relationship drift reports cause" \
    'contains reserved vaultlock control path' "$reserved_drift_output"
fi
check_count "adopt reserved relationship drift reaches no copy" 0 \
  'ditto ' "$mutation_log"
if [[ -L "$state_dir" && -d "$reserved_drift_source/.vaultlock" ]]; then
  /bin/rm -f "$state_dir"
  /bin/mv "$reserved_drift_source/.vaultlock" "$state_dir"
fi
/bin/rm -rf -- "${reserved_drift_source:?}" \
  "${mount_point:?}/adopt-reserved-post-lock-drift"

reset_operation_lock_fixture
reset_adopt_fixture
timezone_owner_source=$(new_adopt_source adopt-timezone-owner)
timezone_contender_source=$(new_adopt_source adopt-timezone-contender)
: > "$apfs_state/ps_timezone_sensitive"
: > "$apfs_state/hold_ditto"
TZ=Pacific/Honolulu start_vaultlock_background \
  "$test_root/timezone-owner-output" adopt --yes "$timezone_owner_source"
timezone_owner_pid=$BACKGROUND_VAULTLOCK_PID
if ! wait_for_fixture "$apfs_state/ditto_entered"; then
  record_failure "timezone owner reaches held operation"
fi
if timezone_contender_output=$(TZ=Europe/Amsterdam run_vaultlock adopt --yes \
    "$timezone_contender_source" 2>&1); then
  record_failure "different-TZ contender respects live cooperative owner"
else
  check_contains "different-TZ contender reports live owner" \
    'operation lock is held by live pid' "$timezone_contender_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "different-TZ contender preserves live operation lock"
: > "$apfs_state/release_ditto"
if wait "$timezone_owner_pid"; then
  :
else
  record_failure "timezone owner completes after release"
fi
/bin/rm -rf -- "${timezone_owner_source:?}" \
  "${timezone_contender_source:?}" \
  "${mount_point:?}/adopt-timezone-owner" \
  "${mount_point:?}/adopt-timezone-contender"

for deferral_boundary in begin end; do
  for deferral_signal_case in HUP:129 INT:130 TERM:143; do
    reset_operation_lock_fixture
    reset_init_fixture
    deferral_signal=${deferral_signal_case%%:*}
    deferral_status=${deferral_signal_case##*:}
    printf 'signal_%s\n' "$deferral_signal" \
      > "$apfs_state/transition_operation_signal_deferral_${deferral_boundary}_window"
    if deferral_output=$(run_vaultlock init --yes 2>&1); then
      deferral_actual=0
    else
      deferral_actual=$?
    fi
    : "$deferral_output"
    check "operation deferral $deferral_boundary preserves $deferral_signal status" \
      "$deferral_status" "$deferral_actual"
    [[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
      || record_failure \
        "operation deferral $deferral_boundary cleans lock after $deferral_signal"
  done
done

for preparation_signal_case in staged-link:HUP:129 reservation:TERM:143; do
  reset_operation_lock_fixture
  reset_adopt_fixture
  preparation_name=${preparation_signal_case%%:*}
  preparation_rest=${preparation_signal_case#*:}
  preparation_signal=${preparation_rest%%:*}
  preparation_status=${preparation_rest##*:}
  preparation_source=$(new_adopt_source \
    "adopt-preparation-$preparation_name")
  if [[ "$preparation_name" == staged-link ]]; then
    preparation_marker=signal_adopt_staged_link_creation
  else
    preparation_marker=signal_adopt_reservation_creation
  fi
  printf '%s\n' "$preparation_signal" \
    > "$apfs_state/$preparation_marker"
  if preparation_output=$(run_vaultlock adopt --yes \
      "$preparation_source" 2>&1); then
    preparation_actual=0
  else
    preparation_actual=$?
  fi
  check "adopt $preparation_name signal preserves $preparation_signal status" \
    "$preparation_status" "$preparation_actual"
  check_contains "adopt $preparation_name signal reports interruption" \
    "adopt interrupted by $preparation_signal" "$preparation_output"
  [[ -d "$preparation_source" && ! -L "$preparation_source" ]] \
    || record_failure "adopt $preparation_name signal preserves source"
  [[ ! -e "$preparation_source.vaultlock-link" \
      && ! -L "$preparation_source.vaultlock-link" \
      && ! -e "$preparation_source.vaultlock-backup" \
      && ! -L "$preparation_source.vaultlock-backup" ]] \
    || record_failure "adopt $preparation_name signal removes owned blockers"
  [[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
    || record_failure "adopt $preparation_name signal releases operation lock"
  /bin/rm -rf -- "${preparation_source:?}" \
    "${preparation_source:?}.vaultlock-link" \
    "${preparation_source:?}.vaultlock-backup" \
    "${mount_point:?}/adopt-preparation-$preparation_name"
done

for release_boundary in owner-unlink directory-remove; do
  for release_signal_case in HUP:129 INT:130 TERM:143; do
    reset_operation_lock_fixture
    reset_init_fixture
    release_signal=${release_signal_case%%:*}
    release_status=${release_signal_case##*:}
    if [[ "$release_boundary" == owner-unlink ]]; then
      release_marker=signal_operation_owner_unlink
    else
      release_marker=signal_operation_directory_remove
    fi
    printf '%s\n' "$release_signal" > "$apfs_state/$release_marker"
    if release_output=$(run_vaultlock init --yes 2>&1); then
      release_actual=0
    else
      release_actual=$?
    fi
    check "operation release $release_boundary preserves $release_signal status" \
      "$release_status" "$release_actual"
    check_contains "operation release $release_boundary reports $release_signal" \
      "operation interrupted by $release_signal" "$release_output"
    [[ ! -e "$operation_lock_dir" && ! -L "$operation_lock_dir" ]] \
      || record_failure \
        "operation release $release_boundary completes after $release_signal"
  done
done

reset_operation_lock_fixture

exit "$fail"
