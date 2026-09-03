# 선택적 Integration

PhotoArchiveKit의 required runtime은 의도적으로 self-contained다. Apple system framework, CryptoKit, macOS SQLite library를 사용한다. optional tool이 개별 stage를 개선할 수 있지만 core scanner, Live Photo grouping, exact-resource comparison, catalog, event suggestion은 없어도 동작한다.

## 일반 정책

normal integration pattern:

1. 사용자가 upstream program을 독립적으로 설치/configure한다.
2. PhotoArchiveKit이 `PATH` 또는 explicit configuration으로 executable을 찾는다.
3. small adapter가 argument array를 사용해 별도 process로 호출한다.
4. adapter는 필요한 최소 result만 parse한다.
5. agent-facing output에는 path, boolean, confidence, opaque group ID만 포함하고 raw hash, frame, feature data는 포함하지 않는다.

PhotoArchiveKit은 optional binary를 조용히 download하거나 release 안으로 copy하지 않는다.

연동 프로그램의 이름을 정확히 쓰는 것은 일반적인 open-source practice다. documentation은 official name과 project link를 사용하고 optional/separately licensed임을 명시하며 endorsement를 암시하지 않는다.

## rclone

계획된 용도:

- completed archive와 catalog snapshot을 file cloud로 copy
- remote copy verify
- sanitized session result 반환

Safety default:

- `rclone sync`보다 `rclone copy` 우선
- 이후 `rclone check` 수행
- unavailable local root를 remote deletion permission으로 취급하지 않음
- 사용자의 existing configuration/OAuth storage 재사용
- 실행 전에 정확한 proposed operation 표시

rclone은 bundle하지 않는다. upstream license는 MIT다.

## Czkawka CLI 및 Krokiet

PhotoArchiveKit은 이미 local exact-resource grouping을 수행한다. future `czkawka_cli` adapter는 다음을 추가할 수 있다.

- perceptually similar image candidate
- similar-video candidate
- 지원되는 경우 추가 broken-file/duplicate diagnostic

similarity는 review signal이며 automatic deletion authority가 아니다. raw perceptual hash, frame, cache는 로컬에 유지한다.

upstream repository의 component는 distribution boundary가 다르다. CLI/core는 optional subprocess target으로 적합하며 Krokiet은 PhotoArchiveKit에 embed/redistribute하지 않는다. 사용자는 GUI를 독립적으로 사용할 수 있다.

## ExifTool

계획된 용도:

- extended read-only metadata diagnostic
- migration fixture 비교
- native adapter가 충분히 cover하지 못하는 format의 timestamp candidate
- Takeout sidecar 조사
- future rename-plan dry run

초기 release에서 ExifTool로 Live Photo metadata를 rewrite하지 않는다. output에는 identifier, GPS, serial number 등 sensitive field가 포함될 수 있으므로 adapter는 로컬에서 parse하고 허용된 summary만 emit해야 한다.

## ffprobe

user-installed `ffprobe`는 optional container, stream, duration, audio, timed-metadata diagnostic에 사용할 수 있다. applicable license가 build configuration에 따라 달라지므로 PhotoArchiveKit은 generic FFmpeg build를 redistribute하지 않는다.

## Apple PhotoKit

PhotoKit은 bundled third-party dependency가 아니라 Apple system framework다. future local macOS adapter는 user authorization 후 다음을 수행할 수 있다.

- Photos asset, album, folder 읽기
- Live Photo resource 획득
- `.photo` + `.pairedVideo` resource로 Live Photo 생성
- album 생성 및 membership update
- iCloud Photos와 동기화되는 system Photos library 사용

filesystem archive와 neutral catalog가 계속 authoritative하다.

## Google Photos

첫 practical Google adapter는 범위를 좁게 유지한다.

- supported ordinary media의 flat upload
- app-created provider object 기록
- optional app-created media/album 관리
- Picker 기반 explicitly user-selected import
- unsupported existing-library operation capability report

available하지 않은 API capability를 흉내 내기 위해 browser automation을 사용하지 않는다. 또한 official/verified composite import path가 존재하기 전에는 Live Photo flat upload를 차단하고 하나의 logical asset을 unrelated cloud item으로 split하지 않는다.

## Google Takeout

Takeout은 continuously queryable provider API가 아니라 versioned import format으로 취급한다. parser는 unknown file/JSON field를 보존하고 guessed filename convention이 아니라 disposable real fixture를 기반으로 해야 한다.

## Gallery system

Immich, PhotoPrism, Mylio 등은 useful design reference 또는 archive의 optional view다. PhotoArchiveKit의 portable semantic state를 대체하지 않는다. gallery database에만 존재하는 metadata는 또 다른 lock-in이 될 수 있다.

## Bundling checklist

future에 upstream component를 bundle/link하려면 exact version, transitive license, notice, source obligation, trademark, signing/notarization, update, vulnerability, privacy, dependency absence behavior를 별도 review해야 한다.

현재 component별 license note는 [THIRD_PARTY.md](../THIRD_PARTY.md)를 참고한다.
