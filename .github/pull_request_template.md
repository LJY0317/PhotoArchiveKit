## Problem

Describe the archive workflow or safety issue this change addresses.

## Behavior

Describe the smallest user-visible change.

## Safety and privacy

- [ ] Media remains read-only unless this PR explicitly introduces a reviewed plan/apply boundary.
- [ ] Live Photo resources remain atomic.
- [ ] Raw hashes, identifiers, GPS, frames, embeddings, and credentials do not appear in normal reports.
- [ ] No personal media, Takeout export, catalog, token, or private absolute path is included.
- [ ] Optional dependency and license impact is documented.

## Validation

```text
swift build
swift run photoarchive-selftest
bash scripts/check-public-tree.sh
```

Add any disposable-fixture or provider validation performed.

## Documentation

- [ ] README.md / README.ko.md updated when user-visible behavior changed.
- [ ] STATE.md updated when current behavior or the next milestone changed.
- [ ] MILESTONES.md updated only for expensive reusable validation.
- [ ] CHANGELOG.md updated for a notable change.
