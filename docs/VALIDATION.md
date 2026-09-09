# Validation Notes

검증 날짜: **2026-09-05**

이 문서는 vendor guarantee와 local observation을 구분한다. provider behavior는 바뀔 수 있으며 sample이 통과했다는 사실은 regression observation이지 permanent Apple/Google contract가 아니다.

## Duplicate-review native scrolling (2026-09-08)

The advanced-information regression path now checks an internal hosted-SwiftUI height expansion without replacing the parent representable. The document view must keep the same identity and scroll origin while growing, the vertical scroller knob must update for the larger range, and the disclosure is intentionally non-animated so document-height-only changes do not force-retile the whole comparison viewport.

The 2026-09-09 visual-stability pass additionally keeps the default comparison-column outline anchored to the default metadata bottom while advanced rows are inserted below it. Hosted layout completion can update the AppKit document extent immediately rather than waiting for a second asynchronous layout pass. Synthetic validation cannot prove absence of a visible flash on every macOS compositor/GPU path, so release-app human verification remains the final check for that cosmetic behavior.

`bash scripts/test-review-scroll.sh` compiles a dependency-free AppKit/SwiftUI synthetic Grid harness, without opening the user's catalog or media. It checks persistent horizontal scroller geometry outside the clip viewport, overflow knob state, ordinary wheel versus Shift-wheel movement, narrow/wide window resizing, updated document dimensions, same-group position preservation and new-group reset. It uses the main run loop to allow native wheel animation to finish. The test runs with Command Line Tools and does not require XCTest or Swift Testing.

On 2026-09-09 the harness was extended after the advanced-information disclosure exposed a separate dynamic-height failure. It now also changes an observed SwiftUI model inside the already-hosted document from 1200pt to 5200pt and back to 1200pt without replacing the representable's root content. The test requires the AppKit document frame to follow both changes and verifies that the expanded document can move to a >4000pt vertical origin and return to zero. This specifically covers disclosure-driven intrinsic-size changes that the earlier parent-update-only regression test did not exercise.

The comparison Grid's row specs and final-row ID are computed once per body evaluation, rather than rebuilding all formatted metadata for every cell's anchor preference. The GUI launcher uses release optimization by default. These remove identifiable redundant work and debug overhead; they do not establish a measured frame-rate improvement on a user's media library. Interactive trackpad momentum and frame-time measurements during live resize still merit human verification in the release app.

The first isolated-scroll-view test missed a real integration failure: the root NavigationSplitView's bottom `safeAreaInset` placed the action bar over the embedded AppKit horizontal scroller. The regression harness now uses the production `ReviewWindowLayout` and checks the entire bar's visible rectangle and window coordinates above a 44-point action row at 980×640, 1100×750 and 1500×900. This check failed before replacing the inset with a separate VStack row and passed afterward. A separate release-app instance was also checked in the actual four-copy comparison screen: the bar was visible, dragging reached the last copy, and standard window zoom/restore changed between disabled (all columns fit) and enabled (overflow) while keeping the bar visible. The bounded two-copy comparison block was subsequently centered on wide windows; a separate release instance was visually checked at wide and restored widths with the standard scrollers still present. Existing review choices in the original running instance were preserved; the verification instance did not submit decisions or mutate media.

## 5경로 local sample

Disposable set에는 새 iPhone Live Photo 3개와 ordinary video 1개가 있었다. 다음 경로로 확보했다.

1. iPhone Photos -> normal AirDrop
2. iPhone Photos -> AirDrop with **All Photos Data**
3. Google Photos iOS app -> AirDrop
4. Google Photos web -> browser download
5. macOS Image Capture -> filesystem folder

personal media, raw hash, raw Live Photo identifier는 repository에 commit하지 않는다.

### Full-byte comparison

| Image Capture와 비교 | Still resource | Live motion resource | Ordinary video |
|---|---:|---:|---:|
| AirDrop + All Photos Data | identical | identical | identical |
| Google Photos web | identical | identical | identical |
| Normal AirDrop | identical | 3개 모두 absent | identical |
| Google Photos iOS -> AirDrop | transformed file | pair not preserved | transformed representation |

Google web motion filename은 `.MP4`, Image Capture는 `.MOV`였지만 이 sample에서 byte는 identical했다. 이전의 반대 결과는 잘못된 comparison path를 선택한 것이 원인이었다.

### PhotoArchiveKit scan 결과

다섯 folder를 separate source root로 함께 scan했다.

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

source-local occurrence 20개가 logical asset 8개로 합쳐지는 이유는 byte-identical ordinary media와 같은 protected linkage identifier를 가진 Live Photo copy를 unify하기 때문이다. root별 completeness는 계속 visible하므로 다른 위치의 complete copy가 normal-AirDrop occurrence의 incompleteness를 숨기지 않는다.

exact resource group 7개는 여러 경로에서 identical하게 보존된 still image 3개, motion resource 3개, ordinary video 1개다.

## Filename independence 관찰

- 올바른 still/motion pair는 두 filename을 모두 바꾼 뒤에도 Live Photo로 유지되었다.
- 한 Live Photo의 still과 다른 Live Photo의 motion resource는 basename을 같게 만들어도 Live Photo가 되지 않았다.
- test한 Google web HEIC + MP4 pair는 Apple Photos에 Live Photo로 import되었다.
- synthetic complete occurrence에서 still/video basename이 다를 때 `live_photo_verified_distinct_component_names` notice가 생성되고, basename이 같을 때는 생성되지 않는 것을 self-test로 확인했다. agent-safe scan과 archive-coverage JSON에는 notice code가 유지되지만 component filename은 포함되지 않는다.

따라서 PhotoArchiveKit은 embedded linkage evidence를 사용한다. basename은 disambiguation hint일 수 있지만 pairing authority가 아니다.

## `complete`의 의미

현재 scanner는 한 source root 안에서 recognized still 1개와 recognized motion resource 1개가 같은 protected Apple identifier를 공유하고, paired video의 timed metadata track에 int8 `com.apple.quicktime.still-image-time` marker가 정확히 하나 있으며 그 sample이 유효한 movie timeline 위치에 있을 때 occurrence를 complete라고 한다. marker payload 자체를 timestamp로 해석하지 않는다.

아직 다음을 증명하지는 않는다.

- complete media decodability
- expected audio
- edit, key-photo choice, adjustment state restoration
- future software version에서 identical behavior

Synthetic metadata-only MOV fixture에서는 single valid marker, marker absent, wrong datatype, multiple marker를 각각 `valid`, `missing`, `invalid`, `invalid`로 판정하는 것을 확인했다. 현재 real library에서 기존 complete occurrence 1,824개는 모두 strict timed-metadata validation을 통과했다. 다른 Apple device/OS/codec/export variant는 계속 별도 검증 대상으로 남긴다.

## Portable catalog snapshot 검증

Synthetic catalog에서 versioned JSONL export -> restore dry-run -> 새 SQLite apply -> fresh scan round-trip을 검증했다. snapshot은 absolute root path, known raw exact hash, known media bytes를 포함하지 않았고, restored fresh scan은 원래 opaque root/resource/asset ID를 유지하면서 exact evidence를 media에서 다시 계산했다. 별도 Takeout source-folder fixture에서는 collection hierarchy/membership/source mapping이 restore 뒤 유지되고 fresh scan에서 duplicate collection이 생기지 않았다. 기존 snapshot output이나 destination catalog를 덮어쓰는 동작은 거부된다.

이 JSONL은 relative path, original filename, collection label을 보존하므로 agent-safe/share-safe 파일이 아니라 local-private disaster-recovery artifact다.

## Scan progress 검증

Synthetic scan에서 core `ScanProgress` event가 metadata `2/2`, exact-hash `2/2`, finalizing completion을 순서대로 노출하는 것을 self-test로 검증했다. 별도 executable smoke에서는 progress가 stderr로만 출력되는 동안 `--agent-json` stdout이 정상 JSON으로 독립 parse되는 것을 확인했다. Enumeration은 total을 알기 전 discovered count만 보고하며, determinate stage가 시작된 뒤에만 percentage를 계산한다. `--no-progress`는 계산/scan 결과를 바꾸지 않고 renderer만 비활성화한다.

## User-managed archive index / incremental hash cache 검증

synthetic marker-initialized archive root에 `Trips/Japan`과 `Family` hierarchy를 만들고 `archive-index` core/CLI path를 검증했다. 첫 scan은 모든 media에 integrity SHA-256을 생성했고, SQLite에는 세 folder(`Trips`, `Trips/Japan`, `Family`)가 `user_archive_folder` collection으로 저장되며 두 logical asset이 각각 current leaf folder membership을 가졌다.

검증 결과:

```text
first archive index: exact hash cache hits                                  0
repeat on same local SQLite: unchanged hashes reused                        PASS
portable .photoarchive/inventory-v1.jsonl write with explicit apply        PASS
fresh empty SQLite catalog + same HDD inventory: portable hash reuse        PASS
archive-index --fresh: local/portable cache hits                            0
manual Finder-style move Trips/Japan -> Family                              PASS
re-index current folder count                                                1
stale Trips/Japan and Trips user-archive collections pruned                 PASS
agent-safe archive-index report omits root path and filename                PASS
hidden .photoarchive inventory excluded from media scan                     PASS
```

CLI smoke에서 media resource 2개 / represented folder 3개 fixture는 dry-run cache hit 0, 같은 catalog 재실행 cache hit 2, 새 catalog에서 portable inventory cache hit 2, `--fresh` cache hit 0을 재현했다. portable inventory는 relative path, byte size, modification time, opaque role/ID, raw SHA-256을 포함하는 **root-scoped local-private cache/map**이며 mutation authority가 아니다. `archive-copy`, quarantine 등 실제 mutation boundary는 계속 fresh SHA-256을 요구한다.

## Archive coverage / current duplicate membership 검증

`archive-coverage`는 두 개 이상의 등록 root를 current media-read-only scan한 결과에서 계산한다. standalone/photo/video resource의 exact cross-root coverage와 Live Photo logical-asset counterpart completeness를 분리해 보고한다. exact resource는 SHA-256 duplicate group, Live Photo counterpart status는 같은 logical asset의 다른-root occurrence completeness를 사용한다.

Synthetic/CLI 검증:

```text
two-root exact fixture: pairwise shared groups                         1
root A exact-covered / exact-unique                                 1 / 0
root B exact-covered / exact-unique                                 1 / 0
A+B group -> A+C rescan: stable opaque group ID                       PASS
A+B group -> A+C rescan: persisted current members                     2
ambiguous repeated Live Photo peer reported complete                  NO
ambiguous repeated Live Photo peer reported split/ambiguous          PASS
agent-safe coverage omits root path and filename                     PASS
filesModified                                                       false
```

현재 real catalog의 작은 two-root read-only 재검증에서도 reference media 2개가 모두 exact-covered였고 pairwise shared exact group 2개를 보고했다. 같은 session에서 `exact_duplicate_groups.last_seen_session`이 current session인 group들에 대해 다른 session의 stale member가 남은 수는 0이었다. 개인 path/filename/hash는 이 문서에 기록하지 않는다.

## Immutable archive plan 검증

Synthetic marked source/destination fixture에서 `archive-plan`이 non-Takeout canonical exact copy 하나만 AUTO로 선택하고, plan 시점의 fresh SHA-256을 같은 scan/catalog에 저장된 exact evidence와 다시 비교한 뒤 local-private precondition으로 고정하는 것을 검증했다. scan 뒤 source byte를 같은 크기로 바꾸면 `sourceChanged`로 plan 생성이 거부된다. destination에 같은 filename이 이미 있으면 deterministic `_NN` suffix로 충돌을 피한다.

별도 synthetic Live Photo fixture에서는 complete still + paired-video 두 resource가 하나의 AUTO item으로 유지되고 destination basename도 동일했다. source stable marker가 없는 fixture는 REVIEW로 남는다. agent-safe archive plan에는 source/destination path, filename, catalog path, marker key, byte size, SHA-256이 포함되지 않는다. plan schema v2는 이후 replay를 위해 working catalog path까지 local-private precondition으로 고정한다.

## Verified archive copy 검증

별도 synthetic catalog/source/destination에서 `archive-copy` dry-run -> apply -> completed replay를 검증했다. executor는 plan의 source resource/root/path/asset/role/size/hash를 current catalog와 다시 비교하고 source/destination marker와 fresh source SHA-256을 재검증한다. apply는 hidden `.photoarchive/staging/<plan-id>`를 사용하며 final path로 보내기 전후 full-file SHA-256을 확인한다. destination scan은 unique archive media에도 integrity SHA-256을 계산해 기존 logical asset/role과 다시 연결하고, archive `.photoarchive/catalog`에 portable JSONL snapshot을 기록한다.

검증 결과:

```text
dry-run creates no archive media                                     PASS
apply copies and verifies the canonical AUTO resource                PASS
source copies remain byte-identical and unmoved                      PASS
destination archive root/media committed to working catalog          PASS
archive-local portable catalog snapshot written                      PASS
completed replay is no-op and reuses verified final media            PASS
same-size source tamper after immutable plan rejected                PASS
plan asset-ID semantic tamper rejected by current catalog evidence   PASS
one-resource Live Photo item rejected before copy                    PASS
completed catalog snapshot byte tamper rejected                      PASS
agent-safe copy report omits path/filename/marker/hash                PASS
hidden .photoarchive control JSON cataloged as sidecars                 0
archive-plan -> archive-copy dry-run/apply/replay CLI smoke           PASS
```

Live Photo의 두 final path가 하나의 filesystem syscall로 동시에 rename된다고 가정하지 않는다. 대신 item 전체가 staging/final에서 먼저 검증되고 complete manifest는 모든 final resource, destination catalog relationship, archive snapshot이 검증된 뒤에만 기록된다. interruption이 생기면 pending manifest와 exact-verified staged/final state에서 idempotent resume한다. 실제 개인 library의 외장 HDD 대량 apply는 아직 별도 validation 대상으로 남긴다.

## Provenance 결론

byte-identical file만으로 Image Capture와 Google Photos web 중 어디에서 왔는지 알 수 없다. provenance는 file content에서 추론하지 말고 source root, declared import method, relative path, scan session에서 기록해야 한다.

## 남은 high-value test

- 한 asset이 두 album에 들어간 small test-only Google Takeout export
- Edited Live Photo: key photo, crop, color adjustment, mute, Live on/off, effect
- 추가 device/OS/codec/export variant의 timed-metadata/decode validation
- Same-second capture, subsecond, burst, timezone change, metadata-free media
- Archive pair -> PhotoKit -> Apple Photos -> Google Photos iOS -> download round trip
- rclone upload/download 후 local full-byte comparison
- 실제 사용자 HDD의 깊은 user-managed archive root를 `archive-index`로 read-only index하고, 첫 full hash pass와 incremental repeat의 wall-clock/I/O/cache-hit 비율 측정

이 test가 끝나기 전에도 architecture는 ordinary file, explicit resource relationship, source provenance, many-to-many collection, local equality group을 삭제나 rewrite 없이 안전하게 보존할 수 있다.
