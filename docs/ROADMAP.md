# Roadmap

Roadmap은 작고 검증 가능한 layer를 우선한다. 어느 phase도 existing original을 삭제해야 진행되는 구조가 아니다.

## v0.1 — Read-only scanner와 catalog

상태: initial implementation 완료.

- [x] Swift package와 lightweight CLI
- [x] 여러 configurable source root
- [x] ImageIO/AVFoundation metadata probe
- [x] embedded identifier 기반 Live Photo pairing
- [x] root별 completeness report
- [x] opaque public ID를 사용하는 local exact duplicate group
- [x] resource, asset, collection, provider, session, event용 SQLite schema
- [x] time-gap event suggestion
- [x] human-readable 및 sanitized JSON report
- [x] dependency-free synthetic self-test
- [x] five-path disposable ingest fixture validation
- [x] official Google/Apple documentation 기반 dated provider capability matrix
- [x] automatic-first event organization policy 및 prior-art boundary
- [ ] Live Photo `still-image-time` timed metadata strict validation
- [ ] versioned sanitized JSONL catalog export/restore test
- [ ] stable file fact를 이용한 incremental scan optimization
- [ ] 한 root 안에서 반복되는 same-identifier resource를 distinct Live Photo occurrence로 partition
- [ ] duplicate-hashing mode와 무관하게 standalone logical asset identity 안정화
- [ ] CI에 적합한 synthetic public Live Photo fixture

## v0.2 — Automatic organization과 immutable plan

- [ ] documented source priority를 가진 canonical capture-time resolver
- [ ] same-second 및 burst grouping
- [ ] deterministic `YYYYMMDD_HHMMSS[_suffix]` rename proposal
- [ ] original-name 및 reversible rename history
- [ ] existing archive folder를 collection example로 import
- [ ] event-level collection proposal
- [ ] confidence band 및 policy preset
- [ ] precondition을 가진 immutable plan format
- [ ] Finder-compatible shadow review folder 또는 lightweight generated review index
- [ ] 기본은 no mutation; explicit plan validation command

목표는 photo별 decision이 아니라 event group을 classify하는 것이다.

## v0.3 — Safe archive application

- [ ] verified root marker
- [ ] staging copy, local byte verification, atomic finalization
- [ ] Live Photo resource-set transaction
- [ ] checkpoint에서 interrupted session resume
- [ ] permanent deletion 대신 quarantine
- [ ] archive metadata directory에 catalog snapshot
- [ ] replica policy 및 verification record
- [ ] user-installed `rclone`을 사용하는 optional rclone adapter
- [ ] 초기 default로 `rclone sync` 사용 금지

## v0.4 — Local visual classification

- [ ] optional Apple Vision feature-print adapter
- [ ] Vision request revision 및 feature schema 기록
- [ ] existing folder example 기반 event-level nearest-neighbor classification
- [ ] optional coarse Vision image label
- [ ] erase/rebuild control을 가진 local-only feature cache
- [ ] report에 feature vector/inferred face data 포함 금지
- [ ] similar image/video용 optional Czkawka CLI candidate import
- [ ] similarity는 review signal이며 deletion authority가 아님

첫 classifier는 큰 universal taxonomy보다 사용자의 archive에서 학습한 familiar folder를 우선한다.

## v0.5 — Apple Photos projection

- [ ] small Swift PhotoKit bridge
- [ ] explicit authorization 후 asset/user album 읽기
- [ ] validated `.photo` + `.pairedVideo` resource import
- [ ] catalog collection에서 album 생성
- [ ] asset membership transactional add/remove
- [ ] system library 전에 isolated Photos library에서 test
- [ ] Apple adjustment history와 별도로 original-resource guarantee 유지

## v0.6 — Provider export와 Google upload

- [ ] fixture-driven Google Takeout parser
- [ ] normalization 전에 sidecar/raw export layout 보존
- [ ] observed Takeout schema가 허용하는 범위에서 album membership reconstruct
- [ ] user-selected item용 Google Photos Picker import
- [ ] supported simple media용 Google Photos Library API upload
- [ ] app-created Google content/album용 capability report
- [ ] official composite mechanism 또는 verified safe route가 있기 전에는 public API Live Photo upload를 지원한다고 주장하지 않음
- [ ] album 없는 upload도 유용한 capability로 허용

Google adapter behavior는 broader scope가 돌아올 것이라는 가정이 아니라 current API를 따라야 한다.

## 이후 가능성

- 같은 core를 사용하는 lightweight SwiftUI 또는 local web frontend
- optional Immich/PhotoPrism projection report
- additional file-cloud replica
- multi-Mac catalog snapshot reconciliation
- edited Live Photo derivative/adjustment-resource preservation
- explicit privacy control을 가진 offline map/timezone enrichment

## 명시적으로 미룸

- background filesystem watcher
- always-on server infrastructure
- browser automation을 core Google adapter로 사용
- automatic permanent deletion
- enterprise multi-user permission
- content-addressed user-facing storage
- original media metadata silent rewrite
