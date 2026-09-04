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
swift run photoarchive-selftest
```

scanner는 media에 대해 read-only다. 명시적으로 선택한 SQLite catalog만 쓴다.

## 제품 결정

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
- Czkawka가 설치된 대규모 library에서는 exact candidate discovery accelerator와 perceptual similarity engine으로 활용하는 방향을 선호한다. final asset decision과 destructive-operation 재검증은 PhotoArchiveKit이 소유한다.

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
- `canonical coverage`를 추가 분석한 결과, non-Takeout complete canonical pair가 있고 해당 logical asset의 모든 Takeout resource가 역할별 exact copy로 완전히 cover되는 경우 repeated occurrence pairing을 먼저 풀지 않아도 안전하게 Takeout set 전체를 redundant로 볼 수 있다. 이 rule을 적용하면 mixed exact Takeout resource 4,466개 중 약 4,245개를 자동 후보로 설명할 수 있고 약 221개만 실제 review/partitioning 대상으로 남는다.
- Takeout-only exact group 4,189개에는 redundant media occurrence 4,193개가 있으며 약 35.19 GiB다. album/collection semantics를 catalog로 옮기기 전에는 자동 제거하지 않는다.

private fixture와 temporary catalog는 repository에 포함하지 않는다.

## 알려진 제한사항

- archive copy, rename, move, quarantine, delete, cloud upload command가 아직 없다.
- Live Photo timed `still-image-time` metadata를 strict하게 parse하지 않는다.
- still-side identifier extraction은 격리되어 있지만 현재 iPhone file에서 관찰한 ImageIO MakerApple entry를 따른다. 추가 format fixture가 필요하다.
- source-root identity는 현재 canonical path를 따른다. stable movable ID와 root marker가 구현되기 전에는 Inbox/archive root를 이동하면 새 root record가 만들어진다.
- versioned JSONL catalog export/restore가 없다.
- SQLite persistence 외 incremental metadata/hash cache optimization이 없다.
- event grouping은 time-based만 구현되어 있으며 archive-guided semantic folder prediction은 계획 단계다.
- 같은 source root 안에서 동일 Live Photo identifier의 반복 copy는 현재 하나의 ambiguous occurrence로 요약된다. duplicated export folder를 위한 occurrence partitioning이 필요하다. 다만 canonical coverage가 성립하는 current Takeout cleanup에서는 occurrence partitioning 없이도 반복 exact copy 상당수를 안전하게 처리할 수 있다.
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
- 미래 mutating command는 missing path를 해석하기 전에 archive-root marker를 추가하고 검증해야 함

## 다음 구체 작업

1. explicit provenance와 exact/Live Photo evidence를 이용한 read-only preferred-representation reconciliation plan 추가. 기본 policy는 quality가 동등하면 non-Takeout을 Google Takeout보다 우선한다.
2. reconciliation plan에 canonical coverage를 구현한다. non-Takeout complete pair가 있고 해당 logical asset의 모든 제거 대상 Takeout resource가 역할별 exact copy로 cover되면 repeated occurrence 내부 pairing을 먼저 확정하지 않아도 Takeout set 전체를 automatic redundant candidate로 제안한다.
3. canonical coverage로 풀리지 않는 약 221 mixed-exact Takeout resource를 위해 same-identifier occurrence partitioning을 구현한다. embedded identifier는 pairing authority로 유지하고 directory/co-location, basename, source export structure, exact equivalence는 partition hint로만 사용한다.
4. Czkawka adapter를 large-library exact candidate accelerator + perceptual image/video similarity engine으로 설계한다. raw Czkawka hash/cache는 local adapter 안에 두고 agent에는 opaque group만 전달한다. destructive plan/apply 직전에는 native fresh hash/direct byte verification을 수행한다.
5. Takeout-only exact duplicate를 한 physical representation으로 collapse하기 전에 album/collection membership 등 필요한 Takeout semantics를 catalog로 import한다.
6. mutation 전에 stable movable root ID와 archive-root marker 추가
7. strict Live Photo timed-metadata validation 추가
8. versioned sanitized JSONL catalog export/restore 추가
9. canonical capture-time 및 reversible rename-plan rule 정의
10. 기존 folder를 example로 사용하는 event-level archive-folder learning 추가
11. apply 전에 immutable archive destination plan 추가
12. North Star archive workflow가 real library에서 안정화되기 전에는 Google upload와 broader provider convenience를 보류

## 재개 지점

동작을 변경하기 전에:

```bash
git status --short --branch
swift build
swift run photoarchive-selftest
```

그 다음 이 파일과 `MILESTONES.md`를 읽어 private ingest validation을 반복하지 않는다.
