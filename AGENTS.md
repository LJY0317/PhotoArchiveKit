# PhotoArchiveKit 저장소 지침

## 범위
- `docs/PROJECT_NORTH_STAR.md`를 제품 범위의 최우선 gate로 사용한다. 실제 실패 사례·측정된 병목·핵심 workflow blocker가 아니면 주변 기능을 먼저 확장하지 않는다.
- PhotoArchiveKit은 local-first, session 기반, 경량 도구로 유지한다. 명확한 필요가 확인되기 전에는 background daemon이나 filesystem watcher를 추가하지 않는다.

## 안전
- 기본 동작은 read-only다. scan/plan과 mutation/apply를 분리하고, 초기 release에는 영구 삭제를 구현하지 않는다.
- **Live Photo atomicity가 최상위 invariant다.** still + paired video 중 하나를 건드리는 copy/move/rename/quarantine/delete/archive/projection은 완전한 logical asset/occurrence 단위로 처리하거나 실패해야 한다.
- duplicate cleanup destination은 PhotoArchiveKit product settings를 따른다. 기본값은 OS Trash/Recycle Bin이며, 사용자가 명시한 경우에만 custom quarantine을 사용한다.
- duplicate cleanup 뒤에는 해당 operation이 직접 비운 source parent chain만 registered root 직전까지 정리한다. root, package/symlink boundary, 의미 있는 잔여 항목은 보존한다.
- source/archive root가 unavailable하다는 사실을 삭제 증거로 해석하지 않는다. destructive reconciliation 전에는 현재 root identity와 precondition을 다시 검증한다.

## 개인정보 보호
- 개인 media, provider export/sidecar, catalog/runtime DB, credential/token, raw hash, media-derived identifier, GPS, 개인 absolute path를 commit하지 않는다.
- agent-facing output은 `--agent-json` 같은 privacy-minimized surface를 사용한다. raw hash/identifier뿐 아니라 filename/path, capture timestamp, exact byte size, thumbnail/frame/audio 같은 file-level private detail도 기본적으로 노출하지 않는다.
- repository fixture는 synthetic/generated data 또는 공개가 명시적으로 승인된 자료만 사용한다.

## 의존성과 구현 경계
- 공식 Apple framework/API가 충분하면 우선 사용하고, 핵심 차별 영역이 아닌 복잡한 기능은 성숙한 외부 도구 재사용을 먼저 검토한다.
- Live Photo asset graph, provenance, keeper policy, archive transaction처럼 PhotoArchiveKit이 소유해야 하는 semantic/safety logic은 core에 둔다.
- optional third-party binary를 별도 license review 없이 vendor하거나 재배포하지 않는다.

## 검증과 문서
- 의미 있는 변경은 최소 `swift build`, `swift run photoarchive-selftest`, `bash scripts/check-public-tree.sh`, `git diff --check`를 통과시킨다.
- 사용자에게 보이는 동작이 바뀌면 `README.md`와 `README.ko.md`를 함께 갱신한다. 재사용 가치가 있는 공개 검증은 `docs/VALIDATION.md`, notable change는 `CHANGELOG.md`에 기록한다.
- maintainer의 현재 작업 상태·개인 실험 이력은 `.local/`에 두고 commit하지 않는다.
