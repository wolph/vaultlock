# Changelog

## Unreleased

### Added

- Repository workflow with `make test`, `make check`, and guarded `make install`.
- GitHub Actions checks on macOS 15 and 26 for Intel and Apple Silicon.
- A bounded `make check-ci` gate with CLI smoke coverage. The complete
  regressions remain available through `make check` and required by installation.
- Dry-run plans for init, adopt, lock, and unlock.
- Confirmation for init, adopt, and lock, with `--yes` for non-interactive use.
- Elapsed durations such as `1d4h`, `20h`, and `90s`, plus calendar clock
  offsets such as `2:00 +2d`.
- Global and vault-local lifecycle hooks with a stable 24-word named argv
  `make build` installs the fresh executable to `BIN_DIR` as its last step.
  contract and `--no-hooks` bypass.
- Status output that separates recorded JSON state from actual APFS state.
- Compact status with `-v` and `-vv` options for technical observations.
- Absolute local deadlines with remaining days, hours, minutes, or seconds.

### Changed

- Reimplemented the installed command in Go with embedded drand/tlock. The
  standalone binary needs no external tle, jq, curl, or Go installation.
- Adoption can resume with source changes taking precedence, verified copies,
  retained destination backups, and guarded removal of the original data.
- Handle encrypted APFS volumes that lock automatically on unmount by loading
  their keys without mounting before passphrase rotation.
- Run post-unlock hooks after verified convergence even when the vault is
  already unlocked, so failed service starts can be retried.
- Share one terminal display between vault activity and subprocess progress.
  Redirected output keeps compact summaries. Private hook terminals prevent
  colour queries from corrupting visible output while preserving input.
- Build and test native Go binaries in CI on Intel and Apple Silicon macOS,
  including race detection and executable archives with SHA-256 checksums.
- Added bold headings, aligned fields, and coloured status words throughout
  the CLI. Short progress groups now appear by default, with detailed `-v`
  descriptions and complete `-vv` audit plans. Hook paths remain visible.
- `unlock` on a locked vault prints the recorded deadline as a local timestamp
  with the remaining time before contacting drand, and an early attempt fails
  with "still locked until <timestamp> (in <remaining>)" as the bash version
  did. Other recovery failures carry the deadline and the underlying cause.
- Migrated the standalone command and helper suite into a complete local Git
  project.
- Lock and unlock now converge repairable observations to verified target
  states instead of trusting only the recorded `locked` flag.
- Unlock is nonprompting and repairs supported locked or unmounted usable-state
  drift.
- Lock preserves an existing secure deadline instead of silently replacing it.

### Security

- Added cooperative cross-command locking, typed plan revalidation, identity
  checks, private staging, stale-lock quarantine, and signal-safe cleanup.
- Hardened init, adopt, lock, and unlock transactions to retain and classify
  recovery artifacts when safe cleanup cannot be proven.
- Removed secret-bearing process arguments from Keychain and APFS recovery
  operations.
- Guarded installation validates all sources, imported baselines, and targets
  before either installed link can change.
