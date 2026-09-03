# Architecture

## Design goals

PhotoArchiveKit is designed for a Mac-first workflow in which an iPhone is the main camera, cloud backup may run continuously, and deliberate archive sessions happen only when the user chooses to connect storage and start a command.

The core priorities are:

1. Preserve original media resources and Live Photo relationships.
2. Keep media usable as ordinary files without PhotoArchiveKit.
3. Preserve organization independently of Google Photos, Apple Photos, or another provider.
4. Minimize manual classification through deterministic and local machine-learning stages.
5. Keep media-derived secrets local.
6. Make every future mutation reviewable, resumable, and reversible.
7. Avoid background CPU, battery, and filesystem cost.

## Three layers of truth

### Media truth

The canonical bytes live in normal filesystem roots:

```text
Photo Archive/
├── 2026-09-04/
│   ├── 20260904_153012.HEIC
│   └── 20260904_153012.MOV
└── .photoarchive/
```

The archive is not content-addressed in the initial design because human-readable folders are an explicit product requirement. Exact hashes are integrity evidence, not filenames or public IDs.

### Semantic truth

SQLite records information that folders cannot safely express:

- one logical asset to multiple physical resources;
- Live Photo still/paired-video roles;
- copies and provider-derived variants;
- primary folder and additional many-to-many collections;
- source/provenance observations;
- rename and operation history;
- duplicate decisions;
- provider object and album mappings;
- scan and archive sessions.

SQLite is the working database. A future versioned JSONL export will be the portable interchange and disaster-recovery representation. CSV is suitable only for reports, not as the canonical relational model.

### Provider projections

Apple Photos, Google Photos, and optional gallery software are views or delivery targets. Their identifiers are stored as mappings, never used as the permanent identity of a logical asset.

A provider adapter declares capabilities rather than pretending every operation is available:

```text
observe_library
upload_simple_media
upload_live_photo
create_album
add_existing_asset_to_album
remove_asset_from_album
```

A capability can be `supported`, `manual_only`, `unobservable`, `unverified`, or `unsupported`.

As of the current Google Photos Library API, library and album management is centered on media and albums created by the calling app. PhotoArchiveKit must therefore keep desired album state locally even when it cannot observe or apply that state in Google Photos.

## Resource and asset model

```text
LogicalAsset
├── Resource(role: photo)
├── Resource(role: paired_video)
├── Resource(role: rendered_edit)        future
└── Resource(role: provider_derivative)  future
```

A Live Photo is paired using embedded identifiers, not filenames. Current Apple-origin files expose:

- a still-side identifier in the image Exif MakerNote;
- a QuickTime content identifier in the motion resource.

PhotoArchiveKit compares the raw values locally, converts them to an HMAC-SHA-256 fingerprint using a catalog-local random key, and discards the raw values after probing. The keyed fingerprint supports local grouping without making the original identifier available in reports.

Pairing is evaluated at two levels:

- **Logical asset:** all known copies with the same protected identifier.
- **Occurrence:** completeness within one source root.

This distinction is essential. A complete copy in an Image Capture root must not hide the fact that an ordinary AirDrop root contains only the still image.

A shared basename without matching linkage metadata is only a warning candidate and is never paired automatically.

## Identity

Logical assets use opaque local IDs. Identity evidence can include:

- protected Live Photo identifier;
- exact resource hashes;
- provenance and observed source;
- capture metadata;
- future user-confirmed or provider-derived relations.

A filename, provider ID, capture timestamp, or perceptual feature alone is not sufficient permanent identity.

Standalone byte-identical resources may map to one logical asset. Different encodings of the same scene remain distinct assets until a derivation or equivalence relation is established.

## Source roots

The data model permits multiple roots even though a simple UI may begin with one default Inbox:

- `inbox`: unclassified incoming media;
- `archive`: canonical long-term files;
- `import_source`: Takeout or another provider export;
- `reference`: read-only comparison fixture or old collection.

The intended model treats paths as configuration rather than identity: an opaque root ID owns relative paths while the configured Inbox or mount location may change.

The current read-only prototype still resolves an existing root by its canonical path, so moving a configured root currently creates a new root record. Stable user-supplied root IDs and a marker such as `.photoarchive-root` are the next root-identity milestone. Future mutating commands must verify that marker before interpreting absence or applying a plan. An unavailable root must never be interpreted as mass deletion.

## Session model

There is no watcher or sync daemon. Work happens in explicit sessions:

```text
scan
  -> analyze
  -> propose
  -> plan
  -> verify preconditions
  -> apply to staging
  -> verify bytes and relationships
  -> commit catalog
  -> copy replica
  -> verify replica
  -> close session
```

The current implementation stops after `scan`, `analyze`, `propose`, and catalog persistence. It does not modify media.

Future plans will be immutable documents containing:

- operation ID and session ID;
- source and destination resource sets;
- expected size and integrity preconditions;
- Live Photo atomicity constraints;
- reason and confidence;
- reversible rename information.

Interrupted sessions must resume from verified checkpoints instead of repeating completed operations.

## Automatic classification

Manual drag-and-drop should be the fallback, not the normal path.

### Stage 1: deterministic grouping

Current and near-term signals:

- trusted capture instant and local date;
- timezone confidence;
- Live Photo relationship;
- burst and same-second sequence;
- source session;
- file provenance.

### Stage 2: event segmentation

Implemented now. Assets are ordered by trusted capture time and separated into event candidates when the gap exceeds a configurable threshold. The first folder proposal is deliberately conservative and date-based.

### Stage 3: archive-guided classification

Planned. Existing archive folders become labeled examples:

```text
known folder examples
       +
new event cluster
       -> nearest collection candidates
```

The classifier should score an event as a group rather than classify every frame independently. One confident trip event can assign hundreds of assets at once.

### Stage 4: local visual features

Planned and optional. Apple Vision can generate image feature prints and image classifications locally. For a Live Photo, the still resource is analyzed once and the result applies to the entire logical asset; the paired video does not need frame extraction for ordinary classification.

Feature vectors, face geometry, and inferred labels are media-derived private data. They remain local and are never part of normal agent output. Feature-print revisions must be recorded because distances are not assumed stable across algorithm revisions.

### Stage 5: confidence policy

Suggested defaults:

- high confidence: apply to an automatically generated plan;
- medium confidence: show one event-level review decision;
- low confidence: use a date-event folder and preserve alternatives in the catalog.

No classifier result authorizes deletion.

## Exact and perceptual duplicates

### Exact resource duplicate

Candidate files are first grouped by size. SHA-256 is calculated only inside the local process for groups with matching sizes. Reports receive stable IDs such as `D000017`, not the digest.

### Exact logical Live Photo duplicate

Both resource roles must be represented. An identical still with a missing or different paired video is not an exact duplicate Live Photo occurrence.

### Similar or derived copy

Perceptual similarity, matching capture time, or provider provenance can generate a review candidate, but must not collapse assets or authorize deletion automatically.

## Optional interoperability

The required core uses only Apple system frameworks and SQLite. Optional subprocess adapters can reuse mature tools already installed by a user without copying their code or binaries into PhotoArchiveKit:

- rclone for remote file replication and verification;
- Czkawka CLI for additional duplicate/similarity candidates;
- ExifTool for broad metadata diagnostics;
- ffprobe for optional video diagnostics.

This keeps installation small while allowing advanced users to extend a session.

## Design influences

Mature photo systems reinforce several boundaries used here:

- External-library gallery systems can index files without owning the originals, but metadata stored only in their database may be lost when a path changes. PhotoArchiveKit therefore keeps portable semantic state and stable logical IDs outside any gallery database.
- Read-only mounts are a useful safety boundary. PhotoArchiveKit adopts the same principle at the command level: scanning is read-only and future mutation requires a separate explicit plan/apply boundary.
- Job queues are useful for heavy indexing, but a personal archive that is connected periodically does not need a resident server. PhotoArchiveKit uses resumable foreground sessions instead.

## Deliberate exclusions

The initial architecture excludes:

- a server database;
- content-addressed user-facing storage;
- continuous filesystem observation;
- browser UI automation;
- permanent deletion;
- implicit metadata rewriting;
- one database row per cloud item as the primary identity model.
