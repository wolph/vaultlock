# Vaultlock

[![CI](https://github.com/wolph/vaultlock/actions/workflows/ci.yml/badge.svg)](https://github.com/wolph/vaultlock/actions/workflows/ci.yml)

Vaultlock seals a folder on your Mac until a date you choose. Until that date
arrives it does not open. Not for you, not for root, not for a machine with its
clock wound forward.

Screen-time limits and website blockers share one weakness. The person they
restrict is the person who can switch them off, which is fine for a nudge and
useless for a commitment. Vaultlock removes the option instead of asking you
not to take it.

![Four panel comic. Panel one, 8:00 AM: a person works at a laptop while a games console sits on a shelf under a sign reading TIME LOCK, active until 6:00 PM. Panel two: they grin and spin the dial of a bank vault holding the console, its display reading LOCKOUT, 10 hours. Panel three, 1:00 PM: they are on their knees clawing at the sealed vault door, which reports 5 hours remaining. Panel four, 6:00 PM: the vault swings open, the console tumbles into their arms, and the laptop behind them shows a finished task.](https://raw.githubusercontent.com/wolph/vaultlock/master/assets/vaultlock-comic.jpg)

## Why a time lock

I wrote this because I get distracted easily. When I need to work I lock my
games away, and the entire point is that I cannot unlock them at hour two when
the work turns boring.

The enforcement is not a preference you can revisit. Locking rotates the APFS
passphrase, destroys the plaintext copy and the Keychain entry, and leaves the
new passphrase only as a ciphertext encrypted against a future round of the
drand randomness beacon. The signature for that round does not exist yet. Nobody
can publish it ahead of schedule, so nobody can decrypt the passphrase ahead of
schedule, and your local clock has no vote.

Three limits worth knowing before you trust it with something you care about:

- Unlocking fetches the beacon over the network. An offline laptop stays locked.
- A lock that completed is a lock that is sealed. A lock that failed partway can
  retain staged recovery material, which Vaultlock reports rather than quietly
  deleting. See [Failure and recovery boundaries](#failure-and-recovery-boundaries).
- Backups sit outside the lock. A Time Machine copy taken before you locked
  still holds the data.

## Use cases

### Seal a distraction until the work is done

`adopt` moves a directory onto the vault and leaves a symlink in its place, so
paths that pointed at it keep working while the vault is mounted. Move the games
across once, then lock until the morning two weeks out:

```console
vaultlock adopt ~/Games
vaultlock lock -v --dry-run "9:00 +14d"
vaultlock lock "9:00 +14d"
```

The dry run earns its line. It resolves the deadline to an exact local timestamp
and prints the drand round it would encrypt against, while changing nothing, so
you learn what `9:00 +14d` actually means before it is true for a fortnight.
After the real lock, `~/Games` is a dangling symlink and the bytes behind it need
a passphrase that no longer exists in plaintext anywhere.

### Put a waiting period in front of an irreversible act

Some decisions only look good for one afternoon. Sealing the credentials makes
the impulse outlive a delay before it can act:

```console
vaultlock adopt ~/keys/trading
vaultlock lock 72h
```

For three days those keys stop being a question of willpower, because they are
not reachable. `vaultlock status` reports the deadline and remaining time.
Add `-v` for the target and current drand rounds. The vault stays locked until
the target round lands.

Choose the number while the impulse is absent. `20h` is a deadline you will
still be living with at hour 19.

## How it works

Vaultlock time-locks an encrypted APFS volume against a future drand round.
At lock time it rotates the APFS passphrase, encrypts the new passphrase with
the embedded `drand/tlock` library, verifies the recovery artefacts, removes
plaintext recovery material, and locks the volume. At unlock time it recovers the passphrase after the
deadline and converges the volume to a mounted, usable state.

## Requirements

The installed command is a standalone Go binary for macOS and APFS. It includes
its Go libraries and needs no separately installed `tle`, `jq`, `curl`, OpenSSL,
Homebrew packages, or Go runtime.

Storage operations use `diskutil`, `security`, `tmutil`, `sudo`, and `ditto`,
which macOS supplies. Locking and unlocking need internet access to Quicknet.
Administrator access is required for the privileged APFS and Time Machine
operations. User hooks can have requirements of their own.

## Installation

Build and install from a checkout with Go 1.25 or newer:

```console
make install
```

This runs the Go tests, vet, formatting check, and a build with CGO disabled,
then copies the executable to `~/bin/vaultlock`. The installed executable is
independent of the checkout. Choose another destination with `BIN_DIR`:

```console
make install BIN_DIR="$HOME/.local/bin"
```

The installer accepts a missing target, an existing Vaultlock Go binary, or an
absolute symlink naming this checkout's `bin/vaultlock`. That recognised legacy
symlink is replaced by the Go binary. The Bash source and its local edits stay
in the checkout. Relative, unexpected, or dangling symlinks, unrelated files,
and special files are refused. The installer stages the executable in the destination directory.
It creates a missing target without overwriting a newly appeared file, or
replaces an existing binary with a rename after checking the target again.

You can also use the usual Go installation command from the checkout:

```console
go install ./cmd/vaultlock
```

That uses Go's installation directory and replacement rules. Go is needed to
build from source, but people receiving a compiled executable only need the
binary. CI builds and uploads archives for Intel and Apple Silicon, with
checksums and executable permissions preserved. Extract the matching archive
and place `vaultlock` in a directory on your `PATH`.

Build without the checks, then inspect the command:

```console
make build
./build/vaultlock --help
./build/vaultlock --version
```

Every build also installs the fresh executable to `BIN_DIR`, so the command on
your `PATH` never lags behind the checkout.

`make dist` builds an archive and checksum in `build/` for distribution.

The defaults and their environment overrides are:

| Setting | Default | Override |
| --- | --- | --- |
| State directory | `~/.vaultlock` | `VAULTLOCK_STATE_DIR` |
| Volume name | `vault` | `VAULTLOCK_VOLUME` |
| APFS container | `disk3` | `VAULTLOCK_CONTAINER` |
| Mount point | `/Volumes/vault` | `VAULTLOCK_MOUNT_POINT` |
| Confirmation terminal | `/dev/tty` | `VAULTLOCK_CONFIRM_DEVICE` |

The Keychain service is `vaultlock-<volume>`. Check your container before `init`.
`disk3` is a default, not automatic device discovery. Start with `--dry-run`.

## Commands

```console
vaultlock status
vaultlock init --dry-run
vaultlock init --yes
vaultlock adopt --dry-run "$HOME/path/to/data"
vaultlock adopt --yes "$HOME/path/to/data"
vaultlock lock -vv --dry-run 20h
vaultlock lock --yes 20h
vaultlock unlock --dry-run
vaultlock unlock
```

Options precede operands. `-v` and `-vv` select increasing detail.
`--color=auto|always|never` controls colour.
`--progress=auto|always|never` controls progress for all commands.
`--no-hooks` skips hooks for `lock` and `unlock`.

`init`, `adopt`, and `lock` require confirmation on the controlling terminal
unless `--yes` is supplied. `unlock` does not prompt. `--dry-run` inspects the
vault without changing APFS, files, Keychain, Time Machine configuration, or the
operation lock, and never runs hooks.

### Progress while waiting

Every lengthy step reports what it is doing, including inspection, directory
scans, hashing, copying, metadata restoration, verification passes, recovery
writes, Keychain access, APFS operations, snapshot cleanup, hooks, and beacon
requests. A timer refreshes the display independently of work callbacks, so a
large file or a system command that produces no output still shows activity.

Terminals show a live progress indicator. Work with known totals includes
completed and total bytes and entries, percentage, throughput, elapsed time,
and an estimated remaining time. Hashing advances while each file is read.
Repeated verification identifies the current pass. Work without a measurable
total shows the current operation and elapsed time without inventing a
percentage or completion estimate.

The default `auto` mode refreshes terminal activity every 200 milliseconds.
Subprocess progress that uses carriage returns shares the live display, so a
hook's progress bar and vaultlock's activity indicator update in place. Ordinary
log lines and errors remain visible above the display.

When progress output is redirected to a file or pipe, `auto` records phase
summaries instead of animation frames. Repeated subprocess progress is reduced
to its initial and final snapshots. `--progress=always` also writes periodic activity snapshots to redirected
output. `--progress=never` disables vaultlock's activity indicator. Progress goes
to standard error. Confirmation and administrator password prompts remain
readable.

Colour separates the active phase and counters in cyan, transfer speed and
completed work in green, waiting estimates and confirmation prompts in yellow,
and errors in red. Paths and elapsed time use less emphasis. The palette uses
your terminal's standard colours and keeps the same layout at narrow widths.
`--color=never`, `NO_COLOR` (including an empty value), and `TERM=dumb` disable
automatic colour. Each output stream detects its own terminal. Redirected output
stays plain unless you request `--color=always`, which overrides those settings.

An installation still pointing at the Bash source can report
`malformed operation lock owner` when it encounters the Go version's kernel
lock file. Run `make install` to migrate the recognised repository symlink and
check `vaultlock --version`. The Go command uses the existing lock file.

### Deadlines

All four deadline forms remain available:

| Form | Example | Meaning |
| --- | --- | --- |
| Duration | `1d4h30m`, `20h`, `90s` | Elapsed time from now |
| Clock | `09:00` | Next occurrence of that local clock time |
| Clock and days | `09:00 +2d` | That local time two calendar days from today |
| Date and clock | `2027-01-02 09:00` | An exact local date and minute |

Quote deadlines containing spaces, or pass their words separately. Local clock
forms use the system timezone. Duration days are always 86,400 seconds, while
calendar days can span a daylight-saving change. Explicit local times that do
not exist are rejected. Clock-only deadlines select the next real occurrence,
including the second occurrence of a repeated local time.

The encryption round is the first Quicknet round scheduled at or after the
deadline. A lock that is already securely sealed keeps its recorded deadline.

## State and recovery

The Go command reads the existing state directory and file names:

```text
state.json
passphrase.txt
passphrase.sha256
passphrase.tle
```

The JSON fields and unknown additional fields are preserved. Binary and armoured
ciphertexts produced by `tle` on Quicknet remain readable. The chain hash,
public key, and signature scheme are pinned. Beacon signatures are verified in
process, and the local clock alone cannot make decryption succeed.

Protected state files require the current user as owner, mode `0600`, no ACL,
and a single hard link. The state directory requires mode `0700` and no ACL.
Symlinked protected files are refused. Writes use private staging files, file
synchronisation, rename, and directory synchronisation.

A normal lock excludes the protected state directory and vault from Time
Machine, deletes vault snapshots, unmounts the vault, and stages a new random
passphrase before rotating APFS. It stores and verifies the time-lock
ciphertext, hash, and locked state before removing plaintext and Keychain
recovery. Data-volume snapshot cleanup then precedes the APFS lock and its
postcondition checks.

A failed rotation or encryption can leave protected recovery material, including
`passphrase-new.txt`. Keep those files until the failure has been inspected.
The command reports failure and retains recovery instead of describing a
partial transition as a sealed vault. A failed data-volume snapshot cleanup
still allows APFS sealing, then reports the cleanup failure.

Before the future key is available, the encrypted recipient and file structure
can be checked, but their final authentication requires decryption. A network
failure cannot satisfy the future-round check. A valid earlier signed beacon
and an unavailable target beacon are required.

`status` is observational and exits successfully even when it reports
`INCONSISTENT`. It compares recorded state with actual APFS state and recovery
file presence. `-v` adds the observations and drand rounds. It does not repair
the vault or establish that recovery-file contents are valid.

`unlock` can repair an unlocked record whose APFS volume is locked or unmounted,
using verified recovery material. A recorded-locked recovery decrypts through
the embedded library, checks the hash, and converges APFS to the expected mounted
volume. Invalid or missing recovery material fails closed.

Mutating commands take an exclusive lock at `~/.vaultlock-operation.lock`.
The Go version keeps a protected file there and holds a kernel file lock while
running. Process exit releases the kernel lock. An old Bash lock directory is
refused, so inspect any older operation before removing its stale directory.
Do not run the Bash and Go implementations concurrently during migration.

## Directory adoption

`adopt` requires the verified vault to be unlocked and mounted at the configured
path. It refuses the filesystem root, home directory, reserved control paths,
and sources overlapping the vault or state directory. A destination that is a
file or symlink, including a dangling symlink, is refused. An existing real
directory can be reused after two complete verification passes establish that
its contents, metadata and hardlinks match the source. Confirmation and the
source replacement transaction recheck both trees. A reused copy is not copied
again. During an unfinished adoption, the source remains authoritative. If the
trees differ, adoption reports the differences and builds a separate replacement
inside a private directory on the vault. Equal file contents are reused with
native APFS clones where available. Other files are copied from the source.
Hardlinks, symlinks and metadata follow the source. Clone progress counts logical
bytes reused, alongside bytes copied from the source.

The existing destination stays intact while the replacement is built and
verified. After confirmation and verification of all three trees, the previous
destination moves into `.vaultlock-adopt-backup-*/original` on the vault and the
replacement takes its place. The backup is retained and its path is printed,
including on later failures. No destination-only data is discarded. A failed
replacement leaves the source intact and reports any retained staging directory.

macOS `ditto` copies the tree. Native Go traversal checks file contents,
permissions, ownership, flags, timestamps, ACLs, extended attributes, symlink
targets, and internal hard-link relationships. Unsupported entries, nested
filesystems, external hard links, and unstable trees are refused. Copy and
verification progress stay separate from the transaction's success or failure.

Literal `._` files remain files. Copying disables `ditto`'s automatic resource
handling, which otherwise consumes those names. Native Go code then restores
the captured extended attributes, including resource forks and Finder metadata,
ACLs and timestamps before verifying the complete copy.

Files owned by your user can still belong to a group you cannot assign, such as
`wheel`. If macOS refuses that group change, adoption uses its native `sudo` and
`chown` with existing administrator authorisation. The privileged command receives
the already opened descriptor and numeric IDs. It does not resolve a path in the
copied tree. Without authorisation, adoption stops with the source intact and
reports how to authorise a retry. Group ownership is never silently changed.
Symlink group changes use a detached helper session because macOS rejects their
descriptors during `sudo` terminal setup. That session may not share credentials
cached by `sudo -v` in your terminal. If authorisation fails, the source remains
intact and the error identifies this restriction.

macOS manages `com.apple.provenance` and can rewrite its bytes on a copy, even
after a successful native attribute write. Adoption excludes only that attribute
from cross-copy equality. Before copying or replacing either tree, it saves the
captured original metadata and SHA-256 hashes in private, synchronised
`.vaultlock-adopt-metadata-*` directories on the vault. The archive retains the
original provenance bytes. Quarantine, access-control attributes, resource forks
and all other captured attributes still require exact equality.

Verification reuses a SHA-256 result within the current command only when the
file identity and complete native metadata, including change time, remain
unchanged before and after the check. Removing an original file always reads and
hashes its contents again immediately before unlinking it.

After verification, the original is renamed into a private sibling directory
and its path is replaced by a symlink to the verified copy. Failures before
original-data removal attempt rollback. Once removal starts, a failure retains
the remaining original entries and reports the verified copy's location.
After a successful adoption, the original source data is gone and its path is a
symlink. Reads and writes through that path use the vault copy.

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

The phase order is unchanged:

1. pre-lock: legacy global script, global directory, vault-local directory
2. post-lock: global directory
3. pre-unlock: global directory
4. post-unlock: vault-local directory, global directory

Directories run non-hidden executable regular files and executable symlinks to
regular files, in bytewise filename order. Missing directories and
non-executable entries are ignored. Hook identity and executable state are
checked before execution. Vault-local hooks require the verified mount.

Each hook receives these 24 argv words:

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

The scope is `global` or `vault`. The locked value is `false` for `pre-lock`
and `post-unlock`, and `true` for `post-lock` and `pre-unlock`. Missing deadline
values are the literal string `null`. Secret-like exported variables are removed
from child environments. Recovery secrets never appear in hook argv. Hooks are
trusted user programs. Interactive hooks use a private controlling terminal on
macOS. Terminal input and visible output are forwarded, while terminal queries
are kept out of the user's terminal and log files.

A failed pre-hook stops the transition. Failed post-hooks allow remaining
post-hooks to run, then return failure. `--no-hooks` skips all hooks.

Every successful `unlock` runs the post-unlock hooks, including when the vault
is already unlocked and mounted. Run `unlock` again to retry a failed service
start. Write these hooks so that running them again is safe. Use `--no-hooks`
to check and repair the unlocked vault without starting its services.

## Development

```console
make check
make test
go test -race ./...
```

Tests use temporary directories and simulated APFS, Keychain, and Time Machine
operations. Native adoption tests use temporary trees and the macOS copy tool.
They do not initialise, rotate, lock, or unlock a real APFS volume.

The optional live crypto test contacts Quicknet without touching a vault:

```console
VAULTLOCK_LIVE_DRAND=1 go test -v ./internal/timelock
```

The previous Bash implementation and its shell regression tests remain in
`bin/`, `scripts/`, and `tests/` while existing work is preserved. The Go build,
installation, and CI use `cmd/` and `internal/`.
