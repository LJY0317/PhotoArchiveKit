# PhotoArchiveKit 프로젝트 지침

## 개발 브랜치와 commit
- 기본 개발 브랜치는 `dev`다. 새 작업을 시작할 때 먼저 `dev`를 확인하고, 안정화된 checkpoint만 `main`으로 올린다.
- 작업 재개 시 `main`이 최신이라고 가정하지 않는다. `dev`와 연결된 worktree, branch/reflog 상태를 먼저 확인하고, `dev`가 `main`보다 앞서 있거나 실제 최근 작업이 이어진 흔적이 있으면 `dev`를 현재 기준 작업선으로 취급한다. `main`은 안정화 시점에 뒤따라올 수 있다.
- 평소에는 remote push보다 local commit을 우선한다. 의미 있는 단위마다 commit하되, push는 공유·CI·backup 가치가 있는 굵직한 checkpoint 또는 사용자의 명시적 요청이 있을 때만 한다.
- commit message는 작은 PR 설명 수준으로 남긴다. 한 줄 제목만 쓰지 말고 문제/변경/검증/privacy·safety 영향/남은 작업을 본문에 기록한다.
- commit message의 제목과 본문은 기본적으로 한국어로 작성한다. Conventional Commit type(`feat:`, `fix:`, `docs:` 등), 명령어, API·제품명, 코드 식별자처럼 번역하면 오히려 불명확한 기술 표기는 원문을 유지할 수 있다.
- `main`은 안정화 branch다. `dev`에서 build, self-test, public-tree check와 관련 real-library validation이 통과한 뒤에만 merge/fast-forward 대상으로 삼는다.

## 제품 범위
- `docs/PROJECT_NORTH_STAR.md`를 제품 범위의 최우선 gate로 사용한다. 새 기능을 제안하거나 구현하기 전에 반드시 읽는다.
- real library에서 duplicate reconciliation, Live Photo 보존, preferred representation 선택, folder archive plan, verified copy, portable semantic state의 완료 기준을 충족하기 전에는 주변 기능을 우선하지 않는다.
- **완료 후에는 멈춘다.** 현재 milestone의 acceptance criteria가 real-library validation에서 충족되면, 단지 더 정교하게 만들 수 있다는 이유만으로 같은 문제를 계속 파고들지 않는다. 추가 구현은 실제 실패 사례, 측정된 병목, 핵심 workflow의 명확한 blocker 중 하나가 있을 때만 연다.
- 새 기능이 핵심 North Star 항목을 직접 진전시키지 않거나 이미 충분히 해결된 문제의 정확도/세분화만 높인다면 기본 판단은 `defer`다. 얼굴 인식, 범용 semantic vision, 세밀한 taxonomy처럼 흥미롭지만 현재 archive 목적에 필수 아닌 기능은 실제 blocker가 되기 전에는 구현하지 않는다.
- PhotoArchiveKit은 local-first, session 기반, 경량 도구로 유지한다. 이후 milestone에서 명시적으로 필요성이 확인되지 않는 한 background daemon이나 filesystem watcher를 추가하지 않는다.
- core는 third-party executable 없이도 유용해야 한다. 선택적 integration은 성숙한 duplicate/replication/metadata 기능을 다시 구현하기보다 사용자가 이미 설치한 도구를 활용할 수 있다.
- **Live Photo atomicity는 최상위 safety invariant다.** Live Photo는 여러 resource를 가진 하나의 logical asset으로 취급한다. copy, move, rename, quarantine, delete, archive, provider projection 중 하나라도 Live Photo resource를 건드리면 operation을 해당 logical asset/occurrence의 완전한 resource set으로 확장하거나 실패해야 한다. provenance preference, exact-duplicate 판단, 성능 최적화보다 이 규칙이 우선하며 검증된 pair의 한쪽만 독립적으로 처리하지 않는다.

## 안전
- 기본 동작은 read-only 검사다. `scan`, `plan`과 미래의 변경 작업인 `apply`를 분리한다.
- 초기 release에는 영구 삭제를 구현하지 않는다. copy, verify, catalog commit, quarantine을 우선한다.
- source 또는 archive root를 사용할 수 없다는 사실은 파일이 삭제되었다는 증거가 아니다. missing file을 reconcile하기 전에 검증된 root marker를 요구한다.
- 기존 사용자 변경을 보존하고 migration은 되돌릴 수 있게 유지한다.

## 개인정보 보호
- 개인 media, Takeout export, sidecar, catalog database, credential, provider token, raw hash, perceptual hash, feature vector, GPS coordinate, Live Photo content identifier, 개인 absolute path를 절대 commit하지 않는다.
- AI agent는 local media-processing trust boundary 밖에 둔다. 정상 agent workflow에서 raw hash, raw identifier, GPS, MakerNote, thumbnail/frame/audio, filename, relative path, canonical path, catalog path, exact byte size, capture timestamp 같은 개인 media/file detail을 읽거나 전달할 필요가 없도록 interface를 설계한다.
- local process는 필요한 민감 값을 계산할 수 있지만 agent에는 opaque root/asset/group/plan ID, provenance category, role, status, count, confidence, warning code 같은 최소 semantic result만 제공한다. AI service로 개인 media byte나 media-derived fingerprint를 보내는 기능은 core에 두지 않는다.
- 사람이 로컬에서 보는 diagnostic output과 agent-safe output을 구분한다. AI agent에는 `--agent-json` 같은 privacy-minimized surface를 사용하고 path를 포함하는 일반 diagnostic output을 전달하지 않는다.
- repository fixture는 synthetic/generated data이거나 공개를 명시적으로 승인받은 자료만 사용한다.

## 의존성과 라이선스
- 필요한 기능을 Apple의 공식 framework/API가 충분히 안정적으로 제공한다면 third-party나 자체 재구현보다 공식 경로를 우선한다.
- 핵심 차별 영역이 아닌 복잡한 기능을 새로 구현하기 전에, 널리 사용되고 유지보수되며 CLI/API와 라이선스가 명확한 best-of-breed 외부 프로젝트가 사실상 상위호환인지 먼저 평가한다. 더 강하고 검증된 도구가 있으면 작은 adapter로 재사용하고 같은 엔진을 다시 만들지 않는다.
- 자체 구현은 Live Photo asset 관계, provenance, preferred representation, archive plan/transaction처럼 PhotoArchiveKit이 반드시 소유해야 하는 semantic/safety 영역이나, 공식/외부 도구가 privacy·정확성·기능 요구를 충족하지 못하는 경우에 한한다.
- 선택적 adapter는 사용자가 설치한 도구를 subprocess로 호출할 수 있다. 별도 license review 없이 third-party binary를 vendor하거나 재배포하지 않는다.
- 선택적 interoperability를 문서화할 때 upstream 도구 이름을 정확하게 사용하고, sponsorship 또는 affiliation을 암시하지 않는다.

## 문서와 프로젝트 상태
- `README.md`는 기본 영어 overview로 유지한다. `README.ko.md`는 한국어 counterpart로 유지하고 사용자에게 보이는 동작이 바뀌면 둘 다 갱신한다.
- 작업을 재개하기 전에 `STATE.md`를 읽는다. 현재 상태 또는 다음 concrete step이 바뀔 때만 갱신한다.
- 비용이 큰 재사용 가능한 validation 결과는 개인 경로, identifier, hash, media detail 없이 `MILESTONES.md`에 기록한다.
