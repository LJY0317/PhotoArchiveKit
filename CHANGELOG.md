# 변경 기록

PhotoArchiveKit의 중요한 변경 사항을 여기에 기록한다.

형식은 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)를 따른다. public CLI와 catalog format이 안정화되면 Semantic Versioning을 시작한다.

## [Unreleased]

### 추가됨

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

### 보안

- general-purpose arbitrary media move, upload, permanent delete command 없음; quarantine과 organize는 각각 exact-redundancy 및 deterministic camera-name organization에 제한된 reversible move만 허용
- core에 background daemon 또는 network request 없음
- raw hash와 raw Live Photo identifier는 agent-safe report 밖에 유지
- agent-safe report는 filename/path, exact byte size, capture timestamp도 제거
