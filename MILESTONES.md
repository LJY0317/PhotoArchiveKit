# 검증된 Milestone

이 파일은 비용이 크거나 재사용 가치가 있는 validation 결과를 기록한다. private path, media, raw hash, Live Photo identifier, 상세 personal metadata는 의도적으로 제외한다.

## 2026-09-04 — 5경로 iPhone/Google ingest fixture

Disposable fixture에는 새 iPhone Live Photo 3개와 일반 video 1개가 포함되었다. 다섯 transfer/export 경로를 로컬에서 비교했다.

### Byte 비교 결과

- Image Capture와 **All Photos Data**를 켠 iPhone AirDrop은 테스트한 모든 still, paired video, 일반 video resource에서 byte-identical이었다.
- Image Capture와 Google Photos web download는 테스트한 모든 resource에서 byte-identical이었다.
- fixture에서 Google web motion file은 `.MP4` extension을 사용했지만 byte는 Image Capture의 `.MOV` resource와 동일했다.
- 일반 iPhone Photos AirDrop은 테스트한 HEIC still byte와 일반 video를 보존했지만 Live Photo paired video 3개를 모두 누락했다.
- Google Photos iOS app AirDrop은 transformed standalone JPG/MP4를 만들었고 fixture를 archival Live Photo resource pair로 보존하지 않았다.

비교는 로컬에서 수행했다. raw digest는 노출하거나 여기에 기록하지 않았다.

### Pairing 결과

- 유효한 pair는 filename을 바꾼 뒤에도 Apple Photos에서 인식되었다.
- 서로 다른 Live Photo의 resource에 같은 basename을 주어도 유효한 pair가 되지 않았다.
- basename equality가 아니라 내부 Live Photo linkage가 pairing authority다.
- `PHLivePhoto` object 생성만으로는 strict mismatch validator로 충분하지 않은 것으로 관찰되었기 때문에 PhotoArchiveKit은 embedded identifier를 직접 비교한다.

### Scanner regression 결과

초기 PhotoArchiveKit scanner가 다섯 root를 함께 처리한 결과:

```text
resources                  29
logical assets              8
logical Live Photos         3
exact duplicate groups      7
event suggestions           1
warnings                    3
```

warning 3개는 ordinary AirDrop root의 예상된 still-only Live Photo occurrence였다. transformed Google Photos iOS AirDrop file은 별도 standalone asset으로 유지되었다. media file은 수정되지 않았다.

### 해석

- Image Capture는 현재 Mac-first workflow의 권장 baseline ingest method다.
- All Photos Data AirDrop은 검증된 대안이지만 매번 option 선택을 확인해야 하는 위험이 있다.
- Ordinary AirDrop과 Google Photos iOS app AirDrop은 archival Live Photo ingest path로 취급하지 않는다.
- Google Photos web download는 이 fixture에 대해 강한 recovery path였지만 모든 future export 또는 Takeout에 일반화하지 않는다.
- byte-identical file만으로 provenance를 추론할 수 없으며 source root와 scan session에서 기록해야 한다.

## 2026-09-04 — 초기 local-first core

완료하고 로컬에서 검증한 항목:

- Swift package build 성공
- XCTest 또는 외부 test framework 없이 synthetic self-test 통과
- self-test가 read-only behavior, stable opaque duplicate group identity, exact-copy logical asset unification, serialized output에 known raw digest가 없음을 확인
- core runtime dependency는 Apple system framework와 SQLite로 제한
- optional rclone, Czkawka CLI, ExifTool, ffprobe integration은 bundle하지 않음

## 아직 필요한 Validation

완료된 fixture만으로 다음 내용을 가정해서는 안 된다.

- Google Takeout Live Photo byte fidelity와 sidecar schema
- edited Live Photo의 original/current/adjustment 보존
- file variant 전반의 timed `still-image-time` validation
- 모든 Apple device, OS, codec, camera-format 조합
- Google Photos API로 still+video에서 하나의 composite Live Photo 생성 가능 여부
- fully automatic semantic folder classification 정확도
