# 기여 가이드

PhotoArchiveKit은 의도적으로 작고 safety-first인 프로젝트다. contribution도 이 성격을 유지해야 한다.

## Branch와 commit workflow

- 기본 개발 branch는 `dev`다. 평소 작업은 `dev`에서 하고 안정화된 checkpoint만 `main`으로 승격한다.
- 의미 있는 작은 단위마다 local commit을 남기고, 모든 commit을 자동으로 push하지 않는다. remote 공유·CI·backup 가치가 있는 굵직한 checkpoint 또는 명시적 요청이 있을 때 `dev`를 push한다.
- commit message는 작은 PR 수준으로 작성한다. 제목 뒤 본문에 **문제/변경 내용/검증/privacy·safety 영향/남은 작업**을 적는다.
- `main`으로 올리기 전에는 최소 `swift build`, self-test, public-tree check를 통과하고 관련 real-library validation이 있으면 재확인한다.

## 변경 전 확인

1. `AGENTS.md`, `STATE.md`, 관련 design document를 읽는다.
2. milestone이 검토된 mutating operation을 명시적으로 도입하지 않는 한 scan 대상 media는 read-only로 유지한다.
3. 가능하면 synthetic data로 재현한다.
4. 실제 photo/video, Takeout export, catalog, hash, identifier, credential, 개인 absolute path를 commit하지 않는다.

## Build 및 Validation

```bash
swift build
swift run photoarchive-selftest
swift run photoarchive doctor
```

현재 local project는 active command-line toolchain에서 XCTest 또는 Swift Testing module을 제공하지 않기 때문에 `swift test` 대신 self-test executable을 사용한다.

scanner 변경 시에는 disposable directory에서도 테스트하고 input byte와 path가 바뀌지 않았는지 확인한다.

## 설계 규칙

- Live Photo resource를 하나의 logical asset으로 취급한다.
- basename만이 아니라 embedded linkage로 pair한다.
- raw hash와 media-derived identifier를 agent-safe report에 넣지 않는다.
- AI agent에는 `--agent-json` 같은 privacy-minimized interface만 사용하고 filename/path, capture timestamp, byte size 등 file-level private detail도 보내지 않는다.
- scan, plan, apply를 분리한다.
- 사용할 수 없는 external root를 deletion으로 해석하지 않는다.
- similarity는 review signal이지 deletion authority가 아니다.
- third-party integration은 optional이며 별도 license를 유지한다.
- future milestone에서 명확한 필요가 확인되기 전에는 background service를 피한다.

## 문서

`README.md`는 기본 영어 문서이고 `README.ko.md`는 한국어 counterpart다. 사용자에게 보이는 command 또는 guarantee가 바뀌면 둘 다 갱신한다.

`STATE.md`에는 지속적으로 유효한 현재 상태만 기록한다. 비용이 큰 validation 결과를 다시 반복하지 않기 위해 필요할 때만 `MILESTONES.md`에 milestone을 추가한다.

## Pull Request

집중된 pull request에는 다음을 설명한다.

- 문제와 safety boundary
- 사용자에게 보이는 동작
- 수행한 validation
- privacy 영향
- migration 또는 rollback 요구사항
- optional third-party license 영향
