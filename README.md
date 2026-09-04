# PhotoArchiveKit

[한국어](README.ko.md)

[![CI](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml/badge.svg)](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PhotoArchiveKit is a local-first, session-based toolkit for preserving and organizing iPhone photos, videos, and Live Photos without making a photo-cloud provider the permanent source of truth.

### Core promises

1. **AI agents do not need your personal photo details.** In the normal agent workflow, the local PhotoArchiveKit process reads the files and computes hashes/metadata locally, while the AI agent receives only opaque IDs and minimal semantic state. `--agent-json` deliberately excludes media bytes, thumbnails/frames/audio, filenames, paths, raw hashes, Live Photo identifiers, GPS, MakerNote data, exact byte sizes, capture timestamps, and other file-level private details. This is designed so an AI agent can orchestrate cleanup without those identifying details being sent to the AI service. A general-purpose shell or an explicitly requested local diagnostic can bypass this boundary, so agents should use only the privacy-minimized CLI/API surface.
2. **A Live Photo is one atomic asset.** Its still image and paired video are never treated as unrelated files for copy, move, rename, quarantine, archive, delete, or provider projection. If the complete resource graph cannot be preserved, the operation must expand to the whole asset or stop.
3. **The archive stays human-readable and restorable.** Media remains as ordinary HEIC/JPEG/MOV/MP4 files on HDD/file replicas, while SQLite keeps the provider-neutral relationships, provenance, collections, and decisions needed to reconstruct a Live Photo or project the archive into Apple/Google services later.
4. **Exact duplicates and similar photos are different problems.** Byte-identical redundancy may be automated after local verification; perceptually similar/best-shot candidates remain human-reviewed.

The project is intentionally small. It does not run a background daemon, host a gallery server, or move media behind an opaque storage format. Media remains in ordinary filesystem folders; a local SQLite catalog records relationships and decisions that folders cannot express.

> **Project status:** early safety-first prototype. `scan`, `plan`, and `organize-plan` are read-only. `quarantine` supports reversible exact-duplicate moves, while marker-gated `organize` can dry-run or apply only automatic iPhone-camera rename/flatten items. Permanent deletion, verified HDD archive copy, and cloud upload are not implemented yet.

## Why this exists

The first product value is **agent-private orchestration**; the second is **atomic, restorable Live Photo preservation**. Duplicate reconciliation, preferred representation selection, human-readable folder organization, verified replicas, and provider-neutral migration state build on those two invariants.

A durable photo archive has at least three different kinds of state:

1. Original media bytes.
2. Logical asset relationships, such as the still image and paired video that form one Live Photo.
3. Human or automatic organization, including primary folders and many-to-many album membership.

No current photo-cloud service is a reliable portable container for all three. PhotoArchiveKit therefore treats them separately:

```text
Filesystem archive        SQLite catalog          Provider projections
HEIC/JPEG + MOV/MP4   +   asset relationships  -> Apple Photos / Google Photos
ordinary folders          collections             optional gallery tools
byte-preserving copies    provenance and history
```

The intended long-term model is:

- **Media truth:** normal files on an archive disk plus at least one verified replica.
- **Semantic truth:** a provider-neutral local SQLite catalog.
- **Cloud services:** useful backup, viewing, search, sharing, or projection targets—not permanent identity authorities.

## Current capabilities

The initial CLI can:

- recursively scan one or more Inbox, archive, import, or reference roots;
- identify Live Photo still and video resources from embedded Apple linkage metadata;
- require a paired video with a matching identifier to contain exactly one valid QuickTime `still-image-time` timed-metadata marker before reporting that Live Photo occurrence as complete;
- group copies found in different roots into one logical Live Photo asset and partition repeated same-identifier exports into physical occurrences using directory/basename only as boundary hints after embedded identifier identity is established;
- report completeness separately for every root, so a complete copy elsewhere does not hide a broken local copy;
- find exact duplicate files using local SHA-256 comparisons only when file sizes match;
- expose duplicate groups as stable opaque IDs instead of raw hashes;
- extract timezone-aware EXIF and QuickTime capture times when available;
- suggest date-based event folders by clustering assets separated by a configurable time gap;
- persist resources, logical assets, provenance, duplicate groups, source collection mappings, original filenames, path history, and scan sessions in SQLite;
- keep same-volume resource identity stable across rename/move and recognize a moved source root through an optional `.photoarchive-root` marker;
- generate a read-only `organize-plan` for only `IMG_####` / `IMG_E####` camera-style names, using capture wall-clock names such as `YYYY-MM-DD_HH-mm-ss[_NN]` while preserving custom filenames;
- require a stable root marker before `organize --apply`, keep Live Photo still+video on one destination basename, verify post-move filesystem identity/size, transactionally update the stable resource path/history in SQLite without a second full scan, write a restore manifest, and roll back filesystem moves if catalog commit fails;
- let `cleanup-empty-dirs` consider only source directories proven by a completed organization manifest plus catalog location history, require the stable root marker, skip package/symlink boundaries, and remove only directories that are still literally empty at apply time;
- produce a human-readable report or sanitized JSON;
- detect optional user-installed interoperability tools without requiring or bundling them;
- dry-run or apply a local quarantine of only `automatic_redundant` exact candidates after fresh SHA-256 verification against a preferred copy; Live Photo candidate sets are verified before any resource in the item moves;
- preserve Google Takeout source-folder/album-like memberships in local SQLite before collapsing Takeout-only exact standalone copies, without exposing collection names or paths to agent-safe output;
- write a local restore manifest for applied quarantine sessions, roll back the whole session if a move fails, and dry-run/apply `restore-quarantine` only after the quarantined bytes are freshly re-verified against the local catalog's original SHA-256 evidence;
- perform all current analysis without contacting a network service.

The catalog stores local integrity data, including raw exact-file hashes, because it needs them for reliable comparison. Human diagnostics and AI-agent output are deliberately separated: `--json` may include local paths for troubleshooting, while `--agent-json` omits paths, filenames, byte sizes, capture timestamps, raw hashes, Live Photo identifiers, GPS, previews, and other file-level private data. AI agents should use only the agent-safe surface.

## Verified ingest behavior

A small disposable fixture containing three iPhone Live Photos and one normal video was compared locally on macOS. No media fixture is committed to this repository.

Observed in that fixture:

| Ingest/export path | Result |
| --- | --- |
| macOS Image Capture | Complete HEIC + MOV Live Photo resources; selected as the reference ingest path |
| iPhone Photos AirDrop with **All Photos Data** | Byte-identical to Image Capture for every tested resource |
| ordinary iPhone Photos AirDrop | Still HEIC files remained byte-identical, but the three paired Live Photo videos were absent |
| Google Photos web download | Every tested HEIC and motion resource was byte-identical to Image Capture; motion files were sometimes named `.MP4` although their bytes matched the original `.MOV` |
| Google Photos iOS app AirDrop | Produced transformed standalone JPG/MP4 files rather than archival Live Photo resources |

The read-only scanner reproduced the expected structure across all five roots:

- 29 media resources;
- 8 logical assets;
- 3 logical Live Photos;
- 7 exact duplicate resource groups;
- 3 warnings for still-only Live Photo copies in the ordinary AirDrop root.

These findings apply to the tested fixture and software versions. They are not a promise that every future Google download or Google Takeout export will behave identically. Takeout remains a separate validation target.

## Requirements

- macOS 14 or later
- Swift 6 toolchain
- No required third-party executable

PhotoArchiveKit currently uses Apple system frameworks (`ImageIO`, `AVFoundation`, and `CryptoKit`) plus the system SQLite library.

## Build and run

```bash
swift build
swift run photoarchive doctor
```

Run a read-only scan of one folder:

```bash
swift run photoarchive scan --inbox "~/Photo Inbox"
```

Generate a read-only preferred-representation plan. This keeps non-Takeout exact copies preferred and applies Live Photo canonical coverage before placing unresolved cases into review:

```bash
swift run photoarchive plan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

For an AI agent, use `--agent-json` with `scan`, `plan`, `organize-plan`, `organize`, `quarantine`, or `cleanup-empty-dirs`; local diagnostic `--json` can contain paths.

Preview a quarantine without moving anything:

```bash
swift run photoarchive quarantine \
  --to "~/LJY Practice Trash" \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

Only after reviewing the dry run, add `--apply` to move the freshly re-verified `automatic_redundant` resources. `REVIEW` items are never moved by this command. Applied sessions are stored under `PhotoArchiveKit/<session-id>/` inside the supplied quarantine directory together with a local restore manifest.

A completed quarantine can be safely reversed. Restore is also a dry run by default and re-hashes every quarantined resource against the exact hash retained only in the local catalog before moving anything back:

```bash
swift run photoarchive restore-quarantine --agent-json "/path/to/session/manifest.json"
# add --apply only after the preflight succeeds
```

Preview deterministic camera-name cleanup without moving media:

```bash
swift run photoarchive organize-plan --agent-json --local "~/Pictures"
```

Before any organization apply, initialize a stable root marker explicitly (`photoarchive root init --apply "~/Pictures"`). `photoarchive organize` then defaults to a marker-verified dry run; only an explicit `--apply` can rename/flatten automatic items. Custom filenames and review items stay untouched.

After organization, empty-directory cleanup can be constrained to directories that actually lost files in that completed organization session. It is also a dry run by default:

```bash
swift run photoarchive cleanup-empty-dirs --agent-json "/path/to/organization.json"
# add --apply only after the preflight succeeds
```

Scan several sources together so exact copies, provenance, and cross-source Live Photo relationships can be reconciled without flattening the folders first:

```bash
swift run photoarchive scan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --takeout "~/Pictures/Takeout-2" \
  --archive "/Volumes/Photo Archive/Photos"
```

Registered nested roots belong to the most specific root, so the Takeout directories above are not scanned a second time through `~/Pictures`. This preserves source provenance even when byte-identical copies cannot be distinguished from file content alone.

Print a local human diagnostic report, which may contain paths:

```bash
swift run photoarchive scan --json --inbox "~/Photo Inbox"
```

For AI-agent workflows, use the privacy-minimized report instead:

```bash
swift run photoarchive scan --agent-json --inbox "~/Photo Inbox"
```

The agent-safe report exposes opaque IDs, provenance/status/counts, and relationships without filenames, paths, raw fingerprints, media content, capture timestamps, or exact byte sizes.

Use a disposable catalog during experiments:

```bash
swift run photoarchive scan \
  --catalog "/tmp/photoarchive-test.sqlite3" \
  --reference "/path/to/test-fixtures"
```

Run the dependency-free synthetic self-test:

```bash
swift run photoarchive-selftest
```

The default working catalog is stored at:

```text
~/Library/Application Support/PhotoArchiveKit/catalog.sqlite3
```

Treat the catalog as private local application state. It may contain paths and locally computed integrity values even though reports are sanitized.

## Commands

### `photoarchive scan`

Root options are repeatable:

- `--inbox PATH` — Inbox with unknown provenance.
- `--local PATH` — mixed local/iPhone-derived library.
- `--apple PATH` — direct Apple/iPhone import.
- `--takeout PATH` — Google Photos Takeout export.
- `--google-web PATH` — Google Photos web download.
- `--archive PATH`
- `--import PATH`
- `--reference PATH`

Bare paths are treated as Inbox roots.

Other options:

- `--catalog PATH` — choose a SQLite catalog.
- `--json` — print local diagnostic JSON; may include paths and filenames.
- `--agent-json` — print privacy-minimized JSON intended for AI agents.
- `--no-exact-duplicates` — skip local SHA-256 comparison.
- `--event-gap-hours NUMBER` — begin a new automatic event after this gap; default is six hours.
- `--jobs NUMBER` — limit concurrent metadata probes.

### `photoarchive doctor`

Reports required system support and whether optional executables are already available in `PATH`.

For registered Google Takeout roots, the scanner reads only the sidecar `title` and `photoTakenTime` fields when embedded media metadata cannot provide a reliable capture instant. GPS, descriptions, and unrelated Takeout metadata are not imported by this path.

## Automatic organization strategy

PhotoArchiveKit is being designed to reduce manual filing rather than merely provide a safer Finder workflow.

The planned classifier is layered:

1. **Deterministic grouping:** capture time, timezone, bursts, Live Photo relationship, and source session.
2. **Local event segmentation:** already implemented as time-gap folder suggestions.
3. **Archive-guided classification:** learn from the user's existing folder organization and propose the nearest known collection.
4. **Optional on-device visual analysis:** use Apple Vision/Core ML locally for similarity and coarse content labels; feature vectors must remain local and must not appear in agent reports.
5. **Confidence policy:** apply high-confidence proposals automatically, place medium-confidence groups in a small review queue, and fall back to date-event folders when confidence is low.

This avoids hard-coding one person's folder names while allowing an archive to become easier to organize over time. See [Automatic Organization Strategy](docs/AUTOMATION.md).

## Provider capability boundary

Apple PhotoKit is the stronger future projection target for Live Photos and user albums because an authorized local macOS client can read Photos assets and collections, create a Live Photo from `.photo` plus `.pairedVideo` resources, and modify editable album membership.

The current Google Photos Library API can upload compatible ordinary media without assigning an album, which is useful even when album synchronization is unavailable. Existing-library reads and album operations are generally limited to app-created content, and the public upload model does not document a composite Live Photo creation operation. The planned Google adapter will therefore support flat upload for eligible ordinary media while blocking any workflow that would split a validated Live Photo and misreport it as preserved.

See [Provider Capabilities](docs/PROVIDER_CAPABILITIES.md) for the dated capability matrix and official references.

## Privacy-safe AI agent boundary

A core reason for PhotoArchiveKit to exist is to let an AI agent reason about duplicate groups, Live Photo completeness, provenance, and archive plans **without receiving the user's media or private file-level metadata**. Hashes, content identifiers, broad metadata dumps, filenames/paths, previews, and timestamps stay inside the local process. The agent receives opaque asset/group/plan IDs and semantic decisions only.

This guarantee applies to PhotoArchiveKit's agent-safe interface; giving a general-purpose AI shell direct access to personal media would bypass that boundary. See [Privacy model](docs/PRIVACY.md) and [Agent interface](docs/AGENT_INTERFACE.md).

## Live Photo safety model

A Live Photo is one logical asset with at least two resources:

```text
Live Photo asset
├── photo          HEIC or JPEG
└── paired_video   MOV or MP4
```

PhotoArchiveKit does not use matching basenames as proof of pairing. It compares the internal still-side and QuickTime content identifiers locally, then requires the paired video to contain exactly one valid int8 `com.apple.quicktime.still-image-time` timed-metadata marker at a valid movie timeline position before the occurrence is considered complete. The marker payload itself is not treated as the timestamp; the timed metadata sample position is the evidence. Only a keyed identifier fingerprint and semantic validation status are exposed beyond the local metadata reader.

A future mutating command must treat all resources of a validated Live Photo as one transaction. One-sided rename, move, quarantine, or deletion is forbidden by project policy.

## Optional interoperability

The core does not vendor or require these projects, but future adapters may invoke copies already installed by the user:

- `rclone` for verified off-site file replication;
- `czkawka_cli` for additional duplicate and perceptual-similarity candidate generation;
- ExifTool for broad metadata inspection and migration diagnostics;
- `ffprobe` for optional video diagnostics.

Naming an interoperable tool is normal and preferable to hiding the dependency. Documentation must clearly state that the tool is optional, separately installed, separately licensed, and not affiliated with PhotoArchiveKit. See [THIRD_PARTY.md](THIRD_PARTY.md).

## Non-goals for the initial releases

- A continuously running sync daemon
- A replacement gallery server
- Browser automation for Google Photos
- Permanent deletion
- Silent metadata rewriting
- Treating perceptual similarity as permission to delete
- Assuming an unavailable external drive means its files were deleted
- Uploading a HEIC and MOV as separate Google Photos items and calling the result a preserved Live Photo

## Documentation

- [Project North Star and scope gate](docs/PROJECT_NORTH_STAR.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Automatic organization strategy](docs/AUTOMATION.md)
- [Provider capabilities](docs/PROVIDER_CAPABILITIES.md)
- [Optional integrations](docs/INTEGRATIONS.md)
- [Privacy model](docs/PRIVACY.md)
- [Ingest guidance](docs/INGEST.md)
- [Validation notes](docs/VALIDATION.md)
- [Agent interface](docs/AGENT_INTERFACE.md)
- [Roadmap](docs/ROADMAP.md)
- [Current development state](STATE.md)
- [Validated milestones](MILESTONES.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

## License

PhotoArchiveKit is licensed under the [MIT License](LICENSE).
