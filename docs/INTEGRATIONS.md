# 선택적 Integration

PhotoArchiveKit의 required runtime은 의도적으로 self-contained다. Apple system framework, CryptoKit, macOS SQLite library를 사용한다. optional tool이 개별 stage를 개선할 수 있지만 core scanner, Live Photo grouping, exact-resource comparison, catalog, event suggestion은 없어도 동작한다.

## 일반 정책

기능 구현 우선순위는 다음과 같다.

1. **공식 platform/provider API 또는 system framework**가 요구 기능을 안정적으로 제공하면 그것을 우선한다. Apple-native 기능은 가능한 범위에서 ImageIO, AVFoundation, PhotoKit 같은 공식 경로를 first choice로 본다.
2. 공식 경로가 없거나 부족하고, 해당 기능이 PhotoArchiveKit의 고유 semantic 영역이 아니라면 **널리 사용되고 유지보수되며 CLI/API·문서·라이선스가 명확한 best-of-breed 외부 도구**를 먼저 평가한다. 검증된 도구가 자체 구현보다 명확히 강하면 adapter로 재사용한다.
3. 자체 구현은 Live Photo asset 관계, provenance, preferred representation, archive plan/transaction처럼 PhotoArchiveKit이 반드시 소유해야 하는 영역이거나, 공식/외부 도구가 privacy·정확성·기능 요구를 충족하지 못할 때만 선택한다.

이 정책의 목적은 dependency 수를 무조건 줄이는 것이 아니라 **이미 더 잘 해결된 문제를 다시 만들다가 정확도와 안정성을 떨어뜨리지 않는 것**이다. 외부 도구를 채택하더라도 raw hash·pHash·frame·광범위한 metadata dump 같은 내부 결과는 로컬에 머물고, SQLite의 provider-neutral semantic state와 최종 archive 결정은 PhotoArchiveKit이 소유한다.

현재 예시는 다음과 같다.

- Apple media metadata와 future Photos projection: 공식 Apple framework가 충분하면 공식 경로 우선
- remote file replication/verification: rclone 같은 성숙한 전용 도구 우선
- perceptual image/video similarity: Czkawka CLI 같은 성숙한 전용 도구 우선
- broad/obscure metadata diagnostic: 필요해지는 시점에 ExifTool을 우선 평가하고 같은 범용 metadata engine을 직접 만들지 않음
- Apple Photos library query/export/album interoperability: 필요해지는 시점에 osxphotos를 우선 평가하되, 동일 기능을 공식 PhotoKit이 더 안전하고 완전하게 제공하면 PhotoKit을 우선

normal integration pattern:

1. 사용자가 upstream program을 독립적으로 설치/configure한다.
2. PhotoArchiveKit이 `PATH` 또는 explicit configuration으로 executable을 찾는다.
3. small adapter가 argument array를 사용해 별도 process로 호출한다.
4. adapter는 필요한 최소 result만 parse한다.
5. agent-facing output에는 path, boolean, confidence, opaque group ID만 포함하고 raw hash, frame, feature data는 포함하지 않는다.

PhotoArchiveKit은 optional binary를 조용히 download하거나 release 안으로 copy하지 않는다.

연동 프로그램의 이름을 정확히 쓰는 것은 일반적인 open-source practice다. documentation은 official name과 project link를 사용하고 optional/separately licensed임을 명시하며 endorsement를 암시하지 않는다.

## Required core와 optional tool의 경계

PhotoArchiveKit은 ExifTool이나 osxphotos가 없어도 핵심 archive scanner가 동작해야 한다. 다만 이것은 외부 도구의 전체 기능을 자체 구현한다는 뜻이 아니다.

| 기능 | required core | optional tool의 추가 가치 |
| --- | --- | --- |
| HEIC/JPEG 촬영시각·timezone | ImageIO의 EXIF metadata probe | ExifTool로 더 넓은 vendor/format metadata 진단 |
| MOV/MP4 creation metadata | AVFoundation QuickTime metadata probe | ExifTool/ffprobe로 container·stream·이상 metadata 진단 |
| Live Photo embedded linkage | ImageIO + AVFoundation으로 identifier를 로컬 비교하고 catalog에는 keyed fingerprint만 저장 | 외부 도구는 cross-check/diagnostic일 뿐 pairing authority가 아님 |
| Google Takeout 기본 촬영시각 | native sidecar importer가 `title`과 `photoTakenTime`만 읽음 | 향후 migration diagnostic에 ExifTool 사용 가능 |
| Apple Photos library query·album·edited/original·export/import | 현재 required core에는 없음 | osxphotos 또는 향후 공식 PhotoKit adapter가 담당 가능 |

따라서 **ExifTool은 현재 core가 필요로 하는 좁은 metadata 역할에는 필수가 아니지만, ExifTool 수준의 폭넓은 metadata coverage를 PhotoArchiveKit이 대체한 것은 아니다.** 마찬가지로 **osxphotos는 현재 scanner에 필요하지 않지만, Apple Photos library 자체를 조회·내보내기·album 조작하는 역할은 아직 PhotoArchiveKit core가 제공하지 않는다.**

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

PhotoArchiveKit은 catalog identity와 archive safety에 필요한 local exact-resource grouping을 이미 수행한다. 이 exact engine은 같은 byte-size 후보에 대해 파일 전체 SHA-256을 읽어 **파일 내용이 cryptographic exact match인 경우만** 같은 exact group으로 묶으며 perceptual similarity를 판정하지 않는다.

future `czkawka_cli` adapter의 주 역할은 다음과 같다.

- perceptually similar image candidate
- similar-video candidate
- 초기 real-library audit나 release validation에서 PhotoArchiveKit exact 결과를 독립적으로 cross-check
- 성능상 이득이 검증될 경우 optional candidate-generation/acceleration
- 지원되는 경우 추가 broken-file diagnostic

정상적인 매 scan마다 Czkawka exact scan을 반드시 한 번 더 돌릴 필요는 없다. PhotoArchiveKit exact engine이 안정화된 뒤에는 Czkawka exact mode를 독립 검증·회귀 점검에 사용하고, 평상시 가장 큰 추가 가치는 **byte가 다르지만 같은 촬영물일 가능성이 있는 image/video similarity 후보**를 찾는 것이다.

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

## osxphotos

osxphotos는 required dependency가 아니다. future adapter 또는 수동 interoperability 경로로 다음 역할을 시험할 수 있다.

- Apple Photos library query/export
- Photos album membership 읽기 및 일부 album update
- original/edited representation 조사
- filesystem archive에서 Photos로 import하는 실험적 bridge

초기 integration은 read/query/export를 우선하고, Photos를 변경하는 operation은 별도 test library에서 검증한 뒤에만 사용한다. 장기적으로 Apple Photos에 쓰는 공식 projection path는 여전히 PhotoKit을 우선한다. osxphotos를 사용하더라도 PhotoArchiveKit의 filesystem archive와 SQLite semantic catalog가 authoritative state를 유지한다.

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
