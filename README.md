# PhotoArchiveKit

[한국어](README.ko.md)

[![CI](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml/badge.svg)](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PhotoArchiveKit is a local-first, session-based toolkit for preserving and organizing iPhone photos, videos, and Live Photos without making a photo-cloud provider the permanent source of truth.

The project is intentionally small. It does not run a background daemon, host a gallery server, or move media behind an opaque storage format. Media remains in ordinary filesystem folders; a local SQLite catalog records relationships and decisions that folders cannot express.

> **Project status:** early read-only prototype. The scanner is usable, but archive mutation, renaming, cloud upload, and deletion are not implemented yet.

## Why this exists

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
- group copies found in different roots into one logical Live Photo asset;
- report completeness separately for every root, so a complete copy elsewhere does not hide a broken local copy;
- find exact duplicate files using local SHA-256 comparisons only when file sizes match;
- expose duplicate groups as stable opaque IDs instead of raw hashes;
- extract timezone-aware EXIF and QuickTime capture times when available;
- suggest date-based event folders by clustering assets separated by a configurable time gap;
- persist resources, logical assets, provenance, duplicate groups, future collection mappings, and scan sessions in SQLite;
- produce a human-readable report or sanitized JSON;
- detect optional user-installed interoperability tools without requiring or bundling them;
- complete all current work without modifying media files or contacting a network service.

The catalog stores local integrity data, including raw exact-file hashes, because it needs them for reliable comparison. Normal CLI and agent-facing reports never expose those hashes or raw Live Photo content identifiers.

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

Scan several sources together so exact copies and cross-source Live Photo relationships can be reconciled:

```bash
swift run photoarchive scan \
  --inbox "~/Photo Inbox" \
  --import "~/Downloads/Google Takeout" \
  --archive "/Volumes/Photo Archive/Photos"
```

Print the full sanitized report:

```bash
swift run photoarchive scan --json --inbox "~/Photo Inbox"
```

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

- `--inbox PATH`
- `--archive PATH`
- `--import PATH`
- `--reference PATH`

Bare paths are treated as Inbox roots.

Other options:

- `--catalog PATH` — choose a SQLite catalog.
- `--json` — print sanitized JSON.
- `--no-exact-duplicates` — skip local SHA-256 comparison.
- `--event-gap-hours NUMBER` — begin a new automatic event after this gap; default is six hours.
- `--jobs NUMBER` — limit concurrent metadata probes.

### `photoarchive doctor`

Reports required system support and whether optional executables are already available in `PATH`.

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

## Live Photo safety model

A Live Photo is one logical asset with at least two resources:

```text
Live Photo asset
├── photo          HEIC or JPEG
└── paired_video   MOV or MP4
```

PhotoArchiveKit does not use matching basenames as proof of pairing. It compares the internal still-side and QuickTime content identifiers locally, stores only a keyed fingerprint in the catalog, and reports the relationship without disclosing the identifier.

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
