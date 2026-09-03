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

### 보안

- media rename, move, upload, quarantine, delete command 없음
- core에 background daemon 또는 network request 없음
- raw hash와 raw Live Photo identifier는 일반 report 밖에 유지
