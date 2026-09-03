# Privacy Model

PhotoArchiveKit is designed so that useful automation does not require sending personal media or media-derived fingerprints to an AI service.

## Default network posture

The current core performs no network requests. A scan reads local files, writes the selected local SQLite catalog, and prints a report.

Future cloud adapters must be separate, opt-in commands with provider-specific authorization and capability documentation. Enabling an adapter must not silently enable telemetry, remote classification, or uploads to any unrelated service.

## Data classes

### Public project data

Safe to commit:

- source code;
- schema migrations;
- documentation;
- generated or explicitly approved synthetic fixtures;
- reports made entirely from synthetic fixtures.

### Private local catalog data

May be stored in the local SQLite catalog:

- configured source-root paths;
- relative file paths and filenames;
- file sizes and capture-time metadata;
- provider object mappings;
- raw exact-file hashes;
- keyed Live Photo identifier fingerprints;
- future perceptual feature vectors;
- collection decisions and operation history.

The catalog is private application state. It is excluded by `.gitignore` and should not be attached to an issue without sanitization.

### Never included in normal reports

- image or video bytes;
- thumbnails or extracted frames;
- audio samples;
- raw SHA-256/BLAKE3 values;
- raw Live Photo content identifiers;
- Exif MakerNote dumps;
- perceptual hashes or Vision feature vectors;
- face geometry or biometric templates;
- precise GPS coordinates;
- OAuth access or refresh tokens;
- cloud client secrets.

## Live Photo identifier protection

The scanner needs to determine whether the still image and motion resource contain the same identifier. It does not need to reveal that identifier.

The current process is:

1. Read the identifier from each resource in local process memory.
2. Normalize only surrounding whitespace.
3. Calculate HMAC-SHA-256 using a random key created for that catalog.
4. Clear the raw identifier from the in-memory probe object immediately after fingerprinting.
5. Store only the keyed fingerprint in SQLite.
6. Expose only logical asset IDs and match/completeness status in reports.

Because the HMAC key is catalog-local, fingerprints from separate catalogs are not intended to be comparable. This reduces accidental cross-dataset correlation.

## Exact hashes

Raw exact-file hashes remain local because reliable incremental duplicate detection needs a stable content fingerprint. The CLI report converts equality into an opaque group such as:

```json
{
  "groupID": "D000017",
  "members": [
    {"rootLabel": "Inbox", "relativePath": "IMG_0001.HEIC"},
    {"rootLabel": "Takeout", "relativePath": "IMG_0001.HEIC"}
  ]
}
```

The digest is not printed. A self-test verifies that the known local SHA-256 value of a synthetic fixture does not appear in the encoded report.

## Agent-facing boundary

An agent should invoke only sanitized operations such as:

```text
scan_roots
list_incomplete_live_photos
list_duplicate_groups
propose_archive_plan
validate_plan
```

The interface should not expose general-purpose operations such as:

```text
read_media_bytes
extract_frame
show_thumbnail
print_hash
print_makernote
print_feature_vector
```

A safe agent-facing asset record may contain:

```json
{
  "assetID": "A0042",
  "kind": "live_photo",
  "pairStatus": "complete",
  "exactDuplicateGroup": "D0017",
  "captureTimeStatus": "trusted",
  "collections": ["Trip"],
  "providerState": {
    "apple": "in_sync",
    "google": "unobservable"
  }
}
```

It must not contain the underlying hash, content identifier, GPS coordinate, media preview, or embedding.

## Optional local visual analysis

Automatic organization may later use Apple Vision or a local Core ML model. This is more private than a cloud classifier, but its outputs are still sensitive.

Rules for visual features:

- operate on the Live Photo still resource by default;
- do not upload pixels, frames, labels, or embeddings;
- record the model/request revision;
- store features only in local protected application state;
- exclude them from normal JSON, logs, crash reports, and support bundles;
- make regeneration preferable to exporting features;
- provide an option to disable and erase the feature cache.

## Credentials

Future OAuth tokens should be stored in the macOS Keychain. They must not be placed in:

- the repository;
- configuration examples;
- SQLite unless encrypted with a separate key-management design;
- CLI arguments, which may appear in process listings;
- normal logs or reports.

## Destructive operations

An AI agent must never receive unrestricted deletion authority.

Future policy layers should permit an agent to create a proposal, while a local helper enforces:

- verified archive root identity;
- complete Live Photo resource sets;
- verified canonical copy;
- at least one independently verified replica for deletion-eligible content;
- quarantine rather than permanent deletion;
- explicit local approval for irreversible actions.

## Issue and support hygiene

Before sharing a report:

1. Prefer `--json` output, which is designed to be sanitized.
2. Review filenames and paths because they are intentionally visible.
3. Do not attach the SQLite catalog.
4. Do not attach personal Takeout sidecars or media.
5. Reproduce bugs with synthetic fixtures whenever possible.
