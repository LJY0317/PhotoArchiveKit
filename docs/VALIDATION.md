# Validation Notes

Validation date: **2026-09-04**

This document separates vendor guarantees from local observations. Provider behavior can change; a passing sample is a regression observation, not a permanent Apple or Google contract.

## Five-route local sample

A disposable set contained three new iPhone Live Photos and one ordinary video. It was acquired through:

1. iPhone Photos -> normal AirDrop
2. iPhone Photos -> AirDrop with **All Photos Data**
3. Google Photos iOS app -> AirDrop
4. Google Photos web -> browser download
5. macOS Image Capture -> filesystem folder

No personal media, raw hash, or raw Live Photo identifier is committed to this repository.

### Full-byte comparison

| Compared with Image Capture | Still resources | Live motion resources | Ordinary video |
|---|---:|---:|---:|
| AirDrop + All Photos Data | identical | identical | identical |
| Google Photos web | identical | identical | identical |
| Normal AirDrop | identical | all three absent | identical |
| Google Photos iOS -> AirDrop | transformed files | pair not preserved | transformed representation |

Google web motion filenames used `.MP4` while Image Capture used `.MOV`, but the bytes were identical in this sample. An earlier contrary result was caused by selecting the wrong comparison path.

### PhotoArchiveKit scan result

The five folders were scanned together as separate source roots:

```text
source roots                         5
media resources                     29
source-local media occurrences      20
provider-neutral logical assets      8
logical Live Photo assets            3
complete Live Photo occurrences      9
still-only Live Photo occurrences    3
exact resource duplicate groups      7
automatic event suggestions           1
warnings                              3
```

Twenty source-local occurrences collapse to eight logical assets because byte-identical ordinary media and Live Photo copies with the same protected linkage identifier are unified. Per-root completeness remains visible, so a complete copy elsewhere does not hide an incomplete normal-AirDrop occurrence.

The seven exact resource groups are three still images, three motion resources, and one ordinary video preserved identically by multiple routes.

## Filename-independence observations

- A correct still/motion pair remained a Live Photo after both filenames changed.
- A still from one Live Photo and a motion resource from another did not become a Live Photo merely because their basenames matched.
- The tested Google web HEIC + MP4 pairs imported into Apple Photos as Live Photos.

PhotoArchiveKit therefore uses embedded linkage evidence. A basename can be a disambiguation hint but never pairing authority.

## Meaning of `complete`

The current scanner calls an occurrence complete when exactly one recognized still and one recognized motion resource share the same protected Apple identifier inside one source root.

It does not yet prove:

- complete media decodability;
- correct timed `still-image-time` metadata;
- expected audio;
- restoration of edits, key-photo choices, or adjustment state;
- identical behavior in future software versions.

## Provenance conclusion

Byte-identical files cannot reveal whether they came from Image Capture or Google Photos web. Provenance must be recorded from the source root, declared import method, relative path, and scan session rather than inferred from file contents.

## Remaining high-value tests

- Small test-only Google Takeout export, including one asset in two albums.
- Edited Live Photos: key photo, crop, color adjustment, mute, Live on/off, and effects.
- Strict timed-metadata and decode validation.
- Same-second captures, subseconds, bursts, timezone changes, and metadata-free media.
- Archive pair -> PhotoKit -> Apple Photos -> Google Photos iOS -> download round trip.
- rclone upload/download followed by local full-byte comparison.

Until those tests are complete, the architecture can safely preserve ordinary files, explicit resource relationships, source provenance, many-to-many collections, and local equality groups without deleting or rewriting anything.
