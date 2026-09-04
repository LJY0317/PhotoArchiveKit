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

## 2026-09-04 — Real-library provenance baseline

대규모 mixed local library와 세 개의 Google Takeout export를 nested-root ownership 및 explicit provenance를 적용해 read-only로 scan했다.

Sanitized baseline:

```text
recognized resources           30240
media resources                18754
logical assets                  8178
logical Live Photos             2710
exact duplicate groups          8261
filename collision groups        289
```

재사용할 결론:

- exact resource group 4,052개가 local-library와 Google-Takeout provenance 경계를 가로질렀다.
- Live Photo asset 1,346개는 local과 Takeout 양쪽에 complete occurrence가 있었고 still/motion resource가 role별로 byte-identical이었다.
- exact standalone logical asset 685개가 local과 Takeout 양쪽에서 관찰되었다.
- 최소 Takeout sidecar importer는 `title`과 `photoTakenTime`만 parse하여 수천 개 media의 provider capture-time evidence를 복구했다. trusted embedded EXIF/QuickTime timestamp는 계속 우선한다.
- provider/date 조건만으로는 삭제 안전성을 증명할 수 없다. 사용자가 다른 device/provider copy가 있다고 기대해도 Takeout occurrence가 현재 filesystem에서 유일한 complete Live Photo representation일 수 있다.
- filename은 identity가 아니다. real scan에서 같은 filename이지만 byte content가 다른 group이 수백 개 확인되었다.

이 validation에서는 media file을 수정하지 않았다.

### Czkawka/Krokiet exact-duplicate 교차검증

같은 real library를 Krokiet/Czkawka 12.0.1의 기존 cache와 `czkawka_cli`로 다시 검사하고 PhotoArchiveKit catalog 결과와 비교했다. GUI cache는 hash/perceptual 계산을 재사용하기 위한 binary cache였고 durable duplicate-group 목록 자체는 아니었지만, CLI 재실행으로 결과를 빠르게 재현할 수 있었다.

PhotoArchiveKit이 지원하는 주요 photo/video extension 집합으로 제한한 Czkawka exact scan의 sanitized 결과:

```text
exact duplicate groups              8269
redundant media occurrences         8739
estimated redundant bytes       76.66 GiB
local + Takeout mixed groups         4052
Takeout occurrences in mixed groups 4466
```

가장 중요한 교차검증은 **local + Takeout mixed exact group 4,052개와 그 안의 Takeout resource 4,466개가 PhotoArchiveKit의 independent exact-resource catalog 결과와 정확히 일치했다**는 점이다. total group 수의 작은 차이는 두 tool의 전체 scan/support semantics 차이로 남아 있지만, 현재 provenance cleanup의 핵심 집합은 일치했다.

사용자 정책 `non-Takeout > Google Takeout`을 적용했을 때, 첫 asset-level 집계는 최소 3,431개 Takeout resource를 자동 redundant candidate로 확인했다. 이후 같은 catalog를 occurrence 단위로 더 세밀하게 재분석해 여러 Takeout export에 반복된 같은 Live Photo occurrence도 각각 평가했다.

```text
Takeout standalone exact resources with non-Takeout copy      739
Takeout Live Photo resources in clean 1-photo+1-video
occurrences with a role-by-role exact non-Takeout pair       2740
current automatic exact-resource candidates                  3479
current held exact-resource candidates                        987
```

보류 987개는 perceptual similarity 후보가 아니다. **모두 파일 단위 exact hash가 non-Takeout resource와 일치하는 집합 안에 있다.** 보류 이유는 Live Photo occurrence boundary다.

```text
candidate resources in ambiguous/incomplete Takeout occurrences 984
candidate resources with no complete non-Takeout occurrence       3
```

984개가 속한 occurrence의 대표 구조:

```text
2 photos + 2 paired videos   163 occurrences / 652 candidate resources
1 photo  + 0 paired videos   217 occurrences / 217 candidate resources
2 photos + 0 paired videos    36 occurrences /  71 candidate resources
0 photos + 1 paired video     44 occurrences /  44 candidate resources
```

즉 파일 하나의 byte equality는 확인됐어도 scanner가 같은 Live Photo identifier의 반복 export를 아직 안전한 1쌍 occurrence로 partition하지 못하는 경우가 대부분이다. 이 집합은 filename이나 visual similarity 때문이 아니라 **logical asset의 resource 경계를 확정하기 전 한쪽 resource만 제거하지 않기 위한 보수적 hold**다.

또한 Takeout 내부끼리만 byte-identical인 media group도 대규모로 존재했다.

```text
Takeout-only exact groups              4189
Takeout-only redundant occurrences     4193
estimated redundant bytes          35.19 GiB
```

이 집합은 같은 media가 연도 folder와 album folder 등에 반복된 경우를 포함할 수 있으므로 collection/album semantics를 catalog로 옮긴 뒤 한 physical representation으로 collapse해야 한다. 이 validation에서도 media file은 수정하지 않았다.

## 2026-09-04 — Product North Star 고정

최초 제품 목적을 `docs/PROJECT_NORTH_STAR.md`와 `AGENTS.md`의 explicit scope gate로 고정했다.

Core completion은 iPhone/Apple, Mac, Google Photos/Takeout, HDD에 흩어진 같은 촬영물을 reconcile하고 Live Photo resource 관계를 보존하며, 사용자 provenance preference를 적용하고, 사람이 읽을 수 있는 folder archive를 만들고, copy를 검증하며, portable provider-neutral semantic state를 유지하는 것을 의미한다.

이 완료 기준이 real library에서 안정적으로 동작하기 전에는 직접 기여하지 않는 기능을 보류한다. Czkawka/Krokiet, rclone, ExifTool, ffprobe, 공식 provider framework처럼 성숙한 외부 도구가 재구현보다 강한 영역은 재사용하고 PhotoArchiveKit은 provider-neutral asset relationship과 archive decision을 소유한다.

## 아직 필요한 Validation

완료된 fixture만으로 다음 내용을 가정해서는 안 된다.

- Google Takeout Live Photo byte fidelity와 sidecar schema
- edited Live Photo의 original/current/adjustment 보존
- file variant 전반의 timed `still-image-time` validation
- 모든 Apple device, OS, codec, camera-format 조합
- Google Photos API로 still+video에서 하나의 composite Live Photo 생성 가능 여부
- fully automatic semantic folder classification 정확도
