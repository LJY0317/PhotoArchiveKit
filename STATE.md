# 현재 상태

마지막 업데이트: 2026-09-06

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
- paired video의 QuickTime timed metadata track에서 `com.apple.quicktime.still-image-time` marker를 strict 검증하고, identifier 일치 + 정확히 1개의 valid int8 marker + 유효한 timeline 위치를 모두 만족해야 occurrence를 complete로 인정
- Live Photo identifier를 위한 catalog-local HMAC 보호
- root별 Live Photo completeness report
- 검증된 complete Live Photo의 still/video basename이 서로 다르면 `live_photo_verified_distinct_component_names` notice를 추가한다. mutation을 막거나 rename하지 않으며, agent-safe scan/archive-coverage output에는 filename/path 없이 notice code와 root ID만 전달한다.
- opaque report ID를 사용하는 local exact duplicate grouping
- exact duplicate group이 다시 관측될 때 `exact_duplicate_members`를 최신 group membership snapshot으로 전체 교체하여, 이전 scan의 unscanned/stale member가 current group에 섞이지 않도록 함. 과거 group row 자체는 history/stable ID를 위해 남을 수 있지만 current report는 current scan observation을 사용
- `photoarchive archive-coverage`: 두 개 이상의 등록 root를 current media-read-only scan한 뒤 root별 exact-covered/exact-unique resource 수, peer root별/pairwise exact group overlap, Live Photo occurrence의 `complete_elsewhere` / `split_or_ambiguous_elsewhere` / still-only / video-only / no-counterpart 상태를 report. exact resource coverage와 logical Live Photo counterpart completeness를 별도 축으로 유지하며, `--agent-json`은 root ID·kind·usage role·provenance·count/status만 노출
- timezone-aware capture-time model
- time-gap 기반 event folder suggestion
- 사람이 읽는 output과 local diagnostic `--json`
- filename/path, byte size, capture timestamp, catalog path 등을 제거하는 AI agent용 `--agent-json` privacy-minimized output
- read-only `photoarchive plan` preferred-representation reconciliation: non-Takeout exact copy 우선, Live Photo canonical coverage, repeated same-identifier occurrence partitioning, Takeout source-folder semantics 보존 후 standalone Takeout-only exact collapse, unresolved Live Photo variant review
- `photoarchive quarantine`: 기본 dry-run, `--apply`에서만 **strong** `automatic_redundant` exact 후보를 사용자 지정 local quarantine으로 이동. recognizable filename/path/capture/tie-break처럼 preference-sensitive keeper 선택은 explicit user approval이 생기기 전에는 mutation authority를 얻지 못한다. apply 직전 source/preferred의 regular-file·size·symlink boundary와 fresh SHA-256을 재검증하고, Live Photo item은 전체 resource가 검증된 뒤 이동하며, session 실패 시 이미 이동한 resource를 전체 rollback. 완료 session에는 local restore manifest를 남김
- `photoarchive restore-quarantine`: 완료된 manifest를 기본 dry-run으로 역검증하고, original source가 비어 있는지와 quarantined resource가 local SQLite의 원래 exact SHA-256과 여전히 같은지 확인한 뒤 `--apply`에서만 복원. 실패 시 이미 복원한 resource를 다시 quarantine으로 rollback하며 agent-safe output에는 path/hash를 노출하지 않음
- same-volume filesystem resource identifier + `resource_locations` history로 rename/move 후에도 physical resource ID를 유지하고, 최초 filename을 `resource_original_names`에 보존
- `.photoarchive-root` stable marker 생성/인식과 marker key -> catalog root binding. marker가 유지되면 root directory 자체가 이동해도 기존 root ID를 재사용
- `photoarchive organize-plan`: `IMG_####` / `IMG_E####` camera-style filename만 대상으로 local capture wall-clock 기반 `YYYY-MM-DD_HH-mm-ss[_NN]` flat rename/move proposal 생성. custom filename, incomplete Live Photo, multiple physical representation은 review
- `photoarchive organize`: 기본 dry-run, `--apply`에서만 marker가 있는 local root의 AUTO organization item을 move. Live Photo still+paired-video는 동일 destination basename을 사용하고 post-move filesystem ID/size 확인 뒤 stable resource path/location history를 SQLite에 transaction commit한다. catalog commit 실패 시 filesystem move 전체 rollback, local restore manifest를 제공하며 별도 full rescan은 필요하지 않음
- `organize`/`organize-plan --singleton-leaf-only`: 기존 camera-name/date organization 규칙과 safety gate를 유지하면서 clean nested singleton asset으로 scope를 좁힌다. `--preserve-name-if-date-untrusted`를 함께 쓰면 trusted capture time이 없는 standalone camera-name item만 root-level filename collision이 없을 때 원래 이름 그대로 AUTO flatten하며, 날짜 metadata를 추측하거나 덮어쓰지 않는다.
- incomplete Live Photo exact coverage: Takeout의 `still_only`/`video_only` occurrence 전체가 같은 role의 non-Takeout exact counterpart로 보존되면 complete counterpart 부재만을 이유로 REVIEW하지 않고 `live_photo_incomplete_occurrence_exact_coverage` AUTO로 분류한다. quarantine atomicity는 candidate가 닿는 occurrence마다 전체 resource set을 포함하는지 검증한다.
- role-aware canonical exact keeper: 각 registered root에 `staging`, `primary_library`, `archive`, `import_source`, `reference` 중 하나의 user-changeable usage role을 저장한다. staging/primary/archive는 **같은 root 안의** exact duplicate를 그 root의 survivor 하나로 줄일 수 있다. archive/primary는 다른 root의 replica 때문에 generic reconciliation에서 제거하지 않는다. import source는 same-root dedupe를 지원하되 Google Takeout은 source-folder semantics capture 뒤에만 허용하고, cross-root cleanup은 staging/primary/archive retained exact counterpart 또는 기존 source semantics 조건을 통과해야 한다. reference는 비교 전용 read-only라 dedupe/import cleanup authority가 없다. staging→archive offload cleanup은 별도 coverage workflow로 남긴다.
- `photoarchive cleanup-empty-dirs`: 완료된 organization manifest의 실제 source location과 SQLite `resource_locations` history가 일치하는 directory만 후보로 삼고 stable root marker/package/symlink boundary를 검증한 뒤 apply 순간에도 완전히 빈 directory만 deepest-first 제거. unrelated empty folder, registered root, Photos library package는 대상으로 삼지 않음
- `photoarchive archive-plan`: marker가 있는 archive destination에 대해 local-private immutable JSON plan 생성. logical asset별 canonical representation을 provenance/complete Live Photo/exact evidence로 선택하고, AUTO source는 scan 당시 source marker binding과 catalog exact SHA-256을 현재 filesystem marker/fresh SHA-256과 다시 비교한 뒤에만 authority를 부여한다. Live Photo는 still+paired-video가 같은 destination basename을 공유하며 existing destination collision은 deterministic suffix로 피한다. command 자체는 media를 copy하지 않음
- `photoarchive archive-copy`: immutable archive plan schema v2를 기본 dry-run으로 독립 재검증하고 `--apply`에서만 AUTO resource를 archive destination에 copy. plan에 기록된 catalog의 current resource/asset/role/exact-hash evidence, source/destination root marker, source byte/size/SHA-256을 다시 확인하고 `.photoarchive/staging/<plan-id>`에 copy한 뒤 full SHA-256을 검증한다. Live Photo item은 still+paired-video 전체가 staging/final에서 검증된 뒤 missing member를 final path로 보낸다. pending manifest와 plan byte hash, staged/final exact verification으로 interrupted session을 idempotent resume하며, 전체 final verify 뒤 archive root를 working catalog에 scan하고 `.photoarchive/catalog`에 portable JSONL snapshot을 기록. source media는 move/delete하지 않음
- `photoarchive catalog export/restore`: working SQLite의 portable semantic subset을 schema-versioned JSONL로 export하고 새 SQLite catalog에만 dry-run/`--apply` restore. snapshot은 absolute root path, raw exact hash, keyed Live Photo fingerprint/HMAC key, filesystem ID, capture timestamp/size, provider object ID, generated scan/event cache를 제외하지만 disaster recovery에 필요한 current root usage role, relative path/original filename/collection label과 opaque root/resource/asset relation은 local-private 상태로 보존. restore 후 fresh scan이 snapshot placeholder를 새 hash/linkage evidence로 rebind하면서 같은 resource의 opaque asset ID와 Takeout collection semantics를 유지
- `photoarchive archive-index`: 사용자가 이미 수동으로 분류한 marker-initialized HDD/archive root 하나를 재배치 없이 recursive index. supported media가 있는 directory와 parent hierarchy를 `user_archive_folder` collection으로 Mac-local SQLite에 보존하고, Finder에서 수동 move 뒤 재index하면 stale archive-folder membership/collection을 current structure에 맞게 prune. 기본 실행은 archive root에 아무것도 쓰지 않고, 명시적 `--apply`에서만 root의 hidden `.photoarchive/inventory-v1.jsonl` portable structure/hash cache를 기록. media는 move/rename/delete/rewrite하지 않음
- incremental metadata/exact cache: root별 cache evidence를 SQLite에서 bulk-load한 뒤 unchanged resource는 same path 또는 filesystem ID + byte size + mtime이 맞고 metadata probe cache version도 현재 parser와 일치할 때 EXIF/QuickTime/Live Photo probe 결과를 재사용한다. 이전 probe 실패와 effective capture time이 mutable Google Takeout sidecar에서 온 media는 보수적으로 다시 probe한다. exact SHA-256도 같은 stable file fact로 재사용하며 같은 volume의 manual move/rename은 filesystem ID로 path 변경 뒤에도 hash를 재사용한다. archive root는 local hash cache miss 뒤 matching stable marker의 portable inventory hash도 seed로 사용할 수 있다. scan 계열 `--fresh`는 metadata/hash cache를 무시하며, cache는 performance accelerator일 뿐 mutation authority가 아니어서 quarantine/archive-copy 등 mutation boundary는 계속 fresh SHA-256을 요구
- structured foreground scan progress: core가 `ScanProgress` event를 내고 CLI는 progress를 stderr에만 표시한다. recursive enumeration 중에는 final total을 아직 모르므로 discovered count만, 목록 확정 뒤 metadata/hash 단계는 `completed/total`과 percentage를 표시한다. TTY는 한 줄 redraw, non-TTY는 stage/5% bucket/time 기준 throttled line을 사용하며 `--no-progress`로 비활성화할 수 있음. JSON/stdout contract는 그대로 유지
- state placement policy: Mac internal SSD의 Application Support SQLite가 authoritative **working catalog**이고, 각 removable archive root의 inventory는 그 root만 설명하는 portable map/cache다. `catalog export`는 전체 semantic disaster-recovery snapshot이고 raw hash를 의도적으로 제외하므로 root inventory와 역할이 다름
- 선택적 `--exact-engine czkawka`: Czkawka cache/prehash candidate discovery 후 native SHA-256 재검증; 기본 `automatic`은 현재 native exact path
- 필수 third-party binary 없이 optional tool 감지
- mixed local, Apple-direct, Google Takeout, Google web root를 구분하는 explicit source provenance
- 상위 local library 안에 Takeout root가 있어도 가장 구체적인 등록 root가 파일을 소유하도록 하는 nested-root ownership. 이제 scan 명령에 nested root를 함께 넘기지 않아도 registry의 active/inactive nested root는 부모 enumeration에서 자동 제외되고, `root remove` 뒤에만 부모 ownership으로 돌아온다.
- filename이 같아도 내용이 다르면 identity로 합치지 않고 경고하는 filename collision 검출
- GPS/description은 읽지 않고 `title`과 `photoTakenTime`만 사용하는 최소 Google Takeout sidecar capture-time import
- recognized sidecar association: Google Takeout JSON의 `title` target 및 모호하지 않은 same-basename XMP/AAE를 logical asset에 연결하고 `sidecar_links`에 보존한다. recognized sidecar는 singleton media organize를 막지 않지만 sidecar file 자체는 자동 삭제하지 않으며, unrecognized JSON은 directory deletion blocker로 남긴다.
- sidecar consumer policy: 검증된 schema/관계의 sidecar는 자동 처리하고 사용자가 JSON/XMP를 직접 판독하도록 요구하지 않는다. unknown/ambiguous sidecar는 source-folder 삭제 경계에서는 보존하지만 media 자체의 이동/열람 가능성을 부정하지 않는다. 현재 recognized parser는 Google Takeout JSON의 최소 `title`/`photoTakenTime` 경로다.
- explicit root registry + usage role: `root add/list/enable/disable/remove/role`로 registration state와 per-root policy를 분리한다. usage role은 장치가 아니라 registered root마다 하나씩 저장하고 변경 이력을 local SQLite에 남긴다. `staging`/`primary_library`는 internal `inbox` kind를 공유하고 나머지 role은 대응 kind로 정규화하며 provenance는 독립적으로 유지한다. role 변경은 media를 수정하지 않고 cached scan/review에도 현재 역할이 즉시 반영된다. 아직 명시 등록되지 않은 history-only root는 현재 scan kind를 따라 역할이 갱신되며, active/inactive/removed registration row가 생긴 뒤부터 saved role이 scan flag보다 우선한다. legacy registered `inbox`는 migration에서 안전하게 `primary_library`로 seed하고 신규 inbox는 `staging` 기본값을 사용한다. remove는 media를 수정하지 않고 current evidence를 prune하며 source root identity/marker/role history는 최소 history로 유지한다. agent-safe list/role/remove output에는 canonical path를 노출하지 않는다.
- `duplicate-review`: current exact reconciliation의 AUTO item을 local-private Finder workspace로 materialize한다. 기본값은 active root registry와 일치하는 가장 최근 complete scan snapshot을 SQLite에서 재구성해 전체 media 재scan 없이 review를 즉시 만든다. 표시 직전 참여 resource만 current size + mtime + filesystem ID와 가능한 경우 stable root marker identity로 가볍게 검증해 `CURRENT`, `STALE`, `OFFLINE`으로 분류한다. CURRENT만 `KEEPER/CANDIDATE`를 사용하고 stale/offline은 `OLD_KEEPER/OLD_CANDIDATE` + `NEEDS-REFRESH.txt`로 과거 판단임을 명시한다. 각 group의 `comparison.txt`는 local-private으로 실제 target byte size, exact-byte/embedded metadata 관계, scan capture evidence, filesystem birth/mtime, filename/path, filesystem identity, xattr equality와 keeper rationale를 기록하고 Finder symlink 자체 size가 media size가 아님을 명시한다. `--preference-only`는 complete Live Photo retention, protected/preferred root, explicit `copy`/`복사본` marker, peer basename과 정확히 대응되는 numeric copy suffix, human-validated recognizable filename, same-root shallower path, filename basename과 일치하는 parent가 placeholder parent보다 우선되는 구조처럼 strong auto choice를 숨긴다. pure deterministic tie-break와 아직 승인되지 않은 weak evidence는 GUI/approval surface에서 사용자가 survivor를 명시하기 전에는 자동 quarantine하지 않는다. `--refresh`는 active root를 incremental rescan하고 `--refresh --fresh`는 metadata/hash cache를 무시한다. media bytes는 copy/move/rename/delete하지 않고 실제 quarantine은 계속 fresh cryptographic verification을 요구한다.
- 영어/한국어 project overview
- 날짜가 명시된 Google Photos 및 Apple PhotoKit capability 문서
- validation 및 optional integration 문서
- issue form, pull-request template, CI, public-tree privacy safeguard
- 기존 archive folder를 활용하는 automatic-first, event-level organization 정책

현재 command:

```bash
swift run photoarchive doctor
swift run photoarchive scan [options] ROOT...
swift run photoarchive archive-coverage [options] ROOT...
swift run photoarchive plan [options] ROOT...
swift run photoarchive organize-plan [options] ROOT...
swift run photoarchive archive-plan --to PATH --output PLAN [options] ROOT...
swift run photoarchive archive-copy [--apply] [--to PATH] [--bind-root ROOT_ID=PATH] PLAN
swift run photoarchive archive-index [--fresh] [--apply] [options] PATH
swift run photoarchive organize [--apply] [options] ROOT...
swift run photoarchive root list [--all] [--json|--agent-json]
swift run photoarchive root add [--role ROLE] [--kind KIND] [--provenance VALUE] PATH
swift run photoarchive root role [--json|--agent-json] ROOT_ID_OR_PATH ROLE
swift run photoarchive root enable ROOT_ID_OR_PATH
swift run photoarchive root disable ROOT_ID_OR_PATH
swift run photoarchive root remove [--json|--agent-json] ROOT_ID_OR_PATH
swift run photoarchive root inspect PATH
swift run photoarchive root init [--apply] PATH
swift run photoarchive quarantine --to PATH [--apply] [options] ROOT...
swift run photoarchive restore-quarantine [--apply] [--catalog PATH] MANIFEST
swift run photoarchive cleanup-empty-dirs [--apply] [--catalog PATH] ORGANIZATION_MANIFEST
swift run photoarchive catalog export --output PATH [--catalog PATH]
swift run photoarchive catalog restore [--apply] --to PATH [--bind-root ROOT_ID=PATH] SNAPSHOT
swift run photoarchive-selftest
```

`scan`, `archive-coverage`, `plan`, `organize-plan`은 media에 대해 read-only다. `archive-index`도 media-read-only이며 기본 실행은 archive root에 아무것도 쓰지 않고 local SQLite만 갱신한다. `archive-index --apply`는 hidden portable inventory만 쓰며 media를 건드리지 않는다. `archive-plan`은 media-read-only지만 local-private persisted plan 파일을 생성한다. `archive-copy`는 기본 dry-run이며 명시적 `--apply`가 있어야 destination에 copy하지만, **현재 사용자는 HDD media copy를 직접 수행하기로 했으므로 추가 real-HDD archive-copy apply는 진행하지 않는다.** `quarantine`과 `organize`도 기본 dry-run이고 명시적 `--apply`에서만 제한된 AUTO item을 이동한다. 영구 삭제는 없다.

## 제품 결정

- **Live Photo atomicity는 최상위 safety invariant다.** still/paired-video 중 하나를 건드리는 copy/move/rename/quarantine/delete/archive/projection operation은 완전한 logical asset/occurrence resource set으로 확장하거나 실패한다. provenance preference, exact dedupe, 성능 최적화보다 이 규칙이 우선한다.
- `docs/PROJECT_NORTH_STAR.md`가 scope gate다. real library에서 duplicate reconciliation, Live Photo 보존, preferred representation 선택, folder archive plan, verified copy, portable semantic state가 안정적으로 동작하기 전에는 주변 기능으로 확장하지 않는다.
- portable filesystem archive가 media truth를 저장한다.
- SQLite가 semantic truth와 provider-neutral desired organization을 저장한다.
- storage/provider 전체가 아니라 **registered root마다 usage role을 지정**한다. 같은 Mac/HDD/cloud file provider 안에서도 서로 다른 하위 root가 staging/archive/import/reference가 될 수 있다. provider capability와 provenance는 root usage role과 별도 축으로 유지한다.
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
- 기존 수동 HDD folder tree는 PhotoArchiveKit이 새 `Media/YYYY` layout으로 덮어쓰거나 재배치하지 않는다. 실제 photo root 자체를 `archive-index` 대상으로 등록하고 current user-authored hierarchy를 semantic state로 보존한다. 사용자는 HDD media copy/분류를 Finder 등으로 직접 수행할 수 있고, PhotoArchiveKit은 재index 시 새 위치/중복/보관 여부를 갱신한다.
- current freshness는 explicit registered-root session이 기준이다. `archive-index`는 지정한 archive root만 갱신하고, full backup 관계를 확인하려면 비교 대상 root들을 `archive-coverage`에 함께 넘긴다. 등록하지 않은 다른 Mac folder/외장장치를 자동 탐색하지 않으며 현재 background watcher는 없다. 미래 GUI는 cached result를 즉시 보여주되 `Checking…` 상태에서 표시 대상의 lightweight filesystem freshness를 background revalidate하고, CURRENT가 된 item만 현재 판정으로 취급한다. stale item만 targeted refresh하는 것을 우선하며 app-open마다 전체 library를 무조건 background rescan하지 않는다.
- human duplicate review의 최종 UI는 Finder의 폴더 왕복/Quick Look을 제품 UX로 채택하지 않는다. 화면 폭이 충분하면 2개뿐 아니라 3~4개 이상의 사본도 **각 사본을 가로 열(column)로 고정**하고, 사용자는 아래로 세로 스크롤하면서 같은 비교 항목 행(row)을 나란히 읽는다. 사진/영상 preview, 파일명·경로·시각·출처 근거, exact-byte 상태, keeper rationale를 같은 열 정렬로 유지하며 필요할 때만 상세 정보를 펼친다. 좁은 화면에서는 별도 responsive 설계를 사용한다.

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
- archive coverage synthetic/CLI validation:
  - 두 root에 byte-identical standalone resource 1개씩을 둔 fixture에서 pairwise exact group 1, 각 root exact-covered 1 / exact-unique 0
  - 같은 exact group을 A+B에서 관측한 뒤 A+C만 다시 scan해 stable group ID는 유지하면서 persisted current membership이 A+C 두 member로 교체됨
  - canonical Live Photo fixture에서 complete peer는 `complete_elsewhere`, repeated ambiguous counterpart는 `split_or_ambiguous_elsewhere`로 구분
  - real current two-root read-only scan에서 reference media 2/2가 exact-covered, pairwise shared exact group 2, current duplicate group의 stale member 0, media 수정 없음
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
- organization synthetic apply test에서 `IMG_1234.HEIC + IMG_1234.MOV`가 같은 capture-time destination basename으로 함께 이동하고 custom filename은 보존되며 marker gate, post-move filesystem ID/size, restore manifest, agent-safe path redaction이 동작함을 확인했다. 별도 tracking fixture에서는 full rescan 없이 catalog resource path가 즉시 갱신되고 stable resource ID와 old/new location history가 유지되는 것, synthetic catalog commit failure 시 모든 filesystem move가 원위치 rollback되는 것도 검증했다.
- real-library `organize`를 stable root marker 초기화 후 실제 적용했다. `2,765` AUTO item / `4,292` resource가 capture-time flat name으로 이동됐고 manifest `complete`, old source 잔존 0, destination 누락 0, size mismatch 0을 확인했다. resource `22,232`, logical asset `8,178`, logical Live Photo `2,710`, exact reconciliation `AUTO 0 / REVIEW 227`은 유지됐다. 적용 후 이미 정리된 1,527 Live Photo를 custom-name REVIEW로 다시 표시하던 idempotence 문제를 수정해 현재 organization plan은 `AUTO 0`, 실제 보류만 `628 item / 795 resource`다: filesystem fallback `58`, custom-name Live Photo `154 resource`, incomplete Live Photo `415 resource`, multiple physical representation `168 resource`.
- 위 real organization manifest를 대상으로 `cleanup-empty-dirs --agent-json` dry-run을 수행해 removal candidate 412개를 확인했다. 후보는 organization source history로 제한되며 count-only local diagnostic에서 `.photoslibrary` 내부 0, Takeout 0, `Pictures` root 자체 0이었다. 이후 같은 manifest에 `--apply`를 수행해 412개 directory를 제거했고, 즉시 다시 dry-run하여 잔여 후보 0을 확인했다.
- strict Live Photo timed-metadata validation을 synthetic MOV fixture와 real library에서 검증했다. self-test는 valid int8 marker, marker 누락, 잘못된 datatype, multiple marker를 각각 검증한다. real library 22,232 resource / 2,710 logical Live Photo를 다시 읽었을 때 기존 complete occurrence 1,824개가 모두 `still-image-time` 검증을 통과했고 새 `missing`/`invalid`/`unreadable` occurrence는 0이었다. 정상 exact plan 재검증도 `AUTO 0 / REVIEW 227`을 그대로 유지했다.
- portable catalog snapshot self-test에서 versioned JSONL export가 absolute root path/raw exact hash/media byte를 포함하지 않는 것을 확인했고, restore dry-run은 destination catalog를 만들지 않으며 `--apply`는 기존 catalog를 덮어쓰지 않고 새 catalog만 생성하는 것을 검증했다. 두 synthetic root를 명시적으로 rebind한 뒤 fresh scan에서 원래 opaque root/resource/asset ID가 유지되고 exact evidence가 파일에서 재생성됐다. 별도 Takeout source-folder fixture에서는 collection hierarchy/membership/source key가 restore 후 유지되고 fresh scan에도 collection이 중복 생성되지 않았다. snapshot 파일 자체는 relative path/original filename/collection label을 포함하므로 agent-safe가 아닌 local-private backup으로 취급한다.
- immutable HDD `archive-plan` synthetic validation에서 marked local + exact Takeout copy는 non-Takeout canonical 1개만 AUTO로 선택되고 fresh SHA-256이 scan/catalog exact evidence와 일치해야 plan에 고정됨을 확인했다. scan 뒤 source byte를 같은 크기로 변조하면 plan 생성 전에 `sourceChanged`로 거부되며, existing destination filename은 deterministic suffix로 회피한다. 별도 synthetic Live Photo plan은 complete still+paired-video 2 resource를 같은 destination basename의 하나의 AUTO item으로 유지했다. source marker가 없는 root는 REVIEW로 남고 agent-safe plan에는 source/destination path, filename, marker key, SHA-256이 노출되지 않는다.
- `archive-copy` synthetic apply와 CLI end-to-end smoke test를 완료했다. dry-run은 media를 만들지 않고 copy-required 1 resource를 보고했고, apply는 canonical source byte를 hidden staging에 copy/verify한 뒤 final path로 이동해 다시 SHA-256을 확인했다. source 두 copy는 그대로였고 destination archive root 1개/media resource 1개가 working catalog에 등록되며 `.photoarchive/catalog` snapshot이 생성됐다. 같은 plan 재apply는 `filesModified=false`/already-final 1로 no-op이었다. same-size source tamper, plan의 asset ID tamper, one-resource Live Photo item, completed snapshot byte tamper를 각각 거부했고 agent-safe report에는 source/destination path, filename, marker key, SHA-256이 없었다. archive control JSON은 hidden scan exclusion 덕분에 catalog sidecar 0개였다.
- Takeout 3개 real source root에 사용자의 명시 요청으로 stable marker를 초기화했고, 이후 scan 시 catalog binding도 `3/3` 확인했다. marker 이전 full preflight의 `source_root_marker_missing` REVIEW 3,964 item은 standalone 3,777 + complete Live Photo 187이며 총 4,151 resource다. 이 4,151 resource를 root별 lightweight verifier로 current regular-file/symlink boundary, byte size, catalog exact SHA-256과 fresh full SHA-256까지 전수 재검증했고 실패 0이었다. 현재 planner gate 기준으로 이 3,964 item은 모두 AUTO 승격 조건을 충족하므로 예상 상태는 `AUTO 7,283 item / 9,098 resource`, `REVIEW 895 item / 1,576 resource`; 남는 REVIEW는 `incomplete_live_photo 892 + conflicting_complete_live_photo_variants 3`이다.
- Takeout marker 이후 full `archive-plan`이 반복 `exit 137`로 종료되던 원인을 측정해 해결했다. 동일 4-source `scan --jobs 1`은 정상 종료했고, pre-fix full planner는 peak RSS `8,779,184 KiB`까지 상승한 뒤 SIGKILL됐다. sequential SHA-256에서 `FileHandle.read(upToCount:)`의 Foundation temporary가 장시간 planning pass 동안 누적되지 않도록 `FileHasher`의 각 4 MiB chunk read를 `autoreleasepool`로 감쌌다. 수정 후 같은 `archive-plan --jobs 1`은 peak RSS `185,648 KiB`, exit 0으로 persisted schema-v2 plan을 생성했고 기본 concurrency도 동일하게 성공했다. 실제 persisted plan은 `AUTO 7,283 item / 9,098 resource`, `REVIEW 895 item / 1,576 resource`로 독립 계산과 정확히 일치하며, 이어 `archive-copy --agent-json` dry-run도 `copyRequiredResourceCount=9,098`, `filesModified=false`로 current catalog/source-byte precondition 전체를 통과했다.
- user-managed archive synthetic/CLI validation: nested `Trips/Japan` + `Family` fixture에서 첫 `archive-index`는 2 media / 3 represented folder / cache reuse 0, 같은 local catalog 재실행은 exact hash 2개 재사용, `--apply`는 hidden root inventory만 생성했다. 완전히 새 SQLite catalog에서도 같은 inventory로 hash 2개를 재사용했고 `--fresh`에서는 reuse 0으로 full-byte path를 강제했다. Finder-style manual move 뒤 재index에서 old nested collection이 제거되고 current `Family` hierarchy만 남는 것도 확인했다. agent-safe archive-index report에는 path/filename/hash가 없고 media mutation은 없었다.
- real 3-way exact comparison: current Mac local media 5,445개, user-managed HDD archive media 4,195개, two completed quarantine manifests의 Takeout resource 8,008개를 비교했다. Mac↔HDD direct exact overlap은 0 resource/0 hash였다. quarantine resource 8,008개는 restore dry-run으로 두 session 모두 fresh SHA-256 검증을 다시 통과했고 `filesModified=false`였다. 현재 Mac resource 3,900개(71.63%)와 HDD resource 3,772개(89.92%)가 각각 quarantine Takeout에 exact counterpart를 가지며, quarantine occurrence 기준 4,239개는 Mac 쪽, 3,767개는 HDD 쪽, 2개 image resource는 현재 두 root 어느 쪽에도 exact counterpart가 없다. A∩B∩C exact hash는 0이다.
- registered nested-root ownership을 parent-only scan에도 적용한 뒤 current Mac + user-managed HDD 두 root만 `archive-coverage --agent-json`으로 다시 읽었다. Mac 5,445 resource와 HDD 4,195 resource가 정확히 관측됐고 direct exact overlap은 다시 0, 양쪽 exact-unique는 각각 5,445 / 4,195였다. Mac Live Photo occurrence 2,058개와 HDD 422개도 상대 root에 counterpart 0이었다. media mutation은 없었다. 따라서 현재 HDD는 current Mac library의 byte-identical backup replica라기보다 서로 겹치지 않는 별도 archive 집합으로 관측된다.
- residual Takeout cleanup 재검증: 현재 nested Takeout root에 media 121개가 남아 있었고 raw byte-only 비교로는 그중 107개가 outer Mac library에 exact counterpart를 가졌지만, 현재 reconciliation/quarantine safety policy를 다시 적용한 dry-run에서는 AUTO가 2 item / 2 resource뿐이었다. `quarantine --apply`로 이 2개만 reversible quarantine에 이동했고 source absence + destination presence를 manifest로 확인했다. Takeout media는 119개로 줄었으며 즉시 post-apply dry-run은 `no automatic redundant candidates`로 종료했다. 따라서 남은 119개는 raw hash overlap만으로 자동 제거하지 않는다.
- progress-enabled real HDD read-only scan: 사용자 지정 archive root 하나만 대상으로 sibling directory를 포함하지 않고 재scan했다. supported media `4,195/4,195`가 metadata 단계에서 실시간 5% bucket으로 보고되었고 catalog/finalizing까지 정상 종료했다. 결과는 resource `4,195`, logical asset `4,186`, logical Live Photo `422`, exact duplicate group `9`, cached exact hash reuse `46`, media modified `false`로 직전 scan과 동일했다. 첫 pass 대비 warm repeat이 빨랐지만 OS/HDD cache 영향이 섞인 관찰이므로 일반 benchmark로 고정하지 않는다.
- cached Finder duplicate review real-library validation: 직전 complete 6-root scan의 `27,352` resource snapshot을 media 재scan 없이 catalog에서 재구성해 primary local-library 후보만 materialize했다. 결과는 `60` review group, `62` candidate resource link, `81` keeper link였고 media modified `false`였다. 최초 구현은 SQLite join index 부재로 catalog load가 약 `20.8s`였으나 `asset_resources(resource_id,last_seen_session)` 등 current-snapshot query index를 추가한 뒤 같은 결과에서 catalog load `0.170s`, reconciliation plan `0.086s`, workspace 생성 `0.020s`로 감소했다. 이 review snapshot은 mutation authority가 아니며 실제 quarantine은 계속 fresh byte/safety verification을 요구한다.
- cached Finder freshness real-library validation: 같은 Pictures 후보 workspace를 새 freshness gate로 다시 materialize했을 때 `60/60 CURRENT`, `STALE 0`, `OFFLINE 0`, keeper link `81`, candidate link `62`, media modified `false`였고 전체 실행은 약 `0.98s`였다. synthetic self-test에서는 candidate의 mtime만 바꿔도 기존 exact decision이 `STALE`로 내려가고 Finder group에 `NEEDS-REFRESH.txt`가 생성되는 것을 확인했다.
- human duplicate-review feedback 반영: Finder가 symbolic link 자체 크기를 보여줘 candidate HEIC가 더 커 보인 초기 1~23번을 실제 target SHA-256/size로 재검증했을 때 matched HEIC는 모두 byte-identical/same target size였고 link-path 길이 차이만 있었다. standalone exact sample도 다시 SHA-256으로 확인해 byte-identical임을 확인했다. explicit `copy`/`복사본`/`사본`/`duplicate` suffix 자체를 strong copy evidence로, numeric-copy suffix는 peer basename과 실제 대응할 때만 strong evidence로 취급한다. 첫 human pass에서 `60 -> 29`, explicit-copy 보강 뒤 `29 -> 23`으로 줄었다. 다음 human pass에서 사용자가 `IMG_####`/KakaoTalk/date-like 등 recognizable source filename 우선과 같은 root의 shallower path 우선을 일반 기본 규칙으로 승인했고 이를 strong default로 승격해 `23 -> 8`로 줄였다. 이어 filename basename과 같은 부모 폴더를 가진 사본이 `무제 폴더`/`Untitled Folder`/`새 폴더`/`New Folder` 같은 placeholder parent의 peer보다 우선한다는 규칙을 승인했고 실제 Pictures `--preference-only`는 `8 -> 6` current group, keeper link `6`, candidate link `8`, stale/offline `0`, media modified `false`가 됐다. 남은 6개는 전부 `deterministic_tie_break`뿐이다. 이전 21번 사례는 4개 사본의 filesystem birth time이 모두 같아 earliest-time 선택이 아니었으므로 생성시각 일반 규칙으로 승격하지 않았다. unresolved tie-break는 quarantine preflight에서 제외하고 향후 thin comparison UI에서 사용자가 survivor를 명시해야 한다. 실험 중 생성한 Agent Workspace review 7개와 Desktop review 1개는 symlink/text/.DS_Store만 포함함을 확인한 뒤 삭제했고 원본 media는 수정하지 않았다.
- root usage-role validation: synthetic registry에서 `reference -> staging -> primary_library` 변경이 media를 건드리지 않고 internal kind를 일관되게 갱신하며 role history 3개를 남기는 것을 확인했다. registered saved role은 이후 scan flag보다 우선하고, 별도 history-only fixture는 `reference` scan 뒤 `inbox`로 다시 scan했을 때 `staging`으로 정상 전환됐다. cached scan snapshot에서도 media reread 없이 현재 registered role이 반영된다. staging exact copy는 import-source cleanup의 retained counterpart가 될 수 있지만 reference-only copy는 standalone/Live Photo 모두 그 권한을 주지 않으며, staging으로 되돌리면 다시 authority가 복구된다. archive는 standalone 및 complete Live Photo의 same-root exact dedupe를 허용하면서도 다른 archive/root replica 때문에 그 root 자체를 collapse하지 않는다. Google Takeout import source의 same-root Live Photo dedupe는 source-folder semantics capture 전에는 차단되고 capture 후에만 허용된다. executor도 candidate와 keeper가 같은 archive root인지 다시 확인하고 reference candidate는 계속 거부한다. reference root의 organization 및 과거 organization manifest 기반 empty-directory cleanup도 거부한다. registered archive destination은 archive-plan과 archive-copy replay 모두 current role이 `archive`인지 재검증한다. portable catalog JSONL은 current role을 보존하고 role 없는 legacy snapshot의 inbox는 `primary_library`로 보수적으로 복원한다. 실제 working catalog에서는 사용자의 확정 의도에 따라 current Mac photo root와 기존 Downloads 비교 root를 모두 `staging`으로 지정했다. 현재 active role은 staging 2개, archive 1개, import source 3개이며 active reference는 0개다. 역할 변경은 catalog/history만 갱신했고 media는 수정하지 않았다.
- Finder review의 사람이 읽는 `comparison.txt`, workspace README, stale/offline 안내문을 한국어로 전환했다. exact-byte 동일, 실제 target 크기, 선택 근거, filesystem/xattr 차이의 의미를 한국어로 설명하고, scan capture source가 `file_creation_date/fallback`인 경우 이를 embedded metadata 차이라고 잘못 표현하지 않고 **파일시스템 생성 시각 fallback이며 파일 내부 촬영 메타데이터가 아님**을 분리해 표시한다. 내부 folder/status token(`CURRENT`, `KEEPER`, `CANDIDATE`)은 도구 식별을 위해 괄호/이름에 유지한다.
- incremental metadata cache validation: valid synthetic MOV를 두 번 scan했을 때 first pass cache reuse 0, unchanged second pass reuse 1/1이었고 mtime을 바꾸면 reuse 0으로 무효화됐다. 실제 reference root 927 resource를 별도 disposable catalog에서 scan한 결과 first pass `reusedMetadataCount=0` 약 `0.25s`, second pass `927/927` reuse 약 `0.14s`, `--fresh`에서는 다시 reuse 0이었으며 모든 pass에서 media modified `false`였다. 기존 full 6-root catalog는 새 cache-version seed가 없어 첫 전체 seeding pass가 metadata I/O에서 장시간 대기해 15% 이후 중단했다. media mutation은 없었고 resource/cache evidence의 catalog commit 전이었지만, catalog open/migration과 scan-session bookkeeping 자체는 local SQLite에 기록될 수 있다. 전체 metadata cache는 다음 정상 complete refresh에서 자연스럽게 채운다.
- interrupted scan recovery: scan 전체 기간에 catalog별 OS advisory lock을 잡아 같은 catalog의 concurrent scan을 거부하고, crash/SIGINT 뒤 남은 `running` session은 다음 scan이 lock을 획득한 뒤 `interrupted`로 회수한다. synthetic regression에서 이전 running row가 `interrupted`로 바뀌고 현재 scan report에 path-free recovery notice가 생기는 것을 확인했다.
- redundant-rescan audit: `duplicate-review` cached path는 전체 root enumeration을 하지 않는다. 일반 `scan/plan/archive-coverage/organize-plan/archive-plan/quarantine/organize`는 현재 library truth가 필요한 command라 root enumeration은 수행하지만 unchanged resource의 metadata/hash는 cache로 재사용한다. `archive-index`의 full enumeration은 current user-authored folder hierarchy와 move/delete를 감지하는 command 목적 자체라 유지하며, `--fresh`가 metadata cache까지 끄도록 수정했다. 남은 큰 최적화 후보는 이미 검토된 quarantine selection을 적용할 때 전체 library를 다시 계획하지 않고 선택된 keeper/candidate만 fresh verify하는 targeted mutation path다.

private fixture와 temporary catalog는 repository에 포함하지 않는다.

## 알려진 제한사항

- archive-copy executor는 synthetic/temporary filesystem, 실제 외장 HDD 1-resource smoke, real-library 10-item/15-resource bounded apply, post-marker full immutable plan 및 9,098-resource dry-run까지 검증됐지만 전체 real-library apply는 아직 수행하지 않았다. 다음 mutation은 기존처럼 logical item 단위 bounded batch로 단계적으로 확대한다. 독립 replica verification/rclone adapter, permanent delete, cloud upload도 아직 없다. `organize`는 same-session deterministic camera-name rename/flatten 전용이며 general-purpose move command가 아니다.
- still-side identifier extraction은 격리되어 있지만 현재 iPhone file에서 관찰한 ImageIO MakerApple entry를 따른다. 추가 format fixture가 필요하다.
- stable root marker 기능은 구현됐지만 기존 real roots에는 자동으로 marker를 쓰지 않는다. 각 root는 사용자가 `photoarchive root init --apply PATH`를 명시적으로 실행한 뒤부터 relocation identity를 가진다.
- incremental metadata + exact-hash cache는 local SQLite에 구현됐고 archive exact hash는 removable-root portable inventory도 seed로 사용할 수 있다. metadata cache는 parser cache version을 명시적으로 기록하므로 parser 규칙이 바뀌면 version을 올려 자동 invalidate해야 한다. Takeout JSON sidecar importer는 현재 sidecar content를 scan 때 다시 읽고, effective capture time이 Google Takeout sidecar에서 온 media는 stale sidecar time 고착을 피하기 위해 media metadata도 다시 probe한다. 향후 실제 benchmark에서 이 경로가 별도 병목으로 측정될 때만 base-metadata/sidecar parse cache 분리를 검토한다.
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
- `quarantine`과 `organize`는 오래된 plan을 replay하지 않고 같은 invocation에서 current root를 scan한 뒤 precondition을 다시 검증하는 제한된 mutation이다. HDD `archive-plan` schema v2는 working catalog path, source/destination marker와 exact-byte precondition을 local-private artifact로 고정하며 `archive-copy`는 plan byte 자체뿐 아니라 current catalog resource/asset/role/hash evidence와 source byte를 다시 검증한다. source/destination root가 이동했으면 동일 marker를 가진 path를 explicit rebind할 수 있다. complete manifest는 final resource 전체와 archive catalog scan/snapshot이 검증된 뒤에만 기록됨

## 다음 구체 작업

1. 남은 `227` mixed-exact Live Photo review는 complete paired-video evidence가 없는 still-only asset이 대부분이므로 자동 제거하지 않는다. additional source/backup/HDD에서 paired video를 찾거나 strict restore evidence가 생길 때만 재평가한다.
2. quarantine의 forward/restore lifecycle은 현재 필요 수준에서 완료로 닫는다. interrupted-session resume은 향후 HDD archive copy/apply에서 실제 필요성이 생길 때 구현한다.
3. 현재 organization REVIEW의 `multiple_physical_representations` 168 resource는 exact-deletion hold와 별개다. 현 core 목표의 blocker가 아니므로 추가 evidence/HDD 비교가 생기기 전까지 보류하고, 이를 줄이기 위한 별도 알고리즘 개발은 하지 않는다.
4. Czkawka image/video similarity adapter는 residual human review가 실제 bottleneck이 될 때만 추가한다. 현재 core archive 흐름보다 앞서지 않는다.
5. native incremental metadata + exact-hash cache는 구현과 synthetic/real disposable-catalog validation까지 완료했다. 다음 성능 작업은 정상 full-library refresh에서 실제 cache hit/time을 관찰해 여전히 남는 병목이 있을 때만 연다. Takeout sidecar parse cache나 Czkawka exact accelerator는 측정된 이점이 생길 때만 다시 평가한다.
6. preferred/canonical representation의 immutable archive plan과 staging copy/apply executor를 구현했고 persisted full plan 기준 `AUTO 7,283 item / 9,098 resource`, `REVIEW 895 item / 1,576 resource`, archive-copy dry-run copy-required `9,098`까지 검증했다. 그러나 사용자는 실제 HDD media copy/수동 folder 분류를 직접 수행하기로 했으므로 추가 `archive-copy --apply` batch 확대는 현재 workflow에서 중단한다. PhotoArchiveKit의 역할은 기존 HDD archive를 index하고 Mac/HDD exact overlap과 missing coverage를 보고하는 쪽으로 전환한다.
7. 사용자 지정 HDD의 **깊은 사진 최상위 root** read-only scan과 current Mac↔HDD `archive-coverage` 비교를 완료했다. current exact overlap은 0이고 양쪽 Live Photo counterpart도 0이므로, 현 HDD는 current Mac의 replica가 아니라 별도 archive 집합으로 취급한다. current root policy는 Mac=`staging`, HDD=`archive`, Takeout=`import_source`, 비교 root=`reference`로 확정됐다. staging→archive offload cleanup은 실제 Finder copy/분류로 overlap이 생긴 뒤 `archive-index/coverage -> exact+Live Photo protection 검증 -> staging cleanup plan` 순서로 열며, 그 전에는 synthetic 데이터로 억지로 mutation workflow를 확대하지 않는다. 같은 비교를 반복하지 말고 실제 HDD 내용이 바뀐 뒤에만 재index/coverage 한다.
8. organization apply 전 persisted immutable plan/approval token은 향후 offline/replay mutation에 필요할 때 추가한다. same-session organize는 post-move catalog transaction까지 이미 완료됨
9. `cleanup-empty-dirs`는 real library apply와 postcondition까지 완료로 닫는다. 같은 organization manifest 기준 412 directory 제거 후 잔여 후보 0을 확인했다.
10. strict Live Photo timed-metadata validation은 구현과 real-library 검증까지 완료로 닫는다. 현재 library의 기존 complete occurrence 1,824개가 모두 통과했고 reconciliation `AUTO 0 / REVIEW 227`도 유지됐다.
11. versioned sanitized JSONL catalog export/restore는 synthetic round-trip, stable opaque ID rebind, Takeout collection semantics preservation까지 완료. archive-copy도 verified destination scan 뒤 archive `.photoarchive/catalog`에 snapshot을 배치하도록 구현했다. 실제 HDD snapshot/restore 확인은 real-library archive apply에서 수행
12. HDD archive-copy transaction 경로는 synthetic/CLI, 실제 외장 HDD 제한 smoke, persisted full plan/dry-run까지 충분히 검증했으며 현재 사용자 workflow에서는 더 이상 자동 copy를 확대하지 않는다. user-managed HDD index/coverage workflow가 안정된 뒤 독립 verified replica가 필요할 때 user-installed rclone replica/check adapter를 연결한다.
13. user-managed archive의 existing folder hierarchy capture는 구현 완료. 이 folder를 신규 event의 자동 분류 example로 학습하는 event-level archive-guided classifier는 현재 index/coverage workflow가 real HDD에서 검증된 뒤로 유지
14. North Star archive workflow가 real library에서 안정화되기 전에는 Google upload와 broader provider convenience를 보류

## 재개 지점

동작을 변경하기 전에:

```bash
git status --short --branch
swift build
swift run photoarchive-selftest
```

그 다음 이 파일과 `MILESTONES.md`를 읽어 private ingest validation을 반복하지 않는다.
