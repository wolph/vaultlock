#!/bin/bash
# Isolated guarded-install tests. All targets live under a temporary directory.
set -euo pipefail

if [[ "${VAULTLOCK_INSTALL_TEST_NESTED:-0}" == "1" ]]; then
  exit 0
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
makefile=$repo_root/Makefile
fail=0

if [[ ! -f "$makefile" ]]; then
  printf 'FAIL guarded install requires %s\n' "$makefile"
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

check_installer_hardening_structure() {
  local register_line chmod_line source_identity_count
  # shellcheck disable=SC2016  # These are literal Make recipe fragments.
  register_line=$(/usr/bin/grep -nF \
    'stage_directories[$$index]=$$stage' "$makefile" \
    | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
  # shellcheck disable=SC2016  # These are literal Make recipe fragments.
  chmod_line=$(/usr/bin/grep -nF '/bin/chmod 700 "$$stage"' "$makefile" \
    | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
  check 'staging directory is registered before chmod can fail' true \
    "$([[ -n "$register_line" && -n "$chmod_line" \
      && "$register_line" -lt "$chmod_line" ]] && printf true || printf false)"

  source_identity_count=$(/usr/bin/grep -cF 'source_identities' "$makefile" \
    || true)
  check 'installer freezes and finally revalidates source identity' true \
    "$([[ "$source_identity_count" -ge 3 ]] && printf true || printf false)"
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
  /bin/chmod +x "$fixture_repo/bin/vaultlock" \
    "$fixture_repo/tests/vaultlock-test.sh" \
    "$fixture_repo/tests/vaultlock-cli-test.sh"
}

run_install() {
  VAULTLOCK_INSTALL_TEST_NESTED=1 \
    /usr/bin/make -s -C "$fixture_repo" install BIN_DIR="$bin_dir"
}

check_installer_hardening_structure

/bin/mkdir -p "$fixture_repo/bin" "$fixture_repo/tests"
/bin/cp "$makefile" "$fixture_repo/Makefile"
/bin/cp "$0" "$fixture_repo/tests/install-test.sh"
/bin/chmod +x "$fixture_repo/tests/install-test.sh"
write_fixture_sources baseline

/usr/bin/git -C "$fixture_repo" init -q -b master 2>/dev/null \
  || /usr/bin/git -C "$fixture_repo" init -q
/usr/bin/git -C "$fixture_repo" config user.name 'Vaultlock install test'
/usr/bin/git -C "$fixture_repo" config user.email 'vaultlock-install@example.invalid'
/usr/bin/git -C "$fixture_repo" add Makefile bin tests
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

bin_dir=$test_root/install-bin
vaultlock_target=$bin_dir/vaultlock
test_target=$bin_dir/vaultlock-test.sh

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
