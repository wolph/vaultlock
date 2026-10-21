The two ciphertext fixtures contain `vaultlock tle compatibility fixture`,
without a trailing newline. They were generated with the released `tle` v1.2.0
binary using Quicknet round 1 and its `--force` option. One uses binary age
encoding and the other uses `--armor`.

The tests decrypt them against a recorded, cryptographically verified Quicknet
round 1 beacon. Normal tests need no network access or installed `tle` binary.
Set `VAULTLOCK_LIVE_DRAND=1` to run the optional live network smoke test.
