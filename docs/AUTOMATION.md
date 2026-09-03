# Automatic Organization Strategy

PhotoArchiveKit is designed so that manual work scales with the number of **ambiguous events**, not the number of individual photos.

The preferred outcome for a large ingest session is:

```text
thousands of resources
  -> exact-copy reconciliation
  -> logical assets
  -> a small number of event groups
  -> high-confidence folder proposals
  -> only uncertain event groups require review
```

Automatic classification never authorizes deletion. It only proposes organization and provider projection state.

## Canonical organization model

Each logical asset can have:

- one primary filesystem collection, represented by its final archive folder;
- zero or more additional logical collections stored in SQLite;
- zero or more provider album projections;
- provenance observations from every source in which a copy was found.

Example:

```text
primary folder:   미국 여행
collections:      미국 여행, 가족, 2026 Best
Google Photos:    flat upload may exist without album projection
Apple Photos:     album membership can mirror the logical collections
```

A filesystem copy is not created for every additional collection. The many-to-many memberships remain catalog data and can later be projected to a provider that supports them.

## Classification pipeline

### 1. Normalize resources into logical assets

Before classification, PhotoArchiveKit:

- pairs Live Photo resources by embedded identifiers;
- keeps completeness status per source root;
- groups byte-identical resources locally;
- distinguishes a complete Live Photo from a still-only copy;
- preserves transformed or re-encoded versions as separate representations until equivalence is established.

This prevents duplicate copies from voting several times in the classifier.

### 2. Segment assets into events

Event-level decisions provide the largest reduction in manual work. The current implementation groups trusted capture times using a configurable time gap and proposes conservative date folders.

Planned event evidence includes:

- capture instant and local calendar date;
- timezone confidence;
- short gaps and overnight boundaries;
- burst and same-second sequences;
- neighboring Live Photos, photos, and videos;
- source import session;
- optional coarse location cells calculated locally.

An event remains one unit unless strong evidence suggests that it should be split.

### 3. Learn from the existing archive

The archive's existing folders are labeled examples. PhotoArchiveKit should not impose a universal taxonomy such as `Travel`, `People`, or `Nature` unless the user chooses it.

For each known folder, the local model can summarize non-secret features such as:

- typical dates or recurring calendar periods;
- event duration and asset count distribution;
- camera/source characteristics;
- locally derived location regions when enabled;
- optional local visual feature centroids;
- user-confirmed aliases and hierarchy.

A new event is compared with these folder profiles. The classifier returns candidates with explicit evidence and confidence rather than a single unexplained answer.

```text
Event E000142
candidate: 일본 여행
confidence: high
reasons:
  - same local region as confirmed examples
  - adjacent dates to an existing trip event
  - visual similarity to confirmed event clusters
```

Agent-facing reports must omit raw GPS coordinates, feature vectors, face representations, perceptual hashes, and image-derived embeddings. They may expose only coarse reasons and confidence.

### 4. Optional local visual analysis

Visual classification is optional and local-only. A future macOS adapter may use Apple Vision/Core ML to calculate image feature prints and coarse labels without uploading media.

Rules:

- analyze one representative still for a Live Photo rather than sampling its motion video by default;
- cache features locally with the model/revision identifier;
- permit complete cache deletion and deterministic rebuilding;
- never send vectors, thumbnails, frames, or face geometry to an agent or cloud service;
- do not enable face recognition in the initial classifier;
- do not make visual similarity an identity or deletion decision.

Users who already have `czkawka_cli` may optionally import its similar-image/video candidate groups. This remains a separate subprocess adapter and is not required by the core.

### 5. Confidence policy

Recommended default policy:

| Confidence | Default action |
| --- | --- |
| High | Add the proposed folder and collection memberships to an immutable plan |
| Medium | Ask for one event-level decision, not one decision per asset |
| Low | Use a neutral date-event folder and retain ranked alternatives in SQLite |
| Conflict | Stop that event and explain the conflicting evidence |

A user may choose a stricter preset in which all proposals require approval, but the default product direction is automatic-first.

## Learning from corrections

A correction should improve future event decisions without creating a hidden global model:

```text
proposal: 일상
user correction: 가족
```

PhotoArchiveKit records:

- the event and chosen primary collection;
- the rejected candidate;
- the classifier version;
- the evidence categories used;
- an optional user-visible note.

It does not need to retain raw media-derived values in portable reports. The local feature cache can be rebuilt from archive files when necessary.

## Duplicate policy before classification

Exact copies are reconciled before event scoring. When choosing a preferred representation, PhotoArchiveKit may propose a ranking based on:

1. complete logical asset over incomplete occurrence;
2. validated camera-origin resources over transformed exports;
3. greater metadata completeness;
4. original dimensions and duration;
5. trusted provenance;
6. user override.

Larger byte size alone is not enough to declare a file superior. No proposal removes the non-preferred copy until the archive and an independent replica have been verified and the user has approved quarantine.

## Prior-art lessons adopted selectively

PhotoArchiveKit is not a replacement implementation of another product, but mature systems demonstrate useful boundaries:

- **Mylio Photos** keeps a compact catalog while original-quality files can live on multiple Vault devices. PhotoArchiveKit similarly separates a small semantic catalog from ordinary original files and records where complete copies exist.
- **Immich** separates duplicate detection from a review utility and can use XMP sidecars. PhotoArchiveKit likewise treats similarity as review evidence and plans a portable catalog export instead of modifying originals silently.
- **PhotoPrism** groups related resources into stacks, including Live Photos. PhotoArchiveKit adopts the logical multi-resource asset concept but does not accept a shared basename as authoritative proof of Live Photo pairing.

References:

- [Mylio Photos protection and Vault devices](https://support.mylio.com/how-does-mylio-photos-protect-my-photos)
- [Immich duplicate review](https://docs.immich.app/features/duplicates-utility/)
- [Immich XMP sidecars](https://docs.immich.app/features/xmp-sidecars/)
- [PhotoPrism stacks](https://docs.photoprism.app/user-guide/organize/stacks/)

These products and projects are design references, not bundled dependencies or compatibility guarantees.

## Planned commands

The intended lightweight command flow is:

```text
photoarchive scan
photoarchive learn
photoarchive classify
photoarchive plan
photoarchive verify-plan
photoarchive apply
photoarchive verify
```

Only `scan` exists today. `classify` and `plan` will remain read-only. `apply` will not be added until archive-root identity, preconditions, rollback records, Live Photo transaction boundaries, and copy verification are implemented.

## What automatic-first does not mean

It does not mean:

- silently moving files on first scan;
- automatically deleting perceptually similar assets;
- uploading private media for classification;
- forcing every archive into one predefined folder taxonomy;
- classifying each resource independently when the resources form one logical asset;
- treating provider-generated labels as permanent truth;
- hiding uncertain decisions.

The system should be assertive when evidence is strong and conservative when a mistake would be costly.
