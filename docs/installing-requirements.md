# Installing the requirements

The Bash command in `bin/vaultlock` needs three tools that macOS doesn't ship
on every version: `tle` from drand's tlock project, `jq`, and `curl`. Run the
installer once and it reports what it found and what it installed:

```console
scripts/install-deps.sh
```

Read back line by line:

- `tle: /Users/wolph/bin/tle` means the installer downloaded the pinned
  tlock release for your architecture, checked its SHA-256 against the
  `checksums.txt` file of the same release, and installed the binary into
  `~/bin`. Vaultlock looks for `tle` on `PATH`, in `~/bin`, and in `~/go/bin`.
- `jq: /usr/bin/jq (already installed)` is what macOS 15 and later report,
  because Apple bundles `jq` there. Older systems get `brew install jq`, and
  without Homebrew the installer says so and exits 1 after installing `tle`.
- `curl: /usr/bin/curl` is bundled with every supported macOS version.

Preview the plan without downloading or installing anything:

```console
scripts/install-deps.sh --dry-run
```

Install `tle` somewhere other than `~/bin`:

```console
scripts/install-deps.sh --bin-dir "$HOME/.local/bin"
```

> [!NOTE]
> The installer pins tlock 1.2.0 (released 2024-08-21). Set
> `VAULTLOCK_DEPS_TLE_VERSION` to install another release. It verifies the
> archive against the checksum list that drand publishes next to it, so a
> tampered download fails with `checksum mismatch` and nothing is installed.

## Manual installation

Without the script, the same result takes three steps:

1. Download `tlock_1.2.0_darwin_arm64.tar.gz` (or `darwin_amd64` on Intel)
   and `checksums.txt` from
   https://github.com/drand/tlock/releases/tag/v1.2.0.
2. Check the archive with `shasum -a 256 -c checksums.txt --ignore-missing`,
   then extract `tle` into `~/bin` and make it executable.
3. Install `jq` with `brew install jq` on macOS 14 or older. macOS 15 and
   later already have `/usr/bin/jq`.

The test suite for the installer lives in `tests/install-deps-test.sh`. It
replaces the network with a fixture that serves a locally built release
archive, so it runs offline.
