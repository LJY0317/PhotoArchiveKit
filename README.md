# PhotoArchiveKit

[![CI](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml/badge.svg)](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PhotoArchiveKit is a local-first macOS toolkit for safely reconciling iPhone, Mac, Google Photos, and external-drive photo copies while preserving Live Photos as complete logical assets.

The project is intentionally small and session-based. It does not run a background daemon, own media through an opaque storage format, or treat a cloud provider as the permanent source of truth.

## Core promises

1. **Agent-private by design.** The local process may read media and compute metadata/hashes, but normal AI-agent workflows use `--agent-json`, which omits media bytes, previews, filenames, paths, exact byte sizes, capture timestamps, raw hashes, Live Photo identifiers, GPS, and other file-level private details.
2. **Live Photos are atomic.** A validated still + paired video is treated as one asset for copy, move, rename, quarantine, archive, deletion, and future provider projection. One-sided mutation is rejected.
3. **Media stays ordinary and recoverable.** Files remain normal HEIC/JPEG/MOV/MP4 files on the filesystem. SQLite stores relationships, provenance, collections, root roles, and operation state that folders alone cannot express.
4. **Exact duplicate is not perceptual similarity.** Byte-identical redundancy can become an automatic candidate after local verification. Similar/best-shot candidates remain human-reviewed.
5. **Mutation is explicit and reversible.** Scan/plan paths are read-only by default. Cleanup uses Trash or an explicitly configured quarantine; permanent deletion is not implemented.

## Current status

Implemented today:

- multi-root recursive scanning with local SQLite catalog;
- embedded-identifier Live Photo pairing plus strict QuickTime `still-image-time` validation;
- stable opaque logical/resource/duplicate IDs;
- current-state exact duplicate grouping and cross-root archive coverage;
- simple comparison-location purposes: default, long-term archive, or read-only; source/import provenance is tracked internally;
- deterministic preferred-representation planning with Live Photo safety gates;
- native SwiftUI duplicate-review GUI and Finder-oriented review workspace;
- reversible duplicate cleanup to macOS Trash or app-managed quarantine;
- verified `restore-quarantine`;
- deterministic camera-name organization and verified empty-directory cleanup;
- stable `.photoarchive-root` identity for root relocation and mutation boundaries;
- user-managed HDD archive indexing without reorganizing the user's folders;
- Mac-local incremental metadata/hash cache plus removable-root portable hash inventory;
- portable catalog JSONL export/restore;
- immutable archive plans and resumable verified archive copies;
- agent-safe JSON reports that exclude file-level private details;
- structured foreground scan progress without a resident watcher.

Not complete or intentionally deferred:

- permanent deletion;
- independent off-site replica verification / rclone workflow;
- general perceptual/best-shot automation;
- cloud upload/projection;
- always-on filesystem monitoring;
- general gallery/search/OCR/face-recognition features.

## Recommended workflow

PhotoArchiveKit separates local observation, human decisions, and mutation.

1. Register or scan the roots that should participate: Mac library, Takeout/import folders, external archive roots, or read-only references.
2. Use `scan`, `archive-coverage`, and `plan` to understand current state without modifying media.
3. Review exact duplicates in the native app or generated local review workspace.
4. Apply only reviewed/automatic exact cleanup through a reversible destination.
5. If an external HDD is manually organized in Finder, run `archive-index` afterward so the catalog reflects its current hierarchy.
6. For programmatic archive copies, create an immutable `archive-plan`, preflight it with `archive-copy`, then use `--apply` only after the current root/byte checks pass.

An unavailable drive is never interpreted as evidence that its media was deleted.

## Build

Requirements:

- macOS 14 or later
- Swift 6 toolchain
- no required third-party executable

```bash
swift build
swift run photoarchive doctor
swift run photoarchive-selftest
```

Launch the native review app:

```bash
"$HOME/LJY Projects/PhotoArchiveKit/scripts/run-app.sh"
```

## Basic scanning

```bash
swift run photoarchive scan --inbox "~/Photo Inbox"
```

Multiple roots can be scanned together:

```bash
swift run photoarchive scan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --archive "/Volumes/Photo Archive/Photos"
```

Registered nested roots belong to the most specific root, preventing a nested Takeout/import tree from being counted again through its parent.

For human-local diagnostics:

```bash
swift run photoarchive scan --json --inbox "~/Photo Inbox"
```

For AI-agent workflows:

```bash
swift run photoarchive scan --agent-json --inbox "~/Photo Inbox"
```

`--json` may contain local paths and filenames. `--agent-json` is the privacy-minimized interface.

## Root registry and purposes

The native app exposes only three purposes: **Default** for normal comparison and cleanup, **Long-term Archive** when that location's copy should be preferred for retention, and **Read-only** when files may be compared but never moved or deleted. Provider/import provenance such as Google Takeout is detected and kept internally rather than requested from the user.

Examples:

```bash
swift run photoarchive root add "~/Pictures"
swift run photoarchive root init --apply "/Volumes/My HDD/My Photos"
```

Changing a purpose changes policy only; it does not itself move or delete media.

## Exact duplicate review and cleanup

Generate a read-only preferred-representation plan:

```bash
swift run photoarchive plan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

The native duplicate-review app shows physical copies or Live Photo occurrences as aligned comparison columns. User-facing metadata stays compact; deeper local metadata can be expanded as advanced information. Selection is reversible and is not itself mutation authority. A single bulk action can select every recommended cleanup copy across the current comparison, and the same control clears those selections. The comparison-folder popover uses standard multi-select checkboxes, allows an empty selection, and shows the simple folder purpose as secondary information. **Folder Details** handles purpose changes and unregistering; purpose choices expose short hover help. Adding an already registered folder is a no-op and does not rescan it. Newly selected, unscanned folders surface a prominent **Scan Selected Folders** action, while the ordinary refresh button only reloads recent review results without rereading media.

Launch or refresh the GUI with `scripts/run-app.sh`. It rebuilds the single local `.build/PhotoArchiveKit.app`, closes an older running review process, and opens the newly built app instead of keeping versioned app copies.

The Finder-oriented review workspace is also available:

```bash
swift run photoarchive duplicate-review \
  --output "~/Desktop/PhotoArchiveKit-Duplicate-Review" \
  --candidate-root "~/Pictures"
```

Preview reversible cleanup:

```bash
swift run photoarchive quarantine \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

Only after reviewing the dry run should `--apply` be used. Before a candidate moves, PhotoArchiveKit re-checks current root/path boundaries, regular-file state, expected size, exact bytes, keeper evidence, and complete Live Photo resource sets.

The default destination is macOS Trash. A custom app-managed quarantine can be configured when a restore manifest is preferred:

```bash
swift run photoarchive settings deletion-destination trash
swift run photoarchive settings deletion-destination quarantine "/path/to/quarantine"
```

Restore is also dry-run by default and freshly verifies quarantined bytes:

```bash
swift run photoarchive restore-quarantine --agent-json "/path/to/session/manifest.json"
# add --apply only after the preflight succeeds
```

Cleanup may remove only the source parent chain made empty by that same operation, stopping before the registered root and preserving package/symlink/unknown-content boundaries.

## Organization

PhotoArchiveKit can propose deterministic camera-name cleanup without touching custom filenames:

```bash
swift run photoarchive organize-plan --agent-json --local "~/Pictures"
```

`organize --apply` requires a stable root marker. Validated Live Photo still/video resources move atomically under one destination basename, and catalog commit failure rolls filesystem moves back.

For clean singleton leaf folders, `--singleton-leaf-only` can narrow the scope. `cleanup-empty-dirs` is limited to source directories proven by a completed organization manifest and does not sweep unrelated empty folders.

## User-managed HDD archives

PhotoArchiveKit does not require its own generated folder layout. Existing hand-organized HDD trees can remain exactly as they are.

Initialize the photo root once, then index it:

```bash
swift run photoarchive root init --apply "/Volumes/My HDD/My Photos"
swift run photoarchive archive-index --agent-json "/Volumes/My HDD/My Photos"
```

The default index updates the Mac-local SQLite catalog without moving/re-writing media. `archive-index --apply` additionally writes a hidden root-scoped `.photoarchive/inventory-v1.jsonl` containing relative structure and integrity/cache evidence. That inventory is **local-private** and not safe to send to an AI agent.

`archive-index --fresh` bypasses local and portable caches and re-reads media bytes when a full integrity audit is desired.

Current cross-root coverage can be recomputed explicitly:

```bash
swift run photoarchive archive-coverage --agent-json \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --archive "/Volumes/My HDD/My Photos"
```

Coverage reports exact resource preservation and Live Photo counterpart completeness separately. File-level exact overlap alone does not authorize cleanup.

## Portable catalog recovery

The authoritative working catalog stays on the Mac, normally at:

```text
~/Library/Application Support/PhotoArchiveKit/catalog.sqlite3
```

It is private local state and may contain paths and raw local integrity values.

Export a portable semantic snapshot:

```bash
swift run photoarchive catalog export \
  --output "/path/to/photoarchive-catalog.jsonl"
```

Restore validates first and refuses to overwrite an existing catalog:

```bash
swift run photoarchive catalog restore \
  --to "/path/to/restored-catalog.sqlite3" \
  --bind-root ROOT_ID="/path/to/current/root" \
  "/path/to/photoarchive-catalog.jsonl"
# add --apply only after the dry run succeeds
```

The JSONL snapshot deliberately omits reproducible raw caches such as exact hashes and absolute machine paths, but it still contains relative paths/filenames and collection semantics needed for recovery. It is therefore **local-private, not agent-safe/share-safe**.

## Immutable archive copy

Create a local-private immutable archive plan:

```bash
swift run photoarchive archive-plan \
  --to "/Volumes/Photo Archive" \
  --output "~/Library/Application Support/PhotoArchiveKit/archive-plan.json" \
  --agent-json \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

The persisted plan contains local replay preconditions such as source/destination identity and expected exact bytes, so the plan file itself is not agent-safe.

Preflight it again at the copy boundary:

```bash
swift run photoarchive archive-copy --agent-json \
  "~/Library/Application Support/PhotoArchiveKit/archive-plan.json"
```

Only after successful preflight:

```bash
swift run photoarchive archive-copy --apply --agent-json \
  "~/Library/Application Support/PhotoArchiveKit/archive-plan.json"
```

AUTO items are copied through hidden staging, fully hashed before and after finalization, and complete Live Photo resources are handled as one item. Re-running an interrupted operation reuses already verified staging/final files. Source media is never moved or deleted by `archive-copy`.

Large real-HDD archive applications should still be expanded in bounded logical-item batches rather than treating an old plan as permanent authority.

## Ingest observations

A disposable five-path fixture showed:

| Path | Observed result |
| --- | --- |
| macOS Image Capture | complete archival HEIC + MOV resources |
| iPhone AirDrop with **All Photos Data** | byte-identical to Image Capture for tested resources |
| ordinary Photos AirDrop | still images preserved, tested Live Photo motion resources absent |
| Google Photos web download | tested resources byte-identical to Image Capture, sometimes with different extension |
| Google Photos iOS app AirDrop | transformed standalone JPG/MP4 rather than archival Live Photo resource pairs |

These are observations from the tested fixture, not permanent guarantees about future Apple/Google behavior. Image Capture is the current baseline ingest path when preserving the original Live Photo resources matters.

## Privacy and security boundary

The core currently makes no network request. Cloud/provider integrations, when added, must be separate opt-in adapters.

Never publish or attach personal media, catalog databases, provider exports/sidecars, credentials, raw hashes, Live Photo identifiers, GPS, private paths, or unsanitized diagnostic output to an issue or support request. Prefer a synthetic reproduction.

High-priority security bugs include:

- path traversal outside configured roots;
- unintended symlink following;
- unavailable roots interpreted as deletion;
- one-sided Live Photo mutation;
- stale-plan mutation after source bytes change;
- partial commit/corruption after interruption;
- private file-level data leaking through the agent-safe interface;
- command injection through optional subprocess adapters.

If GitHub private vulnerability reporting is enabled, use **Security → Report a vulnerability**. Otherwise open only a minimal public issue without sensitive details and request a private contact path.

## Optional interoperability

The required core does not bundle third-party executables. Optional adapters may use software the user installs and licenses separately:

- `rclone` — file replica and verification workflows;
- Czkawka / Krokiet — duplicate/similarity candidate generation;
- ExifTool — broad metadata diagnostics;
- `ffprobe` — optional video diagnostics;
- osxphotos — possible Apple Photos query/export interoperability when it is preferable to custom code.

External tools never own PhotoArchiveKit's semantic truth, Live Photo atomicity, keeper policy, or mutation authority.

## Development

Before submitting a meaningful change, run:

```bash
swift build
swift run photoarchive-selftest
bash scripts/check-public-tree.sh
git diff --check
```

For duplicate-review scrolling/layout changes also run:

```bash
bash scripts/test-review-scroll.sh
```

Keep changes small, preserve existing user data and behavior unless intentionally changed, and prefer synthetic/public fixtures over personal media.

Git history is the change log; this repository does not maintain a duplicate hand-written changelog or detailed roadmap document.

## License

PhotoArchiveKit is licensed under the [MIT License](LICENSE).
