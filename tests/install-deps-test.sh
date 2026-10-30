#!/bin/bash
# Isolated tests for the dependency installer. Network access is replaced by
# a curl fixture that serves a release archive built in the temporary root,
# and PATH holds only fixtures so the bundled /usr/bin/jq of macOS 15 and
# later stays out of the picture.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
installer=$repo_root/scripts/install-deps.sh
fail=0

if [[ ! -x "$installer" ]]; then
  printf 'FAIL dependency installer requires %s\n' "$installer"
  exit 1
fi

test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vaultlock-deps-test.XXXXXX")
test_root=$(cd "$test_root" && pwd -P)
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM
fake_bin=$test_root/fake-bin
release=$test_root/release
bin_dir=$test_root/bin
home_dir=$test_root/home
brew_prefix=$test_root/brew
tle_version=1.2.0

check() { # description expected actual
  local description=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   %s\n' "$description"
  else
    printf 'FAIL %s: expected [%s], got [%s]\n' \
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

# Release fixture: a tle stand-in inside the archive layout drand publishes.
build_release() { # archive_name
  local archive_name=$1 stage=$test_root/stage
  /bin/rm -rf "$stage" "$release"
  /bin/mkdir -p "$stage" "$release"
  cat > "$stage/tle" <<'TLE'
#!/bin/bash
printf 'tle fixture %s\n' "$*"
TLE
  /bin/chmod +x "$stage/tle"
  /usr/bin/tar -czf "$release/$archive_name" -C "$stage" tle
  (cd "$release" && /usr/bin/shasum -a 256 "$archive_name") \
    > "$release/checksums.txt"
}

write_fakes() {
  /bin/rm -rf "$fake_bin" "$brew_prefix"
  /bin/mkdir -p "$fake_bin" "$brew_prefix/bin"
  cat > "$fake_bin/curl" <<'CURL'
#!/bin/bash
# Serves files from the release directory: the last argument is the URL.
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >> "${VAULTLOCK_DEPS_TEST_LOG:?}"
source_file=$VAULTLOCK_DEPS_TEST_RELEASE/${url##*/}
[[ -f "$source_file" ]] || exit 22
/bin/cp "$source_file" "$output"
CURL
  cat > "$fake_bin/brew" <<'BREW'
#!/bin/bash
printf 'brew %s\n' "$*" >> "${VAULTLOCK_DEPS_TEST_LOG:?}"
case "$1" in
  --prefix) printf '%s\n' "$VAULTLOCK_DEPS_TEST_BREW_PREFIX" ;;
  install)
    printf '#!/bin/bash\nprintf '\''jq-fixture\\n'\''\n' \
      > "$VAULTLOCK_DEPS_TEST_BREW_PREFIX/bin/jq"
    /bin/chmod +x "$VAULTLOCK_DEPS_TEST_BREW_PREFIX/bin/jq"
    ;;
esac
BREW
  /bin/chmod +x "$fake_bin/curl" "$fake_bin/brew"
}

reset_targets() {
  /bin/rm -rf "$bin_dir" "$home_dir" "$brew_prefix/bin/jq"
  /bin/mkdir -p "$bin_dir" "$home_dir"
  : > "$test_root/log"
}

run_installer() { # arguments...
  HOME=$home_dir \
  PATH="$fake_bin:$brew_prefix/bin" \
  VAULTLOCK_DEPS_TEST_LOG=$test_root/log \
  VAULTLOCK_DEPS_TEST_RELEASE=$release \
  VAULTLOCK_DEPS_TEST_BREW_PREFIX=$brew_prefix \
  VAULTLOCK_DEPS_ARCH=${VAULTLOCK_DEPS_ARCH:-arm64} \
  VAULTLOCK_DEPS_TLE_VERSION=$tle_version \
    "$installer" --bin-dir "$bin_dir" "$@"
}

archive="tlock_${tle_version}_darwin_arm64.tar.gz"
write_fakes
build_release "$archive"

# Dry run plans both installs and touches nothing.
reset_targets
if dry_output=$(run_installer --dry-run 2>&1); then
  dry_status=0
else
  dry_status=$?
fi
check "dry run exits successfully" 0 "$dry_status"
check_contains "dry run plans the jq install" \
  'Would run: brew install jq' "$dry_output"
check_contains "dry run plans the tle download" \
  "Would download: https://github.com/drand/tlock/releases/download/v$tle_version/$archive" \
  "$dry_output"
check_contains "dry run plans the tle install" \
  "Would install: $bin_dir/tle" "$dry_output"
check "dry run installs no tle" false \
  "$([[ -e "$bin_dir/tle" ]] && printf true || printf false)"
check "dry run installs no jq" false \
  "$([[ -e "$brew_prefix/bin/jq" ]] && printf true || printf false)"
check "dry run downloads nothing" '' "$(< "$test_root/log")"

# A real run installs tle from the verified archive and jq through Homebrew.
reset_targets
if install_output=$(run_installer 2>&1); then
  install_status=0
else
  install_status=$?
fi
check "install exits successfully" 0 "$install_status"
check "install places tle in the bin directory" 'tle fixture --version' \
  "$("$bin_dir/tle" --version 2>/dev/null || printf '<missing>')"
check "install makes tle executable" true \
  "$([[ -x "$bin_dir/tle" && ! -L "$bin_dir/tle" ]] && printf true || printf false)"
check_contains "install verifies the archive checksum" \
  "Verified: $archive" "$install_output"
check_contains "install fetches the checksum list" \
  "download/v$tle_version/checksums.txt" "$(< "$test_root/log")"
check_contains "install asks Homebrew for jq" 'brew install jq' \
  "$(< "$test_root/log")"
check_contains "install reports tle" "tle: $bin_dir/tle" "$install_output"
check_contains "install reports jq" "jq: $brew_prefix/bin/jq" "$install_output"
check_contains "install reports curl" "curl: $fake_bin/curl" "$install_output"

# A second run finds everything present and changes nothing.
: > "$test_root/log"
if rerun_output=$(run_installer 2>&1); then
  rerun_status=0
else
  rerun_status=$?
fi
check "rerun exits successfully" 0 "$rerun_status"
check_contains "rerun reports tle as present" \
  "tle: $bin_dir/tle (already installed)" "$rerun_output"
check_contains "rerun reports jq as present" \
  "jq: $brew_prefix/bin/jq (already installed)" "$rerun_output"
check "rerun downloads nothing" '' "$(< "$test_root/log")"

# A corrupted archive is refused before anything reaches the bin directory.
reset_targets
printf 'corrupted\n' >> "$release/$archive"
if corrupt_output=$(run_installer 2>&1); then
  corrupt_status=0
else
  corrupt_status=$?
fi
check "corrupted archive fails" 1 "$corrupt_status"
check_contains "corrupted archive is reported" \
  'checksum mismatch' "$corrupt_output"
check "corrupted archive installs no tle" false \
  "$([[ -e "$bin_dir/tle" ]] && printf true || printf false)"
build_release "$archive"

# Without Homebrew the installer still installs tle and explains jq.
reset_targets
/bin/mv "$fake_bin/brew" "$test_root/brew.disabled"
if nobrew_output=$(run_installer 2>&1); then
  nobrew_status=0
else
  nobrew_status=$?
fi
/bin/mv "$test_root/brew.disabled" "$fake_bin/brew"
check "missing Homebrew fails" 1 "$nobrew_status"
check_contains "missing Homebrew explains jq" \
  'jq: missing, install Homebrew from https://brew.sh and rerun' \
  "$nobrew_output"
check "missing Homebrew still installs tle" 'tle fixture --version' \
  "$("$bin_dir/tle" --version 2>/dev/null || printf '<missing>')"

# An unsupported architecture stops before any download.
reset_targets
if arch_output=$(VAULTLOCK_DEPS_ARCH=ppc run_installer 2>&1); then
  arch_status=0
else
  arch_status=$?
fi
check "unsupported architecture fails" 1 "$arch_status"
check_contains "unsupported architecture is named" \
  'unsupported architecture: ppc' "$arch_output"
check "unsupported architecture downloads nothing" '' "$(< "$test_root/log")"

# Unknown options are usage errors.
if usage_output=$(run_installer --bogus 2>&1); then
  usage_status=0
else
  usage_status=$?
fi
check "unknown option exits with usage status" 64 "$usage_status"
check_contains "unknown option prints usage" \
  'usage: install-deps.sh [--dry-run] [--bin-dir DIR]' "$usage_output"

exit "$fail"
