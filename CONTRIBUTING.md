# Contributing

PhotoArchiveKit is intentionally small and safety-first. Contributions should preserve that character.

## Before opening a change

1. Read `AGENTS.md`, `STATE.md`, and the relevant design document.
2. Keep scanned media read-only unless the milestone explicitly introduces a reviewed mutating operation.
3. Reproduce with synthetic data whenever possible.
4. Do not commit real photos, videos, Takeout exports, catalogs, hashes, identifiers, credentials, or personal absolute paths.

## Build and validate

```bash
swift build
swift run photoarchive-selftest
swift run photoarchive doctor
```

The local project currently uses the self-test executable instead of `swift test` because the active command-line toolchain does not expose XCTest or Swift Testing modules.

For scanner changes, also test a disposable directory and verify that input bytes and paths did not change.

## Design rules

- Treat Live Photo resources as one logical asset.
- Pair by embedded linkage, not basename alone.
- Keep raw hashes and media-derived identifiers out of normal reports.
- Separate scan, plan, and apply.
- Do not interpret an unavailable external root as deletion.
- Similarity is a review signal, not deletion authority.
- Keep third-party integrations optional and separately licensed.
- Avoid background services unless a future milestone demonstrates a clear need.

## Documentation

`README.md` is the primary English document and `README.ko.md` is the Korean counterpart. Update both when user-visible commands or guarantees change.

Record only durable current state in `STATE.md`. Add a milestone only when a costly validation result should not be repeated.

## Pull requests

A focused pull request should explain:

- the problem and safety boundary;
- user-visible behavior;
- validation performed;
- privacy implications;
- migration or rollback requirements;
- any optional third-party license impact.
