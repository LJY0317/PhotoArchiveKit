# 현재 상태

마지막 업데이트: 2026-09-04

## 저장소

- GitHub repository: `LJY0317/PhotoArchiveKit`
- Primary local checkout: `~/LJY Projects/PhotoArchiveKit`
- 기본 개발 branch: `dev`
- 안정화 branch: `main`
- 기본 운영: 작은 단위는 local commit, remote push는 의미 있는 checkpoint에서만 수행
- License: MIT
- 기본 README 언어: English
- 한국어 counterpart: `README.ko.md`

## 구현됨

현재 repository에는 다음을 포함한 초기 local-first Swift package가 있다.

- `PhotoArchiveCore` library
- `photoarchive` CLI
- `photoarchive-selftest` synthetic validation executable
- local SQLite catalog
- 여러 configurable scan root
- ImageIO still-image metadata probe
- AVFoundation QuickTime metadata probe
- embedded identifier 기반 Live Photo grouping
- Live Photo identifier를 위한 catalog-local HMAC 보호
- root별 Live Photo completeness report
- opaque report ID를 사용하는 local exact duplicate grouping
- timezone-aware capture-time model
- time-gap 기반 event folder suggestion
- 사람이 읽는 output과 local diagnostic `--json`
- filename/path, byte size, capture timestamp, catalog path 등을 제거하는 AI agent용 `--agent-json` privacy-minimized output
- read-only `photoarchive plan` preferred-representation reconciliation: non-Takeout exact copy 우선, Live Photo canonical coverage, repeated same-identifier occurrence partitioning, Takeout source-folder semantics 보존 후 standalone Takeout-only exact collapse, unresolved Live Photo variant review
- `photoarchive quarantine`: 기본 dry-run, `--apply`에서만 `automatic_redundant` exact 후보를 사용자 지정 local quarantine으로 이동. apply 직전 source/preferred의 regular-file·size·symlink boundary와 fresh SHA-256을 재검증하고, Live Photo item은 전체 resource가 검증된 뒤 이동하며, session 실패 시 이미 이동한 resource를 전체 rollback. 완료 session에는 local restore manifest를 남김
- `photoarchive restore-quarantine`: 완료된 manifest를 기본 dry-run으로 역검증하고, original source가 비어 있는지와 quarantined resource가 local SQLite의 원래 exact SHA-256과 여전히 같은지 확인한 뒤 `--apply`에서만 복원. 실패 시 이미 복원한 resource를 다시 quarantine으로 rollback하며 agent-safe output에는 path/hash를 노출하지 않음
- same-volume filesystem resource identifier + `resource_locations` history로 rename/move 후에도 physical resource ID를 유지하고, 최초 filename을 `resource_original_names`에 보존
- `.photoarchive-root` stable marker 생성/인식과 marker key -> catalog root binding. marker가 유지되면 root directory 자체가 이동해도 기존 root ID를 재사용
- `photoarchive organize-plan`: `IMG_####` / `IMG_E####` camera-style filename만 대상으로 local capture wall-clock 기반 `YYYY-MM-DD_HH-mm-ss[_NN]` flat rename/move proposal 생성. custom filename, incomplete Live Photo, multiple physical representation은 review
- `photoarchive organize`: 기본 dry-run, `--apply`에서만 marker가 있는 local root의 AUTO organization item을 move. Live Photo still+paired-video는 동일 destination basename을 사용하고 post-move filesystem ID/size 확인, session rollback, local restore manifest를 제공
- 선택적 `--exact-engine czkawka`: Czkawka cache/prehash candidate discovery 후 native SHA-256 재검증; 기본 `automatic`은 현재 native exact path
- 필수 third-party binary 없이 optional tool 감지
- mixed local, Apple-direct, Google Takeout, Google web root를 구분하는 explicit source provenance
- 상위 local library 안에 Takeout root가 있어도 가장 구체적인 등록 root가 파일을 소유하도록 하는 nested-root ownership
- filename이 같아도 내용이 다르면 identity로 합치지 않고 경고하는 filename collision 검출
- GPS/description은 읽지 않고 `title`과 `photoTakenTime`만 사용하는 최소 Google Takeout sidecar capture-time import
- 영어/한국어 project overview
- 날짜가 명시된 Google Photos 및 Apple PhotoKit capability 문서
- validation 및 optional integration 문서
- issue form, pull-request template, CI, public-tree privacy safeguard
- 기존 archive folder를 활용하는 automatic-first, event-level organization 정책

현재 command:

```bash
swift run photoarchive doctor
swift run photoarchive scan [options] ROOT...
swift run photoarchive plan [options] ROOT...
swift run photoarchive organize-plan [options] ROOT...
swift run photoarchive organize [--apply] [options] ROOT...
swift run photoarchive root inspect PATH
swift run photoarchive root init [--apply] PATH
swift run photoarchive quarantine --to PATH [--apply] [options] ROOT...
swift run photoarchive restore-quarantine [--apply] [--catalog PATH] MANIFEST
swift run photoarchive-selftest
```

`scan`, `plan`, `organize-plan`은 media에 대해 read-only다. `quarantine`과 `organize`는 기본 dry-run이며 명시적 `--apply`에서만 제한된 AUTO item을 이동한다. `organize --apply`는 stable root marker를 필수로 요구한다. 영구 삭제는 없다.

## 제품 결정

- **Live Photo atomicity는 최상위 safety invariant다.** still/paired-video 중 하나를 건드리는 copy/move/rename/quarantine/delete/archive/projection operation은 완전한 logical asset/occurrence resource set으로 확장하거나 실패한다. provenance preference, exact dedupe, 성능 최적화보다 이 규칙이 우선한다.
- `docs/PROJECT_NORTH_STAR.md`가 scope gate다. real library에서 duplicate reconciliation, Live Photo 보존, preferred representation 선택, folder archive plan, verified copy, portable semantic state가 안정적으로 동작하기 전에는 주변 기능으로 확장하지 않는다.
- portable filesystem archive가 media truth를 저장한다.
- SQLite가 semantic truth와 provider-neutral desired organization을 저장한다.
- 수동 작업량은 개별 사진 수가 아니라 ambiguous event group 수에 비례해야 한다.
- 기존 archive folder는 향후 local classifier의 labeled example이 된다.
- Google Photos에서 album projection을 못 하더라도 eligible ordinary media의 flat upload는 유용한 미래 기능이다.
- 검증된 Live Photo를 unrelated still/video로 나눠 업로드한 뒤 preserved라고 보고해서는 안 된다.
- Apple PhotoKit은 Live Photo 생성과 editable album membership을 위한 우선 projection 경로다.
- dependency 선택은 원칙적으로 `공식 지원 API/framework > 성숙한 best-of-breed 외부 도구 > 자체 재구현` 순서다. 다만 Live Photo asset graph, provenance, preferred representation, archive transaction처럼 PhotoArchiveKit이 반드시 소유해야 하는 semantic/safety logic은 core에 남긴다.
- optional rclone, Czkawka CLI, ExifTool, osxphotos, ffprobe adapter는 required core와 분리한다.
- required metadata core는 ImageIO/AVFoundation과 최소 Takeout sidecar importer로 현재 archive workflow에 필요한 좁은 촬영시각·QuickTime·Live Photo linkage 역할을 수행한다. ExifTool 수준의 broad metadata coverage가 필요해지면 같은 범용 parser를 직접 확대하기보다 ExifTool을 우선 평가한다.
- osxphotos는 required dependency가 아니다. Apple Photos library query/export/album/original-edited interoperability가 필요할 때 자체 구현과 비교해 더 완전하고 검증된 경로라면 optional bridge로 활용한다. 같은 기능을 공식 PhotoKit이 더 안전하고 완전하게 제공하면 PhotoKit을 우선한다.
- AI agent는 media-processing trust boundary 밖에 둔다. 정상 agent workflow는 `--agent-json`을 사용하며 raw hash/identifier/GPS뿐 아니라 filename/path, capture timestamp, exact byte size 같은 file-level private detail도 agent에 전달하지 않는다.
- Google Photos Photo Stack/Top pick은 exact dedupe가 아니라 human-in-the-loop best-shot curation 단계로 취급한다. 사용자의 정상 루틴은 iPhone 촬영 -> Google Photos backup/Top-pick review -> Mac ingest -> 필요 시 Krokiet/Czkawka residual similarity review -> PhotoArchiveKit exact/Live Photo reconciliation -> archive 순서다. Google Photos API는 documented Top-pick/stack-membership 상태를 노출하지 않으므로 second-pass 자동화는 사용자가 UI에서 Top pick을 승인하고 필요하면 Picker API로 survivor를 직접 선택한 뒤 local candidate에 매핑하는 범위로 제한한다.
- Top pick을 사용했다고 batch가 similarity-free라고 가정하지 않는다. Google이 남긴 후보가 마음에 들지 않거나 여러 후보를 유지한 경우에만 Mac에서 Krokiet/Czkawka Similar Images/Videos를 추가 review 도구로 사용한다.
- residual 후보가 여전히 애매하면 Krokiet/Czkawka로 작은 candidate set을 만든 뒤 Google Photos Top pick을 선택적으로 다시 활용할 수 있다. 이때 Google은 canonical file transport가 아니라 decision UI로 사용하고, 선택된 Top pick에 대응하는 Mac의 original resource/Live Photo pair를 보존한다. 후보 재업로드가 반드시 새 Photo Stack을 만들거나 ranking을 다시 실행한다고 가정하지 않는다.
- Czkawka exact mode는 현재 native engine보다 real-library benchmark상 빠르지 않았으므로 `automatic` exact engine은 native를 유지한다. Czkawka exact는 독립 cross-check, Czkawka의 주된 장기 가치는 byte가 다른 similar image/video review candidate 생성이다.

## 검증

로컬에서 완료된 항목:

- `swift build` 통과
- `swift run photoarchive-selftest` 통과
- `scripts/check-public-tree.sh` 통과
- self-test가 synthetic exact copy 두 개를 두 번 scan하여 다음을 확인함:
  - opaque duplicate group 1개
  - logical standalone asset 1개
  - scan 간 stable opaque group ID
  - input byte 불변
  - serialized report에 알려진 raw hash가 없음
- disposable 5-source iPhone/Google fixture scan 결과:
  - media resource 29개
  - logical asset 8개
  - logical Live Photo 3개
  - exact duplicate resource group 7개
  - ordinary AirDrop의 still-only warning 3개
  - media 수정 없음
- Google web 비교 경로를 바로잡은 뒤 fixture를 다시 scan했다. 테스트한 모든 Google Photos web resource는 Image Capture counterpart와 byte-identical이었으며 motion resource filename이 `.MOV`가 아니라 `.MP4`여도 동일했다.
- real library의 기존 Krokiet/Czkawka cache를 재사용해 `czkawka_cli` exact scan을 재현했다. 주요 photo/video extension 기준 8,269 exact group, 8,739 redundant occurrence, 약 76.66 GiB가 확인되었다.
- local-library와 Google-Takeout을 동시에 포함한 exact group은 Czkawka와 PhotoArchiveKit이 동일하게 4,052개를 찾았고, 그 안의 Takeout resource도 양쪽 모두 4,466개였다.
- occurrence 단위의 초기 보수적 rule에서는 Takeout resource 3,479개가 automatic candidate였고 987개가 hold였다. 이 hold는 perceptual similarity가 아니라 개별 file hash가 이미 exact match인 Live Photo resource였다.
- 구현된 `photoarchive plan`의 canonical coverage를 real library에 적용한 최종 기준값은 mixed exact Takeout resource 4,466개 = `automatic 4,195 + review 271`이다. automatic은 standalone 739개 + Live Photo canonical-coverage resource 3,456개이며, review는 complete preferred Live Photo가 없는 exact resource 270개 + uncovered exact variant 1개다. 이전 수동 SQL의 약 4,245/221은 근사치였으므로 이 planner 결과로 대체한다.
- 같은 real library에서 `--exact-engine czkawka`와 `--exact-engine native`가 동일한 reconciliation plan을 생성했다.
- wall-clock benchmark는 `Czkawka candidate discovery + native verification` 약 37.66초, native-only 약 36.21초였다. 현재 hybrid는 이중 작업 때문에 더 빠르지 않으므로 `automatic`은 native를 유지한다.
- quarantine executor가 Live Photo plan을 독립적으로 atomicity 재검증하도록 강화했다. synthetic test에서 4-resource covered Live Photo 중 1개 resource를 제거한 tampered plan은 mutation 전에 `livePhotoAtomicityViolation`으로 거부되고, 정상 plan은 preferred still+paired-video를 함께 보존하면서 redundant resource set 전체를 함께 quarantine한다.
- Apple PhotoKit은 local still + paired-video file을 하나의 Photos Live Photo asset으로 생성하는 documented composite route를 제공한다. Google Photos public upload API는 여전히 개별 `simpleMediaItem`만 문서화하며 composite Live Photo creation route는 없다. Google Photos iPhone/iPad app은 Photos library의 Live Photo backup을 지원하므로 filesystem/Drive 복원은 `pair validation -> PhotoKit composite import -> iOS Photos -> Google Photos app backup`이 현재 권장 경로다.
- 첫 quarantine 이후 남은 Takeout-only standalone exact group에 대해 source-folder hierarchy와 logical-asset membership을 local SQLite `collections`/`memberships`에 보존하도록 구현했다. collection 이름/path는 agent-safe output에 노출하지 않는다. 이 semantic capture 뒤 real-library planner는 3,765 group에서 physical excess 3,769 resource를 AUTO redundant로 승격했다.
- 첫 real-library quarantine dry-run을 `~/Pictures` + Takeout 3개 root와 별도 연습용 quarantine target에 대해 수행했다. 강화된 regular-file/size/symlink-boundary + fresh SHA-256 preflight에서 `2,262` AUTO item / `4,195` resource가 통과했다.
- 이어 같은 AUTO 집합을 실제 quarantine에 적용했다. manifest는 `state=complete`, `4,195` move를 기록했고 postcondition 전수검사에서 source 잔존 0, destination 누락 0, destination size mismatch 0이었다. 재scan 결과 resource는 `30,240 -> 26,045`로 정확히 4,195 감소했지만 logical asset `8,178`, logical Live Photo `2,710`, local-library complete Live Photo `1,604`는 모두 그대로였다.
- 이후 same-identifier occurrence를 directory/basename boundary hint로 partition하되 embedded identifier를 identity authority로 유지하도록 개선했다. real-library에서 추가 22 Live Photo item / 44 resource가 canonical coverage AUTO로 승격했다.
- Takeout source-folder semantics capture까지 적용한 다음 real-library plan은 `3,787` AUTO item / `3,813` resource와 `190` REVIEW item / `227` resource였다. AUTO = source-folder semantics가 보존된 Takeout-only standalone exact excess `3,769` + 새로 partition된 Live Photo canonical coverage `44`. 이 3,813개는 두 번째 real-library quarantine에 실제 적용됐고 manifest `complete`, source 잔존 0, destination 누락 0, size mismatch 0을 확인했다. resource는 `26,045 -> 22,232`, logical asset `8,178`, logical Live Photo `2,710`은 유지됐다. 현재 exact reconciliation은 AUTO 0 / REVIEW 227이다.
- synthetic self-test에서 standalone non-Takeout preferred copy를 유지하면서 exact Takeout copy만 quarantine으로 이동하고, 이동된 byte가 동일하며 restore manifest가 생성되고 agent-safe quarantine report에 path/filename이 노출되지 않음을 확인했다. 같은 fixture에서 restore dry-run/apply, tampered quarantined byte 거부, source 원위치 복원, restore-state 생성, agent-safe path redaction도 검증했다.
- 두 real quarantine의 기존 v1 manifest도 `restore-quarantine --agent-json` dry-run을 통과했다: 첫 session `2,262 item / 4,195 resource`, 둘째 `3,787 item / 3,813 resource`, 둘 다 `filesModified=false`. 첫 legacy manifest의 과거 `photo` 단독 item 24개는 manifest 전체를 session 단위로 역복구하는 compatibility 경로로 취급하고, 새 manifest는 source-relative path와 strict Live Photo item completeness를 요구한다.
- synthetic tracking test에서 같은 volume의 file rename 후 resource ID가 유지되고 old/new path가 location history로 남으며, `.photoarchive-root`가 있는 root directory 자체를 다른 path로 이동한 뒤에도 root ID가 유지됨을 확인했다.
- organization synthetic apply test에서 `IMG_1234.HEIC + IMG_1234.MOV`가 같은 capture-time destination basename으로 함께 이동하고 custom filename은 보존되며 marker gate, post-move filesystem ID/size, restore manifest, agent-safe path redaction이 동작함을 확인했다.
- real-library `organize-plan --agent-json` 최신 결과는 `2,765` AUTO item / `4,292` resource, `628` REVIEW item / `795` resource다. AUTO는 trusted timestamp 또는 timezone이 빠진 EXIF local wall-clock을 가진 iPhone camera-style filename이고, REVIEW는 filesystem fallback `58`, custom-name Live Photo `154 resource`, incomplete Live Photo `415 resource`, multiple physical representation `168 resource`다. 실제 rename/move는 아직 0개다.

private fixture와 temporary catalog는 repository에 포함하지 않는다.

## 알려진 제한사항

- verified HDD archive copy, permanent delete, cloud upload는 아직 없다. `organize`는 same-session deterministic camera-name rename/flatten 전용이며 persisted plan replay나 general-purpose move command가 아니다.
- Live Photo timed `still-image-time` metadata를 strict하게 parse하지 않는다.
- still-side identifier extraction은 격리되어 있지만 현재 iPhone file에서 관찰한 ImageIO MakerApple entry를 따른다. 추가 format fixture가 필요하다.
- stable root marker 기능은 구현됐지만 기존 real roots에는 자동으로 marker를 쓰지 않는다. 각 root는 사용자가 `photoarchive root init --apply PATH`를 명시적으로 실행한 뒤부터 relocation identity를 가진다.
- versioned JSONL catalog export/restore가 없다.
- SQLite persistence 외 incremental metadata/hash cache optimization이 없다.
- event grouping은 time-based만 구현되어 있으며 archive-guided semantic folder prediction은 계획 단계다.
- same-identifier occurrence partitioning은 현재 same embedded identifier 안에서 directory와 basename을 boundary hint로 사용하는 보수적 1차 구현이다. 같은 directory/stem 안에 여러 still/video가 겹치거나 complete pair가 어디에도 없는 경우는 review에 남긴다.
- standalone exact copy는 exact-duplicate hashing이 켜진 경우에만 하나의 logical asset으로 합쳐진다. scan mode 간 stable identity가 필요하다.
- PhotoKit, Google Photos, Takeout, rclone, Czkawka, ExifTool, ffprobe 실행 adapter가 아직 없다.
- Google Photos public API는 full existing-library reconciliation interface로 취급할 수 없다.
- Google Photos public upload documentation에는 현재 project가 검증한 composite Live Photo creation route가 없다.
- dependency-free `photoarchive-selftest`가 required local regression check이며, 일반적인 unit/integration CI를 위해 더 폭넓은 public media fixture가 필요하다.

## 안전 상태

- permanent deletion 없음
- background process 없음
- core의 network request 없음
- agent-safe report에 raw hash나 raw Live Photo identifier 없음
- `--agent-json`은 filename/path, catalog path, exact byte size, capture timestamp, suggested folder name도 제거함
- catalog-local keyed fingerprint를 만든 직후 in-memory probe record에서 raw Live Photo identifier를 제거함
- private media extension과 runtime database는 Git에서 ignore됨
- `quarantine`과 `organize`는 오래된 plan을 replay하지 않고 같은 invocation에서 current root를 scan한 뒤 precondition을 다시 검증하는 제한된 mutation이다. persisted/offline plan replay, archive copy, missing-root reconciliation은 user-initialized stable root marker와 immutable persisted plan/approval token을 함께 요구해야 함

## 다음 구체 작업

1. 남은 `227` mixed-exact Live Photo review는 complete paired-video evidence가 없는 still-only asset이 대부분이므로 자동 제거하지 않는다. additional source/backup/HDD에서 paired video를 찾거나 strict restore evidence가 생길 때만 재평가한다.
2. quarantine의 forward/restore lifecycle은 현재 필요 수준에서 완료로 닫는다. interrupted-session resume은 향후 HDD archive copy/apply에서 실제 필요성이 생길 때 구현한다.
3. 현재 organization REVIEW의 `multiple_physical_representations` 168 resource는 exact-deletion hold와 별개다. preferred representation 선택을 더 강화한 뒤 rename/flatten 대상으로 재평가한다.
4. Czkawka image/video similarity adapter는 residual human review가 실제 bottleneck이 될 때만 추가한다. 현재 core archive 흐름보다 앞서지 않는다.
5. native incremental hash cache를 설계해 unchanged file의 full SHA-256 재계산을 줄인다. Czkawka exact accelerator는 이중 hashing을 피할 수 있을 때만 benchmark 후 `automatic` 후보로 재평가한다.
6. preferred-representation plan을 immutable persisted plan으로 발전시키고 direct byte verification 옵션과 stable replay precondition을 추가한다.
7. 실제 `~/Pictures`와 향후 HDD archive root에 stable root marker를 사용자 승인 후 초기화하고 relocation fixture를 real filesystem에서 확인
8. organization apply 전 persisted immutable plan/approval token 및 post-apply automatic re-scan/catalog commit을 추가
9. verified empty-directory cleanup plan을 추가하되 unsupported/hidden/sidecar file이 하나라도 있으면 자동 삭제하지 않음
10. strict Live Photo timed-metadata validation 추가
11. versioned sanitized JSONL catalog export/restore 추가
12. HDD archive destination plan, verified copy, rclone replica/check adapter 추가
13. 기존 folder를 example로 사용하는 event-level archive-folder learning은 core archive flow 이후로 유지
14. North Star archive workflow가 real library에서 안정화되기 전에는 Google upload와 broader provider convenience를 보류

## 재개 지점

동작을 변경하기 전에:

```bash
git status --short --branch
swift build
swift run photoarchive-selftest
```

그 다음 이 파일과 `MILESTONES.md`를 읽어 private ingest validation을 반복하지 않는다.
