# Vaultlock

Vaultlock time-locks an encrypted APFS volume against a future drand round.
At lock time it rotates the APFS passphrase, encrypts the new passphrase with
`tle`, verifies the recovery artifacts, removes plaintext recovery material,
and locks the volume. At unlock time it recovers the passphrase after the
deadline and converges the volume to a mounted, usable state.

The defaults are:

- State directory: `~/.vaultlock`
- Volume name: `vault`
- APFS container: `disk3`
- Mount point: `/Volumes/vault`
- Keychain service: `vaultlock-vault`

Review those defaults in `bin/vaultlock` before `init`. Creating or adopting a
vault changes storage state. Start with `--dry-run`.

## Requirements

Vaultlock targets macOS and APFS. The executable remains compatible with the
system Bash 3.2. Normal use requires:

- macOS tools including `diskutil`, `plutil`, `security`, `tmutil`, and `lsof`
- `tle` on `PATH`, in `~/bin`, or in `~/go/bin`
- `jq`
- `curl` and internet access to the Quicknet drand service
- administrator access for the `sudo tmutil` operations used while locking

Development checks also require Git, GNU Make, and ShellCheck. Run the complete
gate before installation:

```console
make check
```

The gate runs the helper, isolated CLI, and guarded-install suites. It also
runs Bash syntax checks and ShellCheck. The suites use temporary fixtures and
do not perform a real APFS lifecycle operation.

## Installation

Install the command and its original helper suite into `~/bin`:

```console
make install
```

Choose another destination with `BIN_DIR`:

```console
make install BIN_DIR="$HOME/.local/bin"
```

`make install` runs `make check` first. It validates both repository sources,
both imported baseline blobs, and both destination paths before creating the
destination directory or replacing either target. It accepts only:

- a missing target
- an absolute symlink whose raw link text already names this repository source
- a regular file byte-identical to that source's first imported Git blob

It refuses modified files, relative or unexpected symlinks, dangling symlinks,
directories, devices, sockets, and FIFOs. Each accepted target is replaced by
an absolute repository symlink through a private staged link and verified
afterward.

The two final replacements are separate filesystem operations, not one atomic
pair. An interruption can leave the first link installed and the second target
unchanged. Rerunning `make install` converges that safe partial state.

The installer revalidates each source, destination, and staged link immediately
before its rename. It cannot make the final pathname check and rename atomic
against a hostile process already running as the same macOS user. Such a
process can swap a pathname in that interval.

## Commands

Inspect the current observations before changing anything:

```console
vaultlock status
```

Create the configured APFS volume:

```console
vaultlock init --dry-run
vaultlock init --yes
```

Move an existing directory onto the mounted vault and replace the original
path with a symlink:

```console
vaultlock adopt --dry-run "$HOME/path/to/data"
vaultlock adopt --yes "$HOME/path/to/data"
```

Preview and perform a lock:

```console
vaultlock lock -v --dry-run 20h
vaultlock lock -vv --color=always --dry-run 2:00 +2d
vaultlock lock --yes 20h
```

Unlock after the deadline, or repair a recorded-unlocked volume that is locked
or unmounted:

```console
vaultlock unlock --dry-run
vaultlock unlock
```

The complete command forms are:

```text
vaultlock init [-v | -vv] [--color=auto|always|never] [--dry-run] [--yes]
vaultlock adopt [-v | -vv] [--color=auto|always|never] [--dry-run] [--yes] <directory>
vaultlock lock [-v | -vv] [--color=auto|always|never] [--dry-run] [--yes] [--no-hooks] <deadline>
vaultlock unlock [-v | -vv] [--color=auto|always|never] [--dry-run] [--no-hooks]
vaultlock status [--color=auto|always|never]
```

Options must appear immediately after the subcommand and before the first
operand. `lock` joins its remaining words into one deadline expression, so
both quoted and unquoted `2:00 +2d` forms work.

| Option | `init` | `adopt` | `lock` | `unlock` | `status` | Effect |
|---|---:|---:|---:|---:|---:|---|
| `-v`, `--verbose` | yes | yes | yes | yes | no | Add grouped progress |
| `-vv`, `--very-verbose` | yes | yes | yes | yes | no | Add grouped progress and the complete numbered plan |
| `--color=auto|always|never` | yes | yes | yes | yes | yes | Select terminal colour handling |
| `--dry-run` | yes | yes | yes | yes | no | Inspect the planned outcome without making changes |
| `--yes` | yes | yes | yes | no | no | Bypass confirmation only |
| `--no-hooks` | no | no | yes | yes | no | Disable all lifecycle hooks |

Repeated verbosity options select the highest requested level regardless of
order. Repeated colour options use the last value. `status` accepts colour
selection, but rejects `-v`, `-vv`, and their long forms because it has no
operation plan or progress stream. The colour value must use the inline form,
such as `--color=never`.

Unknown options, options after an operand, missing required operands, and extra
fixed-arity operands are usage errors. `lock` instead joins every remaining
word. Extra words usually make its deadline invalid during preflight rather
than producing a usage error. `--yes --dry-run` is accepted and still changes
nothing.

## Output modes and colour

| Mode | Output |
| --- | --- |
| default | Current state, target, request details, hooks, confirmation, warnings, and result |
| `-v`, `--verbose` | Default output plus grouped execution progress, or `Would:` groups in a dry-run |
| `-vv`, `--very-verbose` | Verbose output plus the complete numbered operation plan and exact planned hook argv |

Default lifecycle output is concise. It identifies the command, current state,
target, resolved request details, known hook scripts, deferred hook
directories, confirmation when required, warnings, and the final result. It
does not print an `Actions:` section or hook argv. A dry-run lock can resemble:

```text
Lock vault
  State: unlocked and mounted at /Volumes/vault
  Target: locked at the resolved deadline
  Requested deadline: 2026-09-02T02:00:00+0200
  Resolved drand round: target 31805812

Hooks:
  pre-lock [global] /Users/example/Vault\ Hooks/pre-lock.sh

Result: no changes made
```

Hook paths and deferred directories use shell-safe quoting. `after mount`
marks a vault-local directory whose entries cannot be inspected until the
expected volume is mounted and its identity is verified. A hook found then is
also reported by phase, scope, and path. A summary containing both forms can
include:

```text
Hooks:
  pre-lock [global] /Users/example/Vault\ Hooks/pre-lock.sh
  pre-lock [vault, after mount] /Volumes/vault/.vaultlock/hooks/pre-lock.d
```

`Hooks: disabled` records `--no-hooks`. `Hooks: none` records that no known or
deferred hooks apply. Exact hook argv appears only in very verbose output.

Verbose mode prints each meaningful progress group once across the command.
Execution uses `->` prefixes. Dry-run uses `Would:` prefixes and never claims
that an operation ran. Hook runs remain individual progress entries rather
than being combined into one group.

Colour mode defaults to `--color=auto`. Automatic mode decides separately for
stdout and stderr. A stream receives colour only when it is a TTY, `TERM` is
not `dumb`, and `NO_COLOR` is unset or empty. `--color=always` and
`--color=never` explicitly override terminal and environment detection. Colour
styles labels and prefixes only. Paths, UUIDs, devices, deadlines, rounds,
operation descriptions, and hook argv remain plain, so colour never carries
meaning by itself.

## Deadlines

Absolute, clock, and calendar-offset deadlines must resolve to a future local
minute. A duration resolves to a future instant by adding elapsed seconds.

| Form | Meaning | Example |
|---|---|---|
| `YYYY-MM-DD HH:MM` | Exact future local date and time | `2026-09-02 14:30` |
| `H:MM` or `HH:MM` | First future occurrence of that local clock time | `1:00` |
| `[Nd][Nh][Nm]` | Positive elapsed duration in day, hour, minute order | `1d4h`, `20h` |
| `H:MM +Nd` | That local clock time a positive N calendar days from today | `2:00 +2d` |

An elapsed `d` is 86,400 seconds, so a duration need not land on a local minute.
The `+Nd` form advances the local calendar date instead. A bare clock skips a
daylight-saving gap by moving to its next valid occurrence. It can select the
second repeated occurrence during a fall-back transition. Absolute and `+Nd`
forms reject nonexistent local minutes and choose the first repeated
occurrence.

For a two-day calendar offset, these are equivalent:

```console
vaultlock lock --dry-run 2:00 +2d
vaultlock lock --dry-run "2:00 +2d"
```

Locking an already securely locked vault preserves its existing deadline and
round. It does not extend the lock with the newly supplied expression.

## Plans, confirmation, and dry-run

Every lifecycle command builds a complete typed plan from the recorded and
actual APFS observations, requested target, resolved deadline, hooks, and
ordered mutations. Default output renders the concise state, target, request,
and hook summary. Very verbose output renders the complete numbered `Actions:`
list and exact planned hook argv.

`init`, `adopt`, and `lock` prompt on the controlling terminal with
`Confirmation required. Continue? [y/N] `. Only `y` or `yes`, ignoring case,
proceeds. Non-interactive execution without `--dry-run` must pass `--yes`.
That option suppresses the confirmation boilerplate only. It does not bypass
preflight, identity, recovery, or postcondition checks.

`unlock` never prompts because its target is a usable mounted vault.

`--dry-run` performs read-only preflight without running hooks or changing
APFS, files, Keychain, Time Machine configuration, or the cooperative operation
lock. It never prompts. Its output follows the selected output mode, and a
successful preview ends with:

```text
Result: no changes made
```

The complete typed plan includes discoverable hook paths, hook bypass state,
and coordination steps. At `-vv`, known hooks also include each hook's named
argv. If the verified vault is not mounted, vault-local hook discovery is
shown as deferred. Dry-run never mounts the volume just to discover hooks.

A preview is a snapshot, not a promise that later execution will succeed.
Normal execution acquires the cooperative lock, repeats inspection, rebuilds
the plan, and aborts without domain mutation if a typed field or identity has
changed.

### Very verbose lock plan

`-vv` expands the exact numbered plan for the current command and inspected
state. The conceptual order for a normal transition is:

Typical standard full-lock sequence:

1. Acquire the cooperative operation lock
2. Conditionally quarantine a verified stale operation lock
3. Run each planned pre-lock hook with its exact argv
4. Persistently exclude the protected state directory from Time Machine and verify the exclusion
5. Add the vault volume root to Time Machine exclusions
6. Delete local Time Machine snapshots for the vault
7. Unmount the vault
8. Generate and durably stage a new random recovery passphrase
9. Rotate the APFS volume passphrase, then commit the staged plaintext recovery file
10. Update Keychain with the rotated recovery material
11. Encrypt the rotated recovery material for the resolved drand round
12. Verify the time-lock ciphertext is nonempty and not yet decryptable
13. Write the recovery hash and durably record the locked deadline and round
14. Remove plaintext recovery material and its Keychain entry
15. Delete local Time Machine snapshots for the data volume
16. Lock the APFS volume
17. Verify APFS encryption, locked state, and failed unauthenticated mounting
18. Release the cooperative operation lock

This is a typical sequence, not fixed output. Actual `-vv` items vary with the
inspected state. Known hooks, multiple hooks, post-hooks, repairs, no-ops,
disabled hooks, and deferred hook discovery add, remove, or replace applicable
items. Hooks found through deferred discovery report exact argv at `-vv` when
they run.

## Status and convergence

`status` reports recorded JSON state and actual APFS state separately. It also
shows the expected and actual mount point, recovery-file presence, an
assessment, and the remaining time and drand round for recorded-locked state.

The assessment is one of:

- `usable`: recorded unlocked, APFS unlocked and mounted as expected, with
  plaintext recovery material present
- `securely locked`: recorded locked, APFS locked and unmounted, with
  ciphertext and hash present and plaintext absent
- `repairable: run diskutil mount <device>`: recorded unlocked, APFS unlocked
  but unmounted, and plaintext present
- `repairable: run vaultlock unlock`: recorded unlocked, APFS locked and
  unmounted, with plaintext and hash present
- `inconsistent`: every other combination, including some recorded-locked
  drift that `lock` or a post-deadline `unlock` can still converge safely

`status` is observational. It renders and exits 0 even when state is absent,
invalid, or assessed as inconsistent. It does not repair state, verify
recovery-file contents, or compare a Keychain value.

The `locked` value in `state.json` is not the only source of truth. `lock` and
`unlock` also inspect APFS locked and mounted state, volume UUID, device,
mount identity, recovery artifacts, and hashes before choosing operations.

Important convergence cases include:

- `unlock` mounts an unlocked but unmounted vault.
- `unlock` can use verified local plaintext when JSON says unlocked but APFS
  is locked and unmounted.
- `lock` repairs a recorded-unlocked vault to mounted and usable before the
  requested lock transition.
- A secure recorded-locked state is verified as a no-op and keeps its current
  deadline.
- An unexpectedly unlocked recorded-locked vault fails before the deadline.
  After the deadline, `unlock` resumes only through verified recovery.

Missing, inconsistent, or hash-mismatched recovery material fails closed.
Vaultlock does not guess a passphrase or rewrite state to hide a mismatch.

## Lifecycle hooks

Global hooks live under the state directory:

```text
~/.vaultlock/pre-lock.sh
~/.vaultlock/hooks/pre-lock.d
~/.vaultlock/hooks/post-lock.d
~/.vaultlock/hooks/pre-unlock.d
~/.vaultlock/hooks/post-unlock.d
```

Vault-local hooks live on the mounted filesystem:

```text
/Volumes/vault/.vaultlock/hooks/pre-lock.d
/Volumes/vault/.vaultlock/hooks/post-unlock.d
```

There is no vault-local `post-lock` or `pre-unlock` directory because the
filesystem is unavailable at those points. The phase order is:

1. pre-lock: legacy global script, global directory, vault-local directory
2. post-lock: global directory
3. pre-unlock: global directory
4. post-unlock: vault-local directory, global directory

Directories run non-hidden executable regular files and executable symlinks
that resolve to regular files. Ordering uses C-locale filename order. Missing
directories and non-executable entries are ignored. A hook's path, type,
identity, and executable state are rechecked before execution.

Default output lists every known hook by phase, scope, and safely quoted path.
It lists an unavailable vault-local hook directory with `after mount`. `-v`
keeps those summaries and reports each hook run as an individual progress
entry. It does not print argv. `-vv` adds exact argv for hooks known while
planning and for hooks found through deferred discovery during execution.

Each hook receives exactly these 24 argv words, in this order:

```text
--phase VALUE
--scope VALUE
--volume VALUE
--mount-point VALUE
--volume-uuid VALUE
--device VALUE
--state-dir VALUE
--state-file VALUE
--deadline VALUE
--deadline-epoch VALUE
--round VALUE
--locked VALUE
```

`--scope` is `global` or `vault`. `--locked` is `false` for `pre-lock` and
`post-unlock`, and `true` for `post-lock` and `pre-unlock`. During a
recorded-unlocked APFS-unlock repair, `--deadline`, `--deadline-epoch`, and
`--round` are the literal value `null`.

Passphrases, decrypted recovery values, ciphertext, hashes, and Keychain values
never appear in hook argv. Vaultlock removes exported secret-like variables
before hooks inherit the remaining caller environment, working directory,
stdin, stdout, and stderr. Hooks are trusted user programs and are not
sandboxed.

The first pre-hook process that exits nonzero stops the transition. If a
post-hook process exits nonzero, remaining post-hook processes run before
Vaultlock returns nonzero for the otherwise reached target. Hook path, type,
identity, permission, or mount drift aborts immediately instead of continuing
the phase. `--no-hooks` skips the legacy, global, and vault-local hooks. Concise
output reports `Hooks: disabled`, and `-vv` also adds an explicit disabled-hooks
item to the numbered plan. When hooks are enabled but none are known or
deferred, concise output reports `Hooks: none`.

Pre-unlock hooks run only for recorded-locked recovery. A usable unlock no-op
and an unlock that only mounts an already-unlocked volume do not run lifecycle
hooks. A user `unlock` that actually performs the expected APFS unlock runs
post-unlock hooks after the usable target is verified. Secure lock no-op and
repair paths do not run hooks. If deferred data-volume snapshot cleanup fails,
Vaultlock still locks and verifies APFS but skips the planned post-lock hooks.

## Time Machine behavior

A full lock transition persistently excludes the canonical state directory
with `sudo tmutil addexclusion -p` and verifies the exact exclusion. This asks
for administrator authorization and leaves `STATE_DIR` excluded from Time
Machine after the command. Vaultlock also excludes the mounted vault root and
deletes vault snapshots before unmounting and rotating recovery material.

Data-volume snapshot deletion occurs later, after durable locked state exists
and plaintext and Keychain recovery values are removed. If that cleanup fails,
Vaultlock still attempts the APFS lock and its postconditions, then reports the
deferred failure.

## Failure and recovery boundaries

Recovery state uses these protected files under `~/.vaultlock`:

```text
state.json
passphrase.txt
passphrase.tle
passphrase.sha256
```

The state directory is mode 0700 and protected files are mode 0600, with owner
and ACL checks. Passphrases are sent to `diskutil` and Keychain operations
through protected stdin channels. They are not placed in child process argv,
plans, logs, errors, or hook arguments.

Normal `init`, `adopt`, `lock`, and `unlock` executions cooperate through
`~/.vaultlock-operation.lock`. A live owner causes refusal. Malformed or
ambiguous ownership fails closed. A verified stale lock is moved without
clobber to a retained sibling named
`.vaultlock-operation.lock.quarantine.<token>`. Vaultlock never recursively
deletes a lock or quarantine directory.

The lock serializes Vaultlock processes that follow the protocol. It does not
provide atomic protection against a hostile process already running as the
same macOS user. Such a process can change this script, its input trees, and
its files between a final identity check and a pathname operation. Detected
drift still fails closed within that boundary.

Failures can retain protected evidence instead of guessing ownership or
deleting data:

- Init can retain generated recovery material, staged state, or a
  `.state-quarantine.*` directory.
- Adopt uses sibling `.vaultlock-link`, `.vaultlock-backup`, and
  `.vaultlock-quarantine.*` paths. It rolls back before verified replacement
  and reports any retained verified or unverified path.
- Unlock can retain `.unlock-recovery.*`, `.tle-unlock.*`, or
  `.state-unlock.*` files.
- Lock can retain `passphrase-new.txt`, `.passphrase-lock.*`, `.tle-lock.*`,
  `.hash-lock.*`, `.state-lock.*`, `.tle-verify.*`, or `.security-output.*`
  files. After an attempted APFS passphrase rotation, it reports whether staged
  recovery material was verified.

Unexpected transient paths fail preflight. Retained quarantines and backups
require manual inspection. Vaultlock does not automatically delete them on a
later run.

## Exit behavior

For lifecycle commands, exit 0 means the requested target was verified or a
trustworthy dry-run plan was rendered. `status` renders its observations and
exits 0 even for inconsistent state. Usage errors exit 64. Declined
confirmation, failed preflight, repair failure, hook failure, incomplete
convergence, or a retained operation lock returns nonzero. Errors identify the
failed operation and unmet postcondition without printing recovery material.

This repository does not infer a remote or software license.
