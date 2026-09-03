# Provider Capabilities

Last reviewed against official documentation: **2026-09-04**.

Provider APIs are adapters around the portable archive. They do not define PhotoArchiveKit asset identity, Live Photo relationships, or collection truth.

## Capability states

PhotoArchiveKit uses explicit capability states instead of pretending that every provider can perform the same operation:

- `supported` — documented and suitable for automatic use.
- `supported_app_created_only` — available only for media or albums created by the PhotoArchiveKit integration.
- `user_selected_only` — available only after an explicit provider picker flow.
- `manual_only` — PhotoArchiveKit can report desired work but cannot apply it safely through the official API.
- `unverified` — technically plausible, but not yet proven by official documentation and a controlled fixture.
- `unsupported` — unavailable or known to lose required information.

## Current comparison

| Operation | Google Photos official APIs | Apple PhotoKit on macOS |
| --- | --- | --- |
| Enumerate an existing whole user library | `unsupported`; only the app-created subset is listable | `supported` after user authorization |
| Access selected existing items | `user_selected_only` through Picker API | `supported` after user authorization |
| Enumerate existing user albums | `unsupported`; only app-created albums are listable | `supported` |
| Create an album | `supported` | `supported` |
| Add arbitrary existing user media to an album | `manual_only` | `supported` for editable user albums |
| Remove arbitrary existing user media from an album | `manual_only` | `supported` for editable user albums |
| Upload a new ordinary photo or video | `supported` | `supported` |
| Upload without assigning an album | `supported` | `supported` |
| Create one Live Photo from still + paired video | `unverified` / no documented public composite request | `supported` using `.photo` and `.pairedVideo` resources |
| Observe an iCloud Photos-backed library | Not applicable | `supported` through the authorized local Photos library |
| Headless cloud account administration | Limited server API | Not a general iCloud Photos REST API; requires a local authorized Photos client |

## Google Photos

Google applied its announced Photos API changes on 2025-04-01. Current Library API list, search, album, and album-membership methods are centered on content created by the calling application. The Picker API is the official route for accessing existing items that a user explicitly selects.

Official references:

- [Google Photos API release notes](https://developers.google.com/photos/support/release-notes)
- [`mediaItems.list`](https://developers.google.com/photos/library/reference/rest/v1/mediaItems/list)
- [`mediaItems.search`](https://developers.google.com/photos/library/reference/rest/v1/mediaItems/search)
- [`albums.list`](https://developers.google.com/photos/library/reference/rest/v1/albums/list)
- [`albums.batchAddMediaItems`](https://developers.google.com/photos/library/reference/rest/v1/albums/batchAddMediaItems)
- [Google Photos Picker API](https://developers.google.com/photos/picker/reference/rest)

### Flat upload is a useful supported target

The Library API accepts ordinary HEIC images and MOV/MP4 videos. Uploading is a two-step operation: upload the bytes, then create each item through `mediaItems.batchCreate`. Omitting `albumId` adds the new item to the user's library without assigning it to an album.

Official reference:

- [Upload media](https://developers.google.com/photos/library/guides/upload-media)

PhotoArchiveKit therefore plans to support a **flat Google Photos upload queue** for compatible ordinary media. Album projection is optional and limited to content and albums the integration is permitted to manage.

### Live Photo upload remains blocked by project safety policy

The documented Google request model creates `simpleMediaItem` objects from individual upload tokens. The current public documentation does not expose an operation equivalent to PhotoKit's `.photo + .pairedVideo` composite asset creation.

Until Google documents such a mechanism or a controlled end-to-end fixture proves a durable official route, PhotoArchiveKit must not:

- upload the HEIC and MOV/MP4 as unrelated items and call that a preserved Live Photo;
- discard the paired video after uploading only the still image;
- report a Live Photo upload as successful merely because both files reached Google Photos.

A future Google adapter should classify each queued logical asset as:

```text
ordinary_photo_or_video  -> eligible for flat upload
validated_live_photo     -> blocked_live_photo_route_unavailable
unknown_or_incomplete    -> blocked_requires_review
```

The local archive remains complete even when a provider projection cannot represent an asset.

## Apple Photos and iCloud Photos

PhotoKit represents images, videos, Live Photos, albums, and album folders in the user's authorized Photos library. When iCloud Photos is enabled, PhotoKit reflects content available through that library across the user's devices.

Official references:

- [PhotoKit overview](https://developer.apple.com/documentation/photokit)
- [Fetching objects and requesting changes](https://developer.apple.com/documentation/photokit/fetching-objects-and-requesting-changes)
- [`PHAssetCollection`](https://developer.apple.com/documentation/photos/phassetcollection)
- [`PHAssetResourceType`](https://developer.apple.com/documentation/photos/phassetresourcetype)
- [`PHAssetCreationRequest.addResource`](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource%28with%3Afileurl%3Aoptions%3A%29)

PhotoKit exposes original Live Photo resources as `.photo` and `.pairedVideo`. It also distinguishes edited/current resources such as `.fullSizePhoto`, `.fullSizePairedVideo`, and adjustment data. This makes Apple Photos the stronger automatic projection target for validated Live Photo assets and user album membership.

PhotoKit is not treated as a general remote iCloud REST service. The adapter will be a small local macOS component that requests explicit Photos authorization and runs only during a user-started session.

## Direct provider-to-provider transfer

Apple's current support documentation says that direct Google Photos to iCloud Photos transfer does not transfer Motion Photos or Live Photos as those compound formats. Apple's iCloud Photos to Google Photos transfer documentation likewise excludes Live Photos and notes that only the most recent edit is transferred, with videos transferred separately from albums.

Official references:

- [Transfer a copy from Google Photos to iCloud Photos](https://support.apple.com/120924)
- [Transfer a copy of iCloud Photos to another service](https://support.apple.com/118257)

These direct transfer services are convenience copies, not PhotoArchiveKit's Live Photo migration path. A migration that promises Live Photo preservation must use validated filesystem resources and a provider-specific importer.

## Adapter rules

Every provider adapter must:

1. Declare capabilities at runtime or from a versioned compatibility table.
2. Preserve provider-neutral desired state even when an operation is unsupported.
3. Record provenance separately from media identity.
4. Produce an immutable plan before network writes.
5. Treat partial upload success as a recoverable session state.
6. Avoid provider deletion in the initial implementation.
7. Never expose OAuth tokens, raw hashes, Live Photo identifiers, thumbnails, or media-derived feature vectors in normal reports.
