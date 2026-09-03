# Ingest Guidance

The safest ingest path is the one that preserves every original resource before selection, renaming, organization, or deletion begins.

## Recommended default: Image Capture

For the current Mac-first workflow:

```text
iPhone
  -> USB connection
  -> macOS Image Capture
  -> configured Photo Inbox
  -> PhotoArchiveKit read-only scan
```

Advantages:

- writes directly to an ordinary Finder folder;
- does not require importing into an Apple Photos library first;
- preserved complete HEIC + MOV Live Photo resources in the validated fixture;
- does not depend on remembering an AirDrop export option for every transfer;
- fits an explicit, occasional archive session.

During early use, do not enable any option that deletes media from the iPhone after import. Import first, scan, verify, create another copy, and only then make a separate deletion decision.

## AirDrop

### All Photos Data enabled

In the validated fixture, enabling **All Photos Data** in the iPhone Photos share options produced resources that were byte-identical to Image Capture.

It remains a secondary method because the setting may not remain enabled for the next share. A future UI or documentation flow should always remind the user to verify this option.

### Ordinary Photos AirDrop

In the same fixture:

- the three HEIC still files were byte-identical to Image Capture;
- all three Live Photo motion resources were missing;
- the independent normal video was preserved.

Ordinary AirDrop is therefore unsafe as a default archival ingest path. PhotoArchiveKit reports each still-only Live Photo occurrence even if another scanned root contains a complete copy.

## Google Photos

### Web download

The tested Google Photos web download contained:

```text
IMG_8735.HEIC
IMG_8735.MP4
```

while the Image Capture reference contained:

```text
IMG_8735.HEIC
IMG_8735.MOV
```

For all three tested Live Photos and the normal video, local byte comparison showed equality with the Image Capture resource. The different `.MP4` extension did not imply different bytes. The embedded Live Photo linkage metadata remained valid.

This is encouraging evidence that Google Photos can act as an emergency recovery source for these items. It is not a universal contract. Retest after material changes to Google Photos, iOS, file formats, or account storage settings.

### Google Photos iOS app to AirDrop

The tested share path produced UUID-named JPG files and an MP4 instead of archival HEIC + paired-video resources. These files are useful as exported media but must not replace known originals.

PhotoArchiveKit should classify them as standalone or derived candidates unless an explicit equivalence relation is later established.

### Google Takeout

Takeout remains unverified by the current fixture. Preserve its directory structure and JSON sidecars exactly on first download.

Recommended first Takeout experiment:

1. Create disposable assets A, B, and C.
2. Put A only in album `Trip`.
3. Put B only in album `Family`.
4. Put C in both albums.
5. Export only the test data where possible.
6. Keep the untouched archive as a baseline.
7. Scan a working copy with PhotoArchiveKit.
8. Record resource counts, Live Photo completeness, exact-copy results, JSON linkage, and album representation.
9. Attempt Apple Photos re-import only in a test library.

Do not build a parser around guessed sidecar naming rules. Capture real, versioned fixtures first.

## Apple Photos export

Apple Photos remains a useful Live Photo-aware source, especially for a future PhotoKit adapter. For ordinary Finder archiving, exporting unmodified originals adds a library-import/export step that Image Capture avoids.

Use Apple Photos when:

- the asset exists only in a Photos library;
- edited/current and original variants need comparison;
- a PhotoKit-based restore test is being performed;
- albums need to be observed or projected.

Use **Export Unmodified Original** when the archival goal is original resources. Preserve optional sidecars separately and do not assume they are part of the minimum Live Photo pair.

## Source provenance

When two files are byte-identical, their bytes cannot reveal whether one came from Image Capture and another from Google Photos web download.

Provenance must therefore be recorded from the ingest context:

```text
root type
root label
scan session
relative source path
user-declared import method
```

It must not be inferred later from metadata or filename conventions.

## Safe first archive sequence

1. Import into a new Inbox without deleting from the source device.
2. Run `photoarchive scan` against the Inbox and any comparison roots.
3. Resolve incomplete Live Photo warnings.
4. Review exact duplicate groups as relationships, not deletion instructions.
5. Keep the original filenames and files unchanged while testing.
6. Create and verify a second copy.
7. Only after repeated successful sessions, enable future rename/copy planning on a small copied subset.
8. Keep provider cleanup and permanent deletion as separate, later operations.

## What a future ingest assistant should say

Recommended wording:

- **Preferred:** use Image Capture to import into the configured Photo Inbox.
- **Alternative:** when using AirDrop from Apple Photos, enable All Photos Data every time.
- **Warning:** ordinary AirDrop may omit the Live Photo motion resource.
- **Warning:** sharing from the Google Photos iOS app may create transformed standalone files.
- **Note:** a tested Google Photos web download was byte-identical, but Takeout and future versions still require validation.
