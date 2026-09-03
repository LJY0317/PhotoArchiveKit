# Validated Milestones

This file records expensive or reusable validation results. It intentionally excludes private paths, media, raw hashes, Live Photo identifiers, and detailed personal metadata.

## 2026-09-04 — Five-path iPhone and Google ingest fixture

A disposable fixture contained three new iPhone Live Photos and one normal video. Five transfer/export paths were compared locally.

### Byte comparison findings

- Image Capture and iPhone AirDrop with **All Photos Data** were byte-identical for every tested still, paired video, and normal video resource.
- Image Capture and Google Photos web download were byte-identical for every tested resource.
- Google web motion files used an `.MP4` extension in the fixture while their bytes matched the Image Capture `.MOV` resources.
- Ordinary iPhone Photos AirDrop preserved the tested HEIC still bytes and normal video, but omitted all three paired Live Photo videos.
- Google Photos iOS app AirDrop produced transformed standalone JPG/MP4 output and did not preserve the fixture as archival Live Photo resource pairs.

Comparison was performed locally. No raw digest was exposed or recorded here.

### Pairing findings

- Valid pairs were recognized by Apple Photos after filenames were changed.
- Giving resources from different Live Photos the same basename did not make them a valid pair.
- Internal Live Photo linkage, not basename equality, is the pairing authority.
- Creating a `PHLivePhoto` object alone was previously observed to be insufficient as a strict mismatch validator; PhotoArchiveKit therefore compares embedded identifiers directly.

### Scanner regression result

The initial PhotoArchiveKit scanner processed all five roots together and reported:

```text
resources                  29
logical assets              8
logical Live Photos         3
exact duplicate groups      7
event suggestions           1
warnings                    3
```

The three warnings were the expected still-only Live Photo occurrences in the ordinary AirDrop root. The transformed Google Photos iOS AirDrop files remained separate standalone assets. No media file was modified.

### Interpretation

- Image Capture is the recommended baseline ingest method for the current Mac-first workflow.
- All Photos Data AirDrop is a valid tested alternative but carries a recurring option-selection risk.
- Ordinary AirDrop and Google Photos iOS app AirDrop should not be treated as archival Live Photo ingest paths.
- Google Photos web download is a strong tested recovery path for this fixture, but this result is not generalized to all future exports or Takeout.
- Provenance cannot be inferred from byte-identical files and must be recorded from the source root and scan session.

## 2026-09-04 — Initial local-first core

Completed and locally verified:

- Swift package builds successfully.
- Synthetic self-test passes without XCTest or an external test framework.
- The self-test confirms read-only behavior, stable opaque duplicate group identity, exact-copy logical asset unification, and absence of a known raw digest in serialized output.
- Core runtime dependencies are limited to Apple system frameworks and SQLite.
- Optional rclone, Czkawka CLI, ExifTool, and ffprobe integrations are not bundled.

## Validation still required

The following findings must not be assumed from the completed fixture:

- Google Takeout Live Photo byte fidelity and sidecar schema;
- edited Live Photo original/current/adjustment preservation;
- timed `still-image-time` validation across file variants;
- all Apple device, OS, codec, and camera-format combinations;
- Google Photos API creation of one composite Live Photo from a still and video;
- fully automatic semantic folder classification accuracy.
