# 보안 정책

PhotoArchiveKit은 초기 prototype이다. 현재 fix는 최신 `main` branch에 적용한다.

## 취약점 보고

이 repository에서 GitHub private vulnerability reporting이 활성화되어 있다면 repository의 Security page에서 **Report a vulnerability** 버튼을 사용한다.

버튼이 없다면 sensitive detail이 없는 최소한의 public issue를 열고 maintainer에게 private channel을 요청한다. public issue에는 실제 catalog database, media file, Takeout sidecar, access token, raw hash, Live Photo identifier, GPS coordinate, 개인 absolute path, raw metadata dump를 포함하지 않는다.

유용한 private report에는 affected commit, sanitized command, expected/actual behavior, 가능하면 synthetic reproduction이 포함된다.

## 우선순위가 높은 보고 유형

다음과 관련된 report는 특히 중요하다.

- configured source/archive root 밖으로 path traversal
- symbolic link를 따라 의도하지 않은 위치에 접근
- unavailable root를 deletion으로 해석
- Live Photo operation이 필요한 resource 중 한쪽만 변경
- source file이 바뀐 뒤에도 plan이 적용됨
- interruption 중 corruption 또는 partial commit
- media, path, hash, GPS, identifier, credential leakage
- optional subprocess adapter를 통한 command injection
- malicious Takeout/sidecar filename
- 잘못된 provider account에 upload/delete 수행

## 현재 경계

현재 core는:

- network request를 하지 않는다.
- scan한 media를 수정하지 않는다.
- working catalog를 로컬에 저장한다.
- raw hash와 Live Photo identifier를 report에서 제외한다.
- permanent-delete command가 없다.
- third-party executable을 bundle하지 않는다.

SQLite catalog에는 path와 local integrity value가 들어갈 수 있다. source control과 public support request에 포함하지 않는다. future provider adapter와 mutating command는 별도의 trust boundary로 review해야 한다.
