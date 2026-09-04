# PhotoArchiveKit 프로젝트 지침

## 제품 범위
- `docs/PROJECT_NORTH_STAR.md`를 제품 범위의 최우선 gate로 사용한다. 새 기능을 제안하거나 구현하기 전에 반드시 읽는다.
- real library에서 duplicate reconciliation, Live Photo 보존, preferred representation 선택, folder archive plan, verified copy, portable semantic state의 완료 기준을 충족하기 전에는 주변 기능을 우선하지 않는다.
- PhotoArchiveKit은 local-first, session 기반, 경량 도구로 유지한다. 이후 milestone에서 명시적으로 필요성이 확인되지 않는 한 background daemon이나 filesystem watcher를 추가하지 않는다.
- core는 third-party executable 없이도 유용해야 한다. 선택적 integration은 성숙한 duplicate/replication/metadata 기능을 다시 구현하기보다 사용자가 이미 설치한 도구를 활용할 수 있다.
- Live Photo는 여러 resource를 가진 하나의 logical asset으로 취급한다. 검증된 pair의 한쪽만 move, rename, quarantine, delete하도록 계획하거나 실행하지 않는다.

## 안전
- 기본 동작은 read-only 검사다. `scan`, `plan`과 미래의 변경 작업인 `apply`를 분리한다.
- 초기 release에는 영구 삭제를 구현하지 않는다. copy, verify, catalog commit, quarantine을 우선한다.
- source 또는 archive root를 사용할 수 없다는 사실은 파일이 삭제되었다는 증거가 아니다. missing file을 reconcile하기 전에 검증된 root marker를 요구한다.
- 기존 사용자 변경을 보존하고 migration은 되돌릴 수 있게 유지한다.

## 개인정보 보호
- 개인 media, Takeout export, sidecar, catalog database, credential, provider token, raw hash, perceptual hash, feature vector, GPS coordinate, Live Photo content identifier, 개인 absolute path를 절대 commit하지 않는다.
- raw hash와 media-derived identifier는 로컬에서 처리할 수 있지만, 일반 report와 agent-facing output에는 boolean, confidence level, opaque group ID만 노출한다.
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
