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

이후 `photoarchive plan`으로 preferred-representation planner와 canonical coverage를 실제 구현해 같은 library를 다시 평가했다. 구현된 planner의 정확한 mixed-exact 기준값은 다음과 같다.

```text
mixed local/Takeout exact resources     4466
automatic redundant resources           4195
  standalone exact                       739
  Live Photo canonical coverage         3456
review resources                          271
  no complete preferred Live Photo       270
  uncovered exact Live Photo variant       1
```

따라서 이전 수동 SQL에서 얻은 약 `4245 automatic / 221 review`는 근사치였고, 위 planner 결과가 새로운 기준값이다. `--exact-engine native`와 `--exact-engine czkawka`는 동일한 plan summary를 만들었다.

성능 benchmark:

```text
Czkawka candidate discovery + native verification   37.66 s
native size-group + full SHA-256                     36.21 s
```

현재 hybrid Czkawka exact path는 이중 작업 때문에 native보다 빠르지 않았다. `automatic`은 native를 유지하고 Czkawka exact는 독립 cross-check로 사용한다. Czkawka의 장기적인 주 전문 영역은 perceptual image/video similarity이며, exact accelerator 승격은 duplicate hashing을 피하는 integration 또는 native incremental cache 이후 다시 benchmark한다.

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

canonical coverage의 초기 exploratory SQL은 약 `4,245 automatic / 221 review`를 추정했지만 이후 실제 `photoarchive plan` 구현이 resource/item boundary를 완전히 적용한 결과 `4,195 automatic / 271 review`가 정확한 기준값으로 확정되었다. exploratory 수치는 historical analysis로만 남기고 deletion/quarantine 판단에는 사용하지 않는다.

또한 Takeout 내부끼리만 byte-identical인 media group도 대규모로 존재했다.

```text
Takeout-only exact groups              4189
Takeout-only redundant occurrences     4193
estimated redundant bytes          35.19 GiB
```

이 집합은 같은 media가 연도 folder와 album folder 등에 반복된 경우를 포함할 수 있으므로 collection/album semantics를 catalog로 옮긴 뒤 한 physical representation으로 collapse해야 한다. 이 validation에서도 media file은 수정하지 않았다.

### 첫 quarantine mutation-path 검증

`photoarchive quarantine`을 same-session scan -> plan -> fresh verification -> optional move 경로로 구현했다. synthetic fixture에서는 preferred local copy를 유지하면서 exact Takeout copy만 quarantine으로 이동했고, 이동된 byte가 동일하며 local restore manifest가 생성되는 것을 확인했다. agent-safe quarantine report에는 source/destination path와 filename을 포함하지 않는다.

real library에서는 실제 move 전에 강화된 dry-run preflight만 수행했다.

```text
freshly verified AUTO items       2262
freshly verified resources        4195
files modified                       0
quarantine target top-level entries  0
```

preflight는 각 candidate와 preferred counterpart가 현재 regular file인지, scan 당시 size를 유지하는지, symlink를 통해 registered root 밖으로 빠지지 않는지 확인한 뒤 full-file SHA-256을 fresh하게 다시 계산했다. Live Photo item은 모든 planned resource verification이 완료되어야 mutation 단계로 넘어갈 수 있다. 실제 apply 중 오류가 발생하면 같은 session에서 이미 이동한 resource 전체를 reverse-order rollback하도록 self-test 경로를 마련했다.

Chat의 현재 DevSpace terminal surface는 사용자 media file move 실행을 허용하지 않으므로 이 milestone에서 real-library mutation은 의도적으로 수행하지 않았다. local CLI의 explicit `--apply` 경로가 다음 실전 단계다.

## 2026-09-04 — 첫 real-library reversible quarantine 적용

`~/Pictures`와 세 개의 Google Takeout root에서 planner가 `automatic_redundant`로 판정한 exact duplicate만 대상으로 첫 실제 quarantine을 수행했다. REVIEW, Takeout-only semantic duplicate, perceptual similarity 후보는 제외했다.

검증 결과:

```text
automatic plan items                 2262
moved resources                      4195
manifest state                   complete
source files still present              0
missing quarantine destinations         0
destination size mismatches              0
```

재scan 전후 비교:

```text
recognized resources      30240 -> 26045
logical assets             8178 -> 8178
logical Live Photos        2710 -> 2710
local complete Live Photos 1604 -> 1604
post-quarantine AUTO resources          0
remaining review resources           7805
```

따라서 첫 실제 mutation은 계획한 4,195개 resource만 reversible quarantine으로 이동했고, local canonical Live Photo completeness와 logical asset graph는 변하지 않았다. restore manifest는 local quarantine에만 보존하며 repository에는 포함하지 않는다.

## 2026-09-04 — Post-quarantine semantic collapse 개선

첫 real-library quarantine 뒤 남은 review를 두 종류로 분해했다. same-identifier Live Photo occurrence를 root당 한 덩어리로 보던 scanner를 개선해 embedded identifier를 identity authority로 유지하면서 directory/basename을 boundary hint로 occurrence를 partition했다. 이 변경만으로 22 Live Photo item / 44 resource가 추가 canonical-coverage AUTO로 승격했다.

Takeout-only standalone exact copy는 물리 파일을 줄이기 전에 원래 Takeout source-folder hierarchy와 logical asset membership을 local SQLite `collections`/`memberships`에 보존하도록 구현했다. collection 이름/path는 agent-safe output에 노출하지 않는다. 실제 library에서 source semantics capture 후 3,765 exact group의 physical excess 3,769 resource가 AUTO로 전환됐다.

최신 agent-safe plan:

```text
automatic items/resources        3787 / 3813
  Takeout source-folder captured 3765 / 3769
  Live Photo canonical coverage    22 /   44
review items/resources            190 /  227
  no complete preferred Live      186 /  220
  uncovered Live variant            4 /    7
```

3,813 AUTO resource는 fresh SHA-256 quarantine dry-run을 통과했고 `filesModified=false`였다. 남은 227 resource는 대부분 local과 Takeout 모두 paired video가 확인되지 않는 still-only Live Photo resource이므로 Live Photo atomicity 원칙상 자동 제거하지 않는다.

## 2026-09-04 — 두 번째 real-library reversible quarantine 적용

Post-quarantine semantic collapse에서 새로 AUTO로 승격된 3,787 item / 3,813 resource를 같은 연습용 quarantine에 실제 적용했다.

```text
moved resources                      3813
manifest state                   complete
source files still present              0
missing quarantine destinations         0
destination size mismatches              0
recognized resources      26045 -> 22232
logical assets             8178 -> 8178
logical Live Photos        2710 -> 2710
post-quarantine AUTO resources          0
remaining exact-review resources       227
```

첫 번째와 두 번째 quarantine을 합치면 exact evidence로 안전하게 격리한 resource는 총 8,008개다. 두 번 모두 permanent deletion 없이 reversible quarantine만 수행했고 logical asset/Live Photo count는 유지됐다.

## 2026-09-04 — Quarantine restore lifecycle 완료

`photoarchive restore-quarantine`을 추가했다. completed manifest만 허용하고 기본은 dry-run이다. original source가 비어 있는지 확인한 뒤 quarantined resource를 expected size와 local SQLite에 남은 원래 exact SHA-256으로 fresh 검증하고, `--apply`에서만 source로 돌려놓는다. apply 중 실패하면 이미 복원한 resource를 다시 quarantine으로 reverse-order rollback한다. agent-safe report에는 manifest/source/destination path와 hash를 포함하지 않는다.

Synthetic test에서 restore dry-run/apply, tampered quarantined byte 거부, byte-identical source 복원, restore-state 생성, agent-safe redaction을 검증했다. 또한 실제 두 quarantine의 기존 v1 manifest를 mutation 없이 dry-run 검증했다.

```text
first legacy session    2262 items / 4195 resources   PASS
second legacy session   3787 items / 3813 resources   PASS
files modified                                        0
```

첫 legacy manifest에는 stricter Live Photo mutation invariant 이전에 생성된 `photo` 단독 item 24개가 있어, legacy restore는 manifest 전체를 하나의 rollback session으로 원상복귀하는 compatibility 경로로 처리한다. 이후 새 manifest는 source-relative path를 기록하고 strict Live Photo item completeness를 요구한다. 이 실제 restore preflight까지 통과했으므로 quarantine forward/restore lifecycle은 현재 필요 수준에서 완료로 닫고, 더 복잡한 recovery subsystem은 실제 실패 사례가 생길 때만 다시 연다.

## 2026-09-04 — Stable identity와 organization planning

Path를 physical identity로 취급하지 않도록 same-volume filesystem resource identifier와 resource location/original-name history를 catalog에 추가했다. Synthetic regression에서 파일 rename 후 resource ID가 유지되고 old/new path history가 모두 남는 것을 확인했다.

Optional `.photoarchive-root` marker와 catalog binding을 추가했다. Synthetic root를 다른 directory path로 이동한 뒤 재scan해도 같은 root ID가 유지됐다. Existing real root에는 marker를 자동 생성하지 않으며 explicit `photoarchive root init --apply PATH`가 필요하다.

`photoarchive organize-plan`은 local/Apple-direct root의 `IMG_####` / `IMG_E####` camera-style filename만 capture wall-clock 기반 `YYYY-MM-DD_HH-mm-ss[_NN]` flat destination으로 제안한다. Live Photo는 complete still+paired-video를 동일 basename item으로 처리하고 custom filename, incomplete pair, multiple physical representation은 review에 남긴다. EXIF `DateTimeOriginal`의 timezone이 빠져도 local wall-clock 자체는 filename에 사용할 수 있지만 filesystem creation fallback은 automatic rename authority로 사용하지 않는다.

Real-library agent-safe dry-run summary:

```text
automatic items/resources      2765 / 4292
review items/resources          628 /  795
  capture-time fallback          58 /   58
  custom-name Live Photo         77 /  154
  incomplete Live Photo         394 /  415
  multiple representation        99 /  168
```

`~/Pictures`에 stable root marker를 명시적으로 초기화한 뒤 위 AUTO 집합을 실제 적용했다. Session `SF1EB17E28C164FDA85AC4D4AFB7D6100`은 `2,765` item / `4,292` resource를 complete manifest로 기록했고, postcondition에서 old source 잔존 0, destination 누락 0, destination size mismatch 0을 확인했다. 재검증 결과 resource `22,232`, logical asset `8,178`, logical Live Photo `2,710`, exact reconciliation `AUTO 0 / REVIEW 227`이 유지됐다.

적용 후 capture-time 이름으로 이미 flat 정리된 Live Photo 1,527개를 `custom_filename_preserved` REVIEW로 다시 표시하던 idempotence 문제를 수정했다. planner는 expected capture-time stem과 root-level same-basename pair가 이미 성립하면 완료된 no-op로 제외한다. 실제 library post-plan은 다시 `AUTO 0`, 원래 보류만 `628 item / 795 resource`로 복원됐다. `photoarchive organize` executor는 marker-gated dry-run/apply, Live Photo atomic same-basename move, post-move filesystem identity/size verification, stable resource ID 기반 SQLite path/location-history transaction, session rollback과 local restore manifest까지 현재 필요 수준에서 완료로 닫는다.

`cleanup-empty-dirs`를 추가해 전체 library의 임의 빈 폴더가 아니라 위 completed organization manifest에서 실제 파일이 빠져나간 source path와 catalog `resource_locations` history가 일치하는 directory chain만 cleanup 후보로 만든다. stable root marker를 요구하고 package/symlink boundary를 거부하며 apply 순간에도 literal empty인지 재검증한다. real organization manifest dry-run 결과는 412 directory였고, count-only 검증에서 `.photoslibrary` 내부 0, Takeout 0, `Pictures` root 자체 0이었다.

이후 같은 completed organization manifest에 실제 `cleanup-empty-dirs --apply`를 수행했다.

```text
verified empty directories before apply   412
removed directories                       412
remaining candidates after apply            0
```

적용 직전 후보 수가 기존 dry-run과 동일했고, apply 뒤 같은 manifest를 즉시 다시 dry-run하여 잔여 후보가 0임을 확인했다. cleanup 범위는 manifest + catalog location history로 제한되며 registered root 자체, package/symlink boundary, unrelated empty directory는 대상이 아니다. 이로써 real-library organization 후 빈 source directory 정리는 현재 범위에서 완료로 닫는다.

## 2026-09-04 — Product North Star 고정

최초 제품 목적을 `docs/PROJECT_NORTH_STAR.md`와 `AGENTS.md`의 explicit scope gate로 고정했다.

Core completion은 iPhone/Apple, Mac, Google Photos/Takeout, HDD에 흩어진 같은 촬영물을 reconcile하고 Live Photo resource 관계를 보존하며, 사용자 provenance preference를 적용하고, 사람이 읽을 수 있는 folder archive를 만들고, copy를 검증하며, portable provider-neutral semantic state를 유지하는 것을 의미한다.

이 완료 기준이 real library에서 안정적으로 동작하기 전에는 직접 기여하지 않는 기능을 보류한다. 공식 framework가 충분하면 공식 경로를 우선하고, Czkawka/Krokiet, rclone, ExifTool, osxphotos, ffprobe처럼 성숙한 외부 도구가 재구현보다 강한 영역은 재사용한다. PhotoArchiveKit은 provider-neutral asset relationship, Live Photo safety, provenance preference, canonical coverage와 archive decision을 소유한다.

AI-agent privacy도 North Star에 포함한다. agent-safe CLI/API에서는 media byte, raw fingerprint, filename/path, capture timestamp 같은 file-level private detail을 제거하고 opaque ID/status만 전달한다.

## 아직 필요한 Validation

완료된 fixture만으로 다음 내용을 가정해서는 안 된다.

- Google Takeout Live Photo byte fidelity와 sidecar schema
- edited Live Photo의 original/current/adjustment 보존
- file variant 전반의 timed `still-image-time` validation
- 모든 Apple device, OS, codec, camera-format 조합
- Google Photos API로 still+video에서 하나의 composite Live Photo 생성 가능 여부
- fully automatic semantic folder classification 정확도
