# PhotoArchiveKit

[English](README.md)

[![CI](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml/badge.svg)](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PhotoArchiveKit은 iPhone 사진·동영상·Live Photo를 특정 사진 클라우드 공급자에 영구 종속시키지 않고 보존하고 정리하기 위한 **로컬 우선·세션 기반 도구**입니다.

프로젝트는 의도적으로 가볍게 유지합니다. 백그라운드 daemon을 실행하거나 별도 gallery server를 운영하지 않으며, 미디어를 불투명한 전용 저장 형식 안으로 옮기지 않습니다. 사진과 동영상은 일반 파일시스템 폴더에 남고, 폴더만으로 표현할 수 없는 관계와 결정만 로컬 SQLite catalog에 기록합니다.

> **현재 상태:** 초기 읽기 전용 prototype입니다. scanner는 실제로 사용할 수 있지만 archive 변경, rename, cloud upload, 삭제는 아직 구현하지 않았습니다.

## 왜 필요한가

장기 사진 archive에는 최소 세 종류의 상태가 있습니다.

1. 사진·동영상 원본 byte
2. 한 장의 정지 이미지와 paired video가 하나의 Live Photo를 이룬다는 논리 관계
3. primary folder와 여러 album membership 같은 사람 또는 프로그램의 분류 결과

어떤 사진 cloud도 이 세 가지를 모두 장기적이고 이동 가능한 형태로 보장하지 않습니다. 그래서 PhotoArchiveKit은 이를 분리합니다.

```text
파일시스템 archive       SQLite catalog            provider별 projection
HEIC/JPEG + MOV/MP4  +   asset 관계             -> Apple Photos / Google Photos
일반 폴더                collection                 선택적 gallery 도구
byte 보존 복제본          provenance와 이력
```

장기 기준은 다음과 같습니다.

- **Media truth:** archive disk의 일반 파일과 최소 하나의 검증된 복제본
- **Semantic truth:** provider-neutral 로컬 SQLite catalog
- **Cloud service:** backup·감상·검색·공유 또는 projection 대상이며, 영구 identity의 기준은 아님

## 현재 가능한 기능

초기 CLI는 다음을 지원합니다.

- Inbox, archive, import, reference root를 하나 이상 재귀적으로 scan
- 내부 Apple linkage metadata로 Live Photo의 still/video resource 식별
- 서로 다른 root에서 발견된 사본을 하나의 논리 Live Photo asset으로 통합
- 다른 root에 완전한 사본이 있어도 현재 root의 누락을 숨기지 않도록 root별 completeness 보고
- 크기가 같은 후보에 한해 로컬 SHA-256으로 exact duplicate 탐색
- 실제 hash 대신 재사용 가능한 opaque duplicate group ID 출력
- 가능한 경우 timezone을 포함한 EXIF·QuickTime 촬영시각 추출
- 설정 가능한 시간 간격을 기준으로 날짜형 event folder 자동 제안
- resource, 논리 asset, provenance, duplicate group, 향후 collection mapping, scan session을 SQLite에 저장
- 사람이 읽는 report와 privacy-safe JSON report 제공
- 선택적 외부 도구의 설치 여부만 감지하며 필수 의존성으로 만들지 않음
- 현재 모든 작업에서 media 파일을 변경하지 않고 network에 접속하지 않음

정확한 중복 판정을 위해 catalog 내부에는 raw exact-file hash가 저장됩니다. 하지만 일반 CLI 및 agent용 report에는 raw hash와 Live Photo content identifier가 절대로 포함되지 않습니다.

## 실제 ingest 검증 결과

iPhone Live Photo 3장과 일반 동영상 1개로 만든 폐기 가능한 작은 fixture를 macOS에서 비교했습니다. 개인 media fixture 자체는 이 repository에 포함하지 않습니다.

해당 fixture에서 확인된 결과는 다음과 같습니다.

| 가져오기·내보내기 경로 | 결과 |
| --- | --- |
| macOS Image Capture | 완전한 HEIC + MOV Live Photo resource. 기준 ingest 경로로 선정 |
| iPhone Photos AirDrop + **모든 사진 데이터** | 테스트한 모든 resource가 Image Capture와 byte 단위로 동일 |
| 일반 iPhone Photos AirDrop | HEIC 자체는 byte 단위로 동일했지만 Live Photo paired video 3개가 누락 |
| Google Photos 웹 다운로드 | 테스트한 모든 HEIC 및 motion resource가 Image Capture와 byte 단위로 동일. 원래 `.MOV`와 같은 byte를 가진 파일이 `.MP4` 이름으로 내려오기도 함 |
| Google Photos iOS 앱 AirDrop | archive용 Live Photo resource가 아니라 변환된 독립 JPG/MP4 생성 |

읽기 전용 scanner로 다섯 root를 동시에 검사한 결과도 예상과 일치했습니다.

- media resource 29개
- logical asset 8개
- logical Live Photo 3개
- exact duplicate resource group 7개
- 일반 AirDrop root에서 Live Photo still-only 경고 3개

이 결과는 당시 fixture와 software version에서 확인된 사실입니다. 앞으로 모든 Google 다운로드나 Google Takeout이 같은 결과를 준다는 보장은 아닙니다. Takeout은 별도 검증 대상으로 남아 있습니다.

## 요구 환경

- macOS 14 이상
- Swift 6 toolchain
- 필수 third-party executable 없음

현재 PhotoArchiveKit은 Apple system framework인 `ImageIO`, `AVFoundation`, `CryptoKit`과 system SQLite library를 사용합니다.

## 빌드와 실행

```bash
swift build
swift run photoarchive doctor
```

한 개 Inbox를 읽기 전용으로 scan합니다.

```bash
swift run photoarchive scan --inbox "~/Photo Inbox"
```

폴더를 먼저 한곳에 섞지 않고 여러 source를 함께 scan하면 exact copy, provenance, source 간 Live Photo 관계를 통합할 수 있습니다.

```bash
swift run photoarchive scan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --takeout "~/Pictures/Takeout-2" \
  --archive "/Volumes/Photo Archive/Photos"
```

등록한 root가 서로 중첩되어 있으면 가장 구체적인 root가 해당 파일을 소유합니다. 따라서 위 예시의 Takeout folder는 `~/Pictures`를 통해 다시 scan되지 않으며, 파일 byte만으로 출처를 구분할 수 없는 exact copy도 Google Takeout provenance를 유지할 수 있습니다.

전체 privacy-safe JSON report를 출력합니다.

```bash
swift run photoarchive scan --json --inbox "~/Photo Inbox"
```

실험에서는 별도 임시 catalog를 사용할 수 있습니다.

```bash
swift run photoarchive scan \
  --catalog "/tmp/photoarchive-test.sqlite3" \
  --reference "/path/to/test-fixtures"
```

외부 test framework가 필요 없는 synthetic self-test를 실행합니다.

```bash
swift run photoarchive-selftest
```

기본 working catalog 위치는 다음과 같습니다.

```text
~/Library/Application Support/PhotoArchiveKit/catalog.sqlite3
```

report는 정제되지만 catalog 자체에는 경로와 로컬 integrity 값이 들어갈 수 있으므로 private application state로 다뤄야 합니다.

## 명령

### `photoarchive scan`

아래 root option은 여러 번 사용할 수 있습니다.

- `--inbox PATH` — provenance를 모르는 Inbox
- `--local PATH` — local/iPhone-derived media가 섞인 library root
- `--apple PATH` — Apple/iPhone에서 직접 가져온 root
- `--takeout PATH` — Google Photos Takeout export
- `--google-web PATH` — Google Photos web download
- `--archive PATH`
- `--import PATH`
- `--reference PATH`

option 없이 입력한 path는 Inbox로 처리합니다.

그 밖의 option:

- `--catalog PATH` — SQLite catalog 경로 지정
- `--json` — privacy-safe JSON 출력
- `--no-exact-duplicates` — 로컬 SHA-256 비교 생략
- `--event-gap-hours NUMBER` — 이 시간보다 긴 공백이 있으면 새 event로 분리, 기본값 6시간
- `--jobs NUMBER` — 동시에 실행할 metadata probe 수 제한

### `photoarchive doctor`

필수 system 기능과 선택적 executable이 `PATH`에 있는지 보고합니다.

Google Takeout root에서는 embedded media metadata로 신뢰할 수 있는 촬영시각을 얻지 못한 경우 sidecar의 `title`과 `photoTakenTime`만 읽습니다. GPS, description 등 다른 Takeout metadata는 이 경로에서 import하지 않습니다.

## 자동 분류 방향

PhotoArchiveKit은 단순히 Finder 작업을 안전하게 만드는 데서 그치지 않고, 사람이 해야 하는 분류를 최대한 줄이는 방향으로 설계합니다.

계획한 classifier는 여러 단계로 나뉩니다.

1. **결정론적 grouping:** 촬영시각·timezone·burst·Live Photo 관계·source session
2. **로컬 event segmentation:** 시간 간격 기반 folder 제안은 이미 구현됨
3. **기존 archive 학습:** 사용자가 이미 정리한 folder를 예시로 삼아 가장 가까운 collection 제안
4. **선택적 on-device visual analysis:** Apple Vision/Core ML로 similarity와 대략적인 content label을 로컬에서만 계산. feature vector는 agent report에 포함하지 않음
5. **confidence policy:** 신뢰도가 높은 제안은 자동 적용하고, 중간 수준만 작은 review queue로 보내며, 낮은 경우 날짜 event folder로 안전하게 fallback

이 방식은 한 사용자의 folder 이름을 code에 하드코딩하지 않으면서도 archive를 사용할수록 자동 분류가 개선되도록 합니다. 자세한 정책은 [자동 분류 전략](docs/AUTOMATION.md)에 정리했습니다.

## Provider 기능 경계

Apple PhotoKit은 사용자 승인을 받은 로컬 macOS client가 Photos asset과 album을 읽고, `.photo`와 `.pairedVideo` resource로 Live Photo를 만들며, 수정 가능한 album membership을 변경할 수 있으므로 향후 Live Photo와 album projection에 더 적합합니다.

현재 Google Photos Library API는 지원되는 일반 media를 album 지정 없이 library에 올릴 수 있으므로, album 자동 동기화가 불가능하더라도 평면 업로드 기능 자체는 유용합니다. 반면 기존 library 읽기와 album 작업은 대부분 app-created content로 제한되며, public upload model에는 still과 paired video를 하나의 composite Live Photo로 만드는 문서화된 operation이 없습니다. 따라서 향후 Google adapter는 가능한 일반 media의 평면 업로드를 지원하되, 검증된 Live Photo를 두 개의 독립 항목으로 나누어 올리고 보존에 성공했다고 표시하지 않습니다.

날짜가 명시된 기능 matrix와 공식 문서 링크는 [Provider 기능](docs/PROVIDER_CAPABILITIES.md)에 있습니다.

## Live Photo 안전 모델

Live Photo는 최소 두 resource를 가진 하나의 논리 asset입니다.

```text
Live Photo asset
├── photo          HEIC 또는 JPEG
└── paired_video   MOV 또는 MP4
```

PhotoArchiveKit은 basename이 같다는 이유만으로 pair라고 판단하지 않습니다. still-side identifier와 QuickTime content identifier를 로컬에서 비교하고, catalog에는 keyed fingerprint만 저장하며, report에는 identifier 값을 노출하지 않습니다.

향후 파일을 변경하는 명령은 검증된 Live Photo의 모든 resource를 한 transaction으로 처리해야 합니다. 한쪽만 rename·move·quarantine·delete하는 동작은 프로젝트 정책상 금지합니다.

## 선택적 외부 도구 연동

core는 아래 프로젝트를 포함하거나 요구하지 않지만, 향후 adapter는 사용자가 이미 설치한 executable을 호출할 수 있습니다.

- `rclone`: 검증 가능한 off-site 파일 복제
- `czkawka_cli`: 추가 exact duplicate 및 perceptual similarity 후보 생성
- ExifTool: 폭넓은 metadata 조사와 migration 진단
- `ffprobe`: 선택적 video 진단

연동 가능한 도구의 이름을 정확히 문서화하는 것이 일반적이며, 숨기는 것보다 낫습니다. 단, 선택 사항이고 별도 설치·별도 license이며 PhotoArchiveKit과 제휴 관계가 없다는 점을 분명히 해야 합니다. 자세한 내용은 [THIRD_PARTY.md](THIRD_PARTY.md)를 참고하십시오.

## 초기 release에서 하지 않을 일

- 상시 실행 sync daemon
- 별도 gallery server
- Google Photos browser UI 자동화
- 영구 삭제
- 사용자 모르게 metadata 수정
- perceptual similarity를 삭제 허가로 취급
- 외장 disk가 연결되지 않은 상태를 파일 삭제로 해석
- HEIC와 MOV를 Google Photos에 별도 항목으로 올리고 Live Photo가 보존됐다고 주장

## 문서

- [프로젝트 초심과 범위 게이트](docs/PROJECT_NORTH_STAR.md)
- [Architecture](docs/ARCHITECTURE.md)
- [자동 분류 전략](docs/AUTOMATION.md)
- [Provider 기능](docs/PROVIDER_CAPABILITIES.md)
- [선택적 연동](docs/INTEGRATIONS.md)
- [Privacy model](docs/PRIVACY.md)
- [Ingest 안내](docs/INGEST.md)
- [검증 기록](docs/VALIDATION.md)
- [Agent interface](docs/AGENT_INTERFACE.md)
- [Roadmap](docs/ROADMAP.md)
- [현재 개발 상태](STATE.md)
- [검증된 milestone](MILESTONES.md)
- [변경 기록](CHANGELOG.md)
- [보안 정책](SECURITY.md)
- [기여 안내](CONTRIBUTING.md)

## License

PhotoArchiveKit은 [MIT License](LICENSE)로 배포됩니다.
