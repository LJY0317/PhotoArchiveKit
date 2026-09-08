# 변경 기록

PhotoArchiveKit의 중요한 변경 사항을 여기에 기록한다.

형식은 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)를 따른다. public CLI와 catalog format이 안정화되면 Semantic Versioning을 시작한다.

## [Unreleased]

### 추가됨

- duplicate-review metadata 표의 시간 정보를 원본 촬영 시각 → 파일·유입·관측 시각 순으로 묶고 상단에 배치한다. 대표 촬영시각의 timestamp·UTC offset·source·confidence를 함께 보여주며, ImageIO에서 EXIF `DateTimeOriginal`/`DateTimeDigitized`, 각 offset/subsecond, TIFF `DateTime`을 local-only 원본 근거로 읽어 교차검증한다. Live Photo/video의 QuickTime creation date도 같은 섹션에서 비교한다. Live Photo가 하나라도 포함된 그룹은 시간뿐 아니라 resource 기반 metadata 전반을 `[still]`/`[video]` 고정 슬롯으로 표시하고 없는 component는 `—`로 채워 열 간 구조를 맞춘다. 시간 차이는 `시간 다름`/`구성 다름`/`시간·구성 다름`으로 구분하고 filesystem timestamp는 별도 의미로 명확히 분리한다.
- duplicate-review GUI의 `검토 결과 제출` 중간 단계를 사용자 주 workflow에서 제거하고, 사용자가 빨간색으로 고른 `삭제 예정` 사본을 현재 session/resource/root/path/Live Photo atomicity 및 가능한 fresh SHA-256로 다시 검증한 뒤 제품 설정의 macOS Trash/custom quarantine으로 직접 이동할 수 있게 했다. 기본 목적지는 `휴지통으로 이동…`, custom quarantine은 `격리 폴더로 이동…`으로 실제 동작을 명시하며, retained exact counterpart가 없는 명시적 선택은 staging/primary-library에서만 별도 경고와 함께 reversible move를 허용한다. opaque decision bundle은 이동 직전 local audit snapshot으로 자동 저장하고 visible app bundle은 `PhotoArchiveKit.app` 하나로 통일한다.
- native duplicate-review GUI의 sidebar를 단일 검색 목록으로 단순화하고 Live Photo는 system `livephoto` symbol로 표시하며 그룹별 전체 사본/occurrence 수를 보여준다. 소비자 화면에서는 `candidate resource`, 내부 item/reason ID, exact-scope debug badge 같은 개발자 표기를 제거하고 `중복 사진 검토`, `중복 항목`, `남기기 추천`, `Live Photo`처럼 의미가 바로 읽히는 문구를 사용한다. 추천된 사본 카드에는 `남기기 추천`과 함께 파일명·추가 시각·촬영 정보·Live Photo 완전성 등 실제 추천 이유를 짧은 자연어로 표시한다. detail은 standalone 사본 또는 Live Photo occurrence 하나당 비교 열 하나를 만들고 still+paired-video completeness, exact byte/SHA-256, filesystem/catalog facts, root/provenance/role, capture/Live Photo metadata, location history와 서로 다른 값/날짜 earliest/latest를 강조한다. 상세 metadata 값은 유지하되 표의 제목과 상태 문구는 소비자용 표현으로 바꾼다. 하나의 SwiftUI Grid가 열 너비와 row 높이를 함께 소유하고 실제 first/last cell anchor로 연속 선택 테두리를 그려 preview부터 마지막 metadata row의 빈 공간까지 시각적 열 경계와 cleanup hit-area를 일치시킨다. 기본 열은 희미한 neutral boundary, hover는 system accent, 실제 삭제 선택만 red border/tint를 사용하고 green은 남기기 추천/complete Live Photo 같은 semantic evidence에 제한한다. 빨간 선택은 앱 추천과 분리해 사용자 클릭으로만 만들며, 같은 열을 다시 클릭하면 취소하고 2사본 그룹에서 반대 열을 클릭하면 삭제 선택이 즉시 반대쪽으로 이동한다. 모든 사본을 삭제 대상으로 선택하는 confirmation은 미리보기의 명시적 `삭제 대상으로 선택` 버튼에서만 연다. 중복된 `이 사본 남기기` control은 제거하고, 빨간 선택이 하나라도 있으면 별도 승인 단계 없이 목적지 이동 확인을 바로 실행할 수 있다. 하단 action bar는 선택 개수와 단순 선택 성공 문구를 제거하고 목적지 이동 action 중심으로 단순화하며, 최종 확인창도 사본/파일/용량 요약과 실제 위험 경고만 보여준다. Live Photo occurrence는 atomic resource set으로 유지하고 유일한 complete pair 제거 여부는 최종 확인 단계에서 경고한다. sidebar는 하단 action bar만큼 scroll inset을 확보해 마지막 row가 가려지지 않게 한다. native AppKit help tag는 app-local 1초 initial hover delay를 사용한다. 비교 위치 메뉴에서는 active registered root를 선택하고 새 폴더를 native macOS picker로 추가한 뒤 usage role/provenance를 지정해 현재 선택 위치들과 한 session으로 incremental scan할 수 있다. toolbar에는 catalog presentation만 다시 읽는 단일 refresh만 남기고 실제 registered-root 재scan은 비교 위치 메뉴 안에서 명시적으로 실행한다.
- 좁은 duplicate-review 창에서는 고정 gutter를 유지한 채 native horizontal scroll indicator로 뒤쪽 copy 열까지 접근할 수 있고, preview의 상태/Live Photo integrity/thumbnail/파일명/resource/action을 공통 높이 slot으로 정렬해 열 간 y축을 맞춘다.
- duplicate-review 비교 영역을 직접 소유하는 AppKit `NSScrollView`로 변경하고 SwiftUI Grid는 유지한다. 하단 action bar를 `.safeAreaInset`에서 별도 VStack 행으로 분리해 가로 막대가 그 뒤에 가려지던 문제를 수정한다. persistent legacy scroller가 viewport 가장자리에 별도 공간을 확보하며 가로 막대 drag/Shift+wheel로 이동한다. 내부 scroll view 비동기 탐색과 overlay 열 이동 버튼을 제거하고 Grid padding을 overflow 너비 계산에 포함한다. 넓은 창에서는 열 너비 상한을 유지하면서 header와 Grid를 함께 가운데 배치한다. 셀 anchor마다 전체 metadata 행을 재생성하던 중복 계산을 제거하고 GUI launcher는 기본 release build를 사용한다.
- `PhotoArchiveCore`, `photoarchive`, dependency-free synthetic self-test를 포함한 local-first macOS Swift package
- Inbox, archive, import, reference source를 위한 read-only multi-root scan
- embedded Apple identifier 기반 Live Photo grouping과 catalog-local keyed fingerprint 보호
- complete, still-only, video-only, ambiguous Live Photo occurrence의 root별 completeness report
- stable opaque report ID를 사용하는 local SHA-256 exact-resource duplicate grouping
- provider-neutral logical asset과 time-gap event-folder suggestion
- root, resource, asset, collection, provider mapping, duplicate group, event, session을 위한 SQLite catalog
- `local_library`, `apple_direct`, `google_takeout`, `google_web` 등 explicit source provenance
- 상위 local root 안의 별도 Takeout root를 중복 scan하지 않는 nested-root ownership
- 같은 filename을 사용하지만 byte content가 다른 media를 별도 경고하는 `filename_collision`
- embedded timestamp가 충분하지 않을 때 Google Takeout sidecar의 `title`과 `photoTakenTime`만 사용하는 최소 capture-time import
- 프로젝트 최초 목적을 개발 우선순위의 gate로 고정하는 `docs/PROJECT_NORTH_STAR.md`
- 영어/한국어 문서, CI, repository privacy check, optional-tool licensing guidance
- AI agent용 `--agent-json`: filename/path, catalog path, exact byte size, capture timestamp, raw fingerprint를 제거하고 opaque ID/status만 출력
- repeated Takeout Live Photo를 non-Takeout complete pair가 역할별 exact copy로 완전히 cover할 때 occurrence partitioning 전에도 redundant로 판단할 수 있는 canonical-coverage 정책
- non-Takeout exact copy 우선과 Live Photo canonical coverage를 적용하는 read-only `photoarchive plan` 및 agent-safe reconciliation plan
- 선택적 `--exact-engine czkawka` candidate discovery + native SHA-256 verification cross-check; real-library benchmark 결과 기본 `automatic` exact path는 현재 native 유지
- same-session `photoarchive quarantine`: 기본 dry-run, 명시적 `--apply`에서만 `automatic_redundant` exact candidate를 local quarantine으로 move. apply 직전 regular-file/size/symlink boundary와 fresh SHA-256을 다시 검증하고, Live Photo item 전체 검증 후 이동하며, session failure 시 전체 rollback과 local restore manifest를 제공
- `photoarchive restore-quarantine`: completed manifest를 기본 dry-run으로 역검증하고 original source vacancy, expected size, local-catalog exact SHA-256을 확인한 뒤 `--apply`에서만 source로 복원. 실패 시 session rollback, agent-safe path/hash redaction, 기존 v1 real manifest 호환
- repeated same-identifier Live Photo export를 directory/basename boundary hint로 occurrence partitioning하되 embedded identifier를 identity authority로 유지
- Google Takeout source-folder hierarchy와 asset membership을 local SQLite에 보존한 뒤 Takeout-only exact standalone duplicate를 한 physical copy로 collapse할 수 있는 reconciliation policy
- Live Photo mutation은 touched occurrence/root의 complete resource set이 plan에 없으면 실행 전 거부하는 독립 atomicity guard; partial still/video plan을 허용하지 않음
- same-volume filesystem resource identifier와 resource location/original-name history를 이용한 path-independent physical resource tracking
- optional `.photoarchive-root` stable marker와 `photoarchive root inspect/init`; moved root를 기존 catalog root ID에 다시 bind
- `photoarchive organize-plan`: iPhone camera-style `IMG_####` / `IMG_E####`만 capture wall-clock 기반 `YYYY-MM-DD_HH-mm-ss[_NN]`으로 rename/flat-move 제안하고 custom filename/incomplete Live Photo/multiple representation은 review
- marker-gated `photoarchive organize`: 기본 dry-run, `--apply`에서 AUTO organization item만 이동하며 Live Photo 동일 basename, post-move filesystem ID/size verification 뒤 stable resource path/location history를 SQLite transaction으로 즉시 commit. catalog commit 실패 시 filesystem rollback, local restore manifest 제공
- `photoarchive cleanup-empty-dirs`: completed organization manifest + catalog location history로 source directory provenance를 검증하고, stable root marker/package/symlink boundary를 확인한 뒤 apply 시점에도 완전히 빈 directory만 deepest-first 제거. agent-safe output에는 directory path를 노출하지 않음

### 변경됨

- 공개 repository 문서를 제품·기여·재사용 가능한 validation 중심으로 정리하고, maintainer의 현재 작업 상태와 개인 validation 이력은 Git에서 제거해 `.local/` 전용으로 분리

### 보안

- general-purpose arbitrary media move, upload, permanent delete command 없음; quarantine과 organize는 각각 exact-redundancy 및 deterministic camera-name organization에 제한된 reversible move만 허용하고, empty-directory cleanup도 completed organization source history로 범위를 제한
- core에 background daemon 또는 network request 없음
- raw hash와 raw Live Photo identifier는 agent-safe report 밖에 유지
- agent-safe report는 filename/path, exact byte size, capture timestamp도 제거
