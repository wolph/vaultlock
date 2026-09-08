#!/bin/bash
# Isolated guarded-install tests. All targets live under a temporary directory.
set -euo pipefail

if [[ "${VAULTLOCK_INSTALL_TRANSITION_FIXTURE:-0}" == "1" ]]; then
  transition_phase=${1:-}
  transition_index=${2:-}
  transition_source=${3:-}
  transition_stage=${5:-}
  case "${VAULTLOCK_INSTALL_TRANSITION_MODE:-}:$transition_phase" in
    fail-stage:after-stage-create)
      printf '%s\n' "$transition_stage" > "$VAULTLOCK_INSTALL_TRANSITION_MARKER"
      exit 7
      ;;
    drift-source:before-replacement)
      if [[ "$transition_index" == "0" \
          && ! -e "$VAULTLOCK_INSTALL_TRANSITION_MARKER" ]]; then
        /bin/mv "$transition_source" "$transition_source.before-drift"
        printf '#!/bin/bash\nprintf '\''drifted source\\n'\''\n' \
          > "$transition_source"
        /bin/chmod +x "$transition_source"
        : > "$VAULTLOCK_INSTALL_TRANSITION_MARKER"
      fi
      ;;
  esac
  exit 0
fi

if [[ "${VAULTLOCK_INSTALL_TEST_NESTED:-0}" == "1" ]]; then
  exit 0
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
makefile=$repo_root/Makefile
installer=$repo_root/scripts/install.sh
fail=0

if [[ ! -f "$makefile" || ! -x "$installer" ]]; then
  printf 'FAIL guarded install requires %s and %s\n' "$makefile" "$installer"
  exit 1
fi

test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vaultlock-install-test.XXXXXX")
test_root=$(cd "$test_root" && pwd -P)
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM
fixture_repo=$test_root/repository
bin_dir=$test_root/install-bin

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

check_file() { # description path expected
  local description=$1 path=$2 expected=$3 actual
  if [[ -f "$path" && ! -L "$path" ]]; then
    actual=$(< "$path")
  else
    actual='<not a regular file>'
  fi
  check "$description" "$expected" "$actual"
}

check_link() { # description path expected
  local description=$1 path=$2 expected=$3 actual
  if [[ -L "$path" ]]; then
    actual=$(/usr/bin/readlink "$path")
  else
    actual='<not a symlink>'
  fi
  check "$description" "$expected" "$actual"
}

reset_bin_dir() {
  /bin/rm -rf "$bin_dir"
  /bin/mkdir -p "$bin_dir"
}

check_no_residue() { # description
  local description=$1 residue_count=0
  if [[ -d "$bin_dir" ]]; then
    residue_count=$(/usr/bin/find "$bin_dir" -maxdepth 2 \
      -name '.vaultlock-install.*' -print | /usr/bin/wc -l | tr -d ' ')
  fi
  check "$description" 0 "$residue_count"
}

restore_fixture_source() { # source
  local source=$1
  /bin/rm -rf "${fixture_repo:?}/$source"
  /usr/bin/git -C "$fixture_repo" show "HEAD:$source" \
    > "$fixture_repo/$source"
  /bin/chmod +x "$fixture_repo/$source"
}

write_fixture_sources() { # version
  local version=$1
  printf '#!/bin/bash\nprintf '\''vaultlock %s\\n'\''\n' "$version" \
    > "$fixture_repo/bin/vaultlock"
  printf '#!/bin/bash\nprintf '\''vaultlock-test %s\\n'\''\n' "$version" \
    > "$fixture_repo/tests/vaultlock-test.sh"
  printf '#!/bin/bash\nexit 0\n' \
    > "$fixture_repo/tests/vaultlock-cli-test.sh"
  printf '#!/bin/bash\nexit 0\n' \
    > "$fixture_repo/tests/vaultlock-time-test.sh"
  /bin/chmod +x "$fixture_repo/bin/vaultlock" \
    "$fixture_repo/tests/vaultlock-test.sh" \
    "$fixture_repo/tests/vaultlock-cli-test.sh" \
    "$fixture_repo/tests/vaultlock-time-test.sh"
}

create_one_commit_fixture() { # repository
  local repository=$1
  /bin/mkdir -p "$repository/bin" "$repository/scripts" "$repository/tests"
  /bin/cp "$makefile" "$repository/Makefile"
  /bin/cp "$installer" "$repository/scripts/install.sh"
  /bin/cp "$0" "$repository/tests/install-test.sh"
  printf '#!/bin/bash\nprintf '\''vaultlock baseline\\n'\''\n' \
    > "$repository/bin/vaultlock"
  printf '#!/bin/bash\nprintf '\''vaultlock-test baseline\\n'\''\n' \
    > "$repository/tests/vaultlock-test.sh"
  printf '#!/bin/bash\nexit 0\n' \
    > "$repository/tests/vaultlock-cli-test.sh"
  printf '#!/bin/bash\nexit 0\n' \
    > "$repository/tests/vaultlock-time-test.sh"
  /bin/chmod +x "$repository/bin/vaultlock" \
    "$repository/tests/vaultlock-test.sh" \
    "$repository/tests/vaultlock-cli-test.sh" \
    "$repository/tests/vaultlock-time-test.sh" \
    "$repository/tests/install-test.sh" \
    "$repository/scripts/install.sh"
  /usr/bin/git -C "$repository" init -q -b master 2>/dev/null \
    || /usr/bin/git -C "$repository" init -q
  /usr/bin/git -C "$repository" config user.name 'Vaultlock install test'
  /usr/bin/git -C "$repository" config user.email \
    'vaultlock-install@example.invalid'
  /usr/bin/git -C "$repository" add Makefile bin scripts tests
  /usr/bin/git -C "$repository" commit -q -m baseline
}

regular_identity() { # path
  if [[ -f "$1" && ! -L "$1" ]]; then
    /usr/bin/stat -f '%d:%i' "$1"
  else
    printf '<not a regular file>\n'
  fi
}

run_install_in() { # repository destination
  VAULTLOCK_INSTALL_TEST_NESTED=1 \
    /usr/bin/make -s -C "$1" install BIN_DIR="$2"
}

run_installer_direct() { # repository destination
  VAULTLOCK_INSTALL_REPO_ROOT="$1" \
  VAULTLOCK_INSTALL_BIN_DIR="$2" \
  VAULTLOCK_INSTALL_BIN_DIR_MODE=explicit \
    "$fixture_repo/scripts/install.sh"
}

run_install() {
  VAULTLOCK_INSTALL_TEST_NESTED=1 \
    /usr/bin/make -s -C "$fixture_repo" install BIN_DIR="$bin_dir"
}

run_install_from_environment() {
  BIN_DIR="$bin_dir" VAULTLOCK_INSTALL_TEST_NESTED=1 \
    /usr/bin/make -s -C "$fixture_repo" install
}

run_install_with_home() { # home
  HOME=$1 VAULTLOCK_INSTALL_TEST_NESTED=1 \
    /usr/bin/make -s -C "$fixture_repo" install
}

run_install_with_transition() { # mode marker
  VAULTLOCK_INSTALL_TEST_NESTED=1 \
  VAULTLOCK_INSTALL_TEST_MODE=1 \
  VAULTLOCK_INSTALL_TEST_TRANSITION="$0" \
  VAULTLOCK_INSTALL_TRANSITION_FIXTURE=1 \
  VAULTLOCK_INSTALL_TRANSITION_MODE=$1 \
  VAULTLOCK_INSTALL_TRANSITION_MARKER=$2 \
    /usr/bin/make -s -C "$fixture_repo" install BIN_DIR="$bin_dir"
}

/bin/mkdir -p "$fixture_repo/bin" "$fixture_repo/scripts" "$fixture_repo/tests"
/bin/cp "$makefile" "$fixture_repo/Makefile"
/bin/cp "$installer" "$fixture_repo/scripts/install.sh"
/bin/cp "$0" "$fixture_repo/tests/install-test.sh"
/bin/chmod +x "$fixture_repo/tests/install-test.sh"
/bin/chmod +x "$fixture_repo/scripts/install.sh"
write_fixture_sources baseline

/usr/bin/git -C "$fixture_repo" init -q -b master 2>/dev/null \
  || /usr/bin/git -C "$fixture_repo" init -q
/usr/bin/git -C "$fixture_repo" config user.name 'Vaultlock install test'
/usr/bin/git -C "$fixture_repo" config user.email 'vaultlock-install@example.invalid'
/usr/bin/git -C "$fixture_repo" add Makefile bin scripts tests
/usr/bin/git -C "$fixture_repo" commit -q -m baseline

write_fixture_sources current
/usr/bin/git -C "$fixture_repo" add bin tests
/usr/bin/git -C "$fixture_repo" commit -q -m current

vaultlock_source=$fixture_repo/bin/vaultlock
test_source=$fixture_repo/tests/vaultlock-test.sh
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh

reset_bin_dir
run_install >/dev/null
check_link 'missing vaultlock target becomes absolute repository symlink' \
  "$vaultlock_target" "$vaultlock_source"
check_link 'missing test target becomes absolute repository symlink' \
  "$test_target" "$test_source"
check_no_residue 'successful install leaves no staging residue'

bin_dir=$test_root/nested/install/bin
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh
/bin/rm -rf "$test_root/nested"
run_install >/dev/null
check_link 'missing nested BIN_DIR is created after validation' \
  "$vaultlock_target" "$vaultlock_source"
check_link 'nested BIN_DIR receives both targets' "$test_target" "$test_source"

physical_suffix_root=$test_root/physical-suffix
/bin/mkdir -p "$physical_suffix_root/real-destination"
/bin/ln -s "$physical_suffix_root/real-destination" \
  "$physical_suffix_root/destination-alias"
bin_dir=$physical_suffix_root/missing/../destination-alias/subdir
vaultlock_target=$physical_suffix_root/real-destination/subdir/vaultlock
test_target=$physical_suffix_root/real-destination/subdir/vaultlock-test.sh
if run_install >/dev/null 2>&1; then
  printf 'ok   suffix symlink reached after dot-dot is resolved before mkdir\n'
else
  printf 'FAIL suffix symlink reached after dot-dot was rejected after mutation\n'
  fail=1
fi
check 'suffix normalization creates no cancelled component' false \
  "$([[ -e "$physical_suffix_root/missing" \
      || -L "$physical_suffix_root/missing" ]] \
    && printf true || printf false)"
check_link 'suffix normalization installs command in physical directory' \
  "$vaultlock_target" "$vaultlock_source"
check_link 'suffix normalization installs helper in physical directory' \
  "$test_target" "$test_source"

# shellcheck disable=SC2016  # Literal shell syntax tests Make expansion safety.
bin_dir=$test_root/'bin with spaces"`touch injected-marker`'
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh
/bin/rm -rf "$bin_dir"
run_install >/dev/null
check_link 'BIN_DIR with spaces and shell punctuation is literal' \
  "$vaultlock_target" "$vaultlock_source"
check 'BIN_DIR cannot inject a command through Make expansion' false \
  "$([[ -e "$fixture_repo/injected-marker" || -e "$test_root/injected-marker" ]] \
    && printf true || printf false)"

# shellcheck disable=SC2016  # Literal Make syntax must remain pathname text.
bin_dir=$test_root/'bin$(shell touch make-injected-marker)'
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh
/bin/rm -rf "$bin_dir"
/bin/rm -f "$fixture_repo/make-injected-marker"
run_install >/dev/null
check_link 'BIN_DIR with literal Make function syntax is preserved' \
  "$vaultlock_target" "$vaultlock_source"
check 'BIN_DIR cannot execute a Make shell function' false \
  "$([[ -e "$fixture_repo/make-injected-marker" ]] \
    && printf true || printf false)"

# shellcheck disable=SC2016  # Literal environment value must stay literal.
bin_dir=$test_root/'env-bin$(shell touch env-make-injected-marker)'
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh
/bin/rm -rf "$bin_dir"
/bin/rm -f "$fixture_repo/env-make-injected-marker"
run_install_from_environment >/dev/null
check_link 'environment BIN_DIR preserves literal Make syntax' \
  "$vaultlock_target" "$vaultlock_source"
check 'environment BIN_DIR cannot execute a Make shell function' false \
  "$([[ -e "$fixture_repo/env-make-injected-marker" ]] \
    && printf true || printf false)"

# shellcheck disable=SC2016  # Literal HOME Make syntax must stay literal.
default_home=$test_root/'home$(shell touch home-make-injected-marker)'
bin_dir=$default_home/bin
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh
/bin/rm -rf "$default_home"
/bin/rm -f "$fixture_repo/home-make-injected-marker"
run_install_with_home "$default_home" >/dev/null
check_link 'default HOME preserves literal Make syntax' \
  "$vaultlock_target" "$vaultlock_source"
check_link 'default HOME installs both targets' "$test_target" "$test_source"
check 'default HOME cannot execute a Make shell function' false \
  "$([[ -e "$fixture_repo/home-make-injected-marker" ]] \
    && printf true || printf false)"

newline_free_bin=$test_root/newline-bin
newline_bin=$newline_free_bin$'\n'
/bin/mkdir -p "$newline_free_bin" "$newline_bin"
newline_bin_output=''
if newline_bin_output=$(run_installer_direct \
    "$fixture_repo" "$newline_bin" 2>&1); then
  printf 'FAIL BIN_DIR with a newline was accepted\n'
  fail=1
else
  printf 'ok   BIN_DIR with a newline is refused\n'
fi
check_contains 'newline BIN_DIR reports the pathname byte policy' \
  'BIN_DIR must contain only printable ASCII bytes' "$newline_bin_output"
check 'newline BIN_DIR cannot redirect to its newline-free sibling' false \
  "$([[ -e "$newline_free_bin/vaultlock" \
      || -L "$newline_free_bin/vaultlock" \
      || -e "$newline_free_bin/vaultlock-test.sh" \
      || -L "$newline_free_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"
check 'newline BIN_DIR is unchanged before refusal' false \
  "$([[ -e "$newline_bin/vaultlock" || -L "$newline_bin/vaultlock" \
      || -e "$newline_bin/vaultlock-test.sh" \
      || -L "$newline_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

tab_bin=$test_root/$'tab\tbin'
/bin/mkdir -p "$tab_bin"
tab_bin_output=''
if tab_bin_output=$(run_installer_direct \
    "$fixture_repo" "$tab_bin" 2>&1); then
  printf 'FAIL BIN_DIR with a tab was accepted\n'
  fail=1
else
  printf 'ok   BIN_DIR with a tab is refused\n'
fi
check_contains 'tab BIN_DIR reports the pathname byte policy' \
  'BIN_DIR must contain only printable ASCII bytes' "$tab_bin_output"
check 'tab BIN_DIR is unchanged before refusal' false \
  "$([[ -e "$tab_bin/vaultlock" || -L "$tab_bin/vaultlock" \
      || -e "$tab_bin/vaultlock-test.sh" \
      || -L "$tab_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

newline_repo=$fixture_repo$'\n'
newline_repo_bin=$test_root/newline-repo-bin
/bin/mkdir -p "$newline_repo"
newline_repo_output=''
if newline_repo_output=$(run_installer_direct \
    "$newline_repo" "$newline_repo_bin" 2>&1); then
  printf 'FAIL repository root with a newline was accepted\n'
  fail=1
else
  printf 'ok   repository root with a newline is refused\n'
fi
check_contains 'newline repository root reports the pathname byte policy' \
  'repository root must contain only printable ASCII bytes' \
  "$newline_repo_output"
check 'newline repository root cannot redirect to its newline-free sibling' \
  false \
  "$([[ -e "$newline_repo_bin/vaultlock" \
      || -L "$newline_repo_bin/vaultlock" \
      || -e "$newline_repo_bin/vaultlock-test.sh" \
      || -L "$newline_repo_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

tab_repo=$test_root/$'tab\trepository'
tab_repo_bin=$test_root/tab-repo-bin
create_one_commit_fixture "$tab_repo"
tab_repo_output=''
if tab_repo_output=$(run_installer_direct \
    "$tab_repo" "$tab_repo_bin" 2>&1); then
  printf 'FAIL repository root with a tab was accepted\n'
  fail=1
else
  printf 'ok   repository root with a tab is refused\n'
fi
check_contains 'tab repository root reports the pathname byte policy' \
  'repository root must contain only printable ASCII bytes' "$tab_repo_output"
check 'tab repository root is unchanged before refusal' false \
  "$([[ -e "$tab_repo_bin/vaultlock" || -L "$tab_repo_bin/vaultlock" \
      || -e "$tab_repo_bin/vaultlock-test.sh" \
      || -L "$tab_repo_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

empty_home_bin=$test_root/empty-home-bin
if VAULTLOCK_INSTALL_REPO_ROOT="$fixture_repo" \
    VAULTLOCK_INSTALL_BIN_DIR="$empty_home_bin" \
    VAULTLOCK_INSTALL_BIN_DIR_MODE=default-home \
    VAULTLOCK_INSTALL_HOME='' \
    "$fixture_repo/scripts/install.sh" >/dev/null 2>&1; then
  printf 'FAIL omitted BIN_DIR with empty HOME was accepted\n'
  fail=1
else
  printf 'ok   omitted BIN_DIR with empty HOME is refused\n'
fi
check 'empty HOME refusal creates no command target' false \
  "$([[ -e "$empty_home_bin/vaultlock" \
      || -L "$empty_home_bin/vaultlock" ]] && printf true || printf false)"
check 'empty HOME refusal creates no helper target' false \
  "$([[ -e "$empty_home_bin/vaultlock-test.sh" \
      || -L "$empty_home_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

unset_home_bin=$test_root/unset-home-bin
if /usr/bin/env -u HOME -u VAULTLOCK_INSTALL_HOME \
    VAULTLOCK_INSTALL_REPO_ROOT="$fixture_repo" \
    VAULTLOCK_INSTALL_BIN_DIR="$unset_home_bin" \
    VAULTLOCK_INSTALL_BIN_DIR_MODE=default-home \
    "$fixture_repo/scripts/install.sh" >/dev/null 2>&1; then
  printf 'FAIL omitted BIN_DIR with unset HOME was accepted\n'
  fail=1
else
  printf 'ok   omitted BIN_DIR with unset HOME is refused\n'
fi
check 'unset HOME refusal creates no command target' false \
  "$([[ -e "$unset_home_bin/vaultlock" \
      || -L "$unset_home_bin/vaultlock" ]] && printf true || printf false)"
check 'unset HOME refusal creates no helper target' false \
  "$([[ -e "$unset_home_bin/vaultlock-test.sh" \
      || -L "$unset_home_bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

one_commit_bin_repo=$test_root/one-commit-bin
create_one_commit_fixture "$one_commit_bin_repo"
one_commit_source=$one_commit_bin_repo/bin/vaultlock
one_commit_identity=$(regular_identity "$one_commit_source")
one_commit_content=$(< "$one_commit_source")
if run_install_in "$one_commit_bin_repo" "$one_commit_bin_repo/bin" \
    >/dev/null 2>&1; then
  printf 'FAIL BIN_DIR equal to repository bin was accepted\n'
  fail=1
else
  printf 'ok   BIN_DIR equal to repository bin is refused\n'
fi
check_file 'repository bin source is preserved' \
  "$one_commit_source" "$one_commit_content"
check 'repository bin source identity is preserved' "$one_commit_identity" \
  "$(regular_identity "$one_commit_source")"
check 'repository bin refusal installs no helper link' false \
  "$([[ -e "$one_commit_bin_repo/bin/vaultlock-test.sh" \
      || -L "$one_commit_bin_repo/bin/vaultlock-test.sh" ]] \
    && printf true || printf false)"

one_commit_tests_repo=$test_root/one-commit-tests
create_one_commit_fixture "$one_commit_tests_repo"
one_commit_source=$one_commit_tests_repo/tests/vaultlock-test.sh
one_commit_identity=$(regular_identity "$one_commit_source")
one_commit_content=$(< "$one_commit_source")
if run_install_in "$one_commit_tests_repo" "$one_commit_tests_repo/tests" \
    >/dev/null 2>&1; then
  printf 'FAIL BIN_DIR equal to repository tests was accepted\n'
  fail=1
else
  printf 'ok   BIN_DIR equal to repository tests is refused\n'
fi
check_file 'repository test source is preserved' \
  "$one_commit_source" "$one_commit_content"
check 'repository test source identity is preserved' "$one_commit_identity" \
  "$(regular_identity "$one_commit_source")"
check 'repository tests refusal installs no command link' false \
  "$([[ -e "$one_commit_tests_repo/tests/vaultlock" \
      || -L "$one_commit_tests_repo/tests/vaultlock" ]] \
    && printf true || printf false)"

one_commit_alias_repo=$test_root/one-commit-alias
create_one_commit_fixture "$one_commit_alias_repo"
/bin/ln -s "$one_commit_alias_repo" "$test_root/repository-alias"
one_commit_source=$one_commit_alias_repo/bin/vaultlock
one_commit_identity=$(regular_identity "$one_commit_source")
one_commit_content=$(< "$one_commit_source")
if run_install_in "$one_commit_alias_repo" \
    "$test_root/repository-alias/bin" >/dev/null 2>&1; then
  printf 'FAIL physical BIN_DIR alias to repository bin was accepted\n'
  fail=1
else
  printf 'ok   physical BIN_DIR alias to repository bin is refused\n'
fi
check_file 'physical BIN_DIR alias preserves repository source' \
  "$one_commit_source" "$one_commit_content"
check 'physical BIN_DIR alias preserves source identity' "$one_commit_identity" \
  "$(regular_identity "$one_commit_source")"

one_commit_parent_repo=$test_root/one-commit-parent
create_one_commit_fixture "$one_commit_parent_repo"
one_commit_source=$one_commit_parent_repo/bin/vaultlock
one_commit_content=$(< "$one_commit_source")
if run_install_in "$one_commit_parent_repo" \
    "$one_commit_parent_repo/missing/../bin" >/dev/null 2>&1; then
  printf 'FAIL lexical parent BIN_DIR alias to repository bin was accepted\n'
  fail=1
else
  printf 'ok   lexical parent BIN_DIR alias to repository bin is refused\n'
fi
check_file 'lexical parent BIN_DIR alias preserves repository source' \
  "$one_commit_source" "$one_commit_content"
check 'lexical parent BIN_DIR alias creates no directory' false \
  "$([[ -e "$one_commit_parent_repo/missing" \
      || -L "$one_commit_parent_repo/missing" ]] \
    && printf true || printf false)"

one_commit_dot_repo=$test_root/one-commit-dot
create_one_commit_fixture "$one_commit_dot_repo"
one_commit_source=$one_commit_dot_repo/bin/vaultlock
one_commit_content=$(< "$one_commit_source")
if run_install_in "$one_commit_dot_repo" "$one_commit_dot_repo/./bin" \
    >/dev/null 2>&1; then
  printf 'FAIL lexical dot BIN_DIR alias to repository bin was accepted\n'
  fail=1
else
  printf 'ok   lexical dot BIN_DIR alias to repository bin is refused\n'
fi
check_file 'lexical dot BIN_DIR alias preserves repository source' \
  "$one_commit_source" "$one_commit_content"

bin_dir=$test_root/install-bin
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh

reset_bin_dir
stage_failure_marker=$test_root/stage-failure-marker
if run_install_with_transition fail-stage "$stage_failure_marker" \
    >/dev/null 2>&1; then
  printf 'FAIL staging failure transition was ignored\n'
  fail=1
else
  printf 'ok   staging failure stops installation\n'
fi
if [[ -f "$stage_failure_marker" ]]; then
  failed_stage=$(< "$stage_failure_marker")
  check 'failed stage is removed by owned cleanup' false \
    "$([[ -e "$failed_stage" || -L "$failed_stage" ]] \
      && printf true || printf false)"
else
  printf 'FAIL staging failure transition did not run\n'
  fail=1
fi
check 'staging failure changes no target' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" \
      || -e "$test_target" || -L "$test_target" ]] \
    && printf true || printf false)"

reset_bin_dir
run_install >/dev/null
source_drift_marker=$test_root/source-drift-marker
first_inode=$(/usr/bin/stat -f '%i' "$vaultlock_target")
if run_install_with_transition drift-source "$source_drift_marker" \
    >/dev/null 2>&1; then
  printf 'FAIL source drift transition was ignored\n'
  fail=1
else
  printf 'ok   source drift before replacement stops installation\n'
fi
check 'source drift transition executed' true \
  "$([[ -e "$source_drift_marker" ]] && printf true || printf false)"
check 'source drift preserves installed target identity' "$first_inode" \
  "$(/usr/bin/stat -f '%i' "$vaultlock_target")"
if [[ -e "$vaultlock_source.before-drift" ]]; then
  /bin/rm "$vaultlock_source"
  /bin/mv "$vaultlock_source.before-drift" "$vaultlock_source"
fi

first_inode=$(/usr/bin/stat -f '%i' "$vaultlock_target")
run_install >/dev/null
second_inode=$(/usr/bin/stat -f '%i' "$vaultlock_target")
if [[ "$first_inode" != "$second_inode" ]]; then
  printf 'ok   existing exact project symlink is refreshed\n'
else
  printf 'FAIL existing exact project symlink was not refreshed\n'
  fail=1
fi

reset_bin_dir
for source in bin/vaultlock tests/vaultlock-test.sh; do
  name=${source##*/}
  first_commit=$(/usr/bin/git -C "$fixture_repo" log --diff-filter=A \
    --format=%H -- "$source" | /usr/bin/tail -n 1)
  /usr/bin/git -C "$fixture_repo" show "$first_commit:$source" \
    > "$bin_dir/$name"
done
run_install >/dev/null
check_link 'byte-identical imported vaultlock baseline may be replaced' \
  "$vaultlock_target" "$vaultlock_source"
check_link 'byte-identical imported test baseline may be replaced' \
  "$test_target" "$test_source"

reset_bin_dir
printf 'locally modified vaultlock\n' > "$vaultlock_target"
printf 'safe second target\n' > "$test_target"
modified_output=''
if modified_output=$(run_install 2>&1); then
  printf 'FAIL modified regular target was accepted\n'
  fail=1
else
  printf 'ok   modified regular target is refused\n'
fi
check_file 'modified regular target is preserved' \
  "$vaultlock_target" 'locally modified vaultlock'
check_file 'refusal preserves the other regular target' \
  "$test_target" 'safe second target'
check_contains 'modified target diagnostic names target' \
  "refusing modified target: $vaultlock_target" "$modified_output"

reset_bin_dir
/bin/ln -s "$test_root/unexpected-vaultlock" "$vaultlock_target"
unexpected_link=$(/usr/bin/readlink "$vaultlock_target")
if run_install >/dev/null 2>&1; then
  printf 'FAIL unexpected symlink was accepted\n'
  fail=1
else
  printf 'ok   unexpected symlink is refused\n'
fi
check_link 'unexpected dangling symlink is preserved' \
  "$vaultlock_target" "$unexpected_link"
check 'unsafe symlink leaves second target missing' false \
  "$([[ -e "$test_target" || -L "$test_target" ]] && printf true || printf false)"
check_no_residue 'symlink refusal leaves no staging residue'

reset_bin_dir
/bin/ln -s '../repository/bin/vaultlock' "$vaultlock_target"
relative_link=$(/usr/bin/readlink "$vaultlock_target")
relative_referent=$(cd "$bin_dir/../repository/bin" && pwd)/vaultlock
check 'relative-link fixture resolves to the project source' \
  "$vaultlock_source" "$relative_referent"
if run_install >/dev/null 2>&1; then
  printf 'FAIL equivalent relative project symlink was accepted\n'
  fail=1
else
  printf 'ok   equivalent relative project symlink is refused\n'
fi
check_link 'equivalent relative project symlink is preserved' \
  "$vaultlock_target" "$relative_link"

reset_bin_dir
/bin/ln -s "$test_source" "$vaultlock_target"
unexpected_link=$(/usr/bin/readlink "$vaultlock_target")
if run_install >/dev/null 2>&1; then
  printf 'FAIL unexpected non-dangling symlink was accepted\n'
  fail=1
else
  printf 'ok   unexpected non-dangling symlink is refused\n'
fi
check_link 'unexpected non-dangling symlink is preserved' \
  "$vaultlock_target" "$unexpected_link"

reset_bin_dir
/bin/mkdir "$vaultlock_target"
if run_install >/dev/null 2>&1; then
  printf 'FAIL directory target was accepted\n'
  fail=1
else
  printf 'ok   directory target is refused\n'
fi
check 'directory target is preserved' true \
  "$([[ -d "$vaultlock_target" && ! -L "$vaultlock_target" ]] \
    && printf true || printf false)"

reset_bin_dir
/usr/bin/mkfifo "$vaultlock_target"
fifo_output=$test_root/fifo-output
run_install > "$fifo_output" 2>&1 &
fifo_pid=$!
fifo_finished=false
for ((attempt=0; attempt<100; attempt++)); do
  if ! /bin/kill -0 "$fifo_pid" 2>/dev/null; then
    fifo_finished=true
    break
  fi
  /bin/sleep 0.02
done
if [[ "$fifo_finished" == "false" ]]; then
  /usr/bin/pkill -TERM -P "$fifo_pid" 2>/dev/null || true
  /bin/kill "$fifo_pid" 2>/dev/null || true
  wait "$fifo_pid" 2>/dev/null || true
  printf 'FAIL FIFO target made install block\n'
  fail=1
else
  if wait "$fifo_pid"; then
    printf 'FAIL FIFO target was accepted\n'
    fail=1
  else
    printf 'ok   FIFO target is refused without reading it\n'
  fi
fi
check 'FIFO target is preserved' true \
  "$([[ -p "$vaultlock_target" ]] && printf true || printf false)"

reset_bin_dir
printf 'unsafe second target\n' > "$test_target"
if run_install >/dev/null 2>&1; then
  printf 'FAIL unsafe second target was accepted\n'
  fail=1
else
  printf 'ok   unsafe second target is refused\n'
fi
check 'unsafe second target does not partially install first target' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
check_file 'unsafe second target is preserved' \
  "$test_target" 'unsafe second target'

reset_bin_dir
/bin/ln -s "$vaultlock_source" "$vaultlock_target"
first_inode=$(/usr/bin/stat -f '%i' "$vaultlock_target")
printf 'unsafe second target\n' > "$test_target"
run_install >/dev/null 2>&1 || true
check_link 'unsafe second target preserves exact first project link' \
  "$vaultlock_target" "$vaultlock_source"
check 'unsafe second target does not refresh exact first project link' \
  "$first_inode" "$(/usr/bin/stat -f '%i' "$vaultlock_target")"

reset_bin_dir
first_commit=$(/usr/bin/git -C "$fixture_repo" log --diff-filter=A \
  --format=%H -- bin/vaultlock | /usr/bin/tail -n 1)
/usr/bin/git -C "$fixture_repo" show "$first_commit:bin/vaultlock" \
  > "$vaultlock_target"
first_inode=$(/usr/bin/stat -f '%i' "$vaultlock_target")
first_content=$(< "$vaultlock_target")
printf 'unsafe second target\n' > "$test_target"
run_install >/dev/null 2>&1 || true
check_file 'unsafe second target preserves first baseline regular file' \
  "$vaultlock_target" "$first_content"
check 'unsafe second target does not replace first baseline regular file' \
  "$first_inode" "$(/usr/bin/stat -f '%i' "$vaultlock_target")"

reset_bin_dir
/bin/ln -s "$vaultlock_source" "$vaultlock_target"
run_install >/dev/null
check_link 'rerun converges after an interrupted partial install' \
  "$vaultlock_target" "$vaultlock_source"
check_link 'rerun installs the target missing after interruption' \
  "$test_target" "$test_source"
check_no_residue 'interrupted-state rerun leaves no staging residue'

reset_bin_dir
/bin/rm "$vaultlock_source"
if run_install >/dev/null 2>&1; then
  printf 'FAIL missing repository source was accepted\n'
  fail=1
else
  printf 'ok   missing repository source is refused\n'
fi
check 'missing source causes no destination mutation' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
restore_fixture_source bin/vaultlock

reset_bin_dir
/bin/mv "$vaultlock_source" "$vaultlock_source.real"
/bin/ln -s "$vaultlock_source.real" "$vaultlock_source"
if run_install >/dev/null 2>&1; then
  printf 'FAIL symlinked repository source was accepted\n'
  fail=1
else
  printf 'ok   symlinked repository source is refused\n'
fi
check 'symlinked source causes no destination mutation' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
/bin/rm "$vaultlock_source"
/bin/mv "$vaultlock_source.real" "$vaultlock_source"

reset_bin_dir
/bin/chmod -x "$vaultlock_source"
if run_install >/dev/null 2>&1; then
  printf 'FAIL non-executable repository source was accepted\n'
  fail=1
else
  printf 'ok   non-executable repository source is refused\n'
fi
check 'non-executable source causes no destination mutation' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
/bin/chmod +x "$vaultlock_source"

reset_bin_dir
/bin/chmod 000 "$vaultlock_source"
if run_install >/dev/null 2>&1; then
  printf 'FAIL unreadable repository source was accepted\n'
  fail=1
else
  printf 'ok   unreadable repository source is refused\n'
fi
check 'unreadable source causes no destination mutation' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
/bin/chmod +rx "$vaultlock_source"

reset_bin_dir
/bin/mv "$vaultlock_source" "$vaultlock_source.real"
/bin/mkdir "$vaultlock_source"
if run_install >/dev/null 2>&1; then
  printf 'FAIL directory repository source was accepted\n'
  fail=1
else
  printf 'ok   directory repository source is refused\n'
fi
check 'directory source causes no destination mutation' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
/bin/rmdir "$vaultlock_source"
/bin/mv "$vaultlock_source.real" "$vaultlock_source"

reset_bin_dir
/bin/mv "$fixture_repo/.git" "$fixture_repo/.git.hidden"
if run_install >/dev/null 2>&1; then
  printf 'FAIL missing imported baseline history was accepted\n'
  fail=1
else
  printf 'ok   missing imported baseline history fails closed\n'
fi
check 'baseline lookup failure causes no destination mutation' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
/bin/mv "$fixture_repo/.git.hidden" "$fixture_repo/.git"

reset_bin_dir
printf '#!/bin/bash\nexit 9\n' > "$fixture_repo/tests/vaultlock-test.sh"
/bin/chmod +x "$fixture_repo/tests/vaultlock-test.sh"
if run_install >/dev/null 2>&1; then
  printf 'FAIL install continued after make check failure\n'
  fail=1
else
  printf 'ok   make install stops when make check fails\n'
fi
check 'failed make check leaves first target missing' false \
  "$([[ -e "$vaultlock_target" || -L "$vaultlock_target" ]] && printf true || printf false)"
check 'failed make check leaves second target missing' false \
  "$([[ -e "$test_target" || -L "$test_target" ]] && printf true || printf false)"
check_no_residue 'failed make check leaves no staging residue'

exit "$fail"
