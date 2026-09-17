# PhotoArchiveKit 저장소 지침

## 제품 범위
- PhotoArchiveKit은 iPhone/Mac/Google Photos/외장 HDD 등에 흩어진 사진·동영상·Live Photo 사본을 **local-first**로 안전하게 정리하고, 사람이 읽을 수 있는 파일 archive와 provider-neutral semantic state를 보존하는 도구다.
- 최우선 제품 가치는 1) AI agent가 개인 media/file-level detail을 보지 않아도 작업할 수 있는 privacy boundary, 2) Live Photo still+paired-video 관계의 완전한 보존이다.
- exact duplicate reconciliation, preferred representation, folder organization, verified replica, provider projection은 그 다음이다. 실제 실패·측정 병목·핵심 workflow blocker가 없으면 주변 기능을 확장하지 않는다.
- background daemon/watcher, 범용 gallery/search/OCR/얼굴인식, browser automation, permanent delete, 자체 cloud storage는 기본 범위 밖이다.

## 안전 invariant
- 기본 동작은 read-only다. scan/plan과 mutation/apply를 분리하고 irreversible delete를 구현하지 않는다.
- **Live Photo atomicity가 최상위 invariant다.** validated still+paired-video 중 하나를 건드리는 copy/move/rename/quarantine/archive/delete/projection은 complete logical asset/occurrence 전체로 확장하거나 실패한다.
- exact/similarity를 구분한다. perceptual similarity나 capture-time/provenance 유사성만으로 삭제 권한을 만들지 않는다.
- root unavailable을 삭제 증거로 해석하지 않는다. mutation 직전 current root marker, path boundary, regular-file 상태, byte size와 필요한 fresh full-file hash를 다시 검증한다.
- duplicate cleanup 기본 destination은 OS Trash/Recycle Bin이다. 사용자가 명시한 경우에만 app-managed quarantine을 사용한다. permanent removal로 fallback하지 않는다.
- cleanup 뒤에는 해당 operation이 직접 비운 source parent chain만 registered root 직전까지 정리한다. package/symlink/unknown residue/다른 항목이 있으면 보존한다.
- 소비자용 위치 용도는 `기본`, `장기 보관`, `읽기 전용` 세 가지다. `장기 보관` 사본을 keeper로 우선하고 intentional archive replica를 generic dedupe로 collapse하지 않는다. `읽기 전용` 위치는 mutation하지 않는다. Takeout/import semantics는 자동 감지한 내부 metadata와 safety gate로 처리한다.

## 데이터·privacy
- media truth는 ordinary filesystem file, semantic truth는 Mac-local SQLite가 맡는다. provider ID나 filename/path 하나를 permanent asset identity로 쓰지 않는다.
- 개인 media, provider export/sidecar, runtime catalog, credentials/tokens, raw hashes, raw Live Photo identifiers, GPS, feature vectors, 개인 absolute path를 commit하지 않는다.
- 정상 agent workflow는 `--agent-json`을 사용한다. filename/path, catalog path, exact byte size, capture timestamp, raw hash/identifier, thumbnail/frame/audio, private collection label을 agent-safe output에 넣지 않는다.
- persisted archive plan, archive manifest/inventory, catalog JSONL은 local-private replay/recovery artifact이며 agent-safe/share-safe가 아니다.
- repository fixture는 synthetic/generated 또는 명시적으로 공개 승인된 자료만 사용한다.

## 구현 경계
- required core는 Apple system frameworks/Swift/SQLite처럼 기본 플랫폼 기능을 우선한다.
- 외부 도구가 더 적합하면 user-installed optional adapter로 재사용한다. 현재 후보는 rclone, Czkawka/Krokiet, ExifTool, ffprobe, osxphotos다. 별도 license review 없이 binary를 vendor/redistribute하지 않는다.
- Live Photo asset graph, provenance, root role, keeper policy, mutation/archive transaction, agent-safe boundary는 PhotoArchiveKit core가 소유한다.
- GUI에는 위치 용도를 `기본`, `장기 보관`, `읽기 전용`만 노출한다. 기존 catalog 호환과 import 안전성에 필요한 세부 role/provenance는 core 내부에만 유지하고 일반 사용자에게 설정을 요구하지 않는다.
- GUI는 local-private human surface다. 사용자 문구는 자연어를 쓰고 internal ID/reason/debug 용어는 필요한 고급 정보가 아니면 숨긴다. 현재는 한국어 완성도를 우선한다.
- GUI 디자인 의도와 정보 구조는 지원 macOS 전체에 공통으로 유지하되, sidebar/list/toolbar/button/scroller/material 같은 표준 UI는 SwiftUI/AppKit의 semantic/native 표현을 우선한다. Finder를 흉내 내기 위한 고정 RGB, OS별 픽셀 값, 커스텀 scroller 같은 복제는 피한다.
- SwiftUI의 표준 container bridge가 실제 OS에서 확인된 private gutter/edge 같은 회귀를 만드는 경우에는 앱 전체를 비네이티브 스택으로 바꾸지 말고, native `NSWindow`/material/scroller/SF Symbols/system font는 유지하면서 해당 surface만 앱 소유 SwiftUI layout으로 교체할 수 있다. duplicate-review sidebar는 이 예외에 해당하며 `NavigationSplitView + List(.sidebar)` source-list bridge를 다시 도입하지 않는다.
- 새 OS의 시스템 디자인 API(예: Liquid Glass)는 해당 OS에서만 좁게 사용하고, 이전 지원 OS에서는 그 버전의 native control/style을 유지한다. 실제 API·렌더링 차이가 확인될 때만 `#available` 분기를 추가하며, 새 디자인 자체를 특정 OS 전용 하드코딩으로 만들지 않는다.

## 작업·Git
- 장기 branch는 `main` 하나를 기본으로 한다. 큰 격리 실험만 임시 feature branch/worktree를 쓰고 완료 후 합쳐 삭제한다.
- `~/LJY Projects/PhotoArchiveKit`을 유일한 영구 기준 checkout으로 유지한다. `~/LJY Projects - Agent Workspace/`에는 병렬·격리 작업에 필요한 임시 worktree만 만들고, merge되었거나 폐기된 작업의 clone/worktree/backup은 검증 후 즉시 제거한다.
- 같은 프로젝트의 독립 clone을 Agent Workspace에 장기 보관하지 않는다. 임시 worktree 이름은 작업 목적을 드러내고, 해당 작업 종료 시 branch와 worktree를 함께 정리한다.
- GUI 작업을 완료하고 검증한 뒤에는 `scripts/run-app.sh`로 현재 실행 중인 `photoarchive-review`를 종료하고 같은 `.build/PhotoArchiveKit.app`을 다시 빌드·실행한다. app bundle을 Desktop/Applications/다른 작업공간에 복제해 버전별 사본을 남기지 않는다.
- 기존 작업 재개 시 Git 상태와 `.local/STATE.md`부터 확인한다. main이 최신이라고 가정하지 말고 다른 worktree/branch가 있으면 실제 기준점을 확인한다.
- 기존 사용자 변경을 보존한다. 예상하지 않은 HEAD/diff 변화가 생기면 쓰기를 중단하고 상태를 다시 확인한다.
- force push는 명시적 요청 없이는 하지 않는다.

## 검증
- 의미 있는 변경은 최소 `swift build`, `swift run photoarchive-selftest`, `bash scripts/check-public-tree.sh`, `git diff --check`를 통과시킨다.
- GUI scroll/layout 변경은 관련 시 `bash scripts/test-review-scroll.sh`도 실행한다.
- cache/snapshot/과거 plan은 mutation authority가 아니다. destructive/mutating path는 항상 fresh precondition을 다시 확인한다.

## 문서 운영
- 장기·재개 작업에 필요한 문서는 최소화한다: `STATE.md`=현재·다음, `AGENTS.md`=고유 장기 규칙, `MILESTONES.md`=비싼 완료 이력, `README.md`=사람용 설명.
- `.local/STATE.md`와 `.local/MILESTONES.md`는 private maintainer 문서이며 commit하지 않는다.
- 완료된 일, Git에서 바로 확인 가능한 SHA/branch 상태, 반복 가능한 작은 테스트 결과를 STATE에 누적하지 않는다.
- MILESTONES에는 실제 재수행 비용·위험이 큰 검증만 남기고 **결론 + 검증 범위 + 다시 검증할 조건** 중심으로 압축한다.
- 같은 사실을 여러 문서에 복사하지 않는다. 새 문서는 기존 4종으로 표현할 수 없고 장기 가치가 분명할 때만 추가한다.
- 권장 상한: `AGENTS.md` 12 KiB, `.local/STATE.md` 16 KiB, `.local/MILESTONES.md` 8 KiB.
