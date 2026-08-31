# Changelog

## Unreleased

### Added

- Repository workflow with `make test`, `make check`, and guarded `make install`.
- Dry-run plans for init, adopt, lock, and unlock.
- Confirmation for init, adopt, and lock, with `--yes` for non-interactive use.
- Elapsed durations such as `1d4h` and `20h`, plus calendar clock offsets such
  as `2:00 +2d`.
- Global and vault-local lifecycle hooks with a stable 24-word named argv
  contract and `--no-hooks` bypass.
- Status output that separates recorded JSON state from actual APFS state.

### Changed

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
