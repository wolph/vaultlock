#!/bin/bash
# Installs the external tools vaultlock needs: tle from a checksum-verified
# drand/tlock GitHub release, and jq through Homebrew.
set -euo pipefail

TLE_VERSION=${VAULTLOCK_DEPS_TLE_VERSION:-1.2.0}
TLE_RELEASE_BASE=https://github.com/drand/tlock/releases/download
DRY_RUN=false
BIN_DIR=${HOME:-}/bin
ARCH=''
MISSING=false
WORK_DIR=''

die() {
  printf 'vaultlock install-deps: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: install-deps.sh [--dry-run] [--bin-dir DIR]\n' >&2
  exit 64
}

report() { printf '%s\n' "$*"; }

cleanup() {
  [[ -z "$WORK_DIR" ]] || /bin/rm -rf "$WORK_DIR"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --bin-dir)
        [[ $# -ge 2 ]] || usage
        BIN_DIR=$2
        shift
        ;;
      -h|--help) usage ;;
      *) usage ;;
    esac
    shift
  done
  [[ -n "$BIN_DIR" ]] || die 'HOME is empty while --bin-dir is omitted'
}

resolve_architecture() {
  local machine=${VAULTLOCK_DEPS_ARCH:-}
  [[ -n "$machine" ]] || machine=$(/usr/bin/uname -m)
  case "$machine" in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) die "unsupported architecture: $machine" ;;
  esac
}

check_bundled_tools() {
  local tool
  for tool in /usr/sbin/diskutil /usr/bin/plutil /usr/bin/security \
      /usr/bin/tmutil /usr/sbin/lsof /usr/bin/ditto; do
    [[ -x "$tool" ]] && continue
    report "${tool##*/}: missing, expected at $tool as part of macOS"
    MISSING=true
  done
}

find_tle() {
  local candidate
  if candidate=$(command -v tle 2>/dev/null); then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in "$BIN_DIR/tle" "${HOME:-}/bin/tle" "${HOME:-}/go/bin/tle"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

expected_checksum() { # checksum_file archive_name
  local line digest
  line=$(/usr/bin/grep -F -- " $2" "$1" | /usr/bin/head -n 1) || return 1
  digest=${line%% *}
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

install_tle() {
  local existing archive url checksums_url expected actual
  if existing=$(find_tle); then
    report "tle: $existing (already installed)"
    return 0
  fi
  archive="tlock_${TLE_VERSION}_darwin_${ARCH}.tar.gz"
  url="$TLE_RELEASE_BASE/v$TLE_VERSION/$archive"
  checksums_url="$TLE_RELEASE_BASE/v$TLE_VERSION/checksums.txt"
  if [[ "$DRY_RUN" == true ]]; then
    report "Would download: $url"
    report "Would verify: $archive against $checksums_url"
    report "Would install: $BIN_DIR/tle"
    return 0
  fi
  WORK_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vaultlock-install-deps.XXXXXX")
  curl -fsSL -o "$WORK_DIR/$archive" "$url" || die "cannot download $url"
  curl -fsSL -o "$WORK_DIR/checksums.txt" "$checksums_url" \
    || die "cannot download $checksums_url"
  expected=$(expected_checksum "$WORK_DIR/checksums.txt" "$archive") \
    || die "checksums.txt does not list $archive"
  actual=$(/usr/bin/shasum -a 256 "$WORK_DIR/$archive" | /usr/bin/cut -d' ' -f1)
  [[ "$expected" == "$actual" ]] \
    || die "checksum mismatch for $archive: expected $expected, got $actual"
  report "Verified: $archive"
  /usr/bin/tar -xzf "$WORK_DIR/$archive" -C "$WORK_DIR" tle \
    || die "cannot extract tle from $archive"
  [[ -f "$WORK_DIR/tle" ]] || die "$archive does not contain tle"
  /bin/mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
  /bin/chmod 755 "$WORK_DIR/tle"
  /bin/mv "$WORK_DIR/tle" "$BIN_DIR/tle" || die "cannot install $BIN_DIR/tle"
  report "tle: $BIN_DIR/tle"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) report "note: $BIN_DIR is not on PATH, vaultlock also looks in ~/bin and ~/go/bin" ;;
  esac
}

install_jq() {
  local existing
  if existing=$(command -v jq 2>/dev/null); then
    report "jq: $existing (already installed)"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    report 'jq: missing, install Homebrew from https://brew.sh and rerun'
    MISSING=true
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    report 'Would run: brew install jq'
    return 0
  fi
  HOMEBREW_NO_AUTO_UPDATE=1 brew install jq || die 'brew install jq failed'
  if existing=$(command -v jq 2>/dev/null); then
    report "jq: $existing"
  elif [[ -x "$(brew --prefix)/bin/jq" ]]; then
    report "jq: $(brew --prefix)/bin/jq"
    report "note: $(brew --prefix)/bin is not on PATH"
  else
    die 'brew install jq finished without a jq executable'
  fi
}

report_curl() {
  local existing
  if existing=$(command -v curl 2>/dev/null); then
    report "curl: $existing"
  else
    report 'curl: missing, expected as part of macOS'
    MISSING=true
  fi
}

main() {
  parse_arguments "$@"
  resolve_architecture
  trap cleanup EXIT HUP INT TERM
  check_bundled_tools
  install_tle
  install_jq
  report_curl
  [[ "$MISSING" == false ]] || exit 1
}

main "$@"
