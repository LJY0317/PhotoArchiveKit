# 현재 상태

마지막 업데이트: 2026-09-04

## 저장소

- GitHub repository: `LJY0317/PhotoArchiveKit`
- Primary local checkout: `~/LJY Projects/PhotoArchiveKit`
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
- 사람이 읽는 output과 sanitized JSON output
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
- optional rclone, Czkawka CLI, ExifTool, ffprobe adapter는 required core와 분리한다.

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

private fixture와 temporary catalog는 repository에 포함하지 않는다.

## 알려진 제한사항

- archive copy, rename, move, quarantine, delete, cloud upload command가 아직 없다.
- Live Photo timed `still-image-time` metadata를 strict하게 parse하지 않는다.
- still-side identifier extraction은 격리되어 있지만 현재 iPhone file에서 관찰한 ImageIO MakerApple entry를 따른다. 추가 format fixture가 필요하다.
- source-root identity는 현재 canonical path를 따른다. stable movable ID와 root marker가 구현되기 전에는 Inbox/archive root를 이동하면 새 root record가 만들어진다.
- versioned JSONL catalog export/restore가 없다.
- SQLite persistence 외 incremental metadata/hash cache optimization이 없다.
- event grouping은 time-based만 구현되어 있으며 archive-guided semantic folder prediction은 계획 단계다.
- 같은 source root 안에서 동일 Live Photo identifier의 반복 copy는 현재 하나의 ambiguous occurrence로 요약된다. duplicated export folder를 위한 occurrence partitioning이 필요하다.
- standalone exact copy는 exact-duplicate hashing이 켜진 경우에만 하나의 logical asset으로 합쳐진다. scan mode 간 stable identity가 필요하다.
- PhotoKit, Google Photos, Takeout, rclone, Czkawka, ExifTool, ffprobe 실행 adapter가 아직 없다.
- Google Photos public API는 full existing-library reconciliation interface로 취급할 수 없다.
- Google Photos public upload documentation에는 현재 project가 검증한 composite Live Photo creation route가 없다.
- dependency-free `photoarchive-selftest`가 required local regression check이며, 일반적인 unit/integration CI를 위해 더 폭넓은 public media fixture가 필요하다.

## 안전 상태

- permanent deletion 없음
- background process 없음
- core의 network request 없음
- report에 raw hash나 raw Live Photo identifier 없음
- catalog-local keyed fingerprint를 만든 직후 in-memory probe record에서 raw Live Photo identifier를 제거함
- private media extension과 runtime database는 Git에서 ignore됨
- 미래 mutating command는 missing path를 해석하기 전에 archive-root marker를 추가하고 검증해야 함

## 다음 구체 작업

1. explicit provenance와 exact/Live Photo evidence를 이용한 read-only preferred-representation reconciliation plan 추가
2. mutation 전에 stable movable root ID와 archive-root marker 추가
3. strict Live Photo timed-metadata validation 추가
4. GPS와 불필요한 metadata를 report에 노출하지 않으면서 migration에 필요한 나머지 Google Takeout sidecar evidence import
5. versioned sanitized JSONL catalog export/restore 추가
6. canonical capture-time 및 reversible rename-plan rule 정의
7. 기존 folder를 example로 사용하는 event-level archive-folder learning 추가
8. apply 전에 immutable archive destination plan 추가
9. North Star archive workflow가 real library에서 안정화되기 전에는 Google upload와 broader provider convenience를 보류

## 재개 지점

동작을 변경하기 전에:

```bash
git status --short --branch
swift build
swift run photoarchive-selftest
```

그 다음 이 파일과 `MILESTONES.md`를 읽어 private ingest validation을 반복하지 않는다.
