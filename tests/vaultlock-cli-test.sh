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

  for fixture_secret_scope in unlock init lock_old lock_new; do
    fixture_expected_secret_path=$VAULTLOCK_TEST_APFS_STATE/expected_child_${fixture_secret_scope}_secret
    [[ -f "$fixture_expected_secret_path" ]] || continue
    fixture_expected_secret=$(< "$fixture_expected_secret_path")
    while IFS= read -r fixture_secret_name; do
      fixture_secret_value=${!fixture_secret_name-}
      if [[ "$fixture_secret_value" == *"$fixture_expected_secret"* ]]; then
        : > "$VAULTLOCK_TEST_APFS_STATE/${fixture_secret_scope}_secret_in_child_environment"
      fi
    done < <(compgen -e)
  done

  printf -v fixture_action '%q' "$fixture_command"
  for fixture_argument in "$@"; do
    printf -v fixture_quoted_argument '%q' "$fixture_argument"
    fixture_action="$fixture_action $fixture_quoted_argument"
  done
  printf '%s\n' "$fixture_action" >> "$VAULTLOCK_TEST_ACTION_LOG"

  case "$fixture_command" in
    diskutil)
      if [[ "${1:-}" != "info" \
          && ! ( "${1:-}" == "apfs" && "${2:-}" == "list" ) ]]; then
        printf '%s\n' "diskutil $*" >> "$VAULTLOCK_TEST_MUTATION_LOG"
      fi
      ;;
  security|tmutil|ditto|mv|ln|rm|rmdir|mkdir|chmod|mktemp)
    if [[ "$fixture_command" == security \
        && "${1:-}" == find-generic-password ]]; then
      :
    elif [[ " $* " != *"$HOME/.vaultlock-operation"* ]]; then
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
    mount|dirname|basename|stat|find|ls|wc|readlink) ;;
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
    if [[ "$fixture_target" == "$VAULTLOCK_MOUNT_POINT" \
        && -f "$VAULTLOCK_TEST_APFS_STATE/shadow_mount_identity" ]]; then
      uuid=UUID-SHADOW-MOUNT
    fi
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
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/filevault_disabled" ]]; then
      printf '   FileVault:                No\n'
    else
      printf '   FileVault:                Yes (Unlocked)\n'
    fi
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
          if [[ "$(fixture_read locked)" != "false" \
              && ! -f "$VAULTLOCK_TEST_APFS_STATE/allow_mount_while_locked" ]]; then
            exit 1
          fi
          fixture_write mounted true
          fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
          ;;
        unmount)
          [[ $# -eq 2 ]] || exit 64
          [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_unmount" ]] || exit 1
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
              [[ $# -eq 7 && "${2:-}" == changePassphrase \
                && "${4:-}" == -user && "${5:-}" == disk \
                && "${6:-}" == -oldStdinpassphrase \
                && "${7:-}" == -newStdinpassphrase ]] || exit 64
              IFS= read -r fixture_old_passphrase || exit 1
              IFS= read -r fixture_new_passphrase || exit 1
              [[ "$fixture_old_passphrase" \
                == "$(fixture_read expected_lock_old_passphrase)" ]] \
                || exit 77
              [[ -n "$fixture_new_passphrase" ]] || exit 78
              if [[ -f "$VAULTLOCK_TEST_APFS_STATE/echo_change_passphrase_error" ]]; then
                printf 'old=%s new=%s\n' \
                  "$fixture_old_passphrase" "$fixture_new_passphrase"
                printf 'old=%s new=%s\n' \
                  "$fixture_old_passphrase" "$fixture_new_passphrase" >&2
                exit 1
              fi
              printf '%s' "$fixture_new_passphrase" \
                > "$VAULTLOCK_TEST_APFS_STATE/lock_new_passphrase"
              printf '%s' "$fixture_new_passphrase" \
                > "$VAULTLOCK_TEST_APFS_STATE/current_apfs_passphrase"
              : > "$VAULTLOCK_TEST_APFS_STATE/change_passphrase_stdin_verified"
              [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_change_passphrase" ]] \
                || exit 79
              ;;
            lockVolume)
              [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_lock_volume" ]] \
                || { printf 'fixture lock failure\n' >&2; exit 1; }
              fixture_write locked true
              fixture_write mounted false
              fixture_write mount_point ""
              printf 'Volume locked\n'
              ;;
            unlockVolume)
              IFS= read -r fixture_unlock_passphrase \
                || [[ -n "$fixture_unlock_passphrase" ]]
              if [[ -f "$VAULTLOCK_TEST_APFS_STATE/expected_unlock_passphrase" \
                  && "$fixture_unlock_passphrase" \
                    != "$(fixture_read expected_unlock_passphrase)" ]]; then
                exit 77
              fi
              : > "$VAULTLOCK_TEST_APFS_STATE/unlock_stdin_verified"
              fixture_write locked false
              if [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/unlock_leaves_unmounted" ]]; then
                fixture_write mounted true
                fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
              fi
              if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_identity_after_unlock" \
                  || -f "$VAULTLOCK_TEST_APFS_STATE/swap_uuid_after_unlock" ]]; then
                fixture_write uuid UUID-UNLOCK-SWAPPED
              fi
              if [[ -f "$VAULTLOCK_TEST_APFS_STATE/swap_identity_after_unlock" \
                  || -f "$VAULTLOCK_TEST_APFS_STATE/swap_device_after_unlock" ]]; then
                fixture_write device disk99s9
              fi
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
          exec "$VAULTLOCK_TEST_FAKE_BIN/$nested_command" "$@"
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
      case "${1:-}" in
        -i)
          [[ $# -eq 1 ]] || exit 64
          for fixture_secret_scope in unlock init lock_old lock_new; do
            if [[ -f "$VAULTLOCK_TEST_APFS_STATE/expected_child_${fixture_secret_scope}_secret" ]]; then
              : > "$VAULTLOCK_TEST_APFS_STATE/${fixture_secret_scope}_secret_environment_probe_ran"
            fi
          done
          IFS= read -r fixture_security_command || exit 1
          [[ "$fixture_security_command" == add-generic-password\ * ]] \
            || exit 64
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
          fixture_keychain_value=${fixture_security_command##* -w }
          fixture_keychain_value=${fixture_keychain_value% -U}
          printf '%s' "$fixture_keychain_value" \
            > "$VAULTLOCK_TEST_APFS_STATE/keychain_value"
          : > "$VAULTLOCK_TEST_APFS_STATE/keychain_marker"
          ;;
        find-generic-password)
          [[ $# -eq 6 && "${2:-}" == -a && "${4:-}" == -s \
            && "${6:-}" == -w ]] || exit 64
          [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_keychain_read" ]] \
            || exit 70
          [[ -f "$VAULTLOCK_TEST_APFS_STATE/keychain_value" ]] || exit 44
          printf '%s\n' "$(fixture_read keychain_value)"
          ;;
        delete-generic-password)
          [[ $# -eq 5 && "${2:-}" == -a && "${4:-}" == -s ]] \
            || exit 64
          [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_keychain_delete" ]] \
            || exit 1
          if [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/noop_keychain_delete" ]]; then
            /bin/rm -f "$VAULTLOCK_TEST_APFS_STATE/keychain_value" \
              "$VAULTLOCK_TEST_APFS_STATE/keychain_marker"
          fi
          ;;
        *) exit 64 ;;
      esac
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
      fixture_ditto_source_physical=$(cd -P -- "$fixture_ditto_source" \
        2>/dev/null && pwd -P) || fixture_ditto_source_physical=
      fixture_ditto_destination_parent=$(/usr/bin/dirname -- \
        "$fixture_ditto_destination")
      fixture_ditto_destination_leaf=$(/usr/bin/basename -- \
        "$fixture_ditto_destination")
      fixture_ditto_destination_parent=$(cd -P -- \
        "$fixture_ditto_destination_parent" 2>/dev/null && pwd -P) \
        || fixture_ditto_destination_parent=
      fixture_ditto_destination_physical=
      if [[ -n "$fixture_ditto_destination_parent" ]]; then
        fixture_ditto_destination_physical=\
$fixture_ditto_destination_parent/$fixture_ditto_destination_leaf
      fi
      case "$fixture_ditto_destination_physical/" in
        "$fixture_ditto_source_physical/"*)
          : > "$VAULTLOCK_TEST_APFS_STATE/ditto_destination_inside_source"
          exit 73
          ;;
      esac
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/foreign_deferred_lock_hook_owner" \
          && "$fixture_stat_path" \
            == "$VAULTLOCK_MOUNT_POINT/.vaultlock/hooks/pre-lock.d/"* \
          && " $* " == *" %d:%i:%Lp:%u:%l "* ]]; then
        fixture_foreign_hook_metadata=$(/usr/bin/stat "$@") || exit 1
        IFS=: read -r fixture_device fixture_inode fixture_mode _ \
          fixture_links <<< "$fixture_foreign_hook_metadata"
        printf '%s:%s:%s:999:%s\n' "$fixture_device" "$fixture_inode" \
          "$fixture_mode" "$fixture_links"
        exit 0
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/foreign_lock_artifact_owner" \
          && "$fixture_stat_path" \
            == "$VAULTLOCK_STATE_DIR/.unlock-recovery.foreign-owner" \
          && "${1:-}" == -f \
          && "${2:-}" == '%d:%i:%Lp:%u:%l' ]]; then
        fixture_foreign_lock_metadata=$(/usr/bin/stat "$@") || exit 1
        IFS=: read -r fixture_device fixture_inode fixture_mode _ \
          fixture_links <<< "$fixture_foreign_lock_metadata"
        printf '%s:%s:%s:999:%s\n' "$fixture_device" "$fixture_inode" \
          "$fixture_mode" "$fixture_links"
        exit 0
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_temp_identity_once" ]]; then
        fixture_unlock_temp_prefix=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_temp_identity_once")
        case "$fixture_stat_path" in
          "$VAULTLOCK_STATE_DIR/$fixture_unlock_temp_prefix"*)
            /bin/rm -f \
              "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_temp_identity_once"
            exit 1
            ;;
        esac
      fi
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_lock_artifact_find" \
          && " $* " == *" -name .passphrase-lock.* "* ]]; then
        exit 72
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/count_tree_traversals" \
          && " $* " == *" -print0 "* ]]; then
        if [[ " $* " == *" -type f "* ]]; then
          fixture_traversal_name=hardlink_index_traversal_count
        else
          fixture_traversal_name=tree_manifest_traversal_count
        fi
        fixture_tree_traversals=0
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/$fixture_traversal_name" ]] \
          || fixture_tree_traversals=$(< \
            "$VAULTLOCK_TEST_APFS_STATE/$fixture_traversal_name")
        fixture_tree_traversals=$((fixture_tree_traversals + 1))
        fixture_write "$fixture_traversal_name" "$fixture_tree_traversals"
        [[ "$fixture_tree_traversals" -le 64 ]] || exit 71
      fi
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_state_install" \
          && "$fixture_mv_source" == "$VAULTLOCK_STATE_DIR"/.state-unlock.* \
          && "$fixture_mv_destination" == "$VAULTLOCK_STATE_DIR/state.json" ]]; then
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_staging_cleanup" \
          && "$fixture_rm_path" == "$VAULTLOCK_STATE_DIR"/.unlock-recovery.* ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_private_temp_cleanup" ]]; then
        fixture_private_temp_prefix=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/fail_unlock_private_temp_cleanup")
        if [[ "$fixture_rm_path" \
            == "$VAULTLOCK_STATE_DIR/$fixture_private_temp_prefix"* ]]; then
          exit 1
        fi
      fi
      if [[ "$fixture_rm_path" == "$VAULTLOCK_STATE_DIR/passphrase.txt" ]]; then
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_lock_plaintext_remove" ]] \
          || exit 1
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/noop_lock_plaintext_remove" ]]; then
          exit 0
        fi
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/inherit_operation_lock_acl" \
          && "$fixture_mkdir_path" == "$HOME/.vaultlock-operation.lock" ]]; then
        /bin/chmod +a 'everyone allow read,file_inherit,directory_inherit' \
          "$fixture_mkdir_path" || exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/inherit_adopt_reservation_acl" \
          && "$fixture_mkdir_path" == *.vaultlock-backup ]]; then
        /bin/chmod +a 'everyone allow read,file_inherit,directory_inherit' \
          "$fixture_mkdir_path" || exit 1
      fi
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_operation_lock_acl_removal" \
          && "$fixture_chmod_mode" == "-N" \
          && "$fixture_chmod_path" == "$HOME/.vaultlock-operation.lock" ]]; then
        exit 1
      fi
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_adopt_reservation_acl_removal" \
          && "$fixture_chmod_mode" == "-N" \
          && "$fixture_chmod_path" == *.vaultlock-backup ]]; then
        exit 1
      fi
      /bin/chmod "$@"
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/tamper_hardlink_metadata_acl" \
          && "$fixture_chmod_mode" == "-N" \
          && "$fixture_chmod_path" == */vaultlock-hardlinks.* ]]; then
        fixture_hardlink_artifact=$(< \
          "$VAULTLOCK_TEST_APFS_STATE/tamper_hardlink_metadata_acl")
        fixture_hardlink_match=false
        case "$fixture_hardlink_artifact:$fixture_chmod_path" in
          map:*/vaultlock-hardlinks.*/map) fixture_hardlink_match=true ;;
          raw:*.raw|sorted:*.sorted|grouped:*.grouped)
            fixture_hardlink_match=true
            ;;
        esac
        if [[ "$fixture_hardlink_match" == true ]]; then
          /bin/chmod +a 'everyone allow read' "$fixture_chmod_path" \
            || exit 1
          printf '%s\n' "$fixture_chmod_path" \
            > "$VAULTLOCK_TEST_APFS_STATE/tampered_hardlink_metadata_path"
        fi
      fi
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
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/preplace_lock_mktemp_shape" \
        && "$fixture_mktemp_path" == "$VAULTLOCK_STATE_DIR"/.passphrase-lock.* ]]; then
      fixture_lock_mktemp_shape=$(fixture_read preplace_lock_mktemp_shape)
      fixture_lock_mktemp_victim=$(fixture_read lock_mktemp_victim)
      /bin/mv "$fixture_mktemp_path" "$fixture_mktemp_path.owned-created"
      if [[ "$fixture_lock_mktemp_shape" == symlink ]]; then
        /bin/ln -s "$fixture_lock_mktemp_victim" "$fixture_mktemp_path"
      elif [[ "$fixture_lock_mktemp_shape" == hardlink ]]; then
        /bin/ln "$fixture_lock_mktemp_victim" "$fixture_mktemp_path"
      else
        exit 64
      fi
      printf '%s\n' "$fixture_mktemp_path" \
        > "$VAULTLOCK_TEST_APFS_STATE/preplaced_lock_mktemp_path"
    fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/preplace_hardlink_metadata_symlink" \
        && "$fixture_mktemp_path" == */vaultlock-hardlinks.* ]]; then
      fixture_hardlink_preplaced_kind=$(< \
        "$VAULTLOCK_TEST_APFS_STATE/preplace_hardlink_metadata_symlink")
      fixture_hardlink_preplaced_target=$(< \
        "$VAULTLOCK_TEST_APFS_STATE/hardlink_metadata_symlink_target")
      if [[ -d "$fixture_mktemp_path" ]]; then
        fixture_hardlink_preplaced_path=$fixture_mktemp_path/$fixture_hardlink_preplaced_kind
      else
        fixture_hardlink_preplaced_path=$fixture_mktemp_path.$fixture_hardlink_preplaced_kind
      fi
      /bin/ln -s "$fixture_hardlink_preplaced_target" \
        "$fixture_hardlink_preplaced_path" || exit 1
      printf '%s\n' "$fixture_hardlink_preplaced_path" \
        > "$VAULTLOCK_TEST_APFS_STATE/hardlink_metadata_preplaced_path"
    fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/inherit_recovery_acl" \
      && "$fixture_mktemp_path" == "$VAULTLOCK_STATE_DIR/.passphrase."* ]]; then
      /bin/chmod +a 'everyone allow read' "$fixture_mktemp_path" || exit 1
    fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/inherit_operation_owner_acl" \
        && "$fixture_mktemp_path" == "$HOME/.vaultlock-operation.lock/.owner."* ]]; then
      /bin/chmod +a 'everyone allow read' "$fixture_mktemp_path" || exit 1
    fi
    if [[ -f "$VAULTLOCK_TEST_APFS_STATE/inherit_adopt_quarantine_acl" \
        && -d "$fixture_mktemp_path" \
        && "$fixture_mktemp_path" == *.vaultlock-quarantine.* ]]; then
      /bin/chmod +a 'everyone allow read,file_inherit,directory_inherit' \
        "$fixture_mktemp_path" || exit 1
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
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/dead_process_pid" \
          && "${2:-}" == "$(fixture_read dead_process_pid)" ]]; then
        exit 1
      fi
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
      signal_HUP|signal_INT|signal_TERM|signal_KILL)
        fixture_transition_signal=${fixture_transition_action#signal_}
        if [[ "$fixture_transition_signal" == KILL ]]; then
          printf '%s\n' "$PPID" \
            > "$VAULTLOCK_TEST_APFS_STATE/dead_process_pid"
        fi
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
        operation_lock_acl_tamper)
          /bin/chmod +a 'everyone allow read' "$fixture_subject"
          ;;
        adopt_quarantine_acl_tamper)
          /bin/chmod +a 'everyone allow read' "$fixture_subject"
          ;;
        adopt_skeleton_acl_inherit|adopt_skeleton_acl_tamper)
          /bin/chmod +a 'everyone allow read' "$fixture_subject"
          ;;
        adopt_current_snapshot_acl_tamper)
          /bin/chmod +a 'everyone allow read' "$fixture_subject"
          printf 'tampered current snapshot\n' >> "$fixture_subject"
          printf '%s\n' "$fixture_subject" \
            > "$VAULTLOCK_TEST_APFS_STATE/tampered_current_snapshot_path"
          ;;
        state_file_retarget_into_source)
          /bin/rm -f "$VAULTLOCK_STATE_DIR/state.json"
          /bin/ln -s "$fixture_subject/retarget-state.json" \
            "$VAULTLOCK_STATE_DIR/state.json"
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
        unlock_apfs_state_swap)
          fixture_write locked false
          fixture_write mounted true
          fixture_write mount_point "$VAULTLOCK_MOUNT_POINT"
          ;;
        unlock_device_revalidation_swap)
          fixture_write device disk9s2
          ;;
        unlock_deadline_round_change)
          fixture_changed_state=$(jq \
            '.deadline = "2000-01-01T00:01:00+0000"
            | .deadline_epoch = 61 | .round = 2' \
            "$VAULTLOCK_STATE_DIR/state.json") || exit 1
          printf '%s\n' "$fixture_changed_state" \
            > "$VAULTLOCK_STATE_DIR/state.json"
          ;;
        unlock_recovery_replace)
          /bin/rm -f "$VAULTLOCK_STATE_DIR/passphrase.txt"
          printf 'VGFtcGVyZWRTZWNyZXQ=' \
            > "$VAULTLOCK_STATE_DIR/passphrase.txt"
          /usr/bin/shasum -a 256 "$VAULTLOCK_STATE_DIR/passphrase.txt" \
            | /usr/bin/cut -d' ' -f1 \
            > "$VAULTLOCK_STATE_DIR/passphrase.sha256"
          ;;
        unlock_state_future_replace)
          printf '%s\n' \
            '{"locked":true,"volume_uuid":"UUID-123","created":"race","deadline":"2099-01-02T03:04:00+0100","deadline_epoch":4070999040,"round":792731235}' \
            > "$VAULTLOCK_STATE_DIR/state.json"
          ;;
        unlock_keychain_change)
          printf 'Q2hhbmdlZEtleWNoYWlu\n' \
            > "$VAULTLOCK_TEST_APFS_STATE/keychain_value"
          ;;
        unlock_staging_artifact_create)
          printf 'post-revalidation plaintext artifact\n' \
            > "$VAULTLOCK_STATE_DIR/.unlock-recovery.post-revalidation"
          ;;
        unlock_apfs_uuid_swap)
          fixture_write uuid UUID-IMMEDIATE-SWAP
          ;;
        unlock_apfs_device_swap)
          fixture_write device disk9s2
          ;;
        unlock_apfs_lock_swap)
          fixture_write locked false
          ;;
        unlock_plaintext_stage_fail)
          exit 75
          ;;
        unlock_tle_error_stage_fail)
          exit 76
          ;;
        unlock_state_stage_fail)
          exit 77
          ;;
        unlock_hook_create)
          /bin/mkdir -p "$VAULTLOCK_STATE_DIR/hooks/post-unlock.d"
          /bin/cp "$0" \
            "$VAULTLOCK_STATE_DIR/hooks/post-unlock.d/drift-hook"
          /bin/chmod +x \
            "$VAULTLOCK_STATE_DIR/hooks/post-unlock.d/drift-hook"
          ;;
        hold_unlock_execution)
          : > "$VAULTLOCK_TEST_APFS_STATE/unlock_execution_entered"
          while [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/release_unlock_execution" ]]; do
            /bin/sleep 0.01
          done
          ;;
        lock_apfs_state_swap)
          fixture_write device disk9s2
          ;;
        lock_artifact_create)
          printf 'crash artifact\n' \
            > "$VAULTLOCK_STATE_DIR/.unlock-recovery.post-lock"
          ;;
        lock_artifact_swap)
          printf 'original crash artifact\n' \
            > "$VAULTLOCK_STATE_DIR/.unlock-recovery.swap"
          /bin/mv "$VAULTLOCK_STATE_DIR/.unlock-recovery.swap" \
            "$VAULTLOCK_STATE_DIR/.unlock-recovery.swap.original"
          printf 'replacement crash artifact\n' \
            > "$VAULTLOCK_STATE_DIR/.unlock-recovery.swap"
          ;;
        lock_plaintext_identity_swap)
          fixture_plaintext_victim=\
$VAULTLOCK_TEST_APFS_STATE/plaintext-delete-victim
          /bin/mv "$VAULTLOCK_STATE_DIR/passphrase.txt" \
            "$VAULTLOCK_STATE_DIR/passphrase.txt.pre-swap"
          /bin/ln -s "$fixture_plaintext_victim" \
            "$VAULTLOCK_STATE_DIR/passphrase.txt"
          ;;
        lock_fixed_stage_symlink)
          fixture_fixed_stage_victim=\
$VAULTLOCK_TEST_APFS_STATE/fixed-stage-victim
          /bin/ln -s "$fixture_fixed_stage_victim" \
            "$VAULTLOCK_STATE_DIR/passphrase-new.txt"
          ;;
        lock_change_device_swap)
          fixture_write device disk9s2
          ;;
        lock_volume_device_swap)
          fixture_write device disk9s2
          ;;
        lock_change_state_swap)
          printf '{"locked":false,"volume_uuid":"UUID-123","created":"change-race","deadline":null,"deadline_epoch":null,"round":null}\n' \
            > "$VAULTLOCK_STATE_DIR/state.json"
          ;;
        lock_volume_cipher_swap)
          printf 'swapped ciphertext\n' \
            > "$VAULTLOCK_STATE_DIR/passphrase.tle"
          ;;
        lock_delete_state_swap)
          jq '.deletion_race = true' "$VAULTLOCK_STATE_DIR/state.json" \
            > "$VAULTLOCK_STATE_DIR/state.json.deletion-race"
          /bin/mv "$VAULTLOCK_STATE_DIR/state.json.deletion-race" \
            "$VAULTLOCK_STATE_DIR/state.json"
          ;;
        lock_delete_cipher_swap)
          printf 'deletion-race ciphertext\n' \
            > "$VAULTLOCK_STATE_DIR/passphrase.tle"
          ;;
        lock_delete_hash_swap)
          printf '%064d\n' 0 > "$VAULTLOCK_STATE_DIR/passphrase.sha256"
          ;;
        lock_delete_keychain_swap)
          printf 'ZGVsZXRpb24tcmFjZS1rZXk=' \
            > "$VAULTLOCK_TEST_APFS_STATE/keychain_value"
          ;;
        lock_deferred_hook_identity_swap)
          /bin/mv "$fixture_subject" "$fixture_subject.pre-swap"
          /bin/cp "$0" "$fixture_subject"
          /bin/chmod +x "$fixture_subject"
          ;;
        lock_deferred_hook_link_swap)
          /bin/mv "$fixture_subject" "$fixture_subject.pre-swap"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/deferred-hook-target" \
            "$fixture_subject"
          ;;
        lock_deferred_hook_target_swap)
          fixture_hook_target=$VAULTLOCK_TEST_APFS_STATE/deferred-hook-target
          /bin/mv "$fixture_hook_target" "$fixture_hook_target.pre-swap"
          /bin/cp "$0" "$fixture_hook_target"
          /bin/chmod +x "$fixture_hook_target"
          ;;
        lock_planned_hook_link_swap)
          fixture_planned_hook=\
$VAULTLOCK_STATE_DIR/hooks/pre-lock.d/10-planned-link
          /bin/mv "$fixture_planned_hook" "$fixture_planned_hook.pre-swap"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/planned-hook-target" \
            "$fixture_planned_hook"
          ;;
        lock_planned_hook_target_swap)
          fixture_hook_target=$VAULTLOCK_TEST_APFS_STATE/planned-hook-target
          /bin/mv "$fixture_hook_target" "$fixture_hook_target.pre-swap"
          /bin/cp "$0" "$fixture_hook_target"
          /bin/chmod +x "$fixture_hook_target"
          ;;
        lock_repair_keychain_swap)
          printf 'cmVwbGFjZW1lbnQta2V5Y2hhaW4=' \
            > "$VAULTLOCK_TEST_APFS_STATE/keychain_value"
          ;;
        lock_state_dir_swap)
          /bin/mv "$VAULTLOCK_STATE_DIR" \
            "$VAULTLOCK_STATE_DIR.pre-stage"
          /bin/mkdir "$VAULTLOCK_STATE_DIR"
          /bin/chmod 700 "$VAULTLOCK_STATE_DIR"
          ;;
        lock_staged_recovery_swap)
          fixture_stage=$VAULTLOCK_STATE_DIR/passphrase-new.txt
          /bin/mv "$fixture_stage" \
            "$VAULTLOCK_TEST_APFS_STATE/staged-recovery-original"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/install-race-victim" \
            "$fixture_stage"
          ;;
        lock_plaintext_install_swap)
          fixture_destination=$VAULTLOCK_STATE_DIR/passphrase.txt
          /bin/mv "$fixture_destination" \
            "$VAULTLOCK_TEST_APFS_STATE/plaintext-install-original"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/install-race-victim" \
            "$fixture_destination"
          ;;
        lock_keychain_update_swap)
          printf 'cmVwbGFjZW1lbnQta2V5Y2hhaW4=' \
            > "$VAULTLOCK_TEST_APFS_STATE/keychain_value"
          ;;
        lock_ciphertext_install_swap)
          /bin/mv "$VAULTLOCK_STATE_DIR/passphrase.tle" \
            "$VAULTLOCK_TEST_APFS_STATE/ciphertext-install-original"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/install-race-victim" \
            "$VAULTLOCK_STATE_DIR/passphrase.tle"
          ;;
        lock_hash_install_swap)
          fixture_destination=$VAULTLOCK_STATE_DIR/passphrase.sha256
          /bin/mv "$fixture_destination" \
            "$VAULTLOCK_TEST_APFS_STATE/hash-install-original"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/install-race-victim" \
            "$fixture_destination"
          ;;
        lock_state_install_swap)
          fixture_destination=$VAULTLOCK_STATE_DIR/state.json
          /bin/mv "$fixture_destination" \
            "$VAULTLOCK_TEST_APFS_STATE/state-install-original"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/install-race-victim" \
            "$fixture_destination"
          ;;
        lock_state_stage_swap)
          fixture_stage=$(/usr/bin/find "$VAULTLOCK_STATE_DIR" \
            -maxdepth 1 -name '.state-lock.*' -type f -print -quit) \
            || exit 1
          [[ -n "$fixture_stage" ]] || exit 1
          /bin/mv "$fixture_stage" \
            "$VAULTLOCK_TEST_APFS_STATE/state-stage-original"
          /bin/ln -s "$VAULTLOCK_TEST_APFS_STATE/install-race-victim" \
            "$fixture_stage"
          ;;
        lock_pre_rotation_abort)
          exit 79
          ;;
        hold_lock_execution)
          : > "$VAULTLOCK_TEST_APFS_STATE/lock_execution_entered"
          while [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/release_lock_execution" ]]; do
            /bin/sleep 0.01
          done
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
    tle)
      if [[ " $* " == *" -e "* ]]; then
        fixture_tle_output=""
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == -o ]]; then
            shift
            fixture_tle_output=${1:-}
            break
          fi
          shift
        done
        [[ -n "$fixture_tle_output" ]] || exit 64
        IFS= read -r fixture_tle_plaintext || exit 1
        [[ "$fixture_tle_plaintext" \
          == "$(fixture_read lock_new_passphrase)" ]] || exit 77
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/echo_tle_encrypt_error" ]]; then
          printf 'tle plaintext=%s\n' "$fixture_tle_plaintext"
          printf 'tle plaintext=%s\n' "$fixture_tle_plaintext" >&2
          exit 2
        fi
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_tle_encrypt" ]] || exit 2
        printf 'fixture lock ciphertext\n' > "$fixture_tle_output"
        printf '%s' "$fixture_tle_plaintext" \
          | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1 \
          > "$VAULTLOCK_TEST_APFS_STATE/tle_lock_plaintext_digest"
        : > "$VAULTLOCK_TEST_APFS_STATE/lock_ciphertext_created"
      elif [[ " $* " == *" -d "* ]]; then
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/lock_ciphertext_created" ]]; then
          if [[ -f "$VAULTLOCK_TEST_APFS_STATE/lock_tle_decrypts_early" ]]; then
            fixture_read lock_new_passphrase
            exit 0
          fi
          if [[ -f "$VAULTLOCK_TEST_APFS_STATE/lock_tle_unexpected_error" ]]; then
            printf 'unexpected fixture failure\n' >&2
            exit 2
          fi
          if [[ -f "$VAULTLOCK_TEST_APFS_STATE/echo_tle_decrypt_error" ]]; then
            printf 'old=%s new=%s\n' \
              "$(fixture_read expected_lock_old_passphrase)" \
              "$(fixture_read lock_new_passphrase)"
            printf 'old=%s new=%s\n' \
              "$(fixture_read expected_lock_old_passphrase)" \
              "$(fixture_read lock_new_passphrase)" >&2
            exit 2
          fi
          printf 'too early for requested round\n' >&2
          exit 1
        fi
        if [[ -f "$VAULTLOCK_TEST_APFS_STATE/tle_early" ]]; then
          printf 'too early for requested round\n' >&2
          exit 1
        fi
        [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_tle" ]] \
          || { printf 'fixture tle failure\n' >&2; exit 2; }
        fixture_read tle_plaintext || exit 3
      fi
      ;;
    mount)
      ;;
    tmutil)
      case "${1:-}" in
        addexclusion)
          if [[ " $* " == *" -p "* \
              && -f "$VAULTLOCK_TEST_APFS_STATE/fail_state_tm_exclusion" ]]; then
            exit 75
          fi
          ;;
        isexcluded)
          [[ $# -eq 3 && "${2:-}" == -X ]] || exit 64
          [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_state_tm_verification" ]] \
            || exit 76
          if [[ -f "$VAULTLOCK_TEST_APFS_STATE/state_tm_included" ]]; then
            fixture_tm_excluded=0
          elif [[ -f "$VAULTLOCK_TEST_APFS_STATE/state_tm_malformed" ]]; then
            printf 'not a plist\n'
            exit 0
          else
            fixture_tm_excluded=1
          fi
          if [[ -f "$VAULTLOCK_TEST_APFS_STATE/state_tm_wrong_path" ]]; then
            fixture_tm_path=/unrelated/excluded-directory
          else
            fixture_tm_path=${3:-}
          fi
          printf '%s\n' \
            '<?xml version="1.0" encoding="UTF-8"?>' \
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
            '<plist version="1.0"><array><dict>' \
            "<key>Path</key><string>$fixture_tm_path</string>" \
            "<key>IsExcluded</key><integer>$fixture_tm_excluded</integer>" \
            '</dict>'
          if [[ -f "$VAULTLOCK_TEST_APFS_STATE/state_tm_multiple_records" ]]; then
            printf '%s\n' \
              '<dict><key>Path</key><string>/unexpected/second-item</string>' \
              '<key>IsExcluded</key><integer>1</integer></dict>'
          fi
          printf '%s\n' '</array></plist>'
          ;;
        deletelocalsnapshots)
          if [[ "${2:-}" == "$VAULTLOCK_MOUNT_POINT" \
              && -f "$VAULTLOCK_TEST_APFS_STATE/fail_vault_snapshot_cleanup" ]]; then
            exit 77
          fi
          if [[ "${2:-}" == /System/Volumes/Data \
              && -f "$VAULTLOCK_TEST_APFS_STATE/fail_data_snapshot_cleanup" ]]; then
            exit 78
          fi
          ;;
        *) exit 64 ;;
      esac
      ;;
    curl)
      [[ ! -f "$VAULTLOCK_TEST_APFS_STATE/fail_curl" ]] || exit 1
      ;;
    *)
      # Hook fixtures use the same dispatcher and only record their argv.
      if [[ " $* " == *" --phase post-unlock "* \
          && -f "$VAULTLOCK_TEST_APFS_STATE/verify_post_hook_target" ]]; then
        [[ "$(fixture_read locked)" == false \
          && "$(fixture_read mounted)" == true \
          && "$(fixture_read mount_point)" == "$VAULTLOCK_MOUNT_POINT" \
          && "$(jq -r .locked "$VAULTLOCK_STATE_DIR/state.json")" == false \
          && -f "$VAULTLOCK_STATE_DIR/passphrase.txt" \
          && -f "$VAULTLOCK_STATE_DIR/passphrase.sha256" \
          && -f "$VAULTLOCK_TEST_APFS_STATE/keychain_value" \
          && "$(< "$VAULTLOCK_STATE_DIR/passphrase.txt")" \
            == "$(fixture_read keychain_value)" ]] || exit 74
        : > "$VAULTLOCK_TEST_APFS_STATE/post_hook_saw_usable_target"
      fi
      if [[ " $* " == *" --phase post-lock "* \
          && -f "$VAULTLOCK_TEST_APFS_STATE/verify_post_lock_target" ]]; then
        [[ "$(fixture_read locked)" == true \
          && "$(fixture_read mounted)" == false \
          && "$(jq -r .locked "$VAULTLOCK_STATE_DIR/state.json")" == true \
          && ! -e "$VAULTLOCK_STATE_DIR/passphrase.txt" \
          && -s "$VAULTLOCK_STATE_DIR/passphrase.tle" \
          && -s "$VAULTLOCK_STATE_DIR/passphrase.sha256" \
          && ! -e "$VAULTLOCK_TEST_APFS_STATE/keychain_value" ]] || exit 74
        : > "$VAULTLOCK_TEST_APFS_STATE/post_lock_hook_saw_secure_target"
      fi
      if [[ "$fixture_command" == 20-post-metadata-tamper \
          && -f "$VAULTLOCK_TEST_APFS_STATE/tamper_plaintext_mode_in_post_hook" ]]; then
        case "$(fixture_read tamper_plaintext_mode_in_post_hook)" in
          mode) /bin/chmod 644 "$VAULTLOCK_STATE_DIR/passphrase.txt" || exit 1 ;;
          acl)
            /bin/chmod +a 'everyone allow read' \
              "$VAULTLOCK_STATE_DIR/passphrase.txt" || exit 1
            ;;
          *) exit 64 ;;
        esac
      fi
      if [[ "$fixture_command" == 20-deferred-identity-swap \
          && -f "$VAULTLOCK_TEST_APFS_STATE/tamper_mount_identity_in_post_hook" ]]; then
        fixture_write uuid UUID-POST-HOOK-SWAP
      fi
      if [[ "$fixture_command" == 10-global-lock-identity-swap \
          && -f "$VAULTLOCK_TEST_APFS_STATE/tamper_mount_identity_in_pre_lock_hook" ]]; then
        fixture_write uuid UUID-PRE-LOCK-SWAP
      fi
      if [[ "$fixture_command" == 10-global-lock-state-swap \
          && -f "$VAULTLOCK_TEST_APFS_STATE/tamper_state_in_pre_lock_hook" ]]; then
        printf '%s\n' \
          '{"locked":false,"volume_uuid":"UUID-123","created":"hook-swap","deadline":null,"deadline_epoch":null,"round":null}' \
          > "$VAULTLOCK_STATE_DIR/state.json"
      fi
      case "$fixture_command" in
        10-post-lock-state-tamper)
          jq '.post_hook_tamper = true' "$VAULTLOCK_STATE_DIR/state.json" \
            > "$VAULTLOCK_STATE_DIR/state.json.post-tamper" || exit 1
          /bin/mv "$VAULTLOCK_STATE_DIR/state.json.post-tamper" \
            "$VAULTLOCK_STATE_DIR/state.json"
          ;;
        10-post-lock-cipher-tamper)
          printf 'post-hook ciphertext tamper\n' \
            > "$VAULTLOCK_STATE_DIR/passphrase.tle"
          ;;
        10-post-lock-hash-tamper)
          printf '%064d\n' 0 > "$VAULTLOCK_STATE_DIR/passphrase.sha256"
          ;;
      esac
      if [[ -f "$VAULTLOCK_TEST_APFS_STATE/fail_hook_name" \
          && "$fixture_command" \
            == "$(fixture_read fail_hook_name)" ]]; then
        exit 73
      fi
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
/bin/chmod 700 "$state_dir"
umask 077
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
  local -a vaultlock_command=(/bin/bash)
  if [[ "${VAULTLOCK_TEST_ALLEXPORT:-0}" == 1 ]]; then
    vaultlock_command+=( -a )
  fi
  if [[ "${VAULTLOCK_TEST_NOGLOB:-0}" == 1 ]]; then
    vaultlock_command+=( -f )
  fi
  if [[ "${VAULTLOCK_TEST_HOSTILE_GLOBS:-0}" == 1 ]]; then
    vaultlock_command+=( -O dotglob -O failglob -O nullglob )
  fi
  vaultlock_command+=( "$VL" "$@" )
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
  VAULTLOCK_TEST_LOCK_CRYPTO_MARKER_LOG="$apfs_state/lock-crypto-markers" \
  VAULTLOCK_TEST_ACTION_LOG="$action_log" \
  VAULTLOCK_TEST_MUTATION_LOG="$mutation_log" \
  VAULTLOCK_TEST_HOOK_LOG="$hook_log" \
  VAULTLOCK_TEST_APFS_STATE="$apfs_state" \
  GLOBIGNORE="${GLOBIGNORE-}" \
  "${vaultlock_command[@]}"
}

run_vaultlock_with_imported_secret_names() (
  export INIT_PASSPHRASE=caller-controlled
  export UNLOCK_PASSPHRASE=caller-controlled
  export content=caller-controlled value=caller-controlled
  export passphrase=caller-controlled expected_plaintext=caller-controlled
  export plaintext=caller-controlled decrypted_recovery=caller-controlled
  export LOCK_PASSPHRASE=caller-controlled
  export lock_old_passphrase=caller-controlled lock_new_passphrase=caller-controlled
  export old_passphrase=caller-controlled new_passphrase=caller-controlled
  export lock_plaintext=caller-controlled
  export actual_content=caller-controlled
  VAULTLOCK_TEST_ALLEXPORT=1 run_vaultlock "$@"
)

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
    "VAULTLOCK_TEST_LOCK_CRYPTO_MARKER_LOG=$apfs_state/lock-crypto-markers" \
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
  VAULTLOCK_TEST_LOCK_CRYPTO_MARKER_LOG="$apfs_state/lock-crypto-markers" \
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
    "$apfs_state/inherit_operation_lock_acl" \
    "$apfs_state/inherit_operation_owner_acl" \
    "$apfs_state/fail_operation_lock_acl_removal" \
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

for status_operand in extra --dry-run; do
  : > "$action_log"
  if status_operand_output=$(run_vaultlock status "$status_operand" 2>&1); then
    status_operand_status=0
    record_failure "status rejects trailing operand $status_operand"
  else
    status_operand_status=$?
  fi
  check "status trailing operand $status_operand exits with usage status" \
    64 "$status_operand_status"
  check_contains "status trailing operand $status_operand reports usage" \
    'usage: vaultlock status' "$status_operand_output"
  check_empty "status trailing operand $status_operand performs no inspection" \
    "$action_log"
done

if help_output=$(run_vaultlock help 2>&1); then
  help_status=0
else
  help_status=$?
fi
check "help exits with usage status" 64 "$help_status"
check_line "help lists init safety options" \
  '  init [--dry-run] [--yes] create the encrypted vault volume' \
  "$help_output"
check_line "help lists adopt safety options" \
  '  adopt [--dry-run] [--yes] <dir>' "$help_output"

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
fake_hash=$(printf '%s' "$fake_passphrase" \
  | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)
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
printf '%s' "$fake_passphrase" > "$apfs_state/keychain_value"
: > "$apfs_state/keychain_marker"
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
  6. Persistently exclude the protected state directory from Time Machine and verify the exclusion
  7. Add the vault volume root to Time Machine exclusions
  8. Delete local Time Machine snapshots for the vault
  9. Unmount the vault
  10. Generate and durably stage a new random recovery passphrase
  11. Rotate the APFS volume passphrase, then commit the staged plaintext recovery file
  12. Update the keychain with the rotated recovery material
  13. Encrypt the rotated recovery material for the resolved drand round
  14. Verify the time-lock ciphertext is nonempty and not yet decryptable
  15. Write the recovery hash and durably record the locked deadline and round
  16. Remove plaintext recovery material and its keychain entry
  17. Delete local Time Machine snapshots for the data volume
  18. Lock the APFS volume
  19. Verify APFS encryption, locked state, and failed unauthenticated mounting
Confirmation:
EOF
)
check "lock dry-run ordered actions" "$expected_lock_actions" "$lock_actions"
check "lock dry-run final result" 'Result: no changes made' \
  "$(tail -n 1 <<< "$lock_plan")"
audit_lock_state_dir=$(printf '%q' "$state_dir")
audit_lock_state_file=$(printf '%q' "$state_dir/state.json")
audit_lock_plaintext=$(printf '%q' "$state_dir/passphrase.txt")
audit_lock_ciphertext=$(printf '%q' "$state_dir/passphrase.tle")
audit_lock_hash=$(printf '%q' "$state_dir/passphrase.sha256")
audit_lock_passphrase_new=$(printf '%q' 'passphrase-new.txt')
audit_lock_unlock_recovery=$(printf '%q' '.unlock-recovery.*')
audit_lock_tle_unlock=$(printf '%q' '.tle-unlock.*')
audit_lock_state_unlock=$(printf '%q' '.state-unlock.*')
audit_lock_passphrase_stage=$(printf '%q' '.passphrase-lock.*')
audit_lock_tle_stage=$(printf '%q' '.tle-lock.*')
audit_lock_hash_stage=$(printf '%q' '.hash-lock.*')
audit_lock_state_stage=$(printf '%q' '.state-lock.*')
audit_lock_tle_verify=$(printf '%q' '.tle-verify.*')
audit_lock_security_output=$(printf '%q' '.security-output.*')
expected_lock_reads=$(cat <<EOF
diskutil info -plist UUID-123
find -P $audit_lock_state_dir -mindepth 1 -maxdepth 1 \( -name $audit_lock_passphrase_new -o -name $audit_lock_unlock_recovery -o -name $audit_lock_tle_unlock -o -name $audit_lock_state_unlock -o -name $audit_lock_passphrase_stage -o -name $audit_lock_tle_stage -o -name $audit_lock_hash_stage -o -name $audit_lock_state_stage -o -name $audit_lock_tle_verify -o -name $audit_lock_security_output \) -print0
stat -f %d:%i:%Lp:%u:%l -- $audit_lock_state_dir
ls -ldeB -- $audit_lock_state_dir
stat -f %d:%i:%Lp:%u:%l -- $audit_lock_state_file
ls -ldeB -- $audit_lock_state_file
stat -f %d:%i:%Lp:%u:%l -- $audit_lock_plaintext
ls -ldeB -- $audit_lock_plaintext
stat -f %d:%i:%Lp:%u:%l -- $audit_lock_ciphertext
ls -ldeB -- $audit_lock_ciphertext
stat -f %d:%i:%Lp:%u:%l -- $audit_lock_hash
ls -ldeB -- $audit_lock_hash
security find-generic-password -a $USER -s vaultlock-vault -w
curl -fsS --max-time 10 https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info
EOF
)
check "lock dry-run audit contains only allowlisted reads" \
  "$expected_lock_reads" \
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
audit_state_dir=$(printf '%q' "$state_dir")
audit_state_file=$(printf '%q' "$state_dir/state.json")
audit_ciphertext=$(printf '%q' "$state_dir/passphrase.tle")
audit_hash=$(printf '%q' "$state_dir/passphrase.sha256")
audit_pre_hook=$(printf '%q' "$state_dir/hooks/pre-unlock.d/10-pre hook")
audit_post_hook=$(printf '%q' "$state_dir/hooks/post-unlock.d/20-post hook")
audit_staging_pattern=$(printf '%q' '.unlock-recovery.*')
audit_tle_pattern=$(printf '%q' '.tle-unlock.*')
audit_state_staging_pattern=$(printf '%q' '.state-unlock.*')
expected_unlock_reads=$(cat <<EOF
diskutil info -plist UUID-123
stat -f %d:%i:%Lp:%u:%l -- $audit_state_dir
ls -ldeB -- $audit_state_dir
find -P $audit_state_dir -mindepth 1 -maxdepth 1 \( -name $audit_staging_pattern -o -name $audit_tle_pattern -o -name $audit_state_staging_pattern \) -print -quit
stat -f %d:%i:%Lp:%u:%l -- $audit_state_file
ls -ldeB -- $audit_state_file
stat -f %d:%i:%Lp:%u:%l -- $audit_ciphertext
ls -ldeB -- $audit_ciphertext
stat -f %d:%i:%Lp:%u:%l -- $audit_hash
ls -ldeB -- $audit_hash
curl -fsS --max-time 10 https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info
stat -f %d:%i:%HT:%Lp:%u:%l -- $audit_pre_hook
stat -f %d:%i:%HT:%Lp:%u:%l -- $audit_post_hook
EOF
)
check "unlock dry-run audit contains only allowlisted reads" \
  "$expected_unlock_reads" \
  "$(< "$action_log")"
check_empty "unlock dry-run mutation log" "$mutation_log"
check_count "unlock dry-run executes no hooks" 0 \
  '--phase ' "$(< "$hook_log")"
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
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s' "$fake_passphrase" > "$apfs_state/keychain_value"
rm -f "$state_dir/passphrase.tle"
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

for keychain_plan_mount_state in mounted unmounted; do
  for keychain_plan_material in missing stale; do
    write_json_state false null null null UUID-123
    if [[ "$keychain_plan_mount_state" == mounted ]]; then
      write_apfs_state false true UUID-123 disk9s1
    else
      write_apfs_state false false UUID-123 disk9s1
    fi
    printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
    printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
    rm -f "$state_dir/passphrase.tle" "$apfs_state/keychain_value"
    if [[ "$keychain_plan_material" == stale ]]; then
      printf 'stale-keychain-value' > "$apfs_state/keychain_value"
    fi
    keychain_repair_plan=$(run_vaultlock unlock --dry-run)
    check_contains \
      "$keychain_plan_mount_state $keychain_plan_material keychain repair is typed as an update" \
      'Update the keychain with the verified recovery material' \
      "$keychain_repair_plan"
    check_count \
      "$keychain_plan_mount_state $keychain_plan_material keychain repair plans no hooks" \
      0 'Run hook ' "$keychain_repair_plan"
  done
done

write_json_state false null null null UUID-123
write_apfs_state false false UUID-123 disk9s1
printf '%s\n' "$fake_passphrase" > "$state_dir/passphrase.txt"
printf '%s\n' "$fake_hash" > "$state_dir/passphrase.sha256"
printf '%s' "$fake_passphrase" > "$apfs_state/keychain_value"
rm -f "$state_dir/passphrase.tle"
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
    "$apfs_state/inherit_adopt_reservation_acl" \
    "$apfs_state/fail_adopt_reservation_acl_removal" \
    "$apfs_state/inherit_adopt_quarantine_acl" \
    "$apfs_state/tamper_hardlink_metadata_acl" \
    "$apfs_state/tampered_hardlink_metadata_path" \
    "$apfs_state/preplace_hardlink_metadata_symlink" \
    "$apfs_state/hardlink_metadata_symlink_target" \
    "$apfs_state/hardlink_metadata_preplaced_path" \
    "$apfs_state/tampered_current_snapshot_path" \
    "$apfs_state/count_directory_traversals" \
    "$apfs_state/directory_traversal_count" \
    "$apfs_state/count_tree_traversals" \
    "$apfs_state/hardlink_index_traversal_count" \
    "$apfs_state/tree_manifest_traversal_count" \
    "$apfs_state/ditto_destination_inside_source" \
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
    "$apfs_state/transition_adopt_before_current_directory_snapshot_cleanup" \
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
reset_adopt_fixture
mount_parent_source=${mount_point%/*}
mount_parent_identity=$(/usr/bin/stat -f '%d:%i' "$mount_parent_source")
if mount_parent_output=$(run_vaultlock adopt --yes \
    "$mount_parent_source//" 2>&1); then
  record_failure "adopt rejects normalized mount parent"
else
  check_contains "adopt mount parent reports containment" \
    'contains the expected mount point' "$mount_parent_output"
fi
check "adopt mount parent preserves source identity" "$mount_parent_identity" \
  "$(/usr/bin/stat -f '%d:%i' "$mount_parent_source")"
check_count "adopt mount parent stops before ditto" 0 'ditto ' \
  "$(< "$mutation_log")"
[[ ! -e "$apfs_state/ditto_destination_inside_source" ]] \
  || record_failure "adopt mount parent reaches recursive ditto boundary"
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

for hardlink_metadata_artifact in map raw sorted grouped; do
  reset_adopt_fixture
  hardlink_metadata_source=$(new_adopt_source \
    "hardlink-metadata-$hardlink_metadata_artifact")
  printf '%s\n' "$hardlink_metadata_artifact" \
    > "$apfs_state/tamper_hardlink_metadata_acl"
  expect_adopt_precopy_manifest_refusal \
    "adopt rejects $hardlink_metadata_artifact hardlink metadata ACL tamper" \
    - "$hardlink_metadata_source"
  if [[ -f "$apfs_state/tampered_hardlink_metadata_path" ]]; then
    hardlink_metadata_retained=$(< \
      "$apfs_state/tampered_hardlink_metadata_path")
    if [[ -f "$hardlink_metadata_retained" \
        && ! -L "$hardlink_metadata_retained" \
        && "$hardlink_metadata_retained" == */vaultlock-hardlinks.* ]]; then
      hardlink_metadata_acl_count=$(/bin/ls -ldeB \
        "$hardlink_metadata_retained" | /usr/bin/tail -n +2 \
        | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
      [[ "$hardlink_metadata_acl_count" -ge 1 ]] \
        || record_failure \
          "adopt retains ACL-tampered $hardlink_metadata_artifact hardlink metadata"
      hardlink_metadata_workspace=${hardlink_metadata_retained%/*}
      /bin/chmod -N "$hardlink_metadata_retained"
      /bin/rm -f -- "$hardlink_metadata_retained"
      [[ "$hardlink_metadata_workspace" == */vaultlock-hardlinks.* ]] \
        && /bin/rmdir "$hardlink_metadata_workspace" 2>/dev/null || true
    else
      record_failure \
        "adopt retains ACL-tampered $hardlink_metadata_artifact hardlink metadata"
    fi
  else
    record_failure \
      "adopt retains ACL-tampered $hardlink_metadata_artifact hardlink metadata"
  fi
done

for hardlink_preplaced_artifact in raw sorted grouped; do
  reset_adopt_fixture
  hardlink_preplaced_source=$(new_adopt_source \
    "hardlink-preplaced-$hardlink_preplaced_artifact")
  hardlink_preplaced_victim=$test_root/hardlink-preplaced-victim-$hardlink_preplaced_artifact
  printf 'victim content for %s\n' "$hardlink_preplaced_artifact" \
    > "$hardlink_preplaced_victim"
  /bin/chmod 640 "$hardlink_preplaced_victim"
  hardlink_preplaced_content=$(< "$hardlink_preplaced_victim")
  hardlink_preplaced_mode=$(/usr/bin/stat -f '%Lp' \
    "$hardlink_preplaced_victim")
  printf '%s\n' "$hardlink_preplaced_artifact" \
    > "$apfs_state/preplace_hardlink_metadata_symlink"
  printf '%s\n' "$hardlink_preplaced_victim" \
    > "$apfs_state/hardlink_metadata_symlink_target"
  expect_adopt_precopy_manifest_refusal \
    "adopt rejects preplaced $hardlink_preplaced_artifact metadata symlink" \
    - "$hardlink_preplaced_source"
  check "preplaced $hardlink_preplaced_artifact symlink preserves victim content" \
    "$hardlink_preplaced_content" "$(< "$hardlink_preplaced_victim")"
  check "preplaced $hardlink_preplaced_artifact symlink preserves victim mode" \
    "$hardlink_preplaced_mode" \
    "$(/usr/bin/stat -f '%Lp' "$hardlink_preplaced_victim")"
  if [[ -f "$apfs_state/hardlink_metadata_preplaced_path" ]]; then
    hardlink_preplaced_path=$(< \
      "$apfs_state/hardlink_metadata_preplaced_path")
    if [[ -L "$hardlink_preplaced_path" ]]; then
      hardlink_preplaced_parent=${hardlink_preplaced_path%/*}
      /bin/rm -f -- "$hardlink_preplaced_path"
      [[ "$hardlink_preplaced_parent" == */vaultlock-hardlinks.* ]] \
        && /bin/rmdir "$hardlink_preplaced_parent" 2>/dev/null || true
    fi
  fi
  /bin/rm -f -- "$hardlink_preplaced_victim"
done

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
    "$apfs_state/keychain_value" \
    "$apfs_state/expected_child_init_secret" \
    "$apfs_state/init_secret_in_child_environment" \
    "$apfs_state/init_secret_environment_probe_ran" \
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
check_count "adopt release failure reports no final success" 0 \
  'Result: adopted' "$release_failure_output"
[[ -d "$operation_lock_dir" ]] \
  || record_failure "adopt operation lock release failure retains lock"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/fail_operation_lock_release"
if init_release_failure_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "init operation lock release failure exits nonzero"
else
  check_contains "init operation lock release failure reports retained lock" \
    "$operation_lock_dir" "$init_release_failure_output"
fi
check_count "init release failure reports no final success" 0 \
  'Result: created encrypted volume' "$init_release_failure_output"
[[ -d "$operation_lock_dir" ]] \
  || record_failure "init operation lock release failure retains lock"

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
for large_directory_index in {1..24}; do
  large_directory_path=$large_directory_path/d$large_directory_index
  mkdir "$large_directory_path"
done
printf 'deep payload\n' > "$large_directory_path/deep-file"
large_file_index=1
while [[ "$large_file_index" -le 200 ]]; do
  printf -v large_file_name '%03d' "$large_file_index"
  printf 'payload %s\n' "$large_file_name" \
    > "$large_directory_source/file-$large_file_name"
  large_file_index=$((large_file_index + 1))
done
/bin/ln "$large_directory_source/file-001" \
  "$large_directory_source/group-a-1"
/bin/ln "$large_directory_source/file-001" \
  "$large_directory_source/group-a-2"
/bin/ln "$large_directory_source/file-101" \
  "$large_directory_source/group-b-1"
/bin/ln "$large_directory_source/file-101" \
  "$large_directory_source/group-b-2"
/bin/ln "$large_directory_source/file-101" \
  "$large_directory_source/group-b-3"
large_scale_file_count=$(/usr/bin/find "$large_directory_source" \
  -type f | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
check "large hardlink index fixture has hundreds of file entries" 207 \
  "$large_scale_file_count"
large_external_link=$test_root/adopt-large-external-link
/bin/ln "$large_directory_source/file-200" "$large_external_link"
: > "$apfs_state/count_tree_traversals"
if large_external_output=$(run_vaultlock adopt --yes \
    "$large_directory_source" 2>&1); then
  record_failure "large adopt rejects hardlink outside source tree"
else
  check_contains "large adopt external hardlink reports manifest refusal" \
    'cannot create stable source manifest' "$large_external_output"
fi
check_count "large external hardlink stops before ditto" 0 'ditto ' \
  "$(< "$mutation_log")"
large_external_index_traversals=$(< \
  "$apfs_state/hardlink_index_traversal_count")
if [[ "$large_external_index_traversals" -le 2 ]]; then
  printf 'ok   large external hardlink uses bounded index traversals: %s\n' \
    "$large_external_index_traversals"
else
  record_failure \
    "large external hardlink uses bounded index traversals: $large_external_index_traversals"
fi
/bin/rm -f -- "$large_external_link"
large_file_index=33
while [[ "$large_file_index" -le 200 ]]; do
  if [[ "$large_file_index" -ne 101 ]]; then
    printf -v large_file_name '%03d' "$large_file_index"
    /bin/rm -f -- "$large_directory_source/file-$large_file_name"
  fi
  large_file_index=$((large_file_index + 1))
done
large_success_file_count=$(/usr/bin/find "$large_directory_source" \
  -type f | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
check "large cleanup fixture retains internal hardlink groups" 40 \
  "$large_success_file_count"
reset_adopt_fixture
: > "$apfs_state/count_directory_traversals"
: > "$apfs_state/count_tree_traversals"
if large_directory_output=$(run_vaultlock adopt --yes \
    "$large_directory_source" 2>&1); then
  :
else
  record_failure \
    "adopt cleans deterministic large-tree skeleton: $large_directory_output"
fi
check "adopt preserves large-tree hardlink group A" \
  "$(/usr/bin/stat -f '%d:%i' "$mount_point/adopt-large-directory-skeleton/file-001")" \
  "$(/usr/bin/stat -f '%d:%i' "$mount_point/adopt-large-directory-skeleton/group-a-2")"
check "adopt preserves large-tree hardlink group B" \
  "$(/usr/bin/stat -f '%d:%i' "$mount_point/adopt-large-directory-skeleton/file-101")" \
  "$(/usr/bin/stat -f '%d:%i' "$mount_point/adopt-large-directory-skeleton/group-b-3")"
large_directory_traversals=$(< "$apfs_state/directory_traversal_count")
if [[ "$large_directory_traversals" -le 3 ]]; then
  printf 'ok   adopt directory cleanup uses bounded traversals\n'
else
  record_failure "adopt directory cleanup uses bounded traversals: $large_directory_traversals"
fi
large_hardlink_index_traversals=$(< \
  "$apfs_state/hardlink_index_traversal_count")
large_tree_manifest_traversals=$(< \
  "$apfs_state/tree_manifest_traversal_count")
if [[ "$large_hardlink_index_traversals" -le 64 ]]; then
  printf 'ok   adopt large tree uses bounded hardlink index traversals: %s\n' \
    "$large_hardlink_index_traversals"
else
  record_failure \
    "adopt large tree uses bounded hardlink index traversals: $large_hardlink_index_traversals"
fi
if [[ "$large_tree_manifest_traversals" -le 64 ]]; then
  printf 'ok   adopt large tree uses bounded manifest traversals: %s\n' \
    "$large_tree_manifest_traversals"
else
  record_failure \
    "adopt large tree uses bounded manifest traversals: $large_tree_manifest_traversals"
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
    'reserved state directory must be a real directory' \
    "$reserved_drift_output"
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

# Approval-review regressions: private ACLs and canonical state leaves.
reset_operation_lock_fixture
reset_adopt_fixture
acl_lock_source=$(new_adopt_source adopt-acl-operation-lock)
: > "$apfs_state/inherit_operation_lock_acl"
: > "$apfs_state/inherit_operation_owner_acl"
: > "$apfs_state/hold_ditto"
start_vaultlock_background "$test_root/acl-lock-output" \
  adopt --yes "$acl_lock_source"
acl_lock_pid=$BACKGROUND_VAULTLOCK_PID
if ! wait_for_fixture "$apfs_state/ditto_entered"; then
  record_failure "ACL lock fixture reaches held operation"
fi
acl_lock_dir_count=$(/bin/ls -ldeB "$operation_lock_dir" \
  | /usr/bin/sed -n '2,$p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
acl_lock_owner_count=$(/bin/ls -ldeB "$operation_lock_dir/owner" \
  | /usr/bin/sed -n '2,$p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
check "operation lock creation removes inherited directory ACL" 0 \
  "$acl_lock_dir_count"
check "operation lock creation removes inherited owner ACL" 0 \
  "$acl_lock_owner_count"
: > "$apfs_state/release_ditto"
if wait "$acl_lock_pid"; then
  :
else
  record_failure "ACL lock fixture completes after release"
fi
/bin/rm -rf -- "${acl_lock_source:?}" \
  "${mount_point:?}/adopt-acl-operation-lock"

reset_operation_lock_fixture
reset_init_fixture
: > "$apfs_state/inherit_operation_lock_acl"
: > "$apfs_state/fail_operation_lock_acl_removal"
if lock_acl_removal_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "operation lock ACL removal failure exits nonzero"
else
  check_contains "operation lock ACL removal failure reports cause" \
    'cannot remove operation lock directory ACL' "$lock_acl_removal_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "operation lock ACL removal failure retains directory"
check_count "operation lock ACL removal failure reaches no APFS mutation" 0 \
  'diskutil apfs addVolume' "$mutation_log"

reset_operation_lock_fixture
reset_adopt_fixture
acl_inspect_source=$(new_adopt_source adopt-acl-lock-inspect)
create_operation_lock 12345 "$fake_process_start" adopt "$fake_operation_token"
/bin/chmod +a 'everyone allow read' "$operation_lock_dir"
/bin/chmod +a 'everyone allow read' "$operation_lock_dir/owner"
if acl_inspect_output=$(run_vaultlock adopt --yes "$acl_inspect_source" 2>&1); then
  record_failure "operation lock inspection rejects ACL-bearing owner"
else
  check_contains "operation lock inspection reports malformed ACL owner" \
    'malformed operation lock owner' "$acl_inspect_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "operation lock inspection preserves ACL-bearing lock"

reset_operation_lock_fixture
reset_adopt_fixture
acl_stale_source=$(new_adopt_source adopt-acl-stale-quarantine)
create_operation_lock 999999 "$fake_process_start" adopt "$fake_operation_token"
printf 'operation_lock_acl_tamper\n' \
  > "$apfs_state/transition_operation_lock_after_quarantine_move"
if acl_stale_output=$(run_vaultlock adopt --yes "$acl_stale_source" 2>&1); then
  record_failure "stale operation quarantine rejects ACL tamper"
else
  check_contains "stale operation quarantine reports ACL tamper" \
    'stale operation lock quarantine changed after move' "$acl_stale_output"
fi
acl_stale_quarantine=$(find "$test_home" -maxdepth 1 -type d \
  -name '.vaultlock-operation.lock.quarantine.*' -print -quit)
[[ -n "$acl_stale_quarantine" ]] \
  || record_failure "stale operation ACL quarantine is retained"
/bin/rm -rf -- "${acl_stale_source:?}" \
  "${mount_point:?}/adopt-acl-stale-quarantine"

reset_operation_lock_fixture
reset_init_fixture
printf 'operation_lock_acl_tamper\n' \
  > "$apfs_state/transition_operation_lock_before_release"
if acl_release_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "operation lock release rejects ACL tamper"
else
  check_contains "operation lock release reports retained ACL lock" \
    'operation lock retained' "$acl_release_output"
fi
[[ -d "$operation_lock_dir" ]] \
  || record_failure "operation lock release retains ACL-tampered lock"

reset_operation_lock_fixture
reset_adopt_fixture
acl_reservation_source=$(new_adopt_source adopt-acl-reservation)
: > "$apfs_state/inherit_adopt_reservation_acl"
printf 'TERM\n' > "$apfs_state/signal_adopt_reservation_creation"
if acl_reservation_output=$(run_vaultlock adopt --yes \
    "$acl_reservation_source" 2>&1); then
  acl_reservation_status=0
else
  acl_reservation_status=$?
fi
: "$acl_reservation_output"
check "adopt inherited reservation ACL preserves TERM status" 143 \
  "$acl_reservation_status"
if ! grep -E 'chmod -N .*adopt-acl-reservation\.vaultlock-backup' \
    "$action_log" >/dev/null; then
  record_failure "adopt removes inherited backup reservation ACL"
fi

reset_operation_lock_fixture
reset_adopt_fixture
acl_reservation_failure_source=$(new_adopt_source \
  adopt-acl-reservation-failure)
: > "$apfs_state/inherit_adopt_reservation_acl"
: > "$apfs_state/fail_adopt_reservation_acl_removal"
if acl_reservation_failure_output=$(run_vaultlock adopt --yes \
    "$acl_reservation_failure_source" 2>&1); then
  record_failure "adopt reservation ACL removal failure exits nonzero"
else
  check_contains "adopt reservation ACL removal failure reports cause" \
    'cannot remove backup reservation ACL' \
    "$acl_reservation_failure_output"
fi
[[ -d "$acl_reservation_failure_source" \
    && ! -L "$acl_reservation_failure_source" ]] \
  || record_failure "adopt reservation ACL failure preserves source"
[[ -d "$acl_reservation_failure_source.vaultlock-backup" ]] \
  || record_failure "adopt reservation ACL failure retains reservation"

reset_operation_lock_fixture
reset_adopt_fixture
acl_quarantine_source=$(new_adopt_source adopt-acl-quarantine)
: > "$apfs_state/inherit_adopt_quarantine_acl"
if acl_quarantine_output=$(run_vaultlock adopt --yes \
    "$acl_quarantine_source" 2>&1); then
  :
else
  record_failure "adopt removes inherited quarantine ACL: $acl_quarantine_output"
fi
if ! grep -E 'chmod -N .*\.vaultlock-quarantine\.' \
    "$action_log" >/dev/null; then
  record_failure "adopt removes inherited backup quarantine ACL"
fi

reset_operation_lock_fixture
reset_adopt_fixture
acl_quarantine_tamper_source=$(new_adopt_source \
  adopt-acl-quarantine-tamper)
printf 'adopt_quarantine_acl_tamper\n' \
  > "$apfs_state/transition_adopt_after_backup_quarantine_move"
if acl_quarantine_tamper_output=$(run_vaultlock adopt --yes \
    "$acl_quarantine_tamper_source" 2>&1); then
  record_failure "adopt quarantine rejects ACL tamper"
else
  check_contains "adopt quarantine ACL tamper reports retained backup" \
    'backup quarantine verification failed' \
    "$acl_quarantine_tamper_output"
fi
acl_quarantine_tamper_path=$(find "$test_root" -maxdepth 1 -type d \
  -name 'adopt-acl-quarantine-tamper.vaultlock-quarantine.*' \
  -print -quit)
[[ -n "$acl_quarantine_tamper_path" ]] \
  || record_failure "adopt ACL-tampered quarantine is retained"

reset_operation_lock_fixture
reset_adopt_fixture
acl_skeleton_source=$(new_adopt_source adopt-acl-skeleton)
printf 'adopt_skeleton_acl_inherit\n' \
  > "$apfs_state/transition_adopt_after_directory_skeleton_created"
if acl_skeleton_output=$(run_vaultlock adopt --yes \
    "$acl_skeleton_source" 2>&1); then
  :
else
  record_failure "adopt removes inherited skeleton ACL: $acl_skeleton_output"
fi
if ! grep -E 'chmod -N .*\.directory-skeleton' \
    "$action_log" >/dev/null; then
  record_failure "adopt removes directory skeleton ACL"
fi

reset_operation_lock_fixture
reset_adopt_fixture
acl_skeleton_tamper_source=$(new_adopt_source \
  adopt-acl-skeleton-tamper)
printf 'adopt_skeleton_acl_tamper\n' \
  > "$apfs_state/transition_adopt_before_directory_skeleton_cleanup"
if acl_skeleton_tamper_output=$(run_vaultlock adopt --yes \
    "$acl_skeleton_tamper_source" 2>&1); then
  record_failure "adopt skeleton cleanup rejects ACL tamper"
else
  check_contains "adopt skeleton ACL tamper reports retained quarantine" \
    'directory skeleton changed' "$acl_skeleton_tamper_output"
fi
acl_skeleton_tamper_path=$(find "$test_root" -maxdepth 1 -type d \
  -name 'adopt-acl-skeleton-tamper.vaultlock-quarantine.*' \
  -print -quit)
[[ -n "$acl_skeleton_tamper_path" ]] \
  || record_failure "adopt skeleton ACL quarantine is retained"

reset_operation_lock_fixture
reset_adopt_fixture
acl_current_snapshot_source=$(new_adopt_source \
  adopt-acl-current-snapshot-tamper)
printf 'adopt_current_snapshot_acl_tamper\n' \
  > "$apfs_state/transition_adopt_before_current_directory_snapshot_cleanup"
if acl_current_snapshot_output=$(run_vaultlock adopt --yes \
    "$acl_current_snapshot_source" 2>&1); then
  record_failure "adopt current snapshot cleanup rejects ACL tamper"
else
  check_contains "adopt current snapshot ACL tamper reports retained snapshot" \
    'current directory snapshot changed' "$acl_current_snapshot_output"
fi
if [[ -f "$apfs_state/tampered_current_snapshot_path" ]]; then
  acl_current_snapshot_path=$(< \
    "$apfs_state/tampered_current_snapshot_path")
  [[ -f "$acl_current_snapshot_path" && ! -L "$acl_current_snapshot_path" ]] \
    || record_failure "adopt ACL-tampered current snapshot is retained"
  acl_current_snapshot_count=$(/bin/ls -ldeB "$acl_current_snapshot_path" \
    | /usr/bin/tail -n +2 | /usr/bin/wc -l \
    | /usr/bin/tr -d '[:space:]')
  [[ "$acl_current_snapshot_count" -ge 1 ]] \
    || record_failure "adopt retained current snapshot keeps tampered ACL"
  acl_current_snapshot_quarantine=${acl_current_snapshot_path%/*}
  /bin/chmod -RN "$acl_current_snapshot_quarantine"
  /bin/rm -rf -- "$acl_current_snapshot_quarantine"
else
  record_failure "adopt ACL-tampered current snapshot is retained"
fi
/bin/rm -rf -- "${acl_current_snapshot_source:?}" \
  "${mount_point:?}/adopt-acl-current-snapshot-tamper"

for state_symlink_case in direct canonical-alias; do
  reset_operation_lock_fixture
  reset_adopt_fixture
  state_symlink_source=$(new_adopt_source \
    "adopt-state-symlink-$state_symlink_case")
  /bin/mv "$state_dir/state.json" "$state_symlink_source/control-state.json"
  if [[ "$state_symlink_case" == canonical-alias ]]; then
    /bin/ln -s "$state_symlink_source" "$test_root/state-target-alias"
    state_symlink_target=$test_root/state-target-alias/control-state.json
  else
    state_symlink_target=$state_symlink_source/control-state.json
  fi
  /bin/ln -s "$state_symlink_target" "$state_dir/state.json"
  if state_symlink_output=$(run_vaultlock adopt --dry-run \
      "$state_symlink_source" 2>&1); then
    record_failure "adopt rejects $state_symlink_case state file symlink"
  else
    check_contains "adopt $state_symlink_case state symlink reports cause" \
      'reserved state file must be a real file' "$state_symlink_output"
  fi
  /bin/rm -f "$state_dir/state.json" "$test_root/state-target-alias"
  /bin/mv "$state_symlink_source/control-state.json" \
    "$state_dir/state.json"
  /bin/rm -rf -- "${state_symlink_source:?}"
done

reset_operation_lock_fixture
reset_adopt_fixture
state_retarget_source=$(new_adopt_source adopt-state-retarget)
/bin/cp "$state_dir/state.json" "$state_retarget_source/retarget-state.json"
printf 'state_file_retarget_into_source\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if state_retarget_output=$(run_vaultlock adopt --yes \
    "$state_retarget_source" 2>&1); then
  record_failure "adopt rejects state file retarget after operation lock"
else
  check_contains "adopt state retarget reports symlink cause" \
    'reserved state file must be a real file' "$state_retarget_output"
fi
/bin/rm -f "$state_dir/state.json"
/bin/mv "$state_retarget_source/retarget-state.json" "$state_dir/state.json"
/bin/rm -rf -- "${state_retarget_source:?}" \
  "${mount_point:?}/adopt-state-retarget"

reset_operation_lock_fixture
reset_adopt_fixture
state_dir_real=$test_root/state-dir-real
/bin/mv "$state_dir" "$state_dir_real"
/bin/ln -s "$state_dir_real" "$state_dir"
state_dir_symlink_source=$(new_adopt_source adopt-state-dir-symlink)
if state_dir_symlink_output=$(run_vaultlock adopt --dry-run \
    "$state_dir_symlink_source" 2>&1); then
  record_failure "adopt rejects symlink state directory"
else
  check_contains "adopt state directory symlink reports cause" \
    'reserved state directory must be a real directory' \
    "$state_dir_symlink_output"
fi
/bin/rm -f "$state_dir"
/bin/mv "$state_dir_real" "$state_dir"
/bin/rm -rf -- "${state_dir_symlink_source:?}"

reset_operation_lock_fixture

# Task 7 normal unlock convergence and cooperative serialization.
unlock_test_passphrase='VGFzazdS ZWNvdmVyeQ=='
unlock_test_passphrase=${unlock_test_passphrase/ /}
unlock_test_hash=$(printf '%s' "$unlock_test_passphrase" \
  | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)

reset_unlock_fixture() {
  reset_operation_lock_fixture
  /bin/rm -rf -- "$state_dir/hooks/pre-unlock.d" \
    "$state_dir/hooks/post-unlock.d" "$mount_point/.vaultlock"
  /bin/rm -f "$state_dir/passphrase.txt" "$state_dir/passphrase.tle" \
    "$state_dir/passphrase.sha256" "$state_dir"/.tle-unlock.* \
    "$state_dir"/.state-unlock.* \
    "$apfs_state/keychain_marker" "$apfs_state/keychain_value" \
    "$apfs_state/fail_keychain" "$apfs_state/fail_keychain_read" \
    "$apfs_state/fail_unlock_state_install" \
    "$apfs_state/fail_unlock_staging_cleanup" \
    "$apfs_state/fail_unlock_private_temp_cleanup" \
    "$apfs_state/fail_unlock_temp_identity_once" \
    "$apfs_state/expected_unlock_passphrase" \
    "$apfs_state/unlock_stdin_verified" \
    "$apfs_state/unlock_leaves_unmounted" \
    "$apfs_state/swap_identity_after_unlock" \
    "$apfs_state/swap_uuid_after_unlock" \
    "$apfs_state/swap_device_after_unlock" \
    "$apfs_state/tle_plaintext" "$apfs_state/tle_early" \
    "$apfs_state/fail_tle" "$apfs_state/fail_hook_name" \
    "$apfs_state/verify_post_hook_target" \
    "$apfs_state/post_hook_saw_usable_target" \
    "$apfs_state/tamper_plaintext_mode_in_post_hook" \
    "$apfs_state/tamper_mount_identity_in_post_hook" \
    "$apfs_state/expected_child_unlock_secret" \
    "$apfs_state/unlock_secret_in_child_environment" \
    "$apfs_state/unlock_secret_environment_probe_ran" \
    "$apfs_state/unlock_execution_entered" \
    "$apfs_state/release_unlock_execution" \
    "$apfs_state"/transition_*
  : > "$action_log"
  : > "$mutation_log"
  : > "$hook_log"
}

check_action_order() { # description earlier later
  local description=$1 earlier=$2 later=$3 earlier_line later_line
  earlier_line=$(/usr/bin/grep -Fn -- "$earlier" "$action_log" \
    | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1 || true)
  later_line=$(/usr/bin/grep -Fn -- "$later" "$action_log" \
    | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1 || true)
  if [[ -n "$earlier_line" && -n "$later_line" \
      && "$earlier_line" -lt "$later_line" ]]; then
    printf 'ok   %s\n' "$description"
  else
    record_failure "$description: [$earlier] must precede [$later]"
  fi
}

write_unlock_plaintext() {
  printf '%s' "$unlock_test_passphrase" > "$state_dir/passphrase.txt"
  printf '%s\n' "$unlock_test_hash" > "$state_dir/passphrase.sha256"
}

write_unlock_ciphertext() {
  printf 'fixture ciphertext\n' > "$state_dir/passphrase.tle"
  printf '%s\n' "$unlock_test_hash" > "$state_dir/passphrase.sha256"
  printf '%s' "$unlock_test_passphrase" > "$apfs_state/tle_plaintext"
}

write_matching_keychain() {
  printf '%s' "$unlock_test_passphrase" > "$apfs_state/keychain_value"
  : > "$apfs_state/keychain_marker"
}

assert_unlock_usable() { # description
  local description=$1
  check "$description records JSON unlocked" false \
    "$(jq -r .locked "$state_dir/state.json")"
  check "$description leaves APFS unlocked" false \
    "$(< "$apfs_state/locked")"
  check "$description leaves APFS mounted" true \
    "$(< "$apfs_state/mounted")"
  check "$description leaves expected mount path" "$mount_point" \
    "$(< "$apfs_state/mount_point")"
  check "$description leaves expected UUID" UUID-123 \
    "$(< "$apfs_state/uuid")"
  check "$description leaves expected device" disk9s1 \
    "$(< "$apfs_state/device")"
  check "$description restores exact plaintext" "$unlock_test_passphrase" \
    "$(< "$state_dir/passphrase.txt")"
  check "$description preserves matching hash" "$unlock_test_hash" \
    "$(< "$state_dir/passphrase.sha256")"
  check "$description stores matching keychain value" \
    "$unlock_test_passphrase" "$(< "$apfs_state/keychain_value")"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "$description releases operation lock"
}

check_no_unlock_staging_artifacts() { # description
  local description=$1 artifact
  artifact=$(/usr/bin/find -P "$state_dir" -mindepth 1 -maxdepth 1 \
    \( -name '.unlock-recovery.*' -o -name '.tle-unlock.*' \
      -o -name '.state-unlock.*' \) -print -quit)
  [[ -z "$artifact" ]] \
    || record_failure "$description leaves staging artifact $artifact"
}

for unsafe_unlock_boundary in state-mode plaintext-mode plaintext-acl; do
  reset_unlock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_unlock_plaintext
  write_matching_keychain
  case "$unsafe_unlock_boundary" in
    state-mode) /bin/chmod 755 "$state_dir" ;;
    plaintext-mode) /bin/chmod 644 "$state_dir/passphrase.txt" ;;
    plaintext-acl)
      /bin/chmod +a 'everyone allow read' "$state_dir/passphrase.txt"
      ;;
  esac
  if unsafe_unlock_output=$(run_vaultlock unlock 2>&1); then
    record_failure "unlock rejects unsafe $unsafe_unlock_boundary boundary"
  else
    check_contains "unlock reports unsafe $unsafe_unlock_boundary boundary" \
      'unsafe protected state metadata' "$unsafe_unlock_output"
  fi
  check_empty "unlock unsafe $unsafe_unlock_boundary performs no mutation" \
    "$mutation_log"
  check_count "unlock unsafe $unsafe_unlock_boundary runs no hooks" 0 \
    '--phase ' "$(< "$hook_log")"
  /bin/chmod -RN "$state_dir"
  /bin/chmod 700 "$state_dir"
  /bin/chmod 600 "$state_dir/passphrase.txt" \
    "$state_dir/passphrase.sha256" "$state_dir/state.json"
done

for hostile_glob_state in normal noglob globignore; do
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf '%s' "$unlock_test_passphrase" \
    > "$state_dir/.unlock-recovery.crash-artifact"
  case "$hostile_glob_state" in
    normal)
      crash_artifact_output=$(run_vaultlock unlock 2>&1) \
        && crash_artifact_status=0 || crash_artifact_status=$?
      ;;
    noglob)
      crash_artifact_output=$(VAULTLOCK_TEST_NOGLOB=1 \
        run_vaultlock unlock 2>&1) \
        && crash_artifact_status=0 || crash_artifact_status=$?
      ;;
    globignore)
      crash_artifact_output=$(GLOBIGNORE='*' run_vaultlock unlock 2>&1) \
        && crash_artifact_status=0 || crash_artifact_status=$?
      ;;
  esac
  [[ "$crash_artifact_status" -ne 0 ]] \
    || record_failure "unlock rejects $hostile_glob_state untracked staging artifact"
  check_contains "unlock reports $hostile_glob_state untracked staging artifact" \
    '.unlock-recovery.crash-artifact' "$crash_artifact_output"
  check_empty "$hostile_glob_state untracked staging artifact stops before mutation" \
    "$mutation_log"
  /bin/rm -f "$state_dir/.unlock-recovery.crash-artifact"
done

for private_temp_kind in tle-unlock state-unlock; do
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  private_temp_artifact="$state_dir/.${private_temp_kind}.crash-artifact"
  printf 'untracked private temporary\n' > "$private_temp_artifact"
  if private_temp_artifact_output=$(run_vaultlock unlock 2>&1); then
    record_failure "unlock rejects untracked $private_temp_kind artifact"
  else
    check_contains "unlock reports untracked $private_temp_kind artifact" \
      ".${private_temp_kind}.crash-artifact" \
      "$private_temp_artifact_output"
  fi
  check_empty "untracked $private_temp_kind stops before mutation" \
    "$mutation_log"
  /bin/rm -f "$private_temp_artifact"
done

for unsafe_keychain_token in user service; do
  for unsafe_keychain_plan in recorded-unlocked recorded-locked; do
    reset_unlock_fixture
    if [[ "$unsafe_keychain_plan" == recorded-locked ]]; then
      write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
      write_unlock_ciphertext
    else
      write_json_state false null null null UUID-123
      write_unlock_plaintext
    fi
    write_apfs_state true false UUID-123 disk9s1
    if [[ "$unsafe_keychain_token" == user ]]; then
      if unsafe_keychain_output=$(USER='unsafe user' \
          run_vaultlock unlock 2>&1); then
        record_failure "$unsafe_keychain_plan unlock rejects unsafe USER"
      fi
    else
      if unsafe_keychain_output=$(VAULTLOCK_VOLUME='unsafe volume' \
          run_vaultlock unlock 2>&1); then
        record_failure "$unsafe_keychain_plan unlock rejects unsafe service"
      fi
    fi
    check_contains "$unsafe_keychain_plan reports unsafe $unsafe_keychain_token" \
      'unsafe' "$unsafe_keychain_output"
    check_empty "$unsafe_keychain_plan unsafe $unsafe_keychain_token performs no mutation" \
      "$mutation_log"
    check_count "$unsafe_keychain_plan unsafe $unsafe_keychain_token stops before TLE" \
      0 'tle -d ' "$(< "$action_log")"
    if [[ "$unsafe_keychain_plan" == recorded-locked \
        && -e "$state_dir/passphrase.txt" ]]; then
      record_failure "$unsafe_keychain_plan unsafe $unsafe_keychain_token restores no plaintext"
    fi
  done
done

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
/bin/mv "$fake_bin/security" "$fake_bin/security.saved"
if missing_security_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock keychain-update plan requires security before mutation"
else
  check_contains "unlock missing security reports preflight failure" \
    'security is required' "$missing_security_output"
fi
/bin/mv "$fake_bin/security.saved" "$fake_bin/security"
check_empty "unlock missing security performs no mutation" "$mutation_log"
check_count "unlock missing security stops before TLE" 0 \
  'tle -d ' "$(< "$action_log")"
[[ ! -e "$state_dir/passphrase.txt" ]] \
  || record_failure "unlock missing security restores no plaintext"

for post_revalidation_drift in state recovery keychain staging; do
  reset_unlock_fixture
  write_json_state false null null null UUID-123
  write_unlock_plaintext
  write_matching_keychain
  if [[ "$post_revalidation_drift" == keychain ]]; then
    write_apfs_state false false UUID-123 disk9s1
    printf 'unlock_keychain_change\n' \
      > "$apfs_state/transition_unlock_before_execution"
  else
    write_apfs_state true false UUID-123 disk9s1
    printf '%s' "$unlock_test_passphrase" \
      > "$apfs_state/expected_unlock_passphrase"
    case "$post_revalidation_drift" in
      state) post_revalidation_action=unlock_state_future_replace ;;
      recovery) post_revalidation_action=unlock_recovery_replace ;;
      staging) post_revalidation_action=unlock_staging_artifact_create ;;
    esac
    printf '%s\n' "$post_revalidation_action" \
      > "$apfs_state/transition_unlock_before_execution"
  fi
  if post_revalidation_output=$(run_vaultlock unlock 2>&1); then
    record_failure "unlock rejects post-revalidation $post_revalidation_drift drift"
  else
    if [[ "$post_revalidation_drift" == staging ]]; then
      check_contains "unlock post-revalidation staging reports retained artifact" \
        '.unlock-recovery.post-revalidation' "$post_revalidation_output"
    else
      check_contains "unlock post-revalidation $post_revalidation_drift reports drift" \
        'unlock inputs changed after plan revalidation' \
        "$post_revalidation_output"
    fi
  fi
  check_count "unlock post-revalidation $post_revalidation_drift stops before APFS mutation" 0 \
    'unlockVolume' "$(< "$mutation_log")"
  check_count "unlock post-revalidation $post_revalidation_drift runs no hooks" 0 \
    '--phase ' "$(< "$hook_log")"
done
/bin/rm -f "$state_dir/.unlock-recovery.post-revalidation"

for immediate_apfs_drift in uuid device lock; do
  reset_unlock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_plaintext
  printf '%s' "$unlock_test_passphrase" \
    > "$apfs_state/expected_unlock_passphrase"
  printf 'unlock_apfs_%s_swap\n' "$immediate_apfs_drift" \
    > "$apfs_state/transition_unlock_before_apfs_unlock"
  if immediate_apfs_output=$(run_vaultlock unlock 2>&1); then
    record_failure "unlock rejects immediate APFS $immediate_apfs_drift drift"
  else
    check_contains "unlock immediate APFS $immediate_apfs_drift reports drift" \
      'expected APFS identity or lock state changed before unlock operation' \
      "$immediate_apfs_output"
  fi
  check_count "unlock immediate APFS $immediate_apfs_drift stops before unlockVolume" 0 \
    'unlockVolume' "$(< "$mutation_log")"
  check_count "unlock immediate APFS $immediate_apfs_drift runs no hooks" 0 \
    '--phase ' "$(< "$hook_log")"
done

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
if unlock_dry_coordination_output=$(run_vaultlock unlock --dry-run 2>&1); then
  unlock_dry_coordination_status=0
else
  unlock_dry_coordination_status=$?
fi
check "unlock dry-run coordination preview exits successfully" 0 \
  "$unlock_dry_coordination_status"
check_plan_coordination "unlock dry-run coordination preview" \
  "$unlock_dry_coordination_output"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "unlock dry-run creates no operation lock"
[[ ! -e "$apfs_state/token_generated" ]] \
  || record_failure "unlock dry-run generates no ownership token"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_plaintext
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
printf 'stale-keychain-value' > "$apfs_state/keychain_value"
: > "$apfs_state/unlock_leaves_unmounted"
: > "$apfs_state/verify_post_hook_target"
/bin/mkdir -p "$state_dir/hooks/post-unlock.d"
/bin/cp "$TEST_SELF" "$state_dir/hooks/post-unlock.d/20-post"
/bin/chmod +x "$state_dir/hooks/post-unlock.d/20-post"
if unlocked_drift_output=$(run_vaultlock unlock 2>&1); then
  unlocked_drift_status=0
else
  unlocked_drift_status=$?
fi
check "recorded-unlocked APFS-locked repair exits successfully" 0 \
  "$unlocked_drift_status"
assert_unlock_usable "recorded-unlocked APFS-locked repair"
[[ -f "$apfs_state/unlock_stdin_verified" ]] \
  || record_failure "recorded-unlocked repair passes plaintext through stdin"
check_count "recorded-unlocked repair performs no TLE recovery" 0 \
  'tle -d ' "$(< "$action_log")"
check_count "recorded-unlocked repair runs no pre-unlock hooks" 0 \
  '--phase pre-unlock' "$(< "$hook_log")"
check_contains "recorded-unlocked repair runs post-unlock hooks" \
  '--phase post-unlock --scope global' "$(< "$hook_log")"
[[ -f "$apfs_state/post_hook_saw_usable_target" ]] \
  || record_failure "recorded-unlocked post hook sees complete usable target"
check_count "recorded-unlocked repair explicitly mounts after APFS unlock" 1 \
  'diskutil mount disk9s1' "$(< "$mutation_log")"
check_contains "recorded-unlocked repair reports final success" \
  "Result: unlocked and mounted at $mount_point" "$unlocked_drift_output"
check_secret_absent "recorded-unlocked repair keeps secret out of output" \
  "$unlocked_drift_output" "$unlock_test_passphrase"
check_secret_absent "recorded-unlocked repair keeps secret out of actions" \
  "$(< "$action_log")" "$unlock_test_passphrase"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
if usable_noop_output=$(run_vaultlock unlock 2>&1); then
  usable_noop_status=0
else
  usable_noop_status=$?
fi
check "usable unlock no-op exits successfully" 0 "$usable_noop_status"
assert_unlock_usable "usable unlock no-op"
check_empty "usable unlock no-op performs no domain mutation" "$mutation_log"
check_count "usable unlock no-op runs no hooks" 0 \
  '--phase ' "$(< "$hook_log")"
check_plan_coordination "usable unlock no-op" "$usable_noop_output"
check_contains "usable unlock no-op verifies keychain read-only" \
  'security find-generic-password' "$(< "$action_log")"
check_count "usable unlock no-op never writes keychain" 0 \
  'security -i' "$(< "$action_log")"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
: > "$apfs_state/fail_keychain_read"
if keychain_read_error_output=$(run_vaultlock unlock 2>&1); then
  record_failure "usable unlock rejects unreadable keychain plaintext"
else
  check_contains "usable unlock reports unreadable keychain plaintext" \
    'cannot verify matching keychain recovery material' \
    "$keychain_read_error_output"
fi
check_empty "unreadable keychain performs no mutation" "$mutation_log"

for keychain_mount_state in mounted unmounted; do
  for keychain_material in missing stale; do
    reset_unlock_fixture
    write_json_state false null null null UUID-123
    if [[ "$keychain_mount_state" == mounted ]]; then
      write_apfs_state false true UUID-123 disk9s1
    else
      write_apfs_state false false UUID-123 disk9s1
    fi
    write_unlock_plaintext
    if [[ "$keychain_material" == stale ]]; then
      printf 'wrong-keychain-value' > "$apfs_state/keychain_value"
    fi
    /bin/mkdir -p "$state_dir/hooks/pre-unlock.d" \
      "$state_dir/hooks/post-unlock.d" \
      "$mount_point/.vaultlock/hooks/post-unlock.d"
    for unused_unlock_hook in \
        "$state_dir/hooks/pre-unlock.d/10-pre" \
        "$state_dir/hooks/post-unlock.d/20-post" \
        "$mount_point/.vaultlock/hooks/post-unlock.d/30-vault-post"; do
      /bin/cp "$TEST_SELF" "$unused_unlock_hook"
      /bin/chmod +x "$unused_unlock_hook"
    done
    if keychain_repair_output=$(run_vaultlock unlock 2>&1); then
      keychain_repair_status=0
    else
      keychain_repair_status=$?
    fi
    check "$keychain_mount_state $keychain_material keychain repair exits successfully" \
      0 "$keychain_repair_status"
    assert_unlock_usable \
      "$keychain_mount_state $keychain_material keychain repair"
    check_contains \
      "$keychain_mount_state $keychain_material keychain repair plans typed update" \
      'Update the keychain with the verified recovery material' \
      "$keychain_repair_output"
    check_plan_coordination \
      "$keychain_mount_state $keychain_material keychain repair" \
      "$keychain_repair_output"
    [[ -e "$apfs_state/token_generated" ]] \
      || record_failure "$keychain_mount_state $keychain_material keychain repair acquires operation lock"
    check_count \
      "$keychain_mount_state $keychain_material keychain repair writes keychain once" \
      1 'security -i' "$(< "$action_log")"
    check_count \
      "$keychain_mount_state $keychain_material keychain repair does not APFS-unlock" \
      0 'unlockVolume' "$(< "$mutation_log")"
    check_count \
      "$keychain_mount_state $keychain_material keychain repair runs no lifecycle hooks" \
      0 '--phase ' "$(< "$hook_log")"
    if [[ "$keychain_mount_state" == unmounted ]]; then
      check_action_order \
        "$keychain_material keychain repair mounts before keychain update" \
        'diskutil mount disk9s1' 'security -i'
    else
      check_count \
        "$keychain_material mounted keychain repair does not remount" \
        0 'diskutil mount disk9s1' "$(< "$mutation_log")"
    fi
  done
done

for keychain_drift_mount_state in mounted unmounted; do
  reset_unlock_fixture
  write_json_state false null null null UUID-123
  if [[ "$keychain_drift_mount_state" == mounted ]]; then
    write_apfs_state false true UUID-123 disk9s1
  else
    write_apfs_state false false UUID-123 disk9s1
  fi
  write_unlock_plaintext
  printf 'stale-before-plan' > "$apfs_state/keychain_value"
  printf 'unlock_keychain_change\n' \
    > "$apfs_state/transition_unlock_before_keychain_update"
  if keychain_drift_output=$(run_vaultlock unlock 2>&1); then
    record_failure "$keychain_drift_mount_state keychain repair rejects execution drift"
  else
    check_contains \
      "$keychain_drift_mount_state keychain repair reports execution drift" \
      'keychain state changed before recovery update' \
      "$keychain_drift_output"
  fi
  check_count \
    "$keychain_drift_mount_state keychain drift stops before keychain write" \
    0 'security -i' "$(< "$action_log")"
  check_count \
    "$keychain_drift_mount_state keychain drift runs no lifecycle hooks" \
    0 '--phase ' "$(< "$hook_log")"
done

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false false UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
if unmounted_repair_output=$(run_vaultlock unlock 2>&1); then
  unmounted_repair_status=0
else
  unmounted_repair_status=$?
fi
check "recorded-unlocked unmounted repair exits successfully" 0 \
  "$unmounted_repair_status"
check_contains "recorded-unlocked unmounted repair reports success" \
  'Result: unlocked and mounted' "$unmounted_repair_output"
assert_unlock_usable "recorded-unlocked unmounted repair"
check_count "unmounted repair mounts exactly once" 1 \
  'diskutil mount disk9s1' "$(< "$mutation_log")"
check_count "unmounted repair does not APFS-unlock" 0 \
  'unlockVolume' "$(< "$mutation_log")"
check_count "unmounted repair runs no hooks" 0 \
  '--phase ' "$(< "$hook_log")"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
printf '%s\n' "$unlock_test_hash" > "$state_dir/passphrase.sha256"
if missing_plaintext_output=$(run_vaultlock unlock 2>&1); then
  record_failure "recorded-unlocked repair rejects missing plaintext"
else
  check_contains "missing plaintext reports exact invariant" \
    'plaintext recovery file is missing' "$missing_plaintext_output"
fi
check_empty "missing plaintext performs no domain mutation" "$mutation_log"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
printf '%s' "$unlock_test_passphrase" > "$state_dir/passphrase.txt"
printf '%064d\n' 0 > "$state_dir/passphrase.sha256"
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
if plaintext_mismatch_output=$(run_vaultlock unlock 2>&1); then
  record_failure "recorded-unlocked repair rejects plaintext hash mismatch"
else
  check_contains "plaintext hash mismatch reports exact invariant" \
    'plaintext recovery material fails sha256 verification' \
    "$plaintext_mismatch_output"
fi
check_count "plaintext hash mismatch stops before APFS unlock" 0 \
  'unlockVolume' "$(< "$mutation_log")"
check_count "plaintext hash mismatch reports no false success" 0 \
  'Result: unlocked and mounted' "$plaintext_mismatch_output"

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
: > "$apfs_state/unlock_leaves_unmounted"
: > "$apfs_state/verify_post_hook_target"
mkdir -p "$state_dir/hooks/pre-unlock.d" \
  "$state_dir/hooks/post-unlock.d" \
  "$mount_point/.vaultlock/hooks/post-unlock.d"
for unlock_hook in \
    "$state_dir/hooks/pre-unlock.d/10-pre" \
    "$mount_point/.vaultlock/hooks/post-unlock.d/20-vault-post" \
    "$state_dir/hooks/post-unlock.d/30-global-post"; do
  /bin/cp "$TEST_SELF" "$unlock_hook"
  /bin/chmod +x "$unlock_hook"
done
if locked_success_output=$(run_vaultlock unlock 2>&1); then
  locked_success_status=0
else
  locked_success_status=$?
fi
check "recorded-locked recovery exits successfully" 0 \
  "$locked_success_status"
assert_unlock_usable "recorded-locked recovery"
check_contains "recorded-locked recovery runs pre hook" \
  '--phase pre-unlock --scope global' "$(< "$hook_log")"
check_contains "recorded-locked recovery runs vault post hook" \
  '--phase post-unlock --scope vault' "$(< "$hook_log")"
check_contains "recorded-locked recovery runs global post hook" \
  '--phase post-unlock --scope global' "$(< "$hook_log")"
[[ -f "$apfs_state/unlock_stdin_verified" ]] \
  || record_failure "recorded-locked recovery passes plaintext through stdin"
[[ -f "$apfs_state/post_hook_saw_usable_target" ]] \
  || record_failure "recorded-locked post hooks see complete usable target"
check_count "recorded-locked recovery decrypts exactly once" 1 \
  'tle -d ' "$(< "$action_log")"
check_action_order "recorded-locked pre hook precedes TLE recovery" \
  '10-pre ' 'tle -d '
check_action_order "recorded-locked TLE precedes APFS unlock" \
  'tle -d ' 'diskutil apfs unlockVolume disk9s1 -stdinpassphrase'
check_action_order "recorded-locked APFS unlock precedes explicit mount" \
  'diskutil apfs unlockVolume disk9s1 -stdinpassphrase' \
  'diskutil mount disk9s1'
check_action_order "recorded-locked keychain restore precedes vault post hook" \
  'security -i' '20-vault-post '
check_action_order "recorded-locked vault post precedes global post hook" \
  '20-vault-post ' '30-global-post '
check_secret_absent "recorded-locked recovery keeps secret out of output" \
  "$locked_success_output" "$unlock_test_passphrase"
check_secret_absent "recorded-locked recovery keeps secret out of actions" \
  "$(< "$action_log")" "$unlock_test_passphrase"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_child_unlock_secret"
(
  export VAULTLOCK_TEST_RENAMED_SECRET_CARRIER="prefix${unlock_test_passphrase}suffix"
  run_vaultlock unlock --dry-run >/dev/null 2>&1
)
[[ -e "$apfs_state/unlock_secret_in_child_environment" ]] \
  || record_failure "secret detector finds renamed exported values containing secret"

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_child_unlock_secret"
if imported_unlock_output=$(run_vaultlock_with_imported_secret_names \
    unlock 2>&1); then
  imported_unlock_status=0
else
  imported_unlock_status=$?
fi
check "unlock clears imported secret export attributes under allexport" 0 \
  "$imported_unlock_status"
check_contains "unlock imported-secret run reports success" \
  'Result: unlocked and mounted' "$imported_unlock_output"
[[ ! -e "$apfs_state/unlock_secret_in_child_environment" ]] \
  || record_failure "unlock recovery secret reaches child environment"
[[ -e "$apfs_state/unlock_secret_environment_probe_ran" ]] \
  || record_failure "unlock secret environment probe did not run after recovery"

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
printf 'unlock_plaintext_stage_fail\n' \
  > "$apfs_state/transition_unlock_plaintext_staged"
if staging_failure_output=$(run_vaultlock unlock 2>&1); then
  record_failure "plaintext staging transition failure exits nonzero"
else
  check_contains "plaintext staging transition failure reports interruption" \
    'plaintext recovery installation failed' "$staging_failure_output"
fi
check_no_unlock_staging_artifacts "plaintext staging transition failure"
check "plaintext staging transition failure leaves JSON locked" true \
  "$(jq -r .locked "$state_dir/state.json")"
check_count "plaintext staging transition failure reports no success" 0 \
  'Result: unlocked and mounted' "$staging_failure_output"

for staging_signal_case in HUP:129 INT:130 TERM:143; do
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  staging_signal=${staging_signal_case%%:*}
  staging_signal_status=${staging_signal_case##*:}
  printf 'signal_%s\n' "$staging_signal" \
    > "$apfs_state/transition_unlock_plaintext_staged"
  if staging_signal_output=$(run_vaultlock unlock 2>&1); then
    staging_signal_actual=0
  else
    staging_signal_actual=$?
  fi
  check "plaintext staging $staging_signal preserves signal status" \
    "$staging_signal_status" "$staging_signal_actual"
  check_no_unlock_staging_artifacts "plaintext staging $staging_signal"
  check "plaintext staging $staging_signal leaves retryable plaintext" \
    "$unlock_test_passphrase" "$(< "$state_dir/passphrase.txt")"
  check "plaintext staging $staging_signal leaves JSON locked" true \
    "$(jq -r .locked "$state_dir/state.json")"
  check_count "plaintext staging $staging_signal reports no success" 0 \
    'Result: unlocked and mounted' "$staging_signal_output"
done

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
printf 'unlock_plaintext_stage_fail\n' \
  > "$apfs_state/transition_unlock_plaintext_staged"
: > "$apfs_state/fail_unlock_staging_cleanup"
if retained_staging_output=$(run_vaultlock unlock 2>&1); then
  record_failure "failed plaintext staging cleanup exits nonzero"
else
  check_contains "failed plaintext staging cleanup reports retained path" \
    'plaintext recovery staging file retained at' "$retained_staging_output"
fi
retained_staging_artifact=
for staging_artifact in "$state_dir"/.unlock-recovery.*; do
  if [[ -e "$staging_artifact" || -L "$staging_artifact" ]]; then
    retained_staging_artifact=$staging_artifact
  fi
done
[[ -n "$retained_staging_artifact" ]] \
  || record_failure "failed plaintext staging cleanup retains reported artifact"
/bin/rm -f "$apfs_state/fail_unlock_staging_cleanup"
if [[ -n "$retained_staging_artifact" ]]; then
  /bin/rm -f "$retained_staging_artifact"
fi

for private_temp_case in tle-error:unlock_tle_error_staged:unlock_tle_error_stage_fail \
    state:unlock_state_staged:unlock_state_stage_fail; do
  private_temp_name=${private_temp_case%%:*}
  private_temp_remainder=${private_temp_case#*:}
  private_temp_transition=${private_temp_remainder%%:*}
  private_temp_failure=${private_temp_case##*:}
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf '%s\n' "$private_temp_failure" \
    > "$apfs_state/transition_$private_temp_transition"
  if private_temp_failure_output=$(run_vaultlock unlock 2>&1); then
    record_failure "$private_temp_name staging transition failure exits nonzero"
  fi
  check_no_unlock_staging_artifacts \
    "$private_temp_name staging transition failure"
  check_count "$private_temp_name staging failure reports no success" 0 \
    'Result: unlocked and mounted' "$private_temp_failure_output"
done

for private_temp_signal_case in \
    tle-error:unlock_tle_error_staged:HUP:129 \
    tle-error:unlock_tle_error_staged:INT:130 \
    tle-error:unlock_tle_error_staged:TERM:143 \
    state:unlock_state_staged:HUP:129 \
    state:unlock_state_staged:INT:130 \
    state:unlock_state_staged:TERM:143; do
  private_temp_name=${private_temp_signal_case%%:*}
  private_temp_remainder=${private_temp_signal_case#*:}
  private_temp_transition=${private_temp_remainder%%:*}
  private_temp_remainder=${private_temp_remainder#*:}
  private_temp_signal=${private_temp_remainder%%:*}
  private_temp_signal_status=${private_temp_signal_case##*:}
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf 'signal_%s\n' "$private_temp_signal" \
    > "$apfs_state/transition_$private_temp_transition"
  if private_temp_signal_output=$(run_vaultlock unlock 2>&1); then
    private_temp_signal_actual=0
  else
    private_temp_signal_actual=$?
  fi
  check "$private_temp_name staging $private_temp_signal preserves signal status" \
    "$private_temp_signal_status" "$private_temp_signal_actual"
  check_no_unlock_staging_artifacts \
    "$private_temp_name staging $private_temp_signal"
  check_count "$private_temp_name staging $private_temp_signal reports no success" \
    0 'Result: unlocked and mounted' "$private_temp_signal_output"
done

for retained_private_temp_case in \
    tle-error:unlock_tle_error_staged:unlock_tle_error_stage_fail:.tle-unlock. \
    state:unlock_state_staged:unlock_state_stage_fail:.state-unlock.; do
  retained_private_temp_name=${retained_private_temp_case%%:*}
  retained_private_temp_remainder=${retained_private_temp_case#*:}
  retained_private_temp_transition=${retained_private_temp_remainder%%:*}
  retained_private_temp_remainder=${retained_private_temp_remainder#*:}
  retained_private_temp_failure=${retained_private_temp_remainder%%:*}
  retained_private_temp_prefix=${retained_private_temp_case##*:}
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf '%s\n' "$retained_private_temp_failure" \
    > "$apfs_state/transition_$retained_private_temp_transition"
  printf '%s\n' "$retained_private_temp_prefix" \
    > "$apfs_state/fail_unlock_private_temp_cleanup"
  if retained_private_temp_output=$(run_vaultlock unlock 2>&1); then
    record_failure "$retained_private_temp_name cleanup failure exits nonzero"
  else
    check_contains "$retained_private_temp_name cleanup reports retained path" \
      "$retained_private_temp_prefix" "$retained_private_temp_output"
  fi
  retained_private_temp_artifact=$(/usr/bin/find -P "$state_dir" \
    -mindepth 1 -maxdepth 1 -name "${retained_private_temp_prefix}*" \
    -print -quit)
  [[ -n "$retained_private_temp_artifact" ]] \
    || record_failure "$retained_private_temp_name cleanup retains reported artifact"
  /bin/rm -f "$apfs_state/fail_unlock_private_temp_cleanup"
  if [[ -n "$retained_private_temp_artifact" ]]; then
    /bin/rm -f "$retained_private_temp_artifact"
  fi
done

for identity_failure_case in \
    tle-error:.tle-unlock.:.tle-unlock. \
    plaintext:.unlock-recovery.:.unlock-recovery. \
    state:.state-unlock.:.state-unlock.; do
  identity_failure_name=${identity_failure_case%%:*}
  identity_failure_remainder=${identity_failure_case#*:}
  identity_failure_prefix=${identity_failure_remainder%%:*}
  identity_failure_expected=${identity_failure_case##*:}
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf '%s\n' "$identity_failure_prefix" \
    > "$apfs_state/fail_unlock_temp_identity_once"
  if identity_failure_output=$(run_vaultlock unlock 2>&1); then
    record_failure "$identity_failure_name identity failure exits nonzero"
  else
    check_contains "$identity_failure_name identity failure reports retained path" \
      "$identity_failure_expected" "$identity_failure_output"
  fi
  identity_failure_artifact=$(/usr/bin/find -P "$state_dir" \
    -mindepth 1 -maxdepth 1 -name "${identity_failure_prefix}*" \
    -print -quit)
  [[ -n "$identity_failure_artifact" ]] \
    || record_failure "$identity_failure_name identity failure retains unverified path"
  check_count "$identity_failure_name identity failure reports no success" 0 \
    'Result: unlocked and mounted' "$identity_failure_output"
  if [[ -n "$identity_failure_artifact" ]]; then
    /bin/rm -f "$identity_failure_artifact"
  fi
done

for partial_unlock_failure in keychain state-install; do
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf '%s' "$unlock_test_passphrase" \
    > "$apfs_state/expected_unlock_passphrase"
  if [[ "$partial_unlock_failure" == keychain ]]; then
    : > "$apfs_state/fail_keychain"
  else
    : > "$apfs_state/fail_unlock_state_install"
  fi
  if partial_unlock_output=$(run_vaultlock unlock 2>&1); then
    record_failure "recorded-locked $partial_unlock_failure failure exits nonzero"
  else
    check_contains "recorded-locked $partial_unlock_failure reports failure" \
      'vaultlock:' "$partial_unlock_output"
  fi
  check "recorded-locked $partial_unlock_failure leaves JSON locked" true \
    "$(jq -r .locked "$state_dir/state.json")"
  check "recorded-locked $partial_unlock_failure leaves APFS unlocked" false \
    "$(< "$apfs_state/locked")"
  check "recorded-locked $partial_unlock_failure retains verified plaintext" \
    "$unlock_test_passphrase" "$(< "$state_dir/passphrase.txt")"
  /bin/rm -f "$apfs_state/fail_keychain" \
    "$apfs_state/fail_unlock_state_install"
  : > "$action_log"
  : > "$mutation_log"
  : > "$hook_log"
  if partial_retry_output=$(run_vaultlock unlock 2>&1); then
    partial_retry_status=0
  else
    partial_retry_status=$?
  fi
  check "recorded-locked $partial_unlock_failure retry converges" 0 \
    "$partial_retry_status"
  check_contains "recorded-locked $partial_unlock_failure retry reports success" \
    'Result: unlocked and mounted' "$partial_retry_output"
  assert_unlock_usable "recorded-locked $partial_unlock_failure retry"
done

for partial_unlock_signal_case in HUP:129 INT:130 TERM:143; do
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  printf '%s' "$unlock_test_passphrase" \
    > "$apfs_state/expected_unlock_passphrase"
  partial_unlock_signal=${partial_unlock_signal_case%%:*}
  partial_unlock_signal_status=${partial_unlock_signal_case##*:}
  printf 'signal_%s\n' "$partial_unlock_signal" \
    > "$apfs_state/transition_unlock_after_plaintext_restored"
  if partial_signal_output=$(run_vaultlock unlock 2>&1); then
    partial_signal_actual=0
  else
    partial_signal_actual=$?
  fi
  check "unlock post-plaintext $partial_unlock_signal preserves status" \
    "$partial_unlock_signal_status" "$partial_signal_actual"
  check "unlock post-plaintext $partial_unlock_signal leaves JSON locked" true \
    "$(jq -r .locked "$state_dir/state.json")"
  check "unlock post-plaintext $partial_unlock_signal retains plaintext" \
    "$unlock_test_passphrase" "$(< "$state_dir/passphrase.txt")"
  check_count "unlock post-plaintext $partial_unlock_signal has no success" 0 \
    'Result: unlocked and mounted' "$partial_signal_output"
  if partial_signal_retry_output=$(run_vaultlock unlock 2>&1); then
    partial_signal_retry_status=0
  else
    partial_signal_retry_status=$?
  fi
  check "unlock post-plaintext $partial_unlock_signal retry converges" 0 \
    "$partial_signal_retry_status"
  : "$partial_signal_retry_output"
  assert_unlock_usable "unlock post-plaintext $partial_unlock_signal retry"
done

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
/bin/mkdir -p "$state_dir/hooks/pre-unlock.d"
/bin/cp "$TEST_SELF" "$state_dir/hooks/pre-unlock.d/10-pre-fail"
/bin/chmod +x "$state_dir/hooks/pre-unlock.d/10-pre-fail"
printf '10-pre-fail\n' > "$apfs_state/fail_hook_name"
if pre_hook_failure_output=$(run_vaultlock unlock 2>&1); then
  record_failure "pre-unlock hook failure exits nonzero"
else
  check_contains "pre-unlock hook failure reports locked vault" \
    'pre-unlock hooks failed, vault remains locked' "$pre_hook_failure_output"
fi
check_count "pre-unlock hook failure stops before TLE" 0 \
  'tle -d ' "$(< "$action_log")"
check_count "pre-unlock hook failure stops before APFS unlock" 0 \
  'unlockVolume' "$(< "$mutation_log")"
check "pre-unlock hook failure preserves JSON locked" true \
  "$(jq -r .locked "$state_dir/state.json")"

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
: > "$apfs_state/verify_post_hook_target"
/bin/mkdir -p "$mount_point/.vaultlock/hooks/post-unlock.d" \
  "$state_dir/hooks/post-unlock.d"
/bin/cp "$TEST_SELF" \
  "$mount_point/.vaultlock/hooks/post-unlock.d/20-post-fail"
/bin/cp "$TEST_SELF" "$state_dir/hooks/post-unlock.d/30-post-continue"
/bin/chmod +x \
  "$mount_point/.vaultlock/hooks/post-unlock.d/20-post-fail" \
  "$state_dir/hooks/post-unlock.d/30-post-continue"
printf '20-post-fail\n' > "$apfs_state/fail_hook_name"
if post_hook_failure_output=$(run_vaultlock unlock 2>&1); then
  record_failure "post-unlock hook failure exits nonzero"
else
  check_contains "post-unlock hook failure reports usable target" \
    'vault is unlocked and mounted' "$post_hook_failure_output"
fi
assert_unlock_usable "post-unlock hook failure"
check_contains "post-unlock failure continues global hooks" \
  '30-post-continue' "$(< "$hook_log")"
[[ -f "$apfs_state/post_hook_saw_usable_target" ]] \
  || record_failure "post-unlock failure hook sees usable target"
check_count "post-unlock failure reports no false success" 0 \
  'Result: unlocked and mounted' "$post_hook_failure_output"

for post_metadata_tamper in mode acl; do
  reset_unlock_fixture
  write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_ciphertext
  /bin/mkdir -p "$state_dir/hooks/post-unlock.d"
  /bin/cp "$TEST_SELF" \
    "$state_dir/hooks/post-unlock.d/20-post-metadata-tamper"
  /bin/cp "$TEST_SELF" \
    "$state_dir/hooks/post-unlock.d/30-post-must-not-run"
  /bin/chmod +x "$state_dir/hooks/post-unlock.d/20-post-metadata-tamper" \
    "$state_dir/hooks/post-unlock.d/30-post-must-not-run"
  printf '%s\n' "$post_metadata_tamper" \
    > "$apfs_state/tamper_plaintext_mode_in_post_hook"
  if metadata_tamper_output=$(run_vaultlock unlock 2>&1); then
    record_failure "post-unlock $post_metadata_tamper tamper prevents success"
  else
    check_contains "post-unlock $post_metadata_tamper tamper reports unsafe target" \
      'unsafe protected state metadata' "$metadata_tamper_output"
  fi
  check_count "post-unlock $post_metadata_tamper tamper stops later hooks" 0 \
    '30-post-must-not-run --phase' "$(< "$hook_log")"
  check_count "post-unlock $post_metadata_tamper tamper reports no false success" 0 \
    'Result: unlocked and mounted' "$metadata_tamper_output"
  /bin/chmod -RN "$state_dir/passphrase.txt"
  /bin/chmod 600 "$state_dir/passphrase.txt"
done

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
/bin/mkdir -p "$mount_point/.vaultlock/hooks/post-unlock.d"
/bin/cp "$TEST_SELF" \
  "$mount_point/.vaultlock/hooks/post-unlock.d/20-deferred-identity-swap"
/bin/cp "$TEST_SELF" \
  "$mount_point/.vaultlock/hooks/post-unlock.d/30-deferred-must-not-run"
/bin/chmod +x \
  "$mount_point/.vaultlock/hooks/post-unlock.d/20-deferred-identity-swap" \
  "$mount_point/.vaultlock/hooks/post-unlock.d/30-deferred-must-not-run"
: > "$apfs_state/tamper_mount_identity_in_post_hook"
if deferred_identity_output=$(run_vaultlock unlock 2>&1); then
  record_failure "deferred post hook mount-identity drift prevents success"
else
  check_contains "deferred post hook mount-identity drift reports target failure" \
    'unlock target is not recorded unlocked, mounted, and identity-verified' \
    "$deferred_identity_output"
fi
check_count "deferred post hook identity drift stops the next hook" 0 \
  '30-deferred-must-not-run --phase' "$(< "$hook_log")"
check_count "deferred post hook identity drift reports no false success" 0 \
  'Result: unlocked and mounted' "$deferred_identity_output"

reset_unlock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
: > "$apfs_state/tle_early"
if early_unlock_output=$(run_vaultlock unlock 2>&1); then
  record_failure "recorded-locked early TLE recovery fails"
else
  check_contains "early TLE recovery reports the active lock" \
    'still locked until 2099-01-02T03:04:00+0100' "$early_unlock_output"
fi
check "early TLE recovery preserves JSON locked" true \
  "$(jq -r .locked "$state_dir/state.json")"
check "early TLE recovery preserves APFS locked" true \
  "$(< "$apfs_state/locked")"
check_count "early TLE recovery stops before APFS unlock" 0 \
  'unlockVolume' "$(< "$mutation_log")"
check_count "early TLE recovery reports no false success" 0 \
  'Result: unlocked and mounted' "$early_unlock_output"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "early TLE recovery releases operation lock"

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_ciphertext
printf 'RGlmZmVyZW50UmVjb3Zlcnk=' > "$apfs_state/tle_plaintext"
if tle_hash_mismatch_output=$(run_vaultlock unlock 2>&1); then
  record_failure "TLE recovery rejects decrypted hash mismatch"
else
  check_contains "TLE hash mismatch reports exact invariant" \
    'decrypted recovery material fails sha256 verification' \
    "$tle_hash_mismatch_output"
fi
check_count "TLE hash mismatch stops before APFS unlock" 0 \
  'unlockVolume' "$(< "$mutation_log")"
check "TLE hash mismatch preserves JSON locked" true \
  "$(jq -r .locked "$state_dir/state.json")"

reset_unlock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_ciphertext
if unexpected_early_output=$(run_vaultlock unlock 2>&1); then
  record_failure "recorded-locked unexpected APFS unlock before deadline fails"
else
  check_contains "unexpected early APFS unlock reports security violation" \
    'APFS volume is unexpectedly unlocked before the recorded deadline' \
    "$unexpected_early_output"
fi
check "unexpected early APFS unlock preserves JSON locked" true \
  "$(jq -r .locked "$state_dir/state.json")"
check_empty "unexpected early APFS unlock performs no domain mutation" \
  "$mutation_log"

reset_unlock_fixture
write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
write_apfs_state false false UUID-123 disk9s1
write_unlock_ciphertext
if unexpected_late_output=$(run_vaultlock unlock 2>&1); then
  unexpected_late_status=0
else
  unexpected_late_status=$?
fi
check "unexpected unlocked APFS resumes after deadline" 0 \
  "$unexpected_late_status"
check_contains "unexpected unlocked APFS recovery reports success" \
  'Result: unlocked and mounted' "$unexpected_late_output"
assert_unlock_usable "unexpected unlocked APFS recovery"
check_count "unexpected unlocked APFS recovery skips APFS unlock" 0 \
  'unlockVolume' "$(< "$mutation_log")"
check_count "unexpected unlocked APFS recovery mounts exactly once" 1 \
  'diskutil mount disk9s1' "$(< "$mutation_log")"
check_count "unexpected unlocked APFS recovery performs TLE recovery" 1 \
  'tle -d ' "$(< "$action_log")"
check_count "unexpected unlocked APFS recovery runs no post hooks" 0 \
  '--phase post-unlock' "$(< "$hook_log")"

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_plaintext
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
: > "$apfs_state/fail_keychain"
/bin/mkdir -p "$state_dir/hooks/post-unlock.d"
/bin/cp "$TEST_SELF" "$state_dir/hooks/post-unlock.d/keychain-post"
/bin/chmod +x "$state_dir/hooks/post-unlock.d/keychain-post"
if unlock_keychain_write_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock keychain restore failure exits nonzero"
else
  check_contains "unlock keychain restore failure reports incomplete target" \
    'keychain recovery update failed' "$unlock_keychain_write_output"
fi
check_count "unlock keychain failure runs no post hooks" 0 \
  '--phase post-unlock' "$(< "$hook_log")"
check_count "unlock keychain failure reports no false success" 0 \
  'Result: unlocked and mounted' "$unlock_keychain_write_output"

for identity_swap_kind in uuid device; do
  reset_unlock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_unlock_plaintext
  printf '%s' "$unlock_test_passphrase" \
    > "$apfs_state/expected_unlock_passphrase"
  : > "$apfs_state/swap_${identity_swap_kind}_after_unlock"
  /bin/mkdir -p "$state_dir/hooks/post-unlock.d"
  /bin/cp "$TEST_SELF" "$state_dir/hooks/post-unlock.d/identity-post"
  /bin/chmod +x "$state_dir/hooks/post-unlock.d/identity-post"
  if identity_swap_output=$(run_vaultlock unlock 2>&1); then
    record_failure "unlock rejects mounted $identity_swap_kind swap"
  else
    check_contains "unlock mounted $identity_swap_kind swap reports mismatch" \
      'expected unlocked APFS volume changed before mount' \
      "$identity_swap_output"
  fi
  check_count "unlock $identity_swap_kind swap reports no false success" 0 \
    'Result: unlocked and mounted' "$identity_swap_output"
  check_count "unlock $identity_swap_kind swap runs no hooks" 0 \
    '--phase ' "$(< "$hook_log")"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "unlock $identity_swap_kind swap releases operation lock"
done

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
create_operation_lock "$$" "$fake_process_start" adopt \
  "$fake_operation_token"
if unlock_live_lock_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock refuses live cooperative operation lock"
else
  check_contains "unlock live lock reports owner" \
    'operation lock is held by live pid' "$unlock_live_lock_output"
fi
check_empty "unlock live lock stops before domain mutation" "$mutation_log"
clear_operation_locks

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
create_operation_lock "$$" "$fake_process_start" lock \
  "$fake_operation_token"
: > "$apfs_state/ps_ambiguous"
if unlock_ambiguous_lock_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock rejects ambiguous operation lock owner"
else
  check_contains "unlock ambiguous lock fails closed" \
    'cannot safely classify operation lock owner' \
    "$unlock_ambiguous_lock_output"
fi
check_empty "unlock ambiguous lock stops before domain mutation" "$mutation_log"
clear_operation_locks

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
create_operation_lock 999999 "$fake_process_start" lock \
  "$fake_operation_token"
printf 'owner_identity_swap\n' \
  > "$apfs_state/transition_operation_lock_final_check"
if unlock_owner_swap_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock rejects operation lock owner identity swap"
else
  check_contains "unlock operation lock owner swap fails closed" \
    'operation lock changed during final verification' \
    "$unlock_owner_swap_output"
fi
check_empty "unlock operation lock owner swap stops before mutation" \
  "$mutation_log"
clear_operation_locks

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
create_operation_lock 999999 "$fake_process_start" lock \
  "$fake_operation_token"
if unlock_stale_lock_output=$(run_vaultlock unlock 2>&1); then
  unlock_stale_lock_status=0
else
  unlock_stale_lock_status=$?
fi
check "unlock replaces verified stale operation lock" 0 \
  "$unlock_stale_lock_status"
check_contains "unlock reports stale lock quarantine" \
  'Retained stale operation lock quarantine:' "$unlock_stale_lock_output"
check "unlock retains one stale lock quarantine" 1 \
  "$(/usr/bin/find "$test_home" -maxdepth 1 -type d \
    -name '.vaultlock-operation.lock.quarantine.*' | /usr/bin/wc -l \
    | /usr/bin/tr -d '[:space:]')"
clear_operation_locks

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
write_unlock_plaintext
printf '%s' "$unlock_test_passphrase" \
  > "$apfs_state/expected_unlock_passphrase"
printf 'unlock_apfs_state_swap\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if unlock_drift_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock rejects post-acquisition plan drift"
else
  check_contains "unlock plan drift reports rerun boundary" \
    'plan changed after operation lock acquisition' "$unlock_drift_output"
fi
check_count "unlock plan drift stops before APFS mutation" 0 \
  'unlockVolume' "$(< "$mutation_log")"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "unlock plan drift releases operation lock"

for unlock_typed_drift_case in \
    recovery state-inode hook-record deadline-round device; do
  reset_unlock_fixture
  if [[ "$unlock_typed_drift_case" == deadline-round ]]; then
    write_json_state true 2000-01-01T00:00:00+0000 1 1 UUID-123
    write_apfs_state true false UUID-123 disk9s1
    write_unlock_ciphertext
    printf 'unlock_deadline_round_change\n' \
      > "$apfs_state/transition_plan_revalidation_before_inspection"
  elif [[ "$unlock_typed_drift_case" == state-inode ]]; then
    write_json_state false null null null UUID-123
    write_apfs_state false true UUID-123 disk9s1
    write_unlock_plaintext
    write_matching_keychain
    printf 'state_equivalent_inode_swap\n' \
      > "$apfs_state/transition_plan_revalidation_before_inspection"
  else
    write_json_state false null null null UUID-123
    write_apfs_state true false UUID-123 disk9s1
    write_unlock_plaintext
    printf '%s' "$unlock_test_passphrase" \
      > "$apfs_state/expected_unlock_passphrase"
    if [[ "$unlock_typed_drift_case" == recovery ]]; then
      printf 'unlock_recovery_replace\n' \
        > "$apfs_state/transition_plan_revalidation_before_inspection"
    elif [[ "$unlock_typed_drift_case" == device ]]; then
      printf 'unlock_device_revalidation_swap\n' \
        > "$apfs_state/transition_plan_revalidation_before_inspection"
    else
      printf 'unlock_hook_create\n' \
        > "$apfs_state/transition_plan_revalidation_before_inspection"
    fi
  fi
  if unlock_typed_drift_output=$(run_vaultlock unlock 2>&1); then
    record_failure "unlock rejects $unlock_typed_drift_case typed plan drift"
  else
    check_contains "unlock $unlock_typed_drift_case drift reports rerun boundary" \
      'plan changed after operation lock acquisition' \
      "$unlock_typed_drift_output"
  fi
  check_count "unlock $unlock_typed_drift_case drift stops before APFS mutation" 0 \
    'unlockVolume' "$(< "$mutation_log")"
  check_count "unlock $unlock_typed_drift_case drift runs no hooks" 0 \
    '--phase ' "$(< "$hook_log")"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "unlock $unlock_typed_drift_case drift releases operation lock"
done

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
: > "$apfs_state/fail_operation_lock_release"
if unlock_release_output=$(run_vaultlock unlock 2>&1); then
  record_failure "unlock release failure exits nonzero"
else
  check_contains "unlock release failure reports retained lock" \
    'operation lock retained' "$unlock_release_output"
fi
check_count "unlock release failure reports no final success" 0 \
  'Result: unlocked and mounted' "$unlock_release_output"
/bin/rm -f "$apfs_state/fail_operation_lock_release"
clear_operation_locks

for unlock_signal_case in HUP:129 INT:130 TERM:143; do
  reset_unlock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_unlock_plaintext
  write_matching_keychain
  unlock_signal=${unlock_signal_case%%:*}
  unlock_signal_status=${unlock_signal_case##*:}
  printf 'signal_%s\n' "$unlock_signal" \
    > "$apfs_state/transition_unlock_before_execution"
  if unlock_signal_output=$(run_vaultlock unlock 2>&1); then
    unlock_signal_actual=0
  else
    unlock_signal_actual=$?
  fi
  : "$unlock_signal_output"
  check "unlock $unlock_signal preserves signal status" \
    "$unlock_signal_status" "$unlock_signal_actual"
  check_count "unlock $unlock_signal reports no false success" 0 \
    'Result: unlocked and mounted' "$unlock_signal_output"
  check "unlock $unlock_signal preserves recorded unlocked state" false \
    "$(jq -r .locked "$state_dir/state.json")"
  check_empty "unlock $unlock_signal no-op performs no domain mutation" \
    "$mutation_log"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "unlock $unlock_signal releases operation lock"
done

reset_unlock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_unlock_plaintext
write_matching_keychain
printf 'hold_unlock_execution\n' \
  > "$apfs_state/transition_unlock_before_execution"
unlock_background_output=$test_root/unlock-background-output
start_vaultlock_background "$unlock_background_output" unlock
unlock_background_pid=$BACKGROUND_VAULTLOCK_PID
wait_for_fixture "$apfs_state/unlock_execution_entered" \
  || record_failure "unlock no-op reaches serialized execution boundary"
if unlock_contender_output=$(run_vaultlock unlock 2>&1); then
  record_failure "concurrent unlock no-op refuses live operation lock"
else
  check_contains "concurrent unlock no-op reports live owner" \
    'operation lock is held by live pid' "$unlock_contender_output"
fi
: > "$apfs_state/release_unlock_execution"
if ! wait "$unlock_background_pid"; then
  record_failure "serialized unlock no-op completes after release"
fi
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "serialized unlock no-op releases operation lock"

reset_init_fixture
init_expected_child_secret=$(printf 'Task6SecretOnlyInStdinChannel!!!' \
  | /usr/bin/base64 | /usr/bin/tr -d '\n')
printf '%s' "$init_expected_child_secret" \
  > "$apfs_state/expected_child_init_secret"
if imported_init_output=$(run_vaultlock_with_imported_secret_names \
    init --yes 2>&1); then
  imported_init_status=0
else
  imported_init_status=$?
fi
check "init clears imported secret export attributes under allexport" 0 \
  "$imported_init_status"
check_contains "init imported-secret run reports success" \
  'Result: created encrypted volume' "$imported_init_output"
[[ ! -e "$apfs_state/init_secret_in_child_environment" ]] \
  || record_failure "init recovery secret reaches child environment"
[[ -e "$apfs_state/init_secret_environment_probe_ran" ]] \
  || record_failure "init secret environment probe did not run after generation"

# Task 8 normal lock convergence, confirmation, and crypto ordering.
lock_old_passphrase='VGFzazhPbGRSZWNvdmVyeQ=='
lock_old_hash=$(printf '%s' "$lock_old_passphrase" \
  | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)
lock_expected_new_secret=$(printf 'Task6SecretOnlyInStdinChannel!!!' \
  | /usr/bin/base64 | /usr/bin/tr -d '\n')

reset_lock_fixture() {
  reset_operation_lock_fixture
  if [[ -L "$state_dir/state.json" ]]; then
    /bin/rm -f "$state_dir/state.json"
  fi
  /bin/rm -rf -- "$state_dir/hooks/pre-lock.d" \
    "$state_dir/hooks/post-lock.d" "$mount_point/.vaultlock"
  /bin/rm -f "$state_dir/passphrase.txt" \
    "$state_dir/passphrase.txt.pre-swap" \
    "$state_dir/passphrase.txt.pre-install" \
    "$state_dir/passphrase-new.txt" \
    "$state_dir/passphrase-new.txt.pre-swap" \
    "$state_dir/passphrase.tle" "$state_dir/passphrase.sha256" \
    "$state_dir/passphrase.sha256.pre-install" \
    "$state_dir/state.json.pre-install" \
    "$state_dir"/.unlock-recovery.* "$state_dir"/.tle-unlock.* \
    "$state_dir"/.state-unlock.* "$state_dir"/.passphrase-lock.* \
    "$state_dir"/.tle-lock.* "$state_dir"/.hash-lock.* \
    "$state_dir"/.state-lock.* "$state_dir"/.tle-verify.* \
    "$state_dir"/.security-output.* \
    "$apfs_state/expected_lock_old_passphrase" \
    "$apfs_state/current_apfs_passphrase" \
    "$apfs_state/keychain_marker" "$apfs_state/keychain_value" \
    "$apfs_state/lock_new_passphrase" \
    "$apfs_state/change_passphrase_stdin_verified" \
    "$apfs_state/lock_ciphertext_created" \
    "$apfs_state/lock_tle_decrypts_early" \
    "$apfs_state/lock_tle_unexpected_error" \
    "$apfs_state/echo_tle_decrypt_error" \
    "$apfs_state/fail_change_passphrase" \
    "$apfs_state/echo_change_passphrase_error" \
    "$apfs_state/fail_tle_encrypt" "$apfs_state/fail_lock_volume" \
    "$apfs_state/echo_tle_encrypt_error" \
    "$apfs_state/tle_lock_plaintext_digest" \
    "$apfs_state/dead_process_pid" \
    "$apfs_state/fail_unmount" "$apfs_state/fail_curl" \
    "$apfs_state/fail_state_tm_exclusion" \
    "$apfs_state/fail_state_tm_verification" \
    "$apfs_state/state_tm_included" \
    "$apfs_state/state_tm_malformed" \
    "$apfs_state/state_tm_multiple_records" \
    "$apfs_state/state_tm_wrong_path" \
    "$apfs_state/fail_vault_snapshot_cleanup" \
    "$apfs_state/fail_data_snapshot_cleanup" \
    "$apfs_state/unlock_leaves_unmounted" \
    "$apfs_state/fail_keychain_delete" \
    "$apfs_state/noop_keychain_delete" \
    "$apfs_state/echo_security_error" \
    "$apfs_state/fail_lock_plaintext_remove" \
    "$apfs_state/noop_lock_plaintext_remove" \
    "$apfs_state/plaintext-delete-victim" \
    "$apfs_state/foreign_lock_artifact_owner" \
    "$apfs_state/fail_lock_artifact_removal" \
    "$apfs_state/fail_hook_name" \
    "$apfs_state/fail_lock_artifact_find" \
    "$apfs_state/preplace_lock_mktemp_shape" \
    "$apfs_state/lock_mktemp_victim" \
    "$apfs_state/preplaced_lock_mktemp_path" \
    "$apfs_state/fixed-stage-victim" \
    "$apfs_state/install-race-victim" \
    "$apfs_state/staged-recovery-original" \
    "$apfs_state/plaintext-install-original" \
    "$apfs_state/ciphertext-install-original" \
    "$apfs_state/hash-install-original" \
    "$apfs_state/state-install-original" \
    "$apfs_state/state-stage-original" \
    "$apfs_state/planned-hook-target" \
    "$apfs_state/deferred-hook-target" \
    "$apfs_state/deferred-hook-target.pre-swap" \
    "$apfs_state/filevault_disabled" \
    "$apfs_state/allow_mount_while_locked" \
    "$apfs_state/verify_post_lock_target" \
    "$apfs_state/post_lock_hook_saw_secure_target" \
    "$apfs_state/tamper_mount_identity_in_pre_lock_hook" \
    "$apfs_state/tamper_state_in_pre_lock_hook" \
    "$apfs_state/shadow_mount_identity" \
    "$apfs_state/foreign_deferred_lock_hook_owner" \
    "$apfs_state/expected_child_lock_old_secret" \
    "$apfs_state/expected_child_lock_new_secret" \
    "$apfs_state/lock_old_secret_in_child_environment" \
    "$apfs_state/lock_new_secret_in_child_environment" \
    "$apfs_state/lock_old_secret_environment_probe_ran" \
    "$apfs_state/lock_new_secret_environment_probe_ran" \
    "$apfs_state/lock-crypto-markers" \
    "$apfs_state/lock_execution_entered" \
    "$apfs_state/release_lock_execution" \
    "$apfs_state"/transition_*
  : > "$action_log"
  : > "$mutation_log"
  : > "$hook_log"
  : > "$confirm_device"
}

write_lock_plaintext() {
  printf '%s' "$lock_old_passphrase" > "$state_dir/passphrase.txt"
  printf '%s\n' "$lock_old_hash" > "$state_dir/passphrase.sha256"
  printf '%s' "$lock_old_passphrase" \
    > "$apfs_state/expected_lock_old_passphrase"
  printf '%s' "$lock_old_passphrase" \
    > "$apfs_state/current_apfs_passphrase"
  printf '%s' "$lock_old_passphrase" > "$apfs_state/keychain_value"
  : > "$apfs_state/keychain_marker"
}

assert_lock_secure() { # description
  local description=$1
  check "$description records JSON locked" true \
    "$(jq -r .locked "$state_dir/state.json")"
  check "$description leaves APFS locked" true \
    "$(< "$apfs_state/locked")"
  check "$description leaves APFS unmounted" false \
    "$(< "$apfs_state/mounted")"
  [[ ! -e "$state_dir/passphrase.txt" ]] \
    || record_failure "$description leaves plaintext recovery"
  [[ ! -e "$apfs_state/keychain_value" ]] \
    || record_failure "$description leaves keychain recovery"
  [[ -s "$state_dir/passphrase.tle" ]] \
    || record_failure "$description leaves no ciphertext"
  [[ -s "$state_dir/passphrase.sha256" ]] \
    || record_failure "$description leaves no recovery hash"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "$description releases operation lock"
}

canonical_crypto_markers=$'generate-new-plaintext\nwrite-staged-plaintext\nchange-apfs-passphrase\ninstall-rotated-plaintext\nupdate-keychain\ncreate-tle-ciphertext\nverify-ciphertext-nonempty\nverify-ciphertext-not-early\nverify-expected-early-error\nwrite-plaintext-hash\nwrite-locked-json\ninstall-locked-json\nremove-plaintext\nremove-keychain-plaintext\nlock-apfs\nverify-filevault\nverify-mount-resistance'

extract_baseline_lock_crypto_markers() { # repository
  local repository=$1 baseline
  baseline=$(git -C "$repository" log --all --format='%H%x09%s' \
    | /usr/bin/awk -F '\t' \
      '$2 == "chore: import verified vaultlock baseline" {print $1}')
  [[ -n "$baseline" && "$baseline" != *$'\n'* ]] || return 1
  git -C "$repository" show "$baseline:bin/vaultlock" \
    | /usr/bin/sed -n '/^cmd_lock()/,/^cmd_unlock()/p' \
    | /usr/bin/awk '
      /pass=\$\(head -c 32/ { print "generate-new-plaintext" }
      /printf .*pass.*passphrase-new.txt/ { print "write-staged-plaintext" }
      /changePassphrase/ { print "change-apfs-passphrase" }
      /mv .*passphrase-new.txt.*passphrase.txt/ { print "install-rotated-plaintext" }
      /security add-generic-password/ { print "update-keychain" }
      /printf .*pass.*tle.* -e / { print "create-tle-ciphertext" }
      /\[\[ -s .*passphrase.tle/ { print "verify-ciphertext-nonempty" }
      /if .*tle.* -d / { print "verify-ciphertext-not-early" }
      /grep -qiE .*EARLY_RE/ { print "verify-expected-early-error" }
      /sha256_of .*pass/ { print "write-plaintext-hash" }
      /jq --arg d / { print "write-locked-json" }
      /mv .*state_file.tmp.*state_file/ { print "install-locked-json" }
      /rm -f .*passphrase.txt/ { print "remove-plaintext" }
      /security delete-generic-password/ { print "remove-keychain-plaintext" }
      /lockVolume/ && /sudo diskutil/ { print "lock-apfs" }
      /FileVault:\.\*Yes/ { print "verify-filevault" }
      /if diskutil mount/ { print "verify-mount-resistance" }
    '
}

extract_current_lock_crypto_markers() { # script
  /usr/bin/sed -n \
    '/^generate_and_stage_rotated_recovery()/,/^execute_post_lock_hooks()/p' "$1" \
    | /usr/bin/awk '
      /^[[:space:]]+complete_lock_crypto_operation / { print $2 }
    '
}

repository_root=$(cd "$(dirname "$VL")/.." && pwd)
baseline_crypto_markers=$(extract_baseline_lock_crypto_markers \
  "$repository_root") || baseline_crypto_markers=missing
check "baseline lock crypto extraction yields canonical 17 markers" \
  "$canonical_crypto_markers" "$baseline_crypto_markers"
current_crypto_markers=$(extract_current_lock_crypto_markers "$VL")
check "current lock executors preserve baseline crypto operation order" \
  "$baseline_crypto_markers" "$current_crypto_markers"
# shellcheck disable=SC2016  # The source scan matches literal shell text.
marker_dispatch_count=$(/usr/bin/sed -n \
  '/^complete_lock_crypto_operation()/,/^generate_and_stage_rotated_recovery()/p' \
  "$VL" | /usr/bin/grep -Ec '^  lock_crypto_marker "?\$marker"?$' || true)
check "crypto operations emit markers only through their operation wrapper" \
  1 "$marker_dispatch_count"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
/bin/mkdir -p "$state_dir/hooks/pre-lock.d" \
  "$state_dir/hooks/post-lock.d"
/bin/cp "$TEST_SELF" "$apfs_state/planned-hook-target"
/bin/chmod +x "$apfs_state/planned-hook-target"
/bin/ln -s "$apfs_state/planned-hook-target" \
  "$state_dir/hooks/pre-lock.d/10-planned-link"
/bin/cp "$TEST_SELF" "$state_dir/hooks/post-lock.d/20-post-lock"
/bin/chmod +x "$state_dir/hooks/post-lock.d/20-post-lock"
: > "$apfs_state/verify_post_lock_target"
if lock_success_output=$(run_vaultlock lock --yes 20h 2>&1); then
  lock_success_status=0
else
  lock_success_status=$?
fi
check "planned lock exits successfully" 0 "$lock_success_status"
check_contains "planned lock reports verified success" 'Result: locked until' \
  "$lock_success_output"
assert_lock_secure "planned lock"
[[ -e "$apfs_state/change_passphrase_stdin_verified" ]] \
  || record_failure "lock rotates APFS with old and new stdin passphrases"
[[ -e "$apfs_state/post_lock_hook_saw_secure_target" ]] \
  || record_failure "post-lock hook sees verified secure target"
check_count "planned executable symlink hook runs" 1 \
  '10-planned-link --phase pre-lock' "$(< "$hook_log")"
check_action_order "FileVault verification precedes mount resistance" \
  'diskutil info disk9s1' 'diskutil mount disk9s1'
check_action_order "mount resistance precedes post-lock hook" \
  'diskutil mount disk9s1' '20-post-lock --phase post-lock'
check "runtime lock crypto order matches baseline canonical order" \
  "$baseline_crypto_markers" "$(< "$apfs_state/lock-crypto-markers")"
check_secret_absent "old lock passphrase absent from child argv" \
  "$(< "$action_log")" "$lock_old_passphrase"
check_secret_absent "new lock passphrase absent from child argv" \
  "$(< "$action_log")" "$(< "$apfs_state/lock_new_passphrase")"
state_dir_canonical=$(cd -P -- "$state_dir" && pwd -P)
state_dir_argument=$(printf '%q' "$state_dir_canonical")
check_action_order "state exclusion precedes new recovery generation" \
  "tmutil addexclusion -p $state_dir_argument" 'head -c 32 /dev/urandom'
check_action_order "verified state exclusion precedes new recovery generation" \
  "tmutil isexcluded -X $state_dir_argument" 'head -c 32 /dev/urandom'

for state_exclusion_failure in add verify included malformed multiple \
    wrong-path; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  case "$state_exclusion_failure" in
    add) : > "$apfs_state/fail_state_tm_exclusion" ;;
    verify) : > "$apfs_state/fail_state_tm_verification" ;;
    included) : > "$apfs_state/state_tm_included" ;;
    malformed) : > "$apfs_state/state_tm_malformed" ;;
    multiple) : > "$apfs_state/state_tm_multiple_records" ;;
    wrong-path) : > "$apfs_state/state_tm_wrong_path" ;;
  esac
  if state_exclusion_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects $state_exclusion_failure state exclusion failure"
  else
    check_contains "lock reports $state_exclusion_failure state exclusion failure" \
      'protected state directory Time Machine exclusion' \
      "$state_exclusion_output"
  fi
  check_count "$state_exclusion_failure state exclusion stops key generation" 0 \
    'head -c 32 /dev/urandom' "$(< "$action_log")"
  check_count "$state_exclusion_failure state exclusion stops APFS rotation" 0 \
    'changePassphrase' "$(< "$action_log")"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_vault_snapshot_cleanup"
if vault_snapshot_failure_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects vault snapshot cleanup failure"
else
  check_contains "lock reports vault snapshot cleanup failure" \
    'cannot delete local Time Machine snapshots for the vault' \
    "$vault_snapshot_failure_output"
fi
check_count "vault snapshot cleanup failure stops key generation" 0 \
  'head -c 32 /dev/urandom' "$(< "$action_log")"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/unlock_leaves_unmounted"
if lock_repair_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
  lock_repair_status=0
else
  lock_repair_status=$?
fi
: "$lock_repair_output"
check "lock repairs recorded-unlocked APFS lock" 0 "$lock_repair_status"
assert_lock_secure "lock repair"
check_action_order "lock repair unlocks before mounting" \
  'diskutil apfs unlockVolume disk9s1 -stdinpassphrase' \
  'diskutil mount disk9s1'
check_action_order "lock repair mounts before Time Machine preflight" \
  'diskutil mount disk9s1' 'tmutil addexclusion'
check_action_order "lock repair preflight precedes passphrase rotation" \
  'tmutil addexclusion' 'diskutil apfs changePassphrase'

for deferred_lock_hook_shape in symlink hardlink foreign-owner; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_lock_plaintext
  deferred_hook_dir=$mount_point/.vaultlock/hooks/pre-lock.d
  deferred_hook_path=$deferred_hook_dir/10-deferred-lock-hook
  /bin/mkdir -p "$deferred_hook_dir"
  case "$deferred_lock_hook_shape" in
    symlink)
      /bin/ln -s "$TEST_SELF" "$deferred_hook_path"
      ;;
    hardlink)
      /bin/cp "$TEST_SELF" "$deferred_hook_dir/deferred-hook-victim"
      /bin/chmod +x "$deferred_hook_dir/deferred-hook-victim"
      /bin/ln "$deferred_hook_dir/deferred-hook-victim" \
        "$deferred_hook_path"
      ;;
    foreign-owner)
      /bin/cp "$TEST_SELF" "$deferred_hook_path"
      /bin/chmod +x "$deferred_hook_path"
      : > "$apfs_state/foreign_deferred_lock_hook_owner"
      ;;
  esac
  if deferred_hook_output=$(run_vaultlock lock --yes 20h 2>&1); then
    deferred_hook_status=0
  else
    deferred_hook_status=$?
  fi
  : "$deferred_hook_output"
  check "lock accepts deferred $deferred_lock_hook_shape hook" 0 \
    "$deferred_hook_status"
  check_count "deferred $deferred_lock_hook_shape hook executes once" 1 \
    '10-deferred-lock-hook --phase pre-lock' "$(< "$hook_log")"
done

for deferred_lock_hook_drift in identity link target; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state true false UUID-123 disk9s1
  write_lock_plaintext
  deferred_hook_dir=$mount_point/.vaultlock/hooks/pre-lock.d
  deferred_hook_path=$deferred_hook_dir/10-deferred-lock-hook
  /bin/mkdir -p "$deferred_hook_dir"
  if [[ "$deferred_lock_hook_drift" == identity ]]; then
    /bin/cp "$TEST_SELF" "$deferred_hook_path"
    /bin/chmod +x "$deferred_hook_path"
  else
    /bin/cp "$TEST_SELF" "$apfs_state/deferred-hook-target"
    /bin/chmod +x "$apfs_state/deferred-hook-target"
    /bin/ln -s "$apfs_state/deferred-hook-target" "$deferred_hook_path"
  fi
  printf 'lock_deferred_hook_%s_swap\n' "$deferred_lock_hook_drift" \
    > "$apfs_state/transition_lock_before_deferred_hook"
  if deferred_hook_drift_output=$(run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects deferred $deferred_lock_hook_drift drift"
  else
    check_contains "lock reports deferred $deferred_lock_hook_drift drift" \
      'discovered pre-lock hook changed before execution' \
      "$deferred_hook_drift_output"
  fi
  check_count "deferred $deferred_lock_hook_drift drift stops before Time Machine" \
    0 'tmutil addexclusion' "$(< "$action_log")"
  check_count "deferred $deferred_lock_hook_drift drift is not executed" 0 \
    '10-deferred-lock-hook --phase pre-lock' "$(< "$hook_log")"
done

for planned_lock_hook_drift in link target; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  /bin/mkdir -p "$state_dir/hooks/pre-lock.d"
  /bin/cp "$TEST_SELF" "$apfs_state/planned-hook-target"
  /bin/chmod +x "$apfs_state/planned-hook-target"
  /bin/ln -s "$apfs_state/planned-hook-target" \
    "$state_dir/hooks/pre-lock.d/10-planned-link"
  printf 'lock_planned_hook_%s_swap\n' "$planned_lock_hook_drift" \
    > "$apfs_state/transition_lock_before_execution"
  if planned_hook_drift_output=$(run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects planned symlink $planned_lock_hook_drift drift"
  else
    check_contains "lock reports planned symlink $planned_lock_hook_drift drift" \
      'planned hook changed before execution' "$planned_hook_drift_output"
  fi
  check_count "planned symlink $planned_lock_hook_drift drift stops before Time Machine" \
    0 'tmutil addexclusion' "$(< "$action_log")"
done

for pre_lock_drift in mount state; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  /bin/mkdir -p "$state_dir/hooks/pre-lock.d" \
    "$mount_point/.vaultlock/hooks/pre-lock.d"
  if [[ "$pre_lock_drift" == mount ]]; then
    global_drift_hook=$state_dir/hooks/pre-lock.d/10-global-lock-identity-swap
    : > "$apfs_state/tamper_mount_identity_in_pre_lock_hook"
  else
    global_drift_hook=$state_dir/hooks/pre-lock.d/10-global-lock-state-swap
    : > "$apfs_state/tamper_state_in_pre_lock_hook"
  fi
  /bin/cp "$TEST_SELF" "$global_drift_hook"
  /bin/cp "$TEST_SELF" \
    "$mount_point/.vaultlock/hooks/pre-lock.d/20-vault-must-not-run"
  /bin/chmod +x "$global_drift_hook" \
    "$mount_point/.vaultlock/hooks/pre-lock.d/20-vault-must-not-run"
  if pre_lock_drift_output=$(run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects $pre_lock_drift drift from pre-lock hook"
  else
    check_contains "lock reports $pre_lock_drift drift from pre-lock hook" \
      'changed' "$pre_lock_drift_output"
  fi
  if [[ "$pre_lock_drift" == mount ]]; then
    check_count "$pre_lock_drift drift runs no vault pre-lock hook" 0 \
      '20-vault-must-not-run --phase pre-lock' "$hook_log"
  fi
  check_count "$pre_lock_drift drift stops before Time Machine mutation" 0 \
    'tmutil addexclusion' "$(< "$action_log")"
done

reset_lock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
printf 'fixture ciphertext\n' > "$state_dir/passphrase.tle"
printf '%s\n' "$lock_old_hash" > "$state_dir/passphrase.sha256"
if secure_lock_output=$(run_vaultlock lock --yes 20h 2>&1); then
  secure_lock_status=0
else
  secure_lock_status=$?
fi
check "secure lock no-op exits successfully" 0 "$secure_lock_status"
check_contains "secure lock no-op preserves deadline" \
  '2099-01-02T03:04:00+0100' "$secure_lock_output"
check "secure lock no-op preserves JSON deadline" \
  '2099-01-02T03:04:00+0100' "$(jq -r .deadline "$state_dir/state.json")"
check "secure lock no-op preserves JSON round" 792731235 \
  "$(jq -r .round "$state_dir/state.json")"
check "secure lock no-op performs only mount-resistance verification" \
  'diskutil mount disk9s1' "$(< "$mutation_log")"
[[ -e "$apfs_state/token_generated" ]] \
  || record_failure "secure lock no-op acquires cooperative operation lock"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "secure lock no-op releases operation lock"

reset_lock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
printf 'fixture ciphertext\n' > "$state_dir/passphrase.tle"
printf '%s\n' "$lock_old_hash" > "$state_dir/passphrase.sha256"
printf '%s' "$lock_old_passphrase" > "$apfs_state/keychain_value"
: > "$apfs_state/keychain_marker"
if locked_keychain_repair_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  locked_keychain_repair_status=0
else
  locked_keychain_repair_status=$?
fi
check "secure lock removes retained keychain plaintext" 0 \
  "$locked_keychain_repair_status"
check_contains "secure keychain repair renders truthful target" \
  'remove retained keychain recovery material' \
  "$locked_keychain_repair_output"
check_contains "secure keychain repair renders disabled hooks" \
  'Hooks disabled by --no-hooks' "$locked_keychain_repair_output"
[[ ! -e "$apfs_state/keychain_value" ]] \
  || record_failure "secure lock repair retains keychain plaintext"
check "secure keychain repair preserves deadline" \
  '2099-01-02T03:04:00+0100' "$(jq -r .deadline "$state_dir/state.json")"
check_count "secure keychain repair performs no APFS rotation" 0 \
  'changePassphrase' "$(< "$action_log")"
check_count "secure keychain repair performs no TLE encryption" 0 \
  'tle -e' "$(< "$action_log")"

reset_lock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
printf 'fixture ciphertext\n' > "$state_dir/passphrase.tle"
printf '%s\n' "$lock_old_hash" > "$state_dir/passphrase.sha256"
printf '%s' "$lock_old_passphrase" > "$apfs_state/keychain_value"
: > "$apfs_state/keychain_marker"
printf 'lock_repair_keychain_swap\n' \
  > "$apfs_state/transition_lock_before_repair_keychain_remove"
if keychain_repair_drift_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "secure keychain repair rejects pre-delete drift"
else
  check_contains "secure keychain repair reports pre-delete drift" \
    'keychain state changed before repair removal' \
    "$keychain_repair_drift_output"
fi
check "secure keychain repair preserves replacement" \
  'cmVwbGFjZW1lbnQta2V5Y2hhaW4=' \
  "$(< "$apfs_state/keychain_value")"
check_count "secure keychain drift does not delete replacement" 0 \
  'security delete-generic-password' "$(< "$action_log")"

reset_lock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state true false UUID-123 disk9s1
write_lock_plaintext
/bin/rm -f "$apfs_state/keychain_value" "$apfs_state/keychain_marker"
printf 'fixture ciphertext\n' > "$state_dir/passphrase.tle"
if locked_plaintext_repair_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  locked_plaintext_repair_status=0
else
  locked_plaintext_repair_status=$?
fi
check "secure lock removes retained plaintext file" 0 \
  "$locked_plaintext_repair_status"
check_contains "secure plaintext repair renders truthful target" \
  'remove retained plaintext recovery material' \
  "$locked_plaintext_repair_output"
[[ ! -e "$state_dir/passphrase.txt" ]] \
  || record_failure "secure plaintext repair retains plaintext file"
check "secure plaintext repair preserves deadline" \
  '2099-01-02T03:04:00+0100' "$(jq -r .deadline "$state_dir/state.json")"
check_count "secure plaintext repair performs no APFS rotation" 0 \
  'changePassphrase' "$(< "$action_log")"

reset_lock_fixture
write_json_state true 2099-01-02T03:04:00+0100 4070999040 792731235 UUID-123
write_apfs_state false true UUID-123 disk9s1
printf 'fixture ciphertext\n' > "$state_dir/passphrase.tle"
printf '%s\n' "$lock_old_hash" > "$state_dir/passphrase.sha256"
if locked_repair_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
  locked_repair_status=0
else
  locked_repair_status=$?
fi
: "$locked_repair_output"
check "recorded-locked mounted repair exits successfully" 0 \
  "$locked_repair_status"
assert_lock_secure "recorded-locked mounted repair"
check "recorded-locked mounted repair preserves deadline" \
  '2099-01-02T03:04:00+0100' "$(jq -r .deadline "$state_dir/state.json")"
check_contains "recorded-locked mounted repair renders disabled hooks" \
  'Hooks disabled by --no-hooks' "$locked_repair_output"
check_count "recorded-locked mounted repair does not rotate recovery" 0 \
  'changePassphrase' "$(< "$action_log")"
check_count "recorded-locked mounted repair runs no hooks" 0 \
  '--phase ' "$(< "$hook_log")"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state true false UUID-123 disk9s1
write_lock_plaintext
/bin/mkdir -p "$state_dir/hooks/pre-lock.d"
/bin/cp "$TEST_SELF" "$state_dir/hooks/pre-lock.d/10-declined-repair-hook"
/bin/chmod +x "$state_dir/hooks/pre-lock.d/10-declined-repair-hook"
declined_repair_dry_plan=$(run_vaultlock \
  lock --dry-run '2099-01-02 03:04' 2>&1)
declined_repair_dry_actions=$(printf '%s\n' "$declined_repair_dry_plan" \
  | /usr/bin/sed -n '/^Actions:$/,/^Confirmation:$/p')
printf 'n\n' > "$confirm_device"
if declined_lock_output=$(run_vaultlock lock '2099-01-02 03:04' 2>&1); then
  record_failure "declined lock exits nonzero"
else
  check_contains "declined lock reports no changes" \
    'cancelled, no changes made' "$declined_lock_output"
fi
declined_repair_confirm_actions=$(printf '%s\n' "$declined_lock_output" \
  | /usr/bin/sed -n '/^Actions:$/,/^Confirmation:$/p')
check "declined repair plan matches dry-run action order" \
  "$declined_repair_dry_actions" "$declined_repair_confirm_actions"
check_empty "declined lock performs no mutation" "$mutation_log"
check_count "declined repair lock executes no hook" 0 \
  '10-declined-repair-hook --phase pre-lock' "$hook_log"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "declined lock creates no operation lock"
[[ ! -e "$apfs_state/token_generated" ]] \
  || record_failure "declined lock generates no operation token"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
if task8_lock_dry_output=$(run_vaultlock lock --dry-run 20h 2>&1); then
  task8_lock_dry_status=0
else
  task8_lock_dry_status=$?
fi
check "planned lock dry-run exits successfully" 0 "$task8_lock_dry_status"
check_contains "planned lock dry-run reports no changes" \
  'Result: no changes made' "$task8_lock_dry_output"
check_empty "planned lock dry-run performs no mutation" "$mutation_log"
[[ ! -e "$operation_lock_dir" && ! -e "$apfs_state/token_generated" ]] \
  || record_failure "planned lock dry-run acquires no operation lock"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/shadow_mount_identity"
if shadow_mount_output=$(run_vaultlock lock --dry-run 20h 2>&1); then
  record_failure "lock dry-run rejects shadowed mount hook discovery"
else
  check_contains "lock dry-run reports shadowed mount hook discovery" \
    'mount identity mismatch' "$shadow_mount_output"
fi
check_empty "shadowed mount dry-run performs no mutation" "$mutation_log"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
/bin/chmod 400 "$confirm_device"
if missing_lock_tty_output=$(run_vaultlock lock 20h 2>&1); then
  record_failure "lock without writable confirmation terminal fails"
else
  check_contains "lock without terminal reports --yes hint" \
    'rerun with --yes' "$missing_lock_tty_output"
fi
/bin/chmod 600 "$confirm_device"
check_empty "lock without terminal performs no mutation" "$mutation_log"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
if invalid_lock_deadline_output=$(run_vaultlock \
    lock --yes not-a-deadline 2>&1); then
  record_failure "lock rejects invalid deadline"
else
  check_contains "lock reports invalid deadline" \
    'cannot resolve' "$invalid_lock_deadline_output"
fi
check_empty "invalid lock deadline performs no mutation" "$mutation_log"
if misplaced_lock_option_output=$(run_vaultlock lock 20h --yes 2>&1); then
  record_failure "lock rejects options after operands"
else
  check_contains "lock reports misplaced option" \
    'options must precede lock operands' "$misplaced_lock_option_output"
fi

for lock_crash_artifact in \
    .unlock-recovery.crash .tle-unlock.crash .state-unlock.crash \
    passphrase-new.txt .passphrase-lock.crash .tle-lock.crash \
    .hash-lock.crash .state-lock.crash .tle-verify.crash \
    .security-output.crash; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'retained crash artifact\n' > "$state_dir/$lock_crash_artifact"
  if artifact_lock_output=$(VAULTLOCK_TEST_NOGLOB=1 \
      run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects crash artifact $lock_crash_artifact"
  else
    check_contains "lock reports crash artifact $lock_crash_artifact" \
      'staging artifact must be resolved' "$artifact_lock_output"
  fi
  check_empty "crash artifact $lock_crash_artifact stops before mutation" \
    "$mutation_log"
  [[ -f "$state_dir/$lock_crash_artifact" ]] \
    || record_failure "lock preserves crash artifact $lock_crash_artifact"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_lock_artifact_find"
if artifact_find_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects failed crash-artifact inventory"
else
  check_contains "lock reports failed crash-artifact inventory" \
    'cannot inspect lock staging artifacts' "$artifact_find_output"
fi
check_empty "failed crash-artifact inventory stops before mutation" \
  "$mutation_log"

for lock_artifact_shape in symlink directory hardlink mode acl unreadable; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  shaped_artifact=$state_dir/.unlock-recovery.shape-$lock_artifact_shape
  shaped_victim=$apfs_state/shape-$lock_artifact_shape-victim
  printf 'victim content\n' > "$shaped_victim"
  case "$lock_artifact_shape" in
    symlink) /bin/ln -s "$shaped_victim" "$shaped_artifact" ;;
    directory) /bin/mkdir "$shaped_artifact" ;;
    hardlink) /bin/ln "$shaped_victim" "$shaped_artifact" ;;
    mode)
      printf 'mode mismatch\n' > "$shaped_artifact"
      /bin/chmod 644 "$shaped_artifact"
      ;;
    acl)
      printf 'ACL mismatch\n' > "$shaped_artifact"
      /bin/chmod +a 'everyone allow read' "$shaped_artifact"
      ;;
    unreadable)
      printf 'unreadable mismatch\n' > "$shaped_artifact"
      /bin/chmod 000 "$shaped_artifact"
      ;;
  esac
  if shaped_artifact_output=$(run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects $lock_artifact_shape crash artifact"
  else
    check_contains "lock reports $lock_artifact_shape crash artifact" \
      'staging artifact must be resolved' "$shaped_artifact_output"
  fi
  check_empty "$lock_artifact_shape artifact stops before mutation" \
    "$mutation_log"
  check "$lock_artifact_shape artifact preserves victim" 'victim content' \
    "$(< "$shaped_victim")"
  if [[ "$lock_artifact_shape" == directory ]]; then
    [[ -d "$shaped_artifact" ]] \
      || record_failure "lock removes directory crash artifact"
    /bin/rmdir "$shaped_artifact"
  else
    [[ -e "$shaped_artifact" || -L "$shaped_artifact" ]] \
      || record_failure "lock removes $lock_artifact_shape crash artifact"
    /bin/chmod -RN "$shaped_artifact" 2>/dev/null || true
    /bin/chmod 600 "$shaped_artifact" 2>/dev/null || true
  fi
done

crypto_kill_index=0
for crypto_kill_marker in \
    generate-new-plaintext write-staged-plaintext change-apfs-passphrase \
    install-rotated-plaintext update-keychain create-tle-ciphertext \
    verify-ciphertext-nonempty verify-ciphertext-not-early \
    verify-expected-early-error write-plaintext-hash write-locked-json \
    install-locked-json remove-plaintext remove-keychain-plaintext \
    lock-apfs verify-filevault verify-mount-resistance; do
  crypto_kill_index=$((crypto_kill_index + 1))
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'signal_KILL\n' \
    > "$apfs_state/transition_lock_crypto_$crypto_kill_marker"
  if crypto_kill_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
    crypto_kill_status=0
  else
    crypto_kill_status=$?
  fi
  check "SIGKILL at $crypto_kill_marker preserves kill status" 137 \
    "$crypto_kill_status"
  check_count "SIGKILL at $crypto_kill_marker reports no success" 0 \
    'Result: locked until' "$crypto_kill_output"
  expected_kill_markers=$(printf '%s\n' "$canonical_crypto_markers" \
    | /usr/bin/head -n "$crypto_kill_index")
  check "SIGKILL at $crypto_kill_marker reached exact crypto prefix" \
    "$expected_kill_markers" "$(< "$apfs_state/lock-crypto-markers")"
  if (( crypto_kill_index >= 3 )); then
    check "SIGKILL at $crypto_kill_marker leaves APFS on new key" \
      "$lock_expected_new_secret" \
      "$(< "$apfs_state/current_apfs_passphrase")"
  else
    check "SIGKILL at $crypto_kill_marker leaves APFS on old key" \
      "$lock_old_passphrase" "$(< "$apfs_state/current_apfs_passphrase")"
  fi
  if (( crypto_kill_index >= 4 && crypto_kill_index < 13 )); then
    check "SIGKILL at $crypto_kill_marker installs canonical new plaintext" \
      "$lock_expected_new_secret" "$(< "$state_dir/passphrase.txt")"
    [[ ! -e "$state_dir/passphrase-new.txt" ]] \
      || record_failure \
        "SIGKILL at $crypto_kill_marker retains committed passphrase-new"
  fi
  if (( crypto_kill_index >= 5 && crypto_kill_index < 14 )); then
    check "SIGKILL at $crypto_kill_marker stores new keychain value" \
      "$lock_expected_new_secret" "$(< "$apfs_state/keychain_value")"
  fi
  if (( crypto_kill_index >= 6 )); then
    [[ -s "$state_dir/passphrase.tle" \
        && -s "$apfs_state/tle_lock_plaintext_digest" ]] \
      || record_failure \
        "SIGKILL at $crypto_kill_marker lacks completed TLE ciphertext"
  fi
  if (( crypto_kill_index >= 12 )); then
    check "SIGKILL at $crypto_kill_marker installs locked JSON" true \
      "$(jq -r .locked "$state_dir/state.json")"
  fi
  if (( crypto_kill_index >= 13 )); then
    [[ ! -e "$state_dir/passphrase.txt" ]] \
      || record_failure \
        "SIGKILL at $crypto_kill_marker retains removed plaintext"
  fi
  if (( crypto_kill_index >= 14 )); then
    [[ ! -e "$apfs_state/keychain_value" ]] \
      || record_failure \
        "SIGKILL at $crypto_kill_marker retains removed keychain value"
  fi
  if (( crypto_kill_index >= 15 )); then
    check "SIGKILL at $crypto_kill_marker leaves APFS locked" true \
      "$(< "$apfs_state/locked")"
  fi
  current_apfs_passphrase=$(< "$apfs_state/current_apfs_passphrase")
  crypto_recovery_available=false
  for crypto_recovery_path in \
      "$state_dir/passphrase.txt" "$state_dir/passphrase-new.txt" \
      "$apfs_state/keychain_value"; do
    if [[ -s "$crypto_recovery_path" \
        && "$(< "$crypto_recovery_path")" == "$current_apfs_passphrase" ]]; then
      crypto_recovery_available=true
    fi
  done
  current_apfs_digest=$(printf '%s' "$current_apfs_passphrase" \
    | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)
  if [[ "$(jq -r .locked "$state_dir/state.json")" == true \
      && -s "$state_dir/passphrase.tle" \
      && -s "$state_dir/passphrase.sha256" \
      && -s "$apfs_state/tle_lock_plaintext_digest" \
      && "$(< "$state_dir/passphrase.sha256")" == "$current_apfs_digest" \
      && "$(< "$apfs_state/tle_lock_plaintext_digest")" \
        == "$current_apfs_digest" ]]; then
    crypto_recovery_available=true
  fi
  [[ "$crypto_recovery_available" == true ]] \
    || record_failure \
      "SIGKILL at $crypto_kill_marker leaves no recoverable key channel"
  [[ -d "$operation_lock_dir" ]] \
    || record_failure \
      "SIGKILL at $crypto_kill_marker must leave cooperative lock evidence"
  crash_leftover=$(/usr/bin/find -P "$state_dir" -mindepth 1 -maxdepth 1 \
    \( -name 'passphrase-new.txt' -o -name '.unlock-recovery.*' \
      -o -name '.tle-unlock.*' -o -name '.state-unlock.*' \
      -o -name '.passphrase-lock.*' -o -name '.tle-lock.*' \
      -o -name '.hash-lock.*' -o -name '.state-lock.*' \
      -o -name '.tle-verify.*' -o -name '.security-output.*' \) \
    -print -quit)
  if [[ -n "$crash_leftover" ]]; then
    mutation_before_retry=$(< "$mutation_log")
    if crash_retry_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
      record_failure \
        "retry after SIGKILL at $crypto_kill_marker rejects leftover"
    else
      check_contains \
        "retry after SIGKILL at $crypto_kill_marker reports leftover" \
        'staging artifact must be resolved' "$crash_retry_output"
    fi
    check "retry after SIGKILL at $crypto_kill_marker performs no mutation" \
      "$mutation_before_retry" "$(< "$mutation_log")"
  else
    if crash_retry_output=$(run_vaultlock \
        lock --yes --no-hooks 20h 2>&1); then
      crash_retry_status=0
    else
      crash_retry_status=$?
    fi
    check "retry after SIGKILL at $crypto_kill_marker converges" 0 \
      "$crash_retry_status"
    check_contains "retry after SIGKILL at $crypto_kill_marker reports success" \
      'Result: locked until' "$crash_retry_output"
    assert_lock_secure "retry after SIGKILL at $crypto_kill_marker"
  fi
done

for selected_lock_stage_shape in symlink hardlink; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  selected_stage_victim=$apfs_state/selected-stage-$selected_lock_stage_shape
  printf 'selected stage victim\n' > "$selected_stage_victim"
  printf '%s\n' "$selected_lock_stage_shape" \
    > "$apfs_state/preplace_lock_mktemp_shape"
  printf '%s\n' "$selected_stage_victim" \
    > "$apfs_state/lock_mktemp_victim"
  if selected_stage_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure \
      "lock rejects selected mktemp $selected_lock_stage_shape preplacement"
  else
    check_contains \
      "selected mktemp $selected_lock_stage_shape reports unsafe staging" \
      'state directory metadata changed while creating rotated recovery staging' \
      "$selected_stage_output"
  fi
  check "selected mktemp $selected_lock_stage_shape preserves victim" \
    'selected stage victim' "$(< "$selected_stage_victim")"
  if [[ -f "$apfs_state/preplaced_lock_mktemp_path" ]]; then
    preplaced_stage_path=$(< "$apfs_state/preplaced_lock_mktemp_path")
    [[ -e "$preplaced_stage_path" || -L "$preplaced_stage_path" ]] \
      || record_failure \
        "lock removes selected mktemp $selected_lock_stage_shape foreign entry"
    [[ -e "$preplaced_stage_path.owned-created" ]] \
      || record_failure \
        "lock removes selected mktemp $selected_lock_stage_shape owned inode"
  else
    record_failure \
      "lock never reaches selected mktemp $selected_lock_stage_shape boundary"
  fi
  check_count "selected mktemp $selected_lock_stage_shape stops before APFS change" \
    0 'changePassphrase' "$(< "$action_log")"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'fixed stage victim\n' > "$apfs_state/fixed-stage-victim"
printf 'lock_fixed_stage_symlink\n' \
  > "$apfs_state/transition_lock_before_recovery_stage"
if fixed_stage_race_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects fixed passphrase-new symlink race"
else
  check_contains "fixed passphrase-new symlink race reports no-clobber" \
    'cannot install recovery staging file without clobbering' \
    "$fixed_stage_race_output"
fi
check "fixed passphrase-new symlink race preserves victim" \
  'fixed stage victim' "$(< "$apfs_state/fixed-stage-victim")"
[[ -L "$state_dir/passphrase-new.txt" ]] \
  || record_failure "fixed passphrase-new symlink race removes foreign entry"
check_count "fixed passphrase-new symlink race stops before APFS change" 0 \
  'changePassphrase' "$(< "$action_log")"

for change_boundary_drift in device state; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'lock_change_%s_swap\n' "$change_boundary_drift" \
    > "$apfs_state/transition_lock_before_change_passphrase"
  if change_boundary_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects $change_boundary_drift drift before changePassphrase"
  else
    check_contains \
      "lock reports $change_boundary_drift drift before changePassphrase" \
      'changed before passphrase rotation' "$change_boundary_output"
  fi
  check_count "$change_boundary_drift drift calls no changePassphrase" 0 \
    'changePassphrase' "$(< "$action_log")"
  check "$change_boundary_drift drift leaves APFS key unchanged" \
    "$lock_old_passphrase" "$(< "$apfs_state/current_apfs_passphrase")"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'lock_state_dir_swap\n' \
  > "$apfs_state/transition_lock_before_stage_create"
if state_dir_stage_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects state-directory drift before staging"
else
  check_contains "lock reports state-directory drift before staging" \
    'state directory metadata changed before staging' \
    "$state_dir_stage_output"
fi
check_count "replacement state directory receives no recovery stage" 0 \
  '.passphrase-lock.' \
  "$(/usr/bin/find "$state_dir" -mindepth 1 -maxdepth 1 -print)"
check_count "state-directory stage drift calls no changePassphrase" 0 \
  'changePassphrase' "$(< "$action_log")"
/bin/rmdir "$state_dir"
/bin/mv "$state_dir.pre-stage" "$state_dir"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'install race victim\n' > "$apfs_state/install-race-victim"
printf 'lock_staged_recovery_swap\n' \
  > "$apfs_state/transition_lock_crypto_write-staged-plaintext"
if staged_recovery_swap_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects staged recovery drift before APFS rotation"
else
  check_contains "lock reports staged recovery drift before APFS rotation" \
    'staged recovery changed before passphrase rotation' \
    "$staged_recovery_swap_output"
fi
check "staged recovery drift preserves victim" 'install race victim' \
  "$(< "$apfs_state/install-race-victim")"
check_count "staged recovery drift calls no changePassphrase" 0 \
  'changePassphrase' "$(< "$action_log")"

for lock_staging_signal_case in \
    lock_after_stage_create:HUP:129 \
    lock_after_recovery_stage_write:INT:130 \
    lock_after_fixed_stage_link:TERM:143; do
  IFS=: read -r lock_staging_transition lock_staging_signal \
    lock_staging_status <<< "$lock_staging_signal_case"
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'signal_%s\n' "$lock_staging_signal" \
    > "$apfs_state/transition_$lock_staging_transition"
  if lock_staging_signal_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    lock_staging_signal_actual=0
  else
    lock_staging_signal_actual=$?
  fi
  check "$lock_staging_transition preserves $lock_staging_signal status" \
    "$lock_staging_status" "$lock_staging_signal_actual"
  check_count "$lock_staging_transition reports no false success" 0 \
    'Result: locked until' "$lock_staging_signal_output"
  lock_staging_signal_leftover=$(/usr/bin/find -P "$state_dir" \
    -mindepth 1 -maxdepth 1 \
    \( -name 'passphrase-new.txt' -o -name '.passphrase-lock.*' \) \
    -print -quit)
  check "$lock_staging_transition removes owned recovery staging" '' \
    "$lock_staging_signal_leftover"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "$lock_staging_transition retains operation lock"
  check "$lock_staging_transition leaves APFS recovery unchanged" \
    "$lock_old_passphrase" "$(< "$apfs_state/current_apfs_passphrase")"
  /bin/rm -f "$apfs_state/transition_$lock_staging_transition"
  if lock_staging_retry_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    lock_staging_retry_status=0
  else
    lock_staging_retry_status=$?
  fi
  check "$lock_staging_transition retry converges" 0 \
    "$lock_staging_retry_status"
  check_contains "$lock_staging_transition retry reports success" \
    'Result: locked until' "$lock_staging_retry_output"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'lock_pre_rotation_abort\n' \
  > "$apfs_state/transition_lock_before_change_passphrase"
if pre_rotation_abort_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "pre-rotation abort exits nonzero"
else
  pre_rotation_abort_status=$?
  check "pre-rotation abort preserves fixture status" 79 \
    "$pre_rotation_abort_status"
fi
: "$pre_rotation_abort_output"
pre_rotation_leftover=$(/usr/bin/find -P "$state_dir" \
  -mindepth 1 -maxdepth 1 \
  \( -name 'passphrase-new.txt' -o -name '.passphrase-lock.*' \) \
  -print -quit)
check "pre-rotation abort removes both disposable recovery links" '' \
  "$pre_rotation_leftover"
/bin/rm -f "$apfs_state/transition_lock_before_change_passphrase"
if pre_rotation_retry_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  pre_rotation_retry_status=0
else
  pre_rotation_retry_status=$?
fi
check "retry after pre-rotation abort converges" 0 \
  "$pre_rotation_retry_status"
check_contains "retry after pre-rotation abort reports success" \
  'Result: locked until' "$pre_rotation_retry_output"

for lock_install_race in plaintext keychain-update ciphertext hash state \
    state-stage; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'install race victim\n' > "$apfs_state/install-race-victim"
  case "$lock_install_race" in
    plaintext)
      install_transition=lock_before_plaintext_install
      install_action=lock_plaintext_install_swap
      expected_install_error='plaintext recovery metadata changed before rotated plaintext installation'
      ;;
    keychain-update)
      install_transition=lock_before_keychain_update
      install_action=lock_keychain_update_swap
      expected_install_error='keychain state changed before recovery update'
      ;;
    ciphertext)
      printf 'previous ciphertext\n' > "$state_dir/passphrase.tle"
      install_transition=lock_before_ciphertext_install
      install_action=lock_ciphertext_install_swap
      expected_install_error='ciphertext metadata changed before ciphertext installation'
      ;;
    hash)
      install_transition=lock_before_hash_install
      install_action=lock_hash_install_swap
      expected_install_error='recovery hash metadata changed before recovery hash installation'
      ;;
    state)
      install_transition=lock_before_state_install
      install_action=lock_state_install_swap
      expected_install_error='state file metadata changed before locked state installation'
      ;;
    state-stage)
      install_transition=lock_crypto_write-locked-json
      install_action=lock_state_stage_swap
      expected_install_error='locked JSON staging changed before installation'
      ;;
  esac
  printf '%s\n' "$install_action" \
    > "$apfs_state/transition_$install_transition"
  if install_race_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects $lock_install_race install drift"
  else
    check_contains "lock reports $lock_install_race install drift" \
      "$expected_install_error" "$install_race_output"
  fi
  if [[ "$lock_install_race" == keychain-update ]]; then
    check "keychain update drift preserves replacement" \
      'cmVwbGFjZW1lbnQta2V5Y2hhaW4=' \
      "$(< "$apfs_state/keychain_value")"
    check_count "keychain update drift does not overwrite replacement" 0 \
      'security -i' "$(< "$action_log")"
  else
    check "$lock_install_race install drift preserves victim" \
      'install race victim' "$(< "$apfs_state/install-race-victim")"
  fi
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_change_passphrase"
if ambiguous_change_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects ambiguous changePassphrase failure"
else
  check_contains "ambiguous changePassphrase reports retained recovery" \
    'staged recovery retained' "$ambiguous_change_output"
fi
ambiguous_current_key=$(< "$apfs_state/current_apfs_passphrase")
ambiguous_recovery_found=false
for ambiguous_recovery_path in "$state_dir/passphrase-new.txt" \
    "$state_dir"/.passphrase-lock.*; do
  if [[ -f "$ambiguous_recovery_path" \
      && "$(< "$ambiguous_recovery_path")" == "$ambiguous_current_key" ]]; then
    ambiguous_recovery_found=true
  fi
done
[[ "$ambiguous_recovery_found" == true ]] \
  || record_failure "ambiguous changePassphrase retains no verified new recovery copy"

for deletion_boundary_drift in state cipher hash keychain; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'lock_delete_%s_swap\n' "$deletion_boundary_drift" \
    > "$apfs_state/transition_lock_before_plaintext_remove"
  if deletion_boundary_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects $deletion_boundary_drift drift before deletion"
  else
    check_contains "lock reports $deletion_boundary_drift drift before deletion" \
      'changed before plaintext removal' "$deletion_boundary_output"
  fi
  [[ -f "$state_dir/passphrase.txt" ]] \
    || record_failure "$deletion_boundary_drift drift removes plaintext"
  [[ -f "$apfs_state/keychain_value" ]] \
    || record_failure "$deletion_boundary_drift drift removes keychain plaintext"
  check_count "$deletion_boundary_drift drift calls no lockVolume" 0 \
    'lockVolume' "$(< "$action_log")"
done

for volume_boundary_drift in device cipher; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'lock_volume_%s_swap\n' "$volume_boundary_drift" \
    > "$apfs_state/transition_lock_before_apfs_lock"
  if volume_boundary_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects $volume_boundary_drift drift before lockVolume"
  else
    check_contains "lock reports $volume_boundary_drift drift before lockVolume" \
      'changed before lockVolume' "$volume_boundary_output"
  fi
  check_count "$volume_boundary_drift drift calls no lockVolume" 0 \
    'lockVolume' "$(< "$action_log")"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'hold_lock_execution\n' \
  > "$apfs_state/transition_lock_before_execution"
lock_background_output=$test_root/lock-background-output
start_vaultlock_background "$lock_background_output" \
  lock --yes --no-hooks 20h
lock_background_pid=$BACKGROUND_VAULTLOCK_PID
wait_for_fixture "$apfs_state/lock_execution_entered" \
  || record_failure "lock reaches held serialized execution boundary"
if [[ -f "$operation_lock_dir/owner" ]]; then
  check_contains "held execution owner records lock command" \
    'command=lock' "$(< "$operation_lock_dir/owner")"
else
  record_failure "held lock execution owns no cooperative lock"
fi
for lock_contender_command in lock unlock adopt; do
  contender_source=$test_root/lock-contender-adopt
  /bin/mkdir -p "$contender_source"
  if [[ "$lock_contender_command" == lock ]]; then
    contender_argv=(lock --yes --no-hooks 20h)
  elif [[ "$lock_contender_command" == unlock ]]; then
    contender_argv=(unlock --no-hooks)
  else
    contender_argv=(adopt --yes "$contender_source")
  fi
  if lock_contender_output=$(run_vaultlock "${contender_argv[@]}" 2>&1); then
    record_failure "held lock excludes $lock_contender_command contender"
  else
    check_contains "held lock reports live owner to $lock_contender_command" \
      'operation lock is held by live pid' "$lock_contender_output"
  fi
done
state_dir_while_held=$test_root/state-while-lock-held
/bin/mv "$state_dir" "$state_dir_while_held"
/bin/mkdir -m 700 "$state_dir"
/bin/mv "$apfs_state/locked" "$apfs_state/locked-while-held"
if init_contender_output=$(run_vaultlock init --yes 2>&1); then
  record_failure "held lock excludes init contender"
else
  check_contains "held lock reports live owner to init" \
    'operation lock is held by live pid' "$init_contender_output"
fi
/bin/rmdir "$state_dir"
/bin/mv "$state_dir_while_held" "$state_dir"
/bin/mv "$apfs_state/locked-while-held" "$apfs_state/locked"
check_empty "all contenders stop before domain mutation" "$mutation_log"
: > "$apfs_state/release_lock_execution"
if ! wait "$lock_background_pid"; then
  record_failure "held lock completes after contenders are released"
fi
assert_lock_secure "held serialized lock"

for lock_staging_family in passphrase-new.txt .passphrase-lock.collision \
    .tle-lock.collision .hash-lock.collision .state-lock.collision \
    .tle-verify.collision; do
  for lock_staging_shape in symlink hardlink; do
    reset_lock_fixture
    write_json_state false null null null UUID-123
    write_apfs_state false true UUID-123 disk9s1
    write_lock_plaintext
    staging_collision=$state_dir/$lock_staging_family
    staging_victim=$apfs_state/staging-${lock_staging_family#.}-$lock_staging_shape
    printf 'staging victim content\n' > "$staging_victim"
    if [[ "$lock_staging_shape" == symlink ]]; then
      /bin/ln -s "$staging_victim" "$staging_collision"
    else
      /bin/ln "$staging_victim" "$staging_collision"
    fi
    if staging_collision_output=$(run_vaultlock \
        lock --yes --no-hooks 20h 2>&1); then
      record_failure \
        "lock rejects $lock_staging_family $lock_staging_shape collision"
    else
      check_contains \
        "$lock_staging_family $lock_staging_shape collision reports boundary" \
        'staging artifact must be resolved' "$staging_collision_output"
    fi
    check "$lock_staging_family $lock_staging_shape preserves victim" \
      'staging victim content' "$(< "$staging_victim")"
    [[ -e "$staging_collision" || -L "$staging_collision" ]] \
      || record_failure \
        "lock removes $lock_staging_family $lock_staging_shape collision"
    check_empty "$lock_staging_family $lock_staging_shape stops before mutation" \
      "$mutation_log"
  done
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'first artifact\n' > "$state_dir/.unlock-recovery.multiple"
printf 'second artifact with mismatched content\n' \
  > "$state_dir/.state-unlock.multiple"
GLOBIGNORE='*' VAULTLOCK_TEST_HOSTILE_GLOBS=1 \
  run_vaultlock lock --yes 20h \
  > "$test_root/lock-hostile-glob-output" 2>&1 \
  && record_failure "lock rejects multiple artifacts under hostile globs"
check_contains "hostile-glob artifact inspection reports boundary" \
  'staging artifact must be resolved' \
  "$(< "$test_root/lock-hostile-glob-output")"
check_empty "hostile-glob artifact inspection performs no mutation" \
  "$mutation_log"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'foreign owner fixture\n' > "$state_dir/.unlock-recovery.foreign-owner"
: > "$apfs_state/foreign_lock_artifact_owner"
: > "$apfs_state/fail_lock_artifact_removal"
if foreign_owner_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects foreign-owner-shaped crash artifact"
else
  check_contains "foreign-owner-shaped artifact reports boundary" \
    'staging artifact must be resolved' "$foreign_owner_output"
fi
[[ -f "$state_dir/.unlock-recovery.foreign-owner" ]] \
  || record_failure "lock removes foreign-owner-shaped crash artifact"
check_count "lock never attempts crash-artifact removal" 0 \
  '.unlock-recovery.foreign-owner' "$(< "$mutation_log")"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'lock_artifact_create\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if lock_artifact_drift_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects post-acquisition crash-artifact drift"
else
  check_contains "lock crash-artifact drift reports plan change" \
    'plan changed after operation lock acquisition' "$lock_artifact_drift_output"
fi
check_empty "lock crash-artifact drift stops before mutation" "$mutation_log"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "lock crash-artifact drift releases operation lock"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'lock_artifact_swap\n' \
  > "$apfs_state/transition_lock_before_execution"
if immediate_artifact_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects immediate crash-artifact identity swap"
else
  check_contains "immediate crash-artifact identity swap reports boundary" \
    'staging artifact must be resolved' "$immediate_artifact_output"
fi
check_count "immediate crash-artifact identity swap stops before rotation" 0 \
  'changePassphrase' "$(< "$action_log")"
check "immediate artifact swap preserves original" \
  'original crash artifact' \
  "$(< "$state_dir/.unlock-recovery.swap.original")"
check "immediate artifact swap preserves replacement" \
  'replacement crash artifact' "$(< "$state_dir/.unlock-recovery.swap")"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
create_operation_lock 999999 "$fake_process_start" unlock \
  "$fake_operation_token"
if lock_stale_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
  lock_stale_status=0
else
  lock_stale_status=$?
fi
check "lock replaces verified stale operation lock" 0 "$lock_stale_status"
check_contains "lock reports retained stale operation lock" \
  'Retained stale operation lock quarantine:' "$lock_stale_output"
check "lock retains one stale operation lock quarantine" 1 \
  "$(/usr/bin/find "$test_home" -maxdepth 1 -type d \
    -name '.vaultlock-operation.lock.quarantine.*' | /usr/bin/wc -l \
    | /usr/bin/tr -d '[:space:]')"
clear_operation_locks

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'lock_apfs_state_swap\n' \
  > "$apfs_state/transition_plan_revalidation_before_inspection"
if lock_plan_drift_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects post-acquisition typed plan drift"
else
  check_contains "lock reports post-acquisition typed plan drift" \
    'plan changed after operation lock acquisition' "$lock_plan_drift_output"
fi
check_empty "lock typed plan drift stops before domain mutation" "$mutation_log"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "lock typed plan drift releases operation lock"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_operation_lock_release"
if lock_release_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock reports cooperative release failure"
else
  check_contains "lock release failure reports retained lock" \
    'operation lock retained' "$lock_release_output"
fi
check_count "lock release failure suppresses final success" 0 \
  'Result: locked until' "$lock_release_output"
check "lock release failure still reaches secure JSON target" true \
  "$(jq -r .locked "$state_dir/state.json")"
[[ -d "$operation_lock_dir" ]] \
  || record_failure "lock release failure retains no operation lock"
/bin/rm -f "$apfs_state/fail_operation_lock_release"
clear_operation_locks

for lock_signal in HUP INT TERM; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  printf 'signal_%s\n' "$lock_signal" \
    > "$apfs_state/transition_lock_before_execution"
  if lock_signal_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    lock_signal_status=0
  else
    lock_signal_status=$?
  fi
  case "$lock_signal" in
    HUP) expected_lock_signal_status=129 ;;
    INT) expected_lock_signal_status=130 ;;
    TERM) expected_lock_signal_status=143 ;;
  esac
  check "lock $lock_signal preserves signal status" \
    "$expected_lock_signal_status" "$lock_signal_status"
  check_count "lock $lock_signal suppresses final success" 0 \
    'Result: locked until' "$lock_signal_output"
  check_empty "lock $lock_signal stops before domain mutation" "$mutation_log"
  [[ ! -e "$operation_lock_dir" ]] \
    || record_failure "lock $lock_signal releases operation lock"
done

for deletion_failure in keychain-fail keychain-noop plaintext-fail plaintext-noop; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  case "$deletion_failure" in
    keychain-fail) : > "$apfs_state/fail_keychain_delete" ;;
    keychain-noop) : > "$apfs_state/noop_keychain_delete" ;;
    plaintext-fail) : > "$apfs_state/fail_lock_plaintext_remove" ;;
    plaintext-noop) : > "$apfs_state/noop_lock_plaintext_remove" ;;
  esac
  if deletion_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects $deletion_failure deletion boundary"
  else
    check_contains "lock reports $deletion_failure deletion boundary" \
      'cannot verify removal' "$deletion_output"
  fi
  check_count "$deletion_failure stops before APFS lock" 0 \
    'lockVolume' "$(< "$action_log")"
  check_count "$deletion_failure reports no final success" 0 \
    'Result: locked until' "$deletion_output"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf 'victim content\n' > "$apfs_state/plaintext-delete-victim"
printf 'lock_plaintext_identity_swap\n' \
  > "$apfs_state/transition_lock_before_plaintext_remove"
if plaintext_swap_output=$(run_vaultlock lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects plaintext removal identity swap"
else
  check_contains "plaintext removal identity swap reports boundary" \
    'protected recovery state changed before plaintext removal' \
    "$plaintext_swap_output"
fi
check "plaintext removal identity swap preserves victim" 'victim content' \
  "$(< "$apfs_state/plaintext-delete-victim")"
check_count "plaintext identity swap stops before APFS lock" 0 \
  'lockVolume' "$(< "$action_log")"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
/bin/mkdir -p "$state_dir/hooks/pre-lock.d"
/bin/cp "$TEST_SELF" "$state_dir/hooks/pre-lock.d/10-failing-pre-lock"
/bin/chmod +x "$state_dir/hooks/pre-lock.d/10-failing-pre-lock"
printf '10-failing-pre-lock\n' > "$apfs_state/fail_hook_name"
if pre_lock_failure_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects failed pre-lock hook"
else
  check_contains "lock reports failed pre-lock hook" \
    'pre-lock hooks failed' "$pre_lock_failure_output"
fi
check_count "failed pre-lock hook stops before Time Machine" 0 \
  'tmutil addexclusion' "$(< "$action_log")"
check_count "failed pre-lock hook stops before crypto" 0 \
  'changePassphrase' "$(< "$action_log")"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
/bin/mkdir -p "$state_dir/hooks/post-lock.d"
for post_hook_name in 10-failing-post-lock 20-following-post-lock; do
  /bin/cp "$TEST_SELF" "$state_dir/hooks/post-lock.d/$post_hook_name"
  /bin/chmod +x "$state_dir/hooks/post-lock.d/$post_hook_name"
done
printf '10-failing-post-lock\n' > "$apfs_state/fail_hook_name"
if post_lock_failure_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock reports failed post-lock hook"
else
  check_contains "lock reports secure target with failed post-lock hook" \
    'vault is locked until' "$post_lock_failure_output"
fi
check_contains "lock continues remaining post-lock hooks" \
  '20-following-post-lock --phase post-lock' "$(< "$hook_log")"
check_count "failed post-lock hook suppresses final success" 0 \
  'Result: locked until' "$post_lock_failure_output"
[[ ! -e "$operation_lock_dir" ]] \
  || record_failure "post-lock hook failure releases operation lock"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_data_snapshot_cleanup"
if data_snapshot_failure_output=$(run_vaultlock \
    lock --yes --no-hooks 20h 2>&1); then
  record_failure "lock rejects data snapshot cleanup failure"
else
  check_contains "lock reports data snapshot cleanup failure" \
    'cannot delete local Time Machine snapshots for the data volume' \
    "$data_snapshot_failure_output"
fi
check "data snapshot cleanup failure retains locked JSON" true \
  "$(jq -r .locked "$state_dir/state.json")"
check_count "data snapshot cleanup failure still locks APFS" 2 \
  'lockVolume' "$(< "$action_log")"
check_count "data snapshot cleanup failure verifies mount resistance" 1 \
  'diskutil mount disk9s1' "$(< "$action_log")"
assert_lock_secure "data snapshot cleanup failure"
check_count "data snapshot cleanup failure reports no final success" 0 \
  'Result: locked until' "$data_snapshot_failure_output"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_lock_volume"
/bin/mkdir -p "$state_dir/hooks/post-lock.d"
/bin/cp "$TEST_SELF" "$state_dir/hooks/post-lock.d/20-must-not-run"
/bin/chmod +x "$state_dir/hooks/post-lock.d/20-must-not-run"
if apfs_lock_failure_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects APFS lockVolume failure"
else
  check_contains "lock reports APFS lockVolume failure" \
    'APFS lock failed' "$apfs_lock_failure_output"
fi
check "APFS lock failure retains locked JSON" true \
  "$(jq -r .locked "$state_dir/state.json")"
[[ -s "$state_dir/passphrase.tle" \
    && -s "$state_dir/passphrase.sha256" ]] \
  || record_failure "APFS lock failure retains recovery ciphertext and hash"
check_count "APFS lock failure runs no post hook" 0 \
  '20-must-not-run --phase post-lock' "$hook_log"
check_count "APFS lock failure suppresses final success" 0 \
  'Result: locked until' "$apfs_lock_failure_output"

for lock_postcondition_failure in filevault mount-resistance; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  /bin/mkdir -p "$state_dir/hooks/post-lock.d"
  /bin/cp "$TEST_SELF" \
    "$state_dir/hooks/post-lock.d/30-post-must-not-run"
  /bin/chmod +x "$state_dir/hooks/post-lock.d/30-post-must-not-run"
  if [[ "$lock_postcondition_failure" == filevault ]]; then
    : > "$apfs_state/filevault_disabled"
  else
    : > "$apfs_state/allow_mount_while_locked"
  fi
  if postcondition_output=$(run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects $lock_postcondition_failure postcondition"
  else
    check_contains "lock reports $lock_postcondition_failure postcondition" \
      'lock target verification failed' "$postcondition_output"
  fi
  check_count "$lock_postcondition_failure runs no post hooks" 0 \
    '--phase post-lock' "$(< "$hook_log")"
  check_count "$lock_postcondition_failure reports no final success" 0 \
    'Result: locked until' "$postcondition_output"
done

for post_lock_tamper in state cipher hash; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  /bin/mkdir -p "$state_dir/hooks/post-lock.d"
  /bin/cp "$TEST_SELF" \
    "$state_dir/hooks/post-lock.d/10-post-lock-$post_lock_tamper-tamper"
  /bin/cp "$TEST_SELF" \
    "$state_dir/hooks/post-lock.d/20-post-lock-after-tamper"
  /bin/chmod +x "$state_dir/hooks/post-lock.d/"*
  if post_lock_tamper_output=$(run_vaultlock lock --yes 20h 2>&1); then
    record_failure "lock rejects post-hook $post_lock_tamper tamper"
  else
    check_contains "lock reports post-hook $post_lock_tamper tamper" \
      'protected recovery state changed' "$post_lock_tamper_output"
  fi
  check_count "post-hook $post_lock_tamper tamper stops later hooks" 0 \
    '20-post-lock-after-tamper --phase post-lock' "$hook_log"
  check_count "post-hook $post_lock_tamper tamper suppresses success" 0 \
    'Result: locked until' "$post_lock_tamper_output"
done

for secret_failure_boundary in change-passphrase keychain tle-encrypt \
    tle-decrypt; do
  reset_lock_fixture
  write_json_state false null null null UUID-123
  write_apfs_state false true UUID-123 disk9s1
  write_lock_plaintext
  case "$secret_failure_boundary" in
    change-passphrase) : > "$apfs_state/echo_change_passphrase_error" ;;
    keychain) : > "$apfs_state/echo_security_error" ;;
    tle-encrypt) : > "$apfs_state/echo_tle_encrypt_error" ;;
    tle-decrypt) : > "$apfs_state/echo_tle_decrypt_error" ;;
  esac
  if secret_failure_output=$(run_vaultlock \
      lock --yes --no-hooks 20h 2>&1); then
    record_failure "lock rejects echoing $secret_failure_boundary failure"
  fi
  generated_lock_secret=$lock_expected_new_secret
  if [[ -f "$apfs_state/lock_new_passphrase" ]]; then
    generated_lock_secret=$(< "$apfs_state/lock_new_passphrase")
  fi
  check_secret_absent "$secret_failure_boundary hides old secret in output" \
    "$secret_failure_output" "$lock_old_passphrase"
  check_secret_absent "$secret_failure_boundary hides new secret in output" \
    "$secret_failure_output" "$generated_lock_secret"
  check_secret_absent "$secret_failure_boundary hides old secret in argv logs" \
    "$(< "$action_log")" "$lock_old_passphrase"
  check_secret_absent "$secret_failure_boundary hides new secret in argv logs" \
    "$(< "$action_log")" "$generated_lock_secret"
  retained_lock_errors=$(/usr/bin/find -P "$state_dir" \
    -mindepth 1 -maxdepth 1 -type f \
    \( -name '.security-output.*' -o -name '.tle-verify.*' \
      -o -name '.lock-error.*' \) -exec /bin/cat -- {} + 2>/dev/null \
    || true)
  check_secret_absent \
    "$secret_failure_boundary hides old secret in retained errors" \
    "$retained_lock_errors" "$lock_old_passphrase"
  check_secret_absent \
    "$secret_failure_boundary hides new secret in retained errors" \
    "$retained_lock_errors" "$generated_lock_secret"
  check_count "$secret_failure_boundary reports no final success" 0 \
    'Result: locked until' "$secret_failure_output"
done

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
: > "$apfs_state/fail_curl"
if unreachable_lock_output=$(run_vaultlock lock --yes 20h 2>&1); then
  record_failure "lock rejects unreachable drand"
else
  check_contains "lock reports unreachable drand" \
    'drand chain info unreachable' "$unreachable_lock_output"
fi
check_empty "unreachable drand stops before mutation" "$mutation_log"

reset_lock_fixture
write_json_state false null null null UUID-123
write_apfs_state false true UUID-123 disk9s1
write_lock_plaintext
printf '%s' "$lock_old_passphrase" \
  > "$apfs_state/expected_child_lock_old_secret"
printf '%s' "$lock_expected_new_secret" \
  > "$apfs_state/expected_child_lock_new_secret"
if imported_lock_output=$(run_vaultlock_with_imported_secret_names \
    lock --yes --no-hooks 20h 2>&1); then
  imported_lock_status=0
else
  imported_lock_status=$?
fi
check "lock clears imported secret export attributes under allexport" 0 \
  "$imported_lock_status"
check_contains "lock imported-secret run reports success" \
  'Result: locked until' "$imported_lock_output"
[[ ! -e "$apfs_state/lock_old_secret_in_child_environment" ]] \
  || record_failure "old lock recovery secret reaches child environment"
[[ ! -e "$apfs_state/lock_new_secret_in_child_environment" ]] \
  || record_failure "new lock recovery secret reaches child environment"
[[ -e "$apfs_state/lock_old_secret_environment_probe_ran" ]] \
  || record_failure "old lock secret environment probe did not run after read"
[[ -e "$apfs_state/lock_new_secret_environment_probe_ran" ]] \
  || record_failure "new lock secret environment probe did not run after generation"

reset_operation_lock_fixture

exit "$fail"
