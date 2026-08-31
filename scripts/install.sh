#!/bin/bash
# Guarded two-target installer for the Vaultlock command and helper suite.
set -euo pipefail

REPO_ROOT_INPUT=${VAULTLOCK_INSTALL_REPO_ROOT:?}
BIN_DIR_INPUT=''
REPO_ROOT=''
BIN_DIR=''
SOURCES=(bin/vaultlock tests/vaultlock-test.sh)
NAMES=(vaultlock vaultlock-test.sh)
SOURCE_PATHS=()
SOURCE_IDENTITIES=()
TARGET_PATHS=()
TARGET_KINDS=()
TARGET_IDENTITIES=()
BASELINE_COMMITS=()
STAGE_DIRECTORIES=()
STAGE_LINKS=()
STAGE_IDENTITIES=()

die() {
  printf 'vaultlock install: %s\n' "$*" >&2
  exit 1
}

validate_path_input() { # label value
  local label=$1 value=$2
  local LC_ALL=C
  case "$value" in
    *[![:print:]]*)
      die "$label must contain only printable ASCII bytes"
      ;;
  esac
}

resolve_bin_dir_input() {
  local mode=${VAULTLOCK_INSTALL_BIN_DIR_MODE-}
  case "$mode" in
    default-home)
      [[ -n "${VAULTLOCK_INSTALL_HOME-}" ]] \
        || die 'HOME is empty while BIN_DIR is omitted'
      BIN_DIR_INPUT=$VAULTLOCK_INSTALL_HOME/bin
      ;;
    explicit)
      BIN_DIR_INPUT=${VAULTLOCK_INSTALL_BIN_DIR-}
      ;;
    *)
      die 'invalid installer BIN_DIR mode'
      ;;
  esac
}

normalize_repo_root() {
  [[ "$REPO_ROOT_INPUT" == /* && -d "$REPO_ROOT_INPUT" \
      && ! -L "$REPO_ROOT_INPUT" ]] \
    || die "invalid repository root: $REPO_ROOT_INPUT"
  REPO_ROOT=$(cd "$REPO_ROOT_INPUT" && pwd -P)
}

normalize_bin_dir() {
  local requested=$BIN_DIR_INPUT cursor parent component candidate
  local suffix_index
  local -a suffix

  [[ -n "$requested" ]] || die 'BIN_DIR is empty'
  [[ "$requested" == /* ]] || requested=$PWD/$requested
  while [[ "$requested" != / && "$requested" == */ ]]; do
    requested=${requested%/}
  done
  [[ ! -L "$requested" ]] || die "refusing unsafe BIN_DIR: $requested"
  if [[ -e "$requested" && ! -d "$requested" ]]; then
    die "refusing unsafe BIN_DIR: $requested"
  fi
  if [[ -d "$requested" ]]; then
    BIN_DIR=$(cd "$requested" && pwd -P)
    return
  fi

  cursor=$requested
  suffix=()
  while [[ ! -e "$cursor" && ! -L "$cursor" ]]; do
    component=${cursor##*/}
    [[ -n "$component" ]] || die "cannot resolve BIN_DIR: $requested"
    if [[ ${suffix[0]+set} == set ]]; then
      suffix=("$component" "${suffix[@]}")
    else
      suffix=("$component")
    fi
    parent=${cursor%/*}
    [[ -n "$parent" ]] || parent=/
    cursor=$parent
  done
  [[ -d "$cursor" ]] || die "unsafe BIN_DIR parent: $cursor"
  BIN_DIR=$(cd "$cursor" && pwd -P)
  for ((suffix_index=0; suffix_index<${#suffix[@]}; suffix_index++)); do
    component=${suffix[$suffix_index]}
    case "$component" in
      ''|.) ;;
      ..)
        [[ "$BIN_DIR" != / ]] || die "BIN_DIR escapes the filesystem root"
        BIN_DIR=${BIN_DIR%/*}
        [[ -n "$BIN_DIR" ]] || BIN_DIR=/
        ;;
      *)
        candidate=${BIN_DIR%/}/$component
        if [[ -e "$candidate" || -L "$candidate" ]]; then
          [[ -d "$candidate" ]] \
            || die "unsafe BIN_DIR component: $candidate"
          if [[ -L "$candidate" \
              && "$suffix_index" -eq $((${#suffix[@]} - 1)) ]]; then
            die "refusing unsafe BIN_DIR: $candidate"
          fi
          BIN_DIR=$(cd "$candidate" && pwd -P)
        else
          BIN_DIR=$candidate
        fi
        ;;
    esac
  done
}

precompute_paths() {
  local index
  for ((index=0; index<${#SOURCES[@]}; index++)); do
    SOURCE_PATHS[index]=$REPO_ROOT/${SOURCES[$index]}
    TARGET_PATHS[index]=$BIN_DIR/${NAMES[$index]}
  done
}

validate_source() { # index freeze|revalidate
  local index=$1 mode=$2 source identity expected
  source=${SOURCE_PATHS[$index]}
  [[ -f "$source" && ! -L "$source" && -r "$source" && -x "$source" ]] \
    || die "invalid repository source: $source"
  identity=$(/usr/bin/stat -f '%d:%i' "$source")
  if [[ "$mode" == freeze ]]; then
    SOURCE_IDENTITIES[index]=$identity
    return
  fi
  expected=${SOURCE_IDENTITIES[$index]}
  [[ "$identity" == "$expected" ]] \
    || die "repository source changed before replacement: $source"
}

load_baseline() { # index
  local index=$1 source first_commit baseline_type
  source=${SOURCES[$index]}
  first_commit=$(/usr/bin/git -C "$REPO_ROOT" log --diff-filter=A \
    --format=%H -- "$source" | /usr/bin/tail -n 1)
  [[ -n "$first_commit" ]] || die "no baseline commit for $source"
  /usr/bin/git -C "$REPO_ROOT" cat-file -e "$first_commit:$source" \
    || die "missing baseline blob for $source"
  baseline_type=$(/usr/bin/git -C "$REPO_ROOT" cat-file -t \
    "$first_commit:$source")
  [[ "$baseline_type" == blob ]] || die "invalid baseline blob for $source"
  BASELINE_COMMITS[index]=$first_commit
}

baseline_matches_target() { # index
  local index=$1
  /usr/bin/git -C "$REPO_ROOT" show \
    "${BASELINE_COMMITS[$index]}:${SOURCES[$index]}" \
    | /usr/bin/cmp -s - "${TARGET_PATHS[$index]}"
}

reject_source_target_aliases() {
  local target_index source_index target target_identity
  for ((target_index=0; target_index<${#TARGET_PATHS[@]}; target_index++)); do
    target=${TARGET_PATHS[$target_index]}
    for ((source_index=0; source_index<${#SOURCE_PATHS[@]}; source_index++)); do
      [[ "$target" != "${SOURCE_PATHS[$source_index]}" ]] \
        || die "install target aliases repository source: $target"
    done
    if [[ -f "$target" && ! -L "$target" ]]; then
      target_identity=$(/usr/bin/stat -f '%d:%i' "$target")
      for ((source_index=0; source_index<${#SOURCE_IDENTITIES[@]}; source_index++)); do
        [[ "$target_identity" != "${SOURCE_IDENTITIES[$source_index]}" ]] \
          || die "install target aliases repository source: $target"
      done
    fi
  done
}

validate_target() { # index freeze|revalidate
  local index=$1 mode=$2 target source current identity kind expected
  target=${TARGET_PATHS[$index]}
  source=${SOURCE_PATHS[$index]}
  if [[ "$mode" == freeze ]]; then
    if [[ -L "$target" ]]; then
      current=$(/usr/bin/readlink "$target")
      [[ "$current" == "$source" ]] \
        || die "refusing unexpected symlink: $target -> $current"
      TARGET_KINDS[index]='link'
      TARGET_IDENTITIES[index]=$(/usr/bin/stat -f '%d:%i' "$target")
    elif [[ -f "$target" ]]; then
      baseline_matches_target "$index" \
        || die "refusing modified target: $target"
      TARGET_KINDS[index]='regular'
      TARGET_IDENTITIES[index]=$(/usr/bin/stat -f '%d:%i' "$target")
    elif [[ -e "$target" ]]; then
      die "refusing unsupported target: $target"
    else
      TARGET_KINDS[index]='absent'
      TARGET_IDENTITIES[index]=''
    fi
    return
  fi

  kind=${TARGET_KINDS[$index]}
  expected=${TARGET_IDENTITIES[$index]}
  case "$kind" in
    absent)
      [[ ! -e "$target" && ! -L "$target" ]] || return 1
      ;;
    link)
      [[ -L "$target" ]] || return 1
      current=$(/usr/bin/readlink "$target")
      identity=$(/usr/bin/stat -f '%d:%i' "$target")
      [[ "$current" == "$source" && "$identity" == "$expected" ]] || return 1
      ;;
    regular)
      [[ -f "$target" && ! -L "$target" ]] || return 1
      identity=$(/usr/bin/stat -f '%d:%i' "$target")
      [[ "$identity" == "$expected" ]] || return 1
      baseline_matches_target "$index" || return 1
      ;;
    *) return 1 ;;
  esac
}

run_transition() { # phase index source target stage
  if [[ "${VAULTLOCK_INSTALL_TEST_MODE:-0}" == 1 \
      && -n "${VAULTLOCK_INSTALL_TEST_TRANSITION:-}" ]]; then
    "$VAULTLOCK_INSTALL_TEST_TRANSITION" "$@"
  fi
}

cleanup_stages() {
  local index stage link expected_source
  for ((index=0; index<${#STAGE_DIRECTORIES[@]}; index++)); do
    stage=${STAGE_DIRECTORIES[$index]-}
    link=${STAGE_LINKS[$index]-}
    expected_source=${SOURCE_PATHS[$index]-}
    if [[ -n "$link" && -L "$link" \
        && "$(/usr/bin/readlink "$link")" == "$expected_source" ]]; then
      /bin/rm "$link"
    fi
    if [[ -n "$stage" && -d "$stage" && ! -L "$stage" ]]; then
      /bin/rmdir "$stage" 2>/dev/null || true
    fi
  done
}

finish_install() {
  local install_status=$?
  trap - EXIT HUP INT TERM
  cleanup_stages
  exit "$install_status"
}

create_stage() { # index
  local index=$1 stage link
  stage=$(/usr/bin/mktemp -d \
    "$BIN_DIR/.vaultlock-install.${NAMES[$index]}.XXXXXX")
  STAGE_DIRECTORIES[index]=$stage
  run_transition after-stage-create "$index" "${SOURCE_PATHS[$index]}" \
    "${TARGET_PATHS[$index]}" "$stage"
  /bin/chmod 700 "$stage"
  link=$stage/link
  STAGE_LINKS[index]=$link
  /bin/ln -s "${SOURCE_PATHS[$index]}" "$link"
  STAGE_IDENTITIES[index]=$(/usr/bin/stat -f '%d:%i' "$link")
}

validate_stage() { # index
  local index=$1 link
  link=${STAGE_LINKS[$index]}
  [[ -L "$link" \
      && "$(/usr/bin/readlink "$link")" == "${SOURCE_PATHS[$index]}" \
      && "$(/usr/bin/stat -f '%d:%i' "$link")" == "${STAGE_IDENTITIES[$index]}" ]]
}

revalidate_all_boundaries() {
  local index
  for ((index=0; index<${#SOURCES[@]}; index++)); do
    validate_source "$index" revalidate
    validate_target "$index" revalidate \
      || die "target changed before installation: ${TARGET_PATHS[$index]}"
    validate_stage "$index" \
      || die "staged link changed before installation: ${STAGE_LINKS[$index]}"
  done
}

apply_target() { # index
  local index=$1 source target stage_link
  source=${SOURCE_PATHS[$index]}
  target=${TARGET_PATHS[$index]}
  stage_link=${STAGE_LINKS[$index]}
  run_transition before-replacement "$index" "$source" "$target" \
    "${STAGE_DIRECTORIES[$index]}"
  validate_source "$index" revalidate
  validate_target "$index" revalidate \
    || die "target changed before replacement: $target"
  validate_stage "$index" \
    || die "staged link changed before replacement: $stage_link"
  /bin/mv -f "$stage_link" "$target"
  [[ -L "$target" && "$(/usr/bin/readlink "$target")" == "$source" ]] \
    || die "installed link verification failed: $target"
  /bin/rmdir "${STAGE_DIRECTORIES[$index]}"
  STAGE_DIRECTORIES[index]=''
  STAGE_LINKS[index]=''
  printf 'installed %s -> %s\n' "$target" "$source"
}

main() {
  local index actual_bin_dir
  resolve_bin_dir_input
  validate_path_input 'repository root' "$REPO_ROOT_INPUT"
  validate_path_input 'BIN_DIR' "$BIN_DIR_INPUT"
  normalize_repo_root
  normalize_bin_dir
  precompute_paths
  for ((index=0; index<${#SOURCES[@]}; index++)); do
    validate_source "$index" freeze
    load_baseline "$index"
  done
  reject_source_target_aliases
  for ((index=0; index<${#SOURCES[@]}; index++)); do
    validate_target "$index" freeze
  done

  /bin/mkdir -p "$BIN_DIR"
  [[ -d "$BIN_DIR" && ! -L "$BIN_DIR" ]] \
    || die "BIN_DIR changed during installation: $BIN_DIR"
  actual_bin_dir=$(cd "$BIN_DIR" && pwd -P)
  [[ "$actual_bin_dir" == "$BIN_DIR" ]] \
    || die "BIN_DIR changed during installation: $BIN_DIR"
  for ((index=0; index<${#SOURCES[@]}; index++)); do
    create_stage "$index"
  done
  revalidate_all_boundaries
  for ((index=0; index<${#SOURCES[@]}; index++)); do
    apply_target "$index"
  done
}

trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
