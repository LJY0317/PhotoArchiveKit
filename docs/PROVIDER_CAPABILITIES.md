# Provider Capability

공식 documentation 기준 마지막 review: **2026-09-04**.

Provider API는 portable archive 주변의 adapter다. PhotoArchiveKit asset identity, Live Photo relationship, collection truth를 정의하지 않는다.

## Capability state

모든 provider가 같은 operation을 할 수 있다고 가정하지 않고 explicit capability state를 사용한다.

- `supported` — documented이며 automatic use에 적합
- `supported_app_created_only` — PhotoArchiveKit integration이 만든 media/album에만 가능
- `user_selected_only` — explicit provider picker flow 후에만 가능
- `manual_only` — desired work는 report할 수 있지만 official API로 안전하게 apply할 수 없음
- `unverified` — 기술적으로 가능해 보이지만 official documentation과 controlled fixture로 아직 검증되지 않음
- `unsupported` — 사용할 수 없거나 required information을 잃는 것으로 알려짐

## 현재 비교

| Operation | Google Photos official API | Apple PhotoKit on macOS |
| --- | --- | --- |
| 기존 전체 user library enumerate | `unsupported`; app-created subset만 list 가능 | user authorization 후 `supported` |
| 선택한 기존 item 접근 | Picker API를 통한 `user_selected_only` | user authorization 후 `supported` |
| 기존 user album enumerate | `unsupported`; app-created album만 list 가능 | `supported` |
| album 생성 | `supported` | `supported` |
| arbitrary existing user media를 album에 추가 | `manual_only` | editable user album에 대해 `supported` |
| arbitrary existing user media를 album에서 제거 | `manual_only` | editable user album에 대해 `supported` |
| 새 ordinary photo/video upload | `supported` | `supported` |
| album assignment 없이 upload | `supported` | `supported` |
| still + paired video에서 하나의 Live Photo 생성 | `unverified` / documented public composite request 없음 | `.photo` + `.pairedVideo` resource로 `supported` |
| iCloud Photos-backed library observe | 해당 없음 | authorized local Photos library를 통해 `supported` |
| headless cloud account administration | 제한된 server API | general iCloud Photos REST API가 아니며 local authorized Photos client 필요 |

## Google Photos

Google은 announced Photos API change를 2025-04-01에 적용했다. 현재 Library API의 list, search, album, album-membership method는 calling application이 생성한 content 중심이다. Picker API가 user가 명시적으로 선택한 existing item에 접근하는 공식 경로다.

Official references:

- [Google Photos API release notes](https://developers.google.com/photos/support/release-notes)
- [`mediaItems.list`](https://developers.google.com/photos/library/reference/rest/v1/mediaItems/list)
- [`mediaItems.search`](https://developers.google.com/photos/library/reference/rest/v1/mediaItems/search)
- [`albums.list`](https://developers.google.com/photos/library/reference/rest/v1/albums/list)
- [`albums.batchAddMediaItems`](https://developers.google.com/photos/library/reference/rest/v1/albums/batchAddMediaItems)
- [Google Photos Picker API](https://developers.google.com/photos/picker/reference/rest)

### Flat upload은 유용한 supported target

Library API는 ordinary HEIC image와 MOV/MP4 video upload를 지원한다. upload는 byte upload 후 `mediaItems.batchCreate`로 item을 생성하는 2단계 operation이다. `albumId`를 생략하면 album assignment 없이 user library에 새 item이 추가된다.

Official reference:

- [Upload media](https://developers.google.com/photos/library/guides/upload-media)

따라서 PhotoArchiveKit은 compatible ordinary media를 위한 **flat Google Photos upload queue**를 지원할 계획이다. album projection은 optional이며 integration이 manage할 수 있는 content/album으로 제한한다.

### Live Photo upload는 project safety policy상 차단

documented Google request model은 individual upload token에서 `simpleMediaItem`을 생성한다. 현재 public documentation에는 PhotoKit의 `.photo + .pairedVideo` composite asset creation과 같은 operation이 없다.

Google이 그런 mechanism을 document하거나 controlled end-to-end fixture가 durable official route를 검증하기 전까지 PhotoArchiveKit은 다음을 해서는 안 된다.

- HEIC와 MOV/MP4를 unrelated item으로 upload하고 preserved Live Photo라고 부르기
- still image만 upload하고 paired video discard
- 두 file이 Google Photos에 도착했다는 이유만으로 Live Photo upload 성공 보고

future Google adapter는 queued logical asset을 다음처럼 classify해야 한다.

```text
ordinary_photo_or_video  -> eligible for flat upload
validated_live_photo     -> blocked_live_photo_route_unavailable
unknown_or_incomplete    -> blocked_requires_review
```

provider projection이 asset을 표현하지 못해도 local archive는 complete하게 유지한다.

## Apple Photos 및 iCloud Photos

PhotoKit은 authorized Photos library에서 image, video, Live Photo, album, album folder를 표현한다. iCloud Photos가 enabled이면 PhotoKit은 해당 library를 통해 user device 전반에서 available한 content를 반영한다.

Official references:

- [PhotoKit overview](https://developer.apple.com/documentation/photokit)
- [Fetching objects and requesting changes](https://developer.apple.com/documentation/photokit/fetching-objects-and-requesting-changes)
- [`PHAssetCollection`](https://developer.apple.com/documentation/photos/phassetcollection)
- [`PHAssetResourceType`](https://developer.apple.com/documentation/photos/phassetresourcetype)
- [`PHAssetCreationRequest.addResource`](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource%28with%3Afileurl%3Aoptions%3A%29)

PhotoKit은 original Live Photo resource를 `.photo`, `.pairedVideo`로 노출한다. `.fullSizePhoto`, `.fullSizePairedVideo`, adjustment data 같은 edited/current resource도 구분한다. 따라서 Apple Photos가 validated Live Photo asset과 user album membership의 더 강한 automatic projection target이다.

PhotoKit을 general remote iCloud REST service로 취급하지 않는다. adapter는 explicit Photos authorization을 요청하고 user-started session 동안만 실행되는 small local macOS component다.

## Direct provider-to-provider transfer

Apple의 current support documentation에 따르면 Google Photos -> iCloud Photos direct transfer는 Motion Photo/Live Photo를 compound format으로 transfer하지 않는다. iCloud Photos -> Google Photos transfer도 Live Photo를 제외하고, most recent edit만 transfer되며 video는 album과 별도로 transfer된다고 명시한다.

Official references:

- [Transfer a copy from Google Photos to iCloud Photos](https://support.apple.com/120924)
- [Transfer a copy of iCloud Photos to another service](https://support.apple.com/118257)

이 direct transfer service는 convenience copy이지 PhotoArchiveKit의 Live Photo migration path가 아니다. Live Photo preservation을 약속하는 migration은 validated filesystem resource와 provider-specific importer를 사용해야 한다.

## Adapter rule

모든 provider adapter는:

1. runtime 또는 versioned compatibility table에서 capability를 선언한다.
2. operation이 unsupported여도 provider-neutral desired state를 보존한다.
3. provenance와 media identity를 분리해 기록한다.
4. network write 전에 immutable plan을 생성한다.
5. partial upload success를 recoverable session state로 취급한다.
6. initial implementation에서는 provider deletion을 피한다.
7. normal report에 OAuth token, raw hash, Live Photo identifier, thumbnail, media-derived feature vector를 노출하지 않는다.
