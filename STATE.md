# Current State

Last updated: 2026-09-04

## Repository

- GitHub repository: `LJY0317/PhotoArchiveKit`
- Primary local checkout: `~/LJY Projects/PhotoArchiveKit`
- License: MIT
- Primary documentation language: English
- Korean counterpart: `README.ko.md`

## Implemented

The repository contains an initial local-first Swift package with:

- `PhotoArchiveCore` library;
- `photoarchive` CLI;
- `photoarchive-selftest` synthetic validation executable;
- local SQLite catalog;
- multiple configurable scan roots;
- ImageIO still-image metadata probe;
- AVFoundation QuickTime metadata probe;
- Live Photo grouping from embedded identifiers;
- catalog-local HMAC protection for Live Photo identifiers;
- per-root Live Photo completeness reporting;
- local exact duplicate grouping with opaque report IDs;
- timezone-aware capture-time model;
- time-gap event folder suggestions;
- human-readable and sanitized JSON output;
- optional tool detection without required third-party binaries;
- English and Korean project overviews;
- dated Google Photos and Apple PhotoKit capability documentation;
- validation and optional-integration documentation;
- issue forms, pull-request template, CI, and public-tree privacy safeguards;
- an automatic-first, event-level organization policy informed by existing archive folders.

Current commands:

```bash
swift run photoarchive doctor
swift run photoarchive scan [options] ROOT...
swift run photoarchive-selftest
```

The scanner is read-only with respect to media. It writes only the explicitly selected SQLite catalog.

## Product decisions

- The portable filesystem archive stores media truth.
- SQLite stores semantic truth and provider-neutral desired organization.
- Manual work should scale with ambiguous event groups, not individual photos.
- Existing archive folders become training examples for future local classification.
- Google Photos flat upload of eligible ordinary media is a useful future capability even without album projection.
- A validated Live Photo must not be uploaded as unrelated still/video items and reported as preserved.
- Apple PhotoKit is the preferred future projection path for Live Photo creation and editable album membership.
- Optional rclone, Czkawka CLI, ExifTool, and ffprobe adapters remain separate from the required core.

## Validation

Completed locally:

- `swift build` passes.
- `swift run photoarchive-selftest` passes.
- `scripts/check-public-tree.sh` passes.
- The self-test scans two synthetic exact copies twice and verifies:
  - one opaque duplicate group;
  - one logical standalone asset;
  - stable opaque group ID across scans;
  - unchanged input bytes;
  - no raw known hash in serialized report.
- A disposable five-source iPhone/Google fixture scan produced the expected:
  - 29 media resources;
  - 8 logical assets;
  - 3 logical Live Photos;
  - 7 exact duplicate resource groups;
  - 3 still-only warnings for ordinary AirDrop;
  - no media modifications.
- The fixture was re-scanned after correcting the Google web comparison path. Every tested Google Photos web resource was byte-identical to its Image Capture counterpart, even when a motion resource used an `.MP4` filename instead of `.MOV`.

The private fixture and temporary catalog are not part of the repository.

## Known limitations

- No archive copy, rename, move, quarantine, deletion, or cloud upload command.
- No strict parsing of Live Photo timed `still-image-time` metadata yet.
- Still-side identifier extraction is isolated but currently follows the observed ImageIO MakerApple entry used by current iPhone files; additional format fixtures are needed.
- Source-root identity currently follows the canonical path; moving an Inbox or archive root creates a new root record until stable movable IDs and root markers are implemented.
- No versioned JSONL catalog export/restore yet.
- No incremental metadata/hash cache optimization beyond SQLite persistence.
- Event grouping is time-based only; archive-guided semantic folder prediction is planned.
- Repeated copies of one Live Photo identifier inside the same source root are currently summarized as one ambiguous occurrence; occurrence partitioning for duplicated export folders is pending.
- Standalone exact copies collapse to one logical asset only when exact-duplicate hashing is enabled; stable identity across scan modes is pending.
- No PhotoKit, Google Photos, Takeout, rclone, Czkawka, ExifTool, or ffprobe execution adapter yet.
- Google Photos public API cannot be treated as a full existing-library reconciliation interface.
- Google Photos public upload documentation does not currently provide a verified composite Live Photo creation route for the project.
- The dependency-free `photoarchive-selftest` is the required local regression check; broader public media fixtures are still needed for normal unit/integration CI coverage.

## Safety state

- No permanent deletion exists.
- No background process exists.
- No network request exists in the core.
- Reports do not include raw hashes or raw Live Photo identifiers.
- Raw Live Photo identifiers are cleared from in-memory probe records immediately after a catalog-local keyed fingerprint is created.
- Private media extensions and runtime databases are ignored by Git.
- Future mutating commands must add and verify archive-root markers before interpreting missing paths.

## Next concrete work

1. Add stable movable root IDs and archive-root markers without changing media.
2. Add strict Live Photo timed-metadata validation.
3. Add versioned sanitized JSONL catalog export and restore.
4. Define canonical capture-time and reversible rename-plan rules.
5. Add event-level archive-folder learning using existing folders as examples.
6. Add an immutable, read-only `plan` command before any apply implementation.
7. Validate a small Google Takeout fixture before writing a Takeout parser.
8. Design the Google flat-upload adapter around immutable queues, partial-success recovery, and explicit Live Photo blocking.

## Resume point

Before changing behavior:

```bash
git status --short --branch
swift build
swift run photoarchive-selftest
```

Then inspect this file and `MILESTONES.md` to avoid repeating the private ingest validation.
