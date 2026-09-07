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

> **Project status:** early safety-first prototype. `scan`, `archive-coverage`, `plan`, and `organize-plan` are media-read-only; `archive-index` can refresh an existing user-managed archive without moving media and writes its root-scoped portable inventory only with explicit `--apply`. The current user-managed HDD workflow is intentionally simple: copy or organize files in Finder, re-index the archive root, then run `archive-coverage` across every root that should count as a current copy. PhotoArchiveKit does not discover arbitrary unregistered folders or run a background filesystem watcher. Permanent deletion, independent replica verification, and cloud upload are not completed yet.

### Recommended current workflow

1. Register the roots that should participate in the comparison, such as a Mac library, a nested Google Takeout root, and a user-managed HDD photo root.
2. Let the user copy or organize archive media in Finder. PhotoArchiveKit does not need to own the HDD folder layout.
3. Run `archive-index` after manual HDD changes so the local catalog reflects the archive root's current files and folder hierarchy.
4. Run `archive-coverage` with all roots that should count as current storage. It reports exact cross-root coverage and whether Live Photo occurrences have complete, partial/ambiguous, or missing counterparts elsewhere.

An `archive-index` refresh updates that archive root; it does not magically discover a source folder that has never been registered or scanned. `archive-coverage` performs the current multi-root comparison explicitly. This keeps filesystem observation separate from mutation and avoids treating an unavailable external drive as a deletion.

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
- report a non-blocking notice when a verified Live Photo still/video pair uses different basenames; the pair remains valid because embedded linkage metadata, not filename equality, is the identity authority, and agent-safe output exposes only the notice code/root ID;
- require a paired video with a matching identifier to contain exactly one valid QuickTime `still-image-time` timed-metadata marker before reporting that Live Photo occurrence as complete;
- group copies found in different roots into one logical Live Photo asset and partition repeated same-identifier exports into physical occurrences using directory/basename only as boundary hints after embedded identifier identity is established;
- report completeness separately for every root, so a complete copy elsewhere does not hide a broken local copy;
- find exact duplicate files using local SHA-256 comparisons only when file sizes match;
- expose duplicate groups as stable opaque IDs instead of raw hashes;
- replace the membership snapshot of an exact duplicate group whenever that group is observed again, so a previously seen member cannot leak into the current group after the filesystem changed;
- run `archive-coverage` as a media-read-only current-state comparison across two or more registered roots: report per-root exact-covered versus exact-unique resource counts, pairwise exact-group overlap, and Live Photo counterpart status (`complete`, `split/ambiguous`, still-only, video-only, or none) on other roots;
- extract timezone-aware EXIF and QuickTime capture times when available;
- suggest date-based event folders by clustering assets separated by a configurable time gap;
- persist resources, logical assets, provenance, duplicate groups, source collection mappings, original filenames, path history, and scan sessions in SQLite;
- index an existing **user-managed archive root** with `archive-index`: preserve the current nested folder hierarchy as user-authored collection semantics, leave all media in place, prune stale folder memberships after manual Finder moves, and compute exact hashes for every media resource;
- reuse metadata probe results for unchanged files when path/filesystem identity, byte size, modification time, and metadata-probe cache version still match; failed probes and media whose effective capture time came from a mutable Google Takeout sidecar are conservatively re-probed;
- reuse metadata and exact SHA-256 evidence for unchanged files from the Mac-local SQLite catalog, and for archive roots optionally seed exact hashes from the root's hidden `.photoarchive/inventory-v1.jsonl`; scan-style commands including `archive-index --fresh` bypass metadata/hash reuse and re-read every media resource;
- keep the fast authoritative working catalog on the Mac while allowing each removable archive root to carry its own root-scoped portable inventory containing relative structure and integrity evidence for another computer; this inventory is an accelerator/portable map, never mutation authority;
- export that catalog's portable semantic subset as versioned JSONL and dry-run/restore it into a new SQLite catalog without carrying raw hashes, Live Photo fingerprints, filesystem IDs, absolute root paths, capture timestamps, provider object IDs, or generated scan/event caches;
- keep same-volume resource identity stable across rename/move and recognize a moved source root through an optional `.photoarchive-root` marker;
- generate a read-only `organize-plan` for only `IMG_####` / `IMG_E####` camera-style names, using capture wall-clock names such as `YYYY-MM-DD_HH-mm-ss[_NN]` while preserving custom filenames;
- generate an immutable `archive-plan` against a marker-initialized destination: choose one canonical representation per logical asset, keep complete Live Photo still+paired-video resources atomic, freeze source/destination marker bindings and relative paths, freshly compare each AUTO source byte stream with exact SHA-256 evidence from the same scan/catalog state, and avoid existing destination filename collisions deterministically;
- dry-run or apply `archive-copy` from immutable plan schema v2: independently re-check current catalog asset/role/hash evidence and root markers, copy each AUTO item through hidden `.photoarchive` staging, verify full SHA-256 before and after finalization, resume from already verified staging/final files, scan the completed archive root back into SQLite, and write a portable catalog JSONL snapshot into the archive control directory; source media is never moved or deleted;
- require a stable root marker before `organize --apply`, keep Live Photo still+video on one destination basename, verify post-move filesystem identity/size, transactionally update the stable resource path/history in SQLite without a second full scan, write a restore manifest, and roll back filesystem moves if catalog commit fails;
- let `cleanup-empty-dirs` consider only source directories proven by a completed organization manifest plus catalog location history, require the stable root marker, skip package/symlink boundaries, and remove only directories that are still literally empty at apply time;
- produce a human-readable report or sanitized JSON;
- detect optional user-installed interoperability tools without requiring or bundling them;
- dry-run or apply a local quarantine only for strong `automatic_redundant` exact decisions after fresh SHA-256 verification against a preferred copy; preference-sensitive keeper choices (for example recognizable-name/path/timestamp/tie-break choices) require explicit human approval before they can gain mutation authority, and Live Photo candidate sets are verified before any resource in the item moves;
- preserve Google Takeout source-folder/album-like memberships in local SQLite before collapsing Takeout-only exact standalone copies, without exposing collection names or paths to agent-safe output;
- write a local restore manifest for applied quarantine sessions, roll back the whole session if a move fails, and dry-run/apply `restore-quarantine` only after the quarantined bytes are freshly re-verified against the local catalog's original SHA-256 evidence;
- perform all current analysis without contacting a network service.
- report structured scan progress without contaminating machine-readable output: recursive enumeration is indeterminate until the file list is known, then metadata/hash stages expose completed/total counts and percentages. Interactive terminals redraw one stderr line; non-interactive logs emit throttled progress lines. `--no-progress` disables it.

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

Generate a read-only preferred-representation plan. Exact duplicates use a role-aware canonical keeper policy. `staging`, `primary_library`, and `archive` roots may reduce redundant **same-root** exact copies while retaining a survivor in that same root. `import_source` may do the same once required source semantics (such as Google Takeout folder membership) are captured, and may also be cleaned against a separate retained copy when the import-cleanup rules allow it. `reference` is read-only. Generic reconciliation never collapses a primary/archive copy merely because another root has the same bytes; staging-to-archive offload remains a separate protection workflow. Live Photo occurrences remain atomic and unresolved variants stay in review:

```bash
swift run photoarchive plan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

For local human review without copying media, `duplicate-review` can materialize the AUTO exact decisions as a Finder-friendly workspace of symbolic links. By default it reuses the latest complete scan snapshot that still matches the active root registry, so opening an already-computed review does not reread the full media library. Before trusting an old decision for display, it cheaply checks the participating files' current size, modification time, filesystem identity, and stable root-marker identity where available. `CURRENT` groups use `KEEPER` / `CANDIDATE`; changed groups are visibly labeled `STALE` and use `OLD_KEEPER` / `OLD_CANDIDATE`; unavailable roots are labeled `OFFLINE`. Every group also gets a local-private Korean `comparison.txt` that states exact-byte evidence, the original target size (not the Finder symlink size), embedded/capture metadata, filesystem creation/modification evidence, path/name differences, filesystem identity, extended-attribute equality, and the keeper rationale. Filesystem-creation-date fallback is explicitly separated from embedded capture metadata. It deliberately says "no differences detected in the metadata PhotoArchiveKit currently inspects" rather than claiming universal metadata identity. `--preference-only` hides strong automatic choices such as complete-Live-Photo retention, explicit `copy` / `복사본` filename markers (numeric copy suffixes remain strong only when they correspond to a peer basename), user-validated recognizable source filenames, and shallower same-root paths. A file whose basename matches its parent folder also strongly outranks a peer under an obvious placeholder parent such as `Untitled Folder`, `무제 폴더`, `New Folder`, or `새 폴더`. Pure deterministic ties remain review-only until an explicit user approval selects the survivor and do not receive automatic quarantine authority. `--candidate-root` can narrow the workspace to cleanup candidates from one registered root. Use `--refresh` to incrementally rescan current roots, or `--refresh --fresh` when a full metadata/hash recomputation is explicitly desired. Originals are never moved, renamed, deleted, or duplicated by review.

```bash
swift run photoarchive duplicate-review \
  --output "~/Desktop/PhotoArchiveKit-Duplicate-Review" \
  --candidate-root "~/Pictures"
```

Refresh first when the library has materially changed:

```bash
swift run photoarchive duplicate-review \
  --refresh \
  --output "~/Desktop/PhotoArchiveKit-Duplicate-Review-Fresh" \
  --candidate-root "~/Pictures"
```

For an AI agent, use `--agent-json` with `scan`, `archive-coverage`, `plan`, `duplicate-review`, `organize-plan`, `archive-index`, `archive-plan`, `archive-copy`, `organize`, `quarantine`, `restore-quarantine`, `cleanup-empty-dirs`, or the `catalog` command reports; local diagnostic `--json` can contain paths. Persisted archive-plan, archive-copy manifest, archive-root inventory, and JSONL snapshot files themselves are **not** agent-safe because safe replay/disaster recovery requires local-private paths, filenames, catalog paths, marker bindings, or integrity preconditions.

Check current Mac/Takeout/HDD coverage without moving media:

```bash
swift run photoarchive archive-coverage --agent-json \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --archive "/Volumes/My HDD/deep/path/My Photos"
```

Only roots supplied to this session participate in the current coverage result. A separately registered active or inactive nested root remains an ownership boundary and is automatically excluded from a parent-only scan; only `root remove` returns that subtree to parent ownership. If media was copied from another Mac folder or another external device that PhotoArchiveKit has never scanned, register that location as an appropriate `--local`, `--import`, or `--reference` root when you want it included in the comparison.

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

For recurring Image Capture-style folders that contain exactly one logical asset and no other entries, add `--singleton-leaf-only` to limit the plan/apply scope to those clean nested folders. Live Photos still move as one still+paired-video asset, and the existing date-based destination/collision rules are reused. If a standalone `IMG_####` / `IMG_E####` file has no trusted capture timestamp, `--preserve-name-if-date-untrusted` can be combined with this scope to flatten it without inventing a date-based filename; root-level name collisions still block that promotion.

Before any organization apply, initialize a stable root marker explicitly (`photoarchive root init --apply "~/Pictures"`). `photoarchive organize` then defaults to a marker-verified dry run; only an explicit `--apply` can rename/flatten automatic items. Custom filenames and review items stay untouched.

After organization, empty-directory cleanup can be constrained to directories that actually lost files in that completed organization session. It is also a dry run by default:

```bash
swift run photoarchive cleanup-empty-dirs --agent-json "/path/to/organization.json"
# add --apply only after the preflight succeeds
```

Create a local-private immutable HDD archive plan without copying media yet. Both the canonical source root and archive destination need stable `.photoarchive-root` markers for an item to receive automatic copy authority:

```bash
swift run photoarchive archive-plan \
  --to "/Volumes/Photo Archive" \
  --output "~/Library/Application Support/PhotoArchiveKit/archive-plan.json" \
  --agent-json \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

The persisted plan is **local-private**: schema v2 contains the working catalog path, source/destination paths, exact byte sizes, marker bindings, and expected SHA-256 preconditions. `--agent-json` exposes only opaque IDs, reason codes, and counts. `archive-plan` never copies or deletes media.

Preview the immutable plan again at the copy boundary. The executor re-checks the plan against current catalog evidence and fresh source bytes, so the plan file alone is not sufficient copy authority:

```bash
swift run photoarchive archive-copy --agent-json \
  "~/Library/Application Support/PhotoArchiveKit/archive-plan.json"
```

Only after the preflight succeeds, add `--apply`. AUTO resources are copied through `.photoarchive/staging/<plan-id>`, full-file SHA-256 is verified before and after finalization, and complete Live Photo items are staged as a full still+paired-video set before a missing member is finalized. A pending operation can be re-run idempotently: already verified staged or final files are reused. On completion the archive root is scanned back into the working catalog and a portable catalog snapshot is written under the archive's hidden `.photoarchive` directory. Source media is never moved or deleted.

```bash
swift run photoarchive archive-copy --apply --agent-json \
  "~/Library/Application Support/PhotoArchiveKit/archive-plan.json"
```

If the HDD already contains a carefully hand-organized photo tree, index that tree instead of forcing it into PhotoArchiveKit's generated folder layout. First place a stable marker at the **photo root itself**, not necessarily at the volume root:

```bash
swift run photoarchive root init --apply "/Volumes/My HDD/deep/path/My Photos"
swift run photoarchive archive-index --agent-json "/Volumes/My HDD/deep/path/My Photos"
```

`archive-index` recursively records the current folders that contain supported media as user-authored collection hierarchy in the Mac-local SQLite catalog. Media is not moved, renamed, deleted, or rewritten. A normal repeat scan reuses cached metadata and exact hashes when stable file facts still match. On the same volume, filesystem identity also lets a manual Finder move/rename reuse the old evidence even when the relative path changed. `archive-index --fresh` bypasses metadata plus local/portable hash reuse. High-risk mutations never trust cache alone; they still perform fresh byte verification.

After reviewing the index, an explicit `--apply` writes only a hidden root-scoped portable inventory:

```bash
swift run photoarchive archive-index --apply --agent-json \
  "/Volumes/My HDD/deep/path/My Photos"
```

The recommended split is intentional:

```text
Mac internal SSD                              Removable archive root
~/Library/Application Support/PhotoArchiveKit  My Photos/
└── catalog.sqlite3                            ├── Family/
    authoritative working catalog             ├── Trips/
                                                └── .photoarchive/
                                                    ├── root marker
                                                    └── inventory-v1.jsonl
                                                        root-scoped portable map/cache
```

The Mac SQLite database remains the authoritative **working** catalog because SQLite random I/O and transaction state belong on reliable local storage. The archive inventory travels with only that archive root and contains relative paths, byte sizes, modification times, opaque IDs, roles, and SHA-256 evidence, so it is **local-private** and should not be shared with an AI agent. When the HDD is attached to a computer with a fresh local catalog, the inventory can seed unchanged-file hashes and avoid re-reading all media bytes. Use `archive-index --fresh` periodically, or whenever a full integrity audit is desired, to ignore both local and portable caches and re-hash every media resource.

The root inventory and `catalog export` serve different purposes. `inventory-v1.jsonl` is root-scoped and intentionally carries raw integrity evidence for fast reattachment; `catalog export` is a broader disaster-recovery semantic snapshot and deliberately omits raw hashes and other reproducible local caches.

Export a versioned disaster-recovery snapshot of the catalog's portable semantic state:

```bash
swift run photoarchive catalog export \
  --output "/path/to/photoarchive-catalog.jsonl"
```

The snapshot excludes absolute root paths and reproducible/sensitive local caches such as raw exact hashes, keyed Live Photo fingerprints, filesystem IDs, capture timestamps, provider object IDs, and generated scan/event results. It is still **local-private**, not share-safe, because it keeps relative paths, original filenames, collection labels, opaque IDs, asset/resource roles, root provenance, and stable root-marker bindings needed for disaster recovery.

Restore always validates first and refuses to overwrite an existing catalog. Roots without a stable marker can be explicitly rebound to current directories:

```bash
swift run photoarchive catalog restore \
  --to "/path/to/restored-catalog.sqlite3" \
  --bind-root ROPAQUEID="/path/to/current/root" \
  "/path/to/photoarchive-catalog.jsonl"
# add --apply only after the dry run succeeds
```

The restored catalog seeds opaque root/resource/asset identity and collection semantics. The next normal scan re-reads media metadata and hashes from the files and replaces snapshot placeholders with fresh local evidence while retaining restored opaque asset identity when the same resources are found.

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

For a path that is already registered, its saved usage role is authoritative: a later scan flag does not silently change `staging`/`primary_library`/`archive`/`import_source`/`reference`. Change policy explicitly with `photoarchive root role`.

Other options:

- `--catalog PATH` — choose a SQLite catalog.
- `--json` — print local diagnostic JSON; may include paths and filenames.
- `--agent-json` — print privacy-minimized JSON intended for AI agents.
- `--no-exact-duplicates` — skip local SHA-256 comparison.
- `--event-gap-hours NUMBER` — begin a new automatic event after this gap; default is six hours.
- `--jobs NUMBER` — limit concurrent metadata probes.
- `--no-progress` — disable stderr progress output. Progress never changes JSON/stdout payloads.

Long scans follow the usual two-phase progress convention used by mature file tools: while recursively enumerating a tree, the final total is not yet known, so PhotoArchiveKit reports only the number discovered. Once enumeration finishes, determinate stages report `completed/total` and a percentage. This avoids an extra full pre-count pass over slow external disks.

### `photoarchive archive-index`

Indexes one existing marker-initialized user-managed archive root without reorganizing it.

- default: update the Mac-local SQLite catalog only; do not write anything into the archive root;
- `--apply`: additionally write `.photoarchive/inventory-v1.jsonl` inside that root;
- `--fresh`: ignore both local SQLite and portable-inventory hash caches and re-read every media byte;
- `--jobs NUMBER`: limit concurrent metadata probes;
- `--json`: local-private diagnostic including the inventory path;
- `--agent-json`: path/hash-free counts and status only.

The current folder collection model represents folders that contain supported media (including their parent hierarchy); empty folders with no indexed media are not semantic collections.

### `photoarchive doctor`

Reports required system support and whether optional executables are already available in `PATH`.

For registered Google Takeout roots, the scanner reads only the sidecar `title` and `photoTakenTime` fields when embedded media metadata cannot provide a reliable capture instant. GPS, descriptions, and unrelated Takeout metadata are not imported by this path.

Sidecar policy is consumer-oriented: users are not expected to open JSON/XMP files manually. Recognized sidecars are associated with their logical media asset automatically: Google Takeout JSON uses its verified `title` target, while unambiguous same-basename XMP/AAE files are linked locally. These sidecars do not block `organize --singleton-leaf-only` from moving the media asset, but the sidecar file itself is preserved in place rather than silently deleted. Unknown or ambiguous JSON remains unassociated and may block deletion of its source folder until it is explicitly reviewed or preserved.

Exact-only Live Photo reconciliation also treats a whole incomplete occurrence (`still_only` or `video_only`) as automatically redundant when every resource in that occurrence has a byte-identical same-role counterpart outside Takeout. This does not require a complete Live Photo counterpart elsewhere and never removes only part of an occurrence; quarantine still re-hashes the candidate and keeper before moving anything.

Canonical keeper selection does **not** collapse intentional backup replicas across every registered root into one global file. Each registered root has one user-changeable usage role: `staging`, `primary_library`, `archive`, `import_source`, or `reference`. Staging is temporary working storage; primary library is retained long-term; archive is a long-term protection target that remains actively manageable; import source is cleanup-eligible after the required coverage/semantics checks; reference is comparison-only and read-only. Byte-identical same-root copies may be reduced in staging, primary, and archive roots while retaining one survivor in that root. Import-source same-root dedupe is also allowed once required source semantics are safe. A primary/archive replica is never removed merely because another root has an equal copy. Every automatic mutation is still re-verified by fresh full-file hashes before quarantine.

A future local GUI should expose the private side of this decision directly: one duplicate group per row/section, with every physical copy's root and path, protected/keeper/candidate badges, and filters by location. This is deliberately a **local-only** view; agent-safe reports continue to expose opaque group/root IDs and counts without filenames or paths. The current human `scan` report already shows paths for the first duplicate groups and `--json` contains the complete local-private result, but a Krokiet-style grouped location view is the intended consumer UX.

Library locations have an explicit root registry. `photoarchive root add`, `enable`, `disable`, `remove`, `role`, and `list` separate locations the user currently manages from roots merely observed by older scans. Roles are assigned **per registered root, not per device**, so different folders on the same Mac, HDD, or future file-cloud provider can have different policies. `root role ROOT ROLE` changes policy only and never moves/deletes media; role changes are recorded in the local catalog. `staging` and `primary_library` both map to the internal `inbox` kind, while `archive`, `import_source`, and `reference` map to their matching kinds. Provenance remains a separate fact. The portable catalog snapshot preserves the current role so disaster recovery does not silently change retention policy. `root remove` never touches media: it prunes current evidence while retaining minimal root identity/history.

Example:

```bash
swift run photoarchive root add --role staging --provenance local_library "~/Pictures"
swift run photoarchive root role ROOT_ID archive
```

Legacy catalogs are migrated conservatively: an existing `inbox` is initially treated as `primary_library` so an upgrade cannot silently make it easier to clean up. New `inbox` roots default to `staging` unless another role is explicitly selected.

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
