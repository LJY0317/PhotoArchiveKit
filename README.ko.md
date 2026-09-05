# PhotoArchiveKit

[English](README.md)

[![CI](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml/badge.svg)](https://github.com/LJY0317/PhotoArchiveKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PhotoArchiveKit은 iPhone 사진·동영상·Live Photo를 특정 사진 클라우드 공급자에 영구 종속시키지 않고 보존하고 정리하기 위한 **로컬 우선·세션 기반 도구**입니다.

### 최우선 핵심 약속

1. **AI agent가 개인 사진의 식별 가능한 세부정보를 읽을 필요가 없습니다.** 정상 agent workflow에서는 PhotoArchiveKit의 로컬 프로세스가 파일을 읽고 hash·metadata를 Mac 안에서 계산하며, AI agent에는 opaque ID와 최소 semantic state만 전달합니다. `--agent-json`은 media byte, thumbnail/frame/audio, filename, path, raw hash, Live Photo identifier, GPS, MakerNote, exact byte size, capture timestamp 등 file-level private detail을 의도적으로 제외합니다. 따라서 AI agent가 정리를 지휘하더라도 이런 개인 식별 정보를 AI service로 보내지 않는 구조를 기본값으로 합니다. 단, general-purpose shell이나 사용자가 명시적으로 요청한 local diagnostic은 이 경계를 우회할 수 있으므로 agent는 privacy-minimized CLI/API surface만 사용해야 합니다.
2. **Live Photo는 무조건 하나의 atomic asset입니다.** still image와 paired video를 copy, move, rename, quarantine, archive, delete, provider projection에서 서로 독립 파일처럼 처리하지 않습니다. 전체 resource graph를 보존할 수 없으면 operation을 전체 asset으로 확장하거나 중단합니다.
3. **Archive는 사람이 읽을 수 있고 다시 복원 가능해야 합니다.** media는 HDD/file replica에 평범한 HEIC/JPEG/MOV/MP4 파일로 남기고, SQLite에는 Live Photo 관계, provenance, collection, decision 같은 provider-neutral semantic state를 보존합니다.
4. **완전 동일 중복과 유사 사진은 다른 문제입니다.** byte-identical redundancy는 local verification 후 자동화할 수 있지만, perceptual similarity와 best-shot 선택은 사람이 검토하는 영역으로 남깁니다.

프로젝트는 의도적으로 가볍게 유지합니다. 백그라운드 daemon을 실행하거나 별도 gallery server를 운영하지 않으며, 미디어를 불투명한 전용 저장 형식 안으로 옮기지 않습니다. 사진과 동영상은 일반 파일시스템 폴더에 남고, 폴더만으로 표현할 수 없는 관계와 결정만 로컬 SQLite catalog에 기록합니다.

> **현재 상태:** 초기 safety-first prototype입니다. `scan`, `archive-coverage`, `plan`, `organize-plan`은 media에 대해 읽기 전용이고, `archive-index`는 사용자가 직접 관리하는 archive를 media 이동 없이 최신 상태로 index하며 명시적 `--apply`에서만 그 root 전용 portable inventory를 씁니다. 현재 user-managed HDD workflow는 단순합니다. 사용자가 Finder로 직접 copy/분류하고, archive root를 다시 index한 뒤, 현재 사본으로 인정할 모든 root를 `archive-coverage`로 함께 비교합니다. PhotoArchiveKit은 등록되지 않은 임의 폴더를 자동 탐색하거나 background filesystem watcher를 실행하지 않습니다. 영구 삭제, 독립 replica 검증, cloud upload는 아직 완료되지 않았습니다.

### 현재 권장 workflow

1. Mac library, nested Google Takeout, user-managed HDD photo root처럼 비교에 포함할 root를 명시적으로 등록합니다.
2. HDD media copy/분류는 사용자가 Finder에서 직접 해도 됩니다. PhotoArchiveKit이 HDD 폴더 구조를 소유할 필요는 없습니다.
3. 수동 HDD 변경 뒤 `archive-index`를 다시 실행하면 local catalog가 archive root의 현재 파일과 folder hierarchy를 반영합니다.
4. 현재 사본으로 인정할 모든 root를 넣어 `archive-coverage`를 실행합니다. root별 exact 보존 상태와 Live Photo가 다른 root에 완전/부분·ambiguous/누락 상태로 존재하는지를 확인할 수 있습니다.

`archive-index`는 해당 archive root를 갱신할 뿐, 한 번도 등록·scan하지 않은 source folder까지 자동 발견하지는 않습니다. 현재 multi-root backup 관계는 `archive-coverage` session에서 명시적으로 다시 계산합니다. 이 구조는 외장 HDD가 잠시 분리된 상태를 삭제로 오해하지 않게 해 줍니다.

## 왜 필요한가

첫 번째 핵심 가치는 **agent-private orchestration**, 두 번째는 **atomic하고 복원 가능한 Live Photo 보존**입니다. duplicate reconciliation, preferred representation, 사람이 읽을 수 있는 folder organization, verified replica, provider-neutral migration state는 이 두 invariant 위에 쌓입니다.

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
- 검증된 Live Photo still/video 한 쌍의 basename이 서로 다르면 non-blocking notice로 알려줌. filename 일치가 아니라 embedded linkage metadata가 identity authority이므로 pair 자체는 정상으로 유지하며, agent-safe output에는 notice code와 root ID만 노출
- identifier가 일치하는 paired video에 유효한 QuickTime `still-image-time` timed-metadata marker가 정확히 하나 있어야 해당 Live Photo occurrence를 complete로 인정
- 서로 다른 root에서 발견된 사본을 하나의 논리 Live Photo asset으로 통합하고, embedded identifier로 identity를 먼저 확정한 뒤 directory/basename은 경계 힌트로만 사용해 반복 export occurrence를 분할
- 다른 root에 완전한 사본이 있어도 현재 root의 누락을 숨기지 않도록 root별 completeness 보고
- 크기가 같은 후보에 한해 로컬 SHA-256으로 exact duplicate 탐색
- 실제 hash 대신 재사용 가능한 opaque duplicate group ID 출력
- exact duplicate group이 새 scan에서 다시 관측되면 member snapshot 전체를 현재 관측값으로 교체하여 과거에 존재했던 member가 current group에 섞이지 않도록 유지
- `archive-coverage`로 두 개 이상의 등록 root를 media-read-only 비교: root별 exact-covered/exact-unique resource 수, root pair별 exact group overlap, 다른 root에 있는 Live Photo counterpart의 complete/split-or-ambiguous/still-only/video-only/none 상태를 보고
- 가능한 경우 timezone을 포함한 EXIF·QuickTime 촬영시각 추출
- 설정 가능한 시간 간격을 기준으로 날짜형 event folder 자동 제안
- resource, 논리 asset, provenance, duplicate group, source collection mapping, 최초 filename, path history, scan session을 SQLite에 저장
- 기존에 사용자가 직접 관리하던 **archive root**를 `archive-index`로 index: 현재 하위 folder hierarchy를 user-authored collection semantics로 보존하고, media는 그대로 둔 채 수동 Finder 이동 뒤 stale folder membership을 정리하며, 모든 media resource의 exact hash를 확보
- path/filesystem identity, byte size, modification time, metadata-probe cache version이 그대로인 파일은 EXIF/QuickTime/Live Photo metadata probe 결과를 재사용함. 과거 metadata probe 실패와 현재 유효 capture time이 변경 가능한 Google Takeout sidecar에서 온 media는 보수적으로 다시 probe함
- 변경되지 않은 파일은 Mac-local SQLite의 metadata와 SHA-256 evidence를 재사용하고, archive root에서는 hidden `.photoarchive/inventory-v1.jsonl`의 portable exact-hash cache도 사용할 수 있음. 일반 scan 계열 command와 `archive-index --fresh`는 metadata/hash reuse를 모두 끔
- 빠른 authoritative working catalog는 Mac에 두되, removable archive root마다 relative 구조와 integrity evidence를 가진 root-scoped portable inventory를 함께 둘 수 있음. 이 inventory는 다른 컴퓨터에서 재스캔을 가속하는 구조도/cache이지 mutation authority가 아님
- catalog의 portable semantic subset을 versioned JSONL로 export하고 raw hash·Live Photo fingerprint·filesystem ID·absolute root path·capture timestamp·provider object ID·generated scan/event cache 없이 새 SQLite catalog로 dry-run/restore
- 같은 volume 안의 rename/move에서는 physical resource identity를 유지하고, optional `.photoarchive-root` marker로 이동된 source root도 동일 root로 다시 인식
- `IMG_####` / `IMG_E####` camera-style 이름만 대상으로 `YYYY-MM-DD_HH-mm-ss[_NN]` 촬영시각 기반 flat rename `organize-plan` 생성; custom filename은 보존
- marker가 초기화된 destination을 대상으로 immutable `archive-plan` 생성: logical asset마다 canonical representation 하나를 선택하고, complete Live Photo still+paired-video를 atomic하게 유지하며, source/destination marker binding과 relative path를 고정하고, AUTO source의 현재 byte를 같은 scan/catalog의 exact SHA-256 evidence와 다시 비교하며, destination에 이미 존재하는 filename collision은 deterministic suffix로 회피
- immutable plan schema v2에서 `archive-copy`를 dry-run/apply: current catalog의 asset/role/hash evidence와 root marker를 독립적으로 다시 확인하고, AUTO item을 hidden `.photoarchive` staging에 copy한 뒤 finalization 전후 full SHA-256을 검증하며, 이미 검증된 staging/final file에서 idempotent resume하고, 완료 archive root를 SQLite에 다시 scan한 뒤 archive 내부에 portable catalog JSONL snapshot을 기록. source media는 move/delete하지 않음
- `organize --apply`에는 stable root marker를 요구하고, Live Photo still+video를 같은 destination basename으로 유지하며 post-move filesystem identity/size를 검증한 뒤 stable resource path/history를 full rescan 없이 SQLite에 transaction commit하고, catalog commit 실패 시 filesystem move 전체 rollback
- `cleanup-empty-dirs`는 완료된 organization manifest와 catalog location history에 실제로 기록된 source directory만 대상으로 하며, stable root marker를 확인하고 package/symlink boundary를 제외한 뒤 apply 순간에도 완전히 빈 directory만 제거
- 사람이 읽는 report와 privacy-safe JSON report 제공
- 선택적 외부 도구의 설치 여부만 감지하며 필수 의존성으로 만들지 않음
- `automatic_redundant` exact 후보만 fresh SHA-256으로 preferred copy와 다시 검증한 뒤 local quarantine dry-run/apply 가능; Live Photo candidate set은 해당 item의 모든 resource 검증이 끝난 뒤에만 이동
- Google Takeout의 source-folder/album-like membership을 local SQLite에 먼저 보존한 뒤 Takeout-only exact standalone copy를 물리적으로 collapse할 수 있으며, collection 이름/path는 agent-safe output에 노출하지 않음
- 적용된 quarantine session에 local restore manifest를 남기고, 이동 중 오류가 발생하면 그 session에서 이미 이동한 resource 전체를 rollback하며, `restore-quarantine`도 local catalog의 원래 SHA-256 evidence와 quarantined byte를 fresh 검증한 뒤에만 dry-run/apply
- 현재 모든 분석 단계는 network에 접속하지 않음
- machine-readable output을 깨뜨리지 않는 구조화 scan progress. 재귀 enumeration 중에는 최종 파일 수가 아직 없으므로 발견 개수만 표시하고, 목록이 확정된 뒤 metadata/hash 단계는 `완료/전체`와 퍼센트를 표시. 터미널에서는 stderr 한 줄을 갱신하고 non-interactive log에서는 throttled progress line만 출력하며 `--no-progress`로 끌 수 있음

정확한 중복 판정을 위해 catalog 내부에는 raw exact-file hash가 저장됩니다. 사람용 local diagnostic과 AI agent용 output은 분리합니다. `--json`은 troubleshooting을 위해 local path를 포함할 수 있지만, `--agent-json`은 path·filename·byte size·capture timestamp·raw hash·Live Photo identifier·GPS·preview 등 file-level private data를 제거합니다. AI agent는 agent-safe surface만 사용합니다.

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

읽기 전용 preferred-representation plan을 생성할 수 있습니다. exact duplicate에는 root 역할을 반영한 canonical keeper 정책을 적용합니다. `staging`/`primary_library` root는 같은 root 안의 exact 중복을 대표 사본 하나로 줄일 수 있고, `archive`/`reference` root는 자동 제거 후보가 되지 않습니다. `import_source` 사본은 안전한 retained counterpart 또는 보존된 source semantics가 있을 때만 줄입니다. Live Photo occurrence는 항상 atomic하게 유지하고 해결되지 않은 variant만 review로 남깁니다.

```bash
swift run photoarchive plan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

media를 복사하지 않고 사람이 Finder에서 AUTO exact 결정을 검토하려면 `duplicate-review`로 symbolic link만 들어 있는 local-private review workspace를 만들 수 있습니다. 기본 동작은 active root registry와 일치하는 가장 최근 complete scan snapshot을 재사용하므로 이미 계산한 review를 다시 열기 위해 전체 media library를 다시 읽지 않습니다. 대신 그 결정에 실제로 등장하는 파일의 현재 size, modification time, filesystem identity와 가능한 경우 stable root marker identity를 빠르게 확인합니다. 그대로인 group은 `CURRENT` + `KEEPER/CANDIDATE`, 달라진 group은 `STALE` + `OLD_KEEPER/OLD_CANDIDATE`, 필요한 root가 연결되지 않았으면 `OFFLINE`으로 명확히 표시합니다. 각 group의 local-private `comparison.txt`와 안내문은 한국어로 표시하며 exact-byte evidence, Finder symbolic-link 크기와 구분된 실제 원본 target size, embedded/capture metadata, filesystem 생성/수정 시각, 파일명/경로 차이, filesystem identity, extended-attribute 동일 여부, keeper 선택 이유를 기록합니다. `file_creation_date` fallback은 embedded capture metadata와 분리해서 "파일시스템 생성 시각을 대신 사용한 값"임을 명시합니다. 또한 절대적인 "모든 metadata가 동일"이라고 과장하지 않고 "PhotoArchiveKit이 현재 검사하는 metadata 범위에서 차이를 찾지 못했다"고 범위를 명시합니다. `--preference-only`는 complete Live Photo 유지, 명시적인 `copy`/`복사본` 파일명 표식, 실제 사용자 검토로 승인된 알아보기 쉬운 출처형 파일명, 같은 root의 더 얕은 경로처럼 강한 기본 결정을 숨깁니다. 숫자형 복사 suffix는 상대 파일명과 실제로 대응될 때만 강한 근거로 취급합니다. 파일 basename과 같은 부모 폴더에 들어 있는 사본은 상대가 `무제 폴더`/`Untitled Folder`/`새 폴더`/`New Folder` 같은 명백한 placeholder 폴더일 때 강하게 우선합니다. 의미 있는 우열 근거가 없는 deterministic tie-break는 명시적인 사용자 승인이 있기 전까지 review 전용이며 자동 quarantine 권한을 갖지 않습니다. `--candidate-root`로 한 root의 후보만 좁힐 수 있고, `--refresh`는 current root를 incremental rescan하며 `--refresh --fresh`는 명시적으로 metadata/hash 전체 재계산을 강제합니다. review 자체는 원본 media를 move/rename/delete/copy하지 않습니다.

```bash
swift run photoarchive duplicate-review \
  --output "~/Desktop/PhotoArchiveKit-Duplicate-Review" \
  --candidate-root "~/Pictures"
```

library가 실제로 바뀐 뒤 먼저 새 scan을 하고 싶다면:

```bash
swift run photoarchive duplicate-review \
  --refresh \
  --output "~/Desktop/PhotoArchiveKit-Duplicate-Review-Fresh" \
  --candidate-root "~/Pictures"
```

AI agent는 `scan`, `archive-coverage`, `plan`, `duplicate-review`, `organize-plan`, `archive-index`, `archive-plan`, `archive-copy`, `organize`, `quarantine`, `restore-quarantine`, `cleanup-empty-dirs`와 `catalog` command의 report에서 `--agent-json`을 사용해야 하며, path를 포함할 수 있는 local diagnostic `--json`은 agent에 전달하지 않습니다. persisted archive-plan, archive-copy manifest, archive-root inventory, JSONL snapshot 파일 자체는 안전한 replay/disaster recovery에 local-private path·filename·catalog path·marker binding 또는 integrity precondition이 필요하므로 **agent-safe가 아닙니다**.

media를 옮기지 않고 현재 Mac/Takeout/HDD coverage를 확인합니다.

```bash
swift run photoarchive archive-coverage --agent-json \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --archive "/Volumes/My HDD/deep/path/My Photos"
```

이 session에 넘긴 root만 current coverage 계산에 포함됩니다. 다만 부모 root 아래에 별도 등록된 active/inactive nested root가 있으면 그 하위 영역은 부모가 다시 소유하지 않도록 자동 제외됩니다. `root remove`로 등록을 해제한 뒤에만 부모 scan이 그 파일을 다시 포함합니다. 다른 Mac folder나 다른 외장장치에서 가져온 media의 source location까지 비교하려면 그 위치를 적절한 `--local`, `--import`, `--reference` root로 한 번은 등록·scan해야 합니다.

아무 파일도 이동하지 않고 quarantine 후보를 먼저 검증합니다.

```bash
swift run photoarchive quarantine \
  --to "~/LJY 연습용 임시 휴지통" \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

Dry-run을 확인한 뒤에만 `--apply`를 붙이면 fresh verification을 다시 통과한 `automatic_redundant` resource만 이동합니다. `REVIEW` 항목은 이 명령이 절대 이동하지 않습니다. 적용된 session은 quarantine 폴더 안의 `PhotoArchiveKit/<session-id>/` 아래에 원래 위치를 복원할 수 있는 local manifest와 함께 보존됩니다.

완료된 quarantine은 안전하게 역복구할 수 있습니다. restore도 기본 dry-run이며, 실제 복원 전에 quarantined resource 전체를 local catalog에만 저장된 원래 exact SHA-256과 다시 비교합니다.

```bash
swift run photoarchive restore-quarantine --agent-json "/path/to/session/manifest.json"
# preflight 성공 후에만 --apply 추가
```

실제 media를 움직이지 않고 camera-style filename 정리 계획을 볼 수 있습니다.

```bash
swift run photoarchive organize-plan --agent-json --local "~/Pictures"
```

Image Capture 계열에서 반복적으로 생길 수 있는, logical asset 하나만 들어 있고 다른 entry가 없는 하위 폴더만 좁게 정리하려면 `--singleton-leaf-only`를 추가할 수 있습니다. Live Photo는 여전히 still+paired-video 한 묶음으로 이동하며 기존 날짜형 destination/collision 규칙을 그대로 재사용합니다. standalone `IMG_####` / `IMG_E####` 파일의 촬영시각을 신뢰할 수 없을 때는 `--preserve-name-if-date-untrusted`를 함께 사용해 날짜를 지어내지 않고 원래 이름 그대로 root로 flatten할 수 있으며, root-level 이름 충돌이 있으면 AUTO로 승격하지 않습니다.

organization apply 전에는 stable root marker를 명시적으로 초기화합니다(`photoarchive root init --apply "~/Pictures"`). `photoarchive organize`는 marker를 확인하는 dry-run이 기본이며, `--apply`에서만 automatic item을 rename/flat move합니다. custom filename과 review item은 그대로 둡니다.

정리가 끝난 뒤에는 해당 organization manifest에서 실제 파일이 빠져나간 source directory만 좁게 대상으로 삼아 빈 폴더를 정리할 수 있습니다. 이 명령도 기본 dry-run입니다.

```bash
swift run photoarchive cleanup-empty-dirs --agent-json "/path/to/organization.json"
# preflight 성공 후에만 --apply 추가
```

아직 media를 copy하지 않고 local-private immutable HDD archive plan만 생성할 수 있습니다. automatic copy authority를 받으려면 canonical source root와 archive destination 모두 stable `.photoarchive-root` marker가 필요합니다.

```bash
swift run photoarchive archive-plan \
  --to "/Volumes/Photo Archive" \
  --output "~/Library/Application Support/PhotoArchiveKit/archive-plan.json" \
  --agent-json \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout"
```

persisted plan schema v2는 working catalog path, source/destination path, exact byte size, marker binding, expected SHA-256 precondition을 포함하는 **local-private** 파일입니다. `--agent-json`에는 opaque ID, reason code, count만 노출합니다. `archive-plan` 자체는 media를 copy/delete하지 않습니다.

copy boundary에서 immutable plan을 다시 dry-run합니다. executor는 current catalog evidence와 fresh source byte를 다시 확인하므로 plan 파일 자체만으로는 copy authority가 되지 않습니다.

```bash
swift run photoarchive archive-copy --agent-json \
  "~/Library/Application Support/PhotoArchiveKit/archive-plan.json"
```

preflight가 성공한 뒤에만 `--apply`를 추가합니다. AUTO resource는 `.photoarchive/staging/<plan-id>`를 거치며 finalization 전후 full-file SHA-256을 검증합니다. complete Live Photo는 missing member 하나를 final path로 보내기 전에 still+paired-video 전체가 staging/final에서 검증되어 있어야 합니다. pending operation은 재실행할 수 있고, 이미 검증된 staged/final file은 재사용합니다. 완료 후 archive root를 working catalog에 다시 scan하고 hidden `.photoarchive` 아래에 portable catalog snapshot을 기록합니다. source media는 move/delete하지 않습니다.

```bash
swift run photoarchive archive-copy --apply --agent-json \
  "~/Library/Application Support/PhotoArchiveKit/archive-plan.json"
```

외장 HDD에 이미 사용자가 오랫동안 직접 분류한 사진 folder tree가 있다면, PhotoArchiveKit의 새 `Media/YYYY` 구조로 강제로 옮기기보다 그 기존 tree 자체를 archive로 index합니다. volume root가 아니라 **실제 사진 최상위 folder 자체**에 stable marker를 둡니다.

```bash
swift run photoarchive root init --apply "/Volumes/My HDD/deep/path/My Photos"
swift run photoarchive archive-index --agent-json "/Volumes/My HDD/deep/path/My Photos"
```

`archive-index`는 supported media가 들어 있는 현재 folder와 그 parent hierarchy를 user-authored collection으로 Mac-local SQLite에 기록합니다. media를 move/rename/delete/rewrite하지 않습니다. 일반 재스캔은 stable file fact가 그대로면 기존 metadata/exact hash를 재사용하고, 같은 volume 안에서 Finder로 move/rename한 경우 relative path가 바뀌어도 filesystem identity로 기존 evidence를 다시 연결할 수 있습니다. `archive-index --fresh`는 metadata와 local/portable hash cache를 모두 무시합니다. 다만 destructive/mutating workflow는 이 cache만 믿지 않고 실행 직전에 fresh byte verification을 다시 합니다.

index를 확인한 뒤 명시적으로 `--apply`를 붙였을 때만 HDD에 hidden root-scoped inventory를 씁니다.

```bash
swift run photoarchive archive-index --apply --agent-json \
  "/Volumes/My HDD/deep/path/My Photos"
```

권장 state 배치는 다음처럼 역할을 분리합니다.

```text
Mac 내부 SSD                                  removable archive root
~/Library/Application Support/PhotoArchiveKit  My Photos/
└── catalog.sqlite3                            ├── Family/
    authoritative working catalog             ├── Trips/
                                                └── .photoarchive/
                                                    ├── root marker
                                                    └── inventory-v1.jsonl
                                                        root-scoped portable map/cache
```

Mac SQLite는 빠르고 안정적인 local transaction/random I/O를 위한 **working catalog의 기준본**입니다. HDD의 inventory는 그 HDD 사진 root만 설명하며 relative path, byte size, modification time, opaque ID, role, SHA-256 evidence를 포함하므로 **local-private**이며 AI agent에 전달하지 않습니다. 다른 컴퓨터에서 새 local catalog로 같은 HDD를 붙여도 이 inventory가 unchanged-file hash를 seed할 수 있어 media byte 전체를 다시 읽는 비용을 줄입니다. 주기적 integrity audit이 필요할 때는 `archive-index --fresh`로 local/portable cache를 모두 무시하고 전체 media를 다시 hash합니다.

HDD root inventory와 `catalog export`는 역할이 다릅니다. `inventory-v1.jsonl`은 한 archive root 전용이고 빠른 재연결을 위해 raw integrity evidence를 의도적으로 보관합니다. 반면 `catalog export`는 전체 semantic disaster-recovery snapshot이며 raw hash와 재생성 가능한 local cache를 의도적으로 제외합니다.

catalog의 portable semantic state를 versioned disaster-recovery snapshot으로 내보낼 수 있습니다.

```bash
swift run photoarchive catalog export \
  --output "/path/to/photoarchive-catalog.jsonl"
```

snapshot은 absolute root path와 raw exact hash, keyed Live Photo fingerprint, filesystem ID, capture timestamp, provider object ID, generated scan/event result 같은 재생성 가능하거나 민감한 local cache를 제외합니다. 하지만 복원에 필요한 relative path·original filename·collection label·opaque ID·asset/resource role·root provenance·stable root-marker binding은 유지하므로 **local-private 파일이며 공유용 sanitized report가 아닙니다**.

restore는 항상 먼저 전체 snapshot을 검증하고 기존 catalog를 덮어쓰지 않습니다. stable marker가 없는 root는 현재 local directory에 명시적으로 다시 bind할 수 있습니다.

```bash
swift run photoarchive catalog restore \
  --to "/path/to/restored-catalog.sqlite3" \
  --bind-root ROPAQUEID="/path/to/current/root" \
  "/path/to/photoarchive-catalog.jsonl"
# dry-run 성공 후에만 --apply 추가
```

복원된 catalog는 opaque root/resource/asset identity와 collection semantics를 seed합니다. 이후 정상 scan은 media metadata와 hash를 파일에서 다시 읽어 snapshot placeholder를 fresh local evidence로 갱신하면서 같은 resource가 확인되면 복원된 opaque asset identity를 유지합니다.

폴더를 먼저 한곳에 섞지 않고 여러 source를 함께 scan하면 exact copy, provenance, source 간 Live Photo 관계를 통합할 수 있습니다.

```bash
swift run photoarchive scan \
  --local "~/Pictures" \
  --takeout "~/Pictures/Takeout" \
  --takeout "~/Pictures/Takeout-2" \
  --archive "/Volumes/Photo Archive/Photos"
```

등록한 root가 서로 중첩되어 있으면 가장 구체적인 root가 해당 파일을 소유합니다. 따라서 위 예시의 Takeout folder는 `~/Pictures`를 통해 다시 scan되지 않으며, 파일 byte만으로 출처를 구분할 수 없는 exact copy도 Google Takeout provenance를 유지할 수 있습니다.

사람이 로컬에서 확인하는 diagnostic JSON을 출력합니다. 이 mode는 path를 포함할 수 있습니다.

```bash
swift run photoarchive scan --json --inbox "~/Photo Inbox"
```

AI agent workflow에서는 privacy-minimized report를 사용합니다.

```bash
swift run photoarchive scan --agent-json --inbox "~/Photo Inbox"
```

agent-safe report는 opaque ID, provenance/status/count, 관계만 제공하며 filename/path, raw fingerprint, media content, capture timestamp, exact byte size를 노출하지 않습니다.

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

이미 등록된 path는 저장된 usage role이 우선합니다. 이후 scan에서 다른 root flag를 사용해도 `staging`/`primary_library`/`archive`/`import_source`/`reference` 역할을 몰래 바꾸지 않으며, 정책 변경은 `photoarchive root role`로 명시적으로 수행합니다.

그 밖의 option:

- `--catalog PATH` — SQLite catalog 경로 지정
- `--json` — 사람용 local diagnostic JSON; path/filename을 포함할 수 있음
- `--agent-json` — AI agent용 privacy-minimized JSON
- `--no-exact-duplicates` — 로컬 SHA-256 비교 생략
- `--event-gap-hours NUMBER` — 이 시간보다 긴 공백이 있으면 새 event로 분리, 기본값 6시간
- `--jobs NUMBER` — 동시에 실행할 metadata probe 수 제한
- `--no-progress` — stderr progress 출력 비활성화. JSON/stdout payload에는 영향을 주지 않음

긴 scan은 성숙한 파일 도구에서 흔히 쓰는 2단계 progress 방식을 따릅니다. 폴더를 재귀적으로 열람하는 동안에는 최종 total을 아직 모르므로 발견된 개수만 표시하고, enumeration이 끝난 뒤부터 `완료/전체`와 퍼센트를 표시합니다. 진행률을 위해 느린 외장 디스크를 미리 한 번 더 전수 순회하지 않습니다.

### `photoarchive archive-index`

marker가 초기화된 기존 user-managed archive root 하나를 재배치 없이 index합니다.

- 기본: Mac-local SQLite만 갱신하고 archive root에는 아무 파일도 쓰지 않음
- `--apply`: root 안에 `.photoarchive/inventory-v1.jsonl`도 기록
- `--fresh`: local SQLite/portable inventory hash cache를 모두 무시하고 media byte 전체를 다시 읽음
- `--jobs NUMBER`: concurrent metadata probe 제한
- `--json`: inventory path를 포함할 수 있는 local-private diagnostic
- `--agent-json`: path/hash를 제거한 count/status만 출력

현재 folder collection model은 supported media가 들어 있는 folder와 그 parent hierarchy를 보존하며, indexed media가 전혀 없는 empty folder는 semantic collection으로 만들지 않습니다.

### `photoarchive doctor`

필수 system 기능과 선택적 executable이 `PATH`에 있는지 보고합니다.

Google Takeout root에서는 embedded media metadata로 신뢰할 수 있는 촬영시각을 얻지 못한 경우 sidecar의 `title`과 `photoTakenTime`만 읽습니다. GPS, description 등 다른 Takeout metadata는 이 경로에서 import하지 않습니다.

sidecar 정책은 일반 사용자 중심입니다. 사용자가 JSON/XMP를 직접 열어볼 필요 없이, Google Takeout JSON은 검증된 `title` target에, XMP/AAE는 같은 폴더에서 basename 관계가 모호하지 않은 media에 자동 연결합니다. recognized sidecar는 `organize --singleton-leaf-only`의 media 이동을 막지 않지만 sidecar 파일 자체는 몰래 삭제하지 않고 원래 위치에 보존합니다. 관계를 확인할 수 없는 JSON은 unrecognized 상태로 남아 source folder 삭제를 막을 수 있으므로 실제 삭제 직전에만 보존/정리 여부를 판단하면 됩니다.

exact-only Live Photo reconciliation은 `still_only` 또는 `video_only`인 불완전 occurrence라도 그 occurrence의 모든 resource가 Takeout 밖에 같은 role의 byte-identical counterpart를 가지고 있으면 occurrence 전체를 `automatic_redundant`로 판단할 수 있습니다. 다른 곳에 complete Live Photo가 반드시 있어야 하는 것은 아니며 occurrence 일부만 제거하지 않습니다. quarantine apply 직전에는 candidate와 keeper를 다시 fresh SHA-256으로 검증합니다.

canonical keeper 선택은 등록된 모든 root의 backup 사본을 전 세계적으로 하나만 남기도록 collapse하는 정책이 아닙니다. 각 등록 root에는 사용자가 나중에 바꿀 수 있는 역할 하나를 지정합니다: `staging`, `primary_library`, `archive`, `import_source`, `reference`. staging은 임시 작업/보관 위치, primary library는 계속 유지할 주 보관 위치, archive는 장기 보호 대상, import source는 안전한 coverage/의미 보존 뒤 정리 가능한 입수처, reference는 비교 전용입니다. staging/primary 안의 byte-identical same-root copy는 대표 사본 하나를 남길 수 있지만 archive/reference는 자동 제거 후보가 되지 않습니다. 실제 quarantine 직전에는 여전히 candidate와 keeper의 full-file hash를 fresh 재검증합니다.

향후 local GUI에서는 이 판단의 private 정보를 사람이 바로 볼 수 있어야 합니다. duplicate group 하나를 한 묶음으로 보여주고, 그 안의 모든 physical copy에 실제 root/path와 protected/keeper/candidate badge를 표시하며 location별 filter를 제공하는 방식이 적합합니다. 이 화면은 **로컬 전용**이고 agent-safe report에는 계속 opaque group/root ID와 count만 전달합니다. 현재 human `scan`도 앞부분 duplicate group의 path를 보여주고 `--json`에는 전체 local-private 결과가 있지만, 장기적으로는 Krokiet처럼 위치를 그룹 안에서 바로 비교하는 GUI가 소비자 UX에 더 적합합니다.

라이브러리 위치에는 명시적인 root registry가 있습니다. `photoarchive root add`, `enable`, `disable`, `remove`, `role`, `list`로 현재 관리하는 위치와 과거 scan에서 한 번 관측된 history root를 구분합니다. 역할은 **장치 전체가 아니라 등록한 root별**로 지정하므로 같은 Mac/HDD/미래 file-cloud 안의 서로 다른 폴더에 서로 다른 역할을 줄 수 있습니다. `root role ROOT ROLE`은 정책만 바꾸며 media를 move/delete하지 않고, 변경 이력은 local catalog에 남깁니다. `staging`과 `primary_library`는 내부 `inbox` kind를 공유하고 `archive`, `import_source`, `reference`는 대응 kind를 사용합니다. provenance는 별도 사실로 유지합니다. portable catalog snapshot에도 현재 역할을 보존합니다. `root remove`는 media를 건드리지 않고 current evidence만 정리하며 최소 root identity/history는 남깁니다.

예:

```bash
swift run photoarchive root add --role staging --provenance local_library "~/Pictures"
swift run photoarchive root role ROOT_ID archive
```

기존 catalog migration은 보수적으로 동작합니다. 과거 `inbox`는 upgrade만으로 cleanup 권한이 넓어지지 않도록 처음에는 `primary_library`로 해석하고, 새 `inbox` root는 별도 역할을 지정하지 않으면 `staging`을 기본값으로 사용합니다.

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

## Privacy-safe AI agent 경계

PhotoArchiveKit이 존재하는 핵심 이유 중 하나는 AI agent가 사용자의 media나 private file-level metadata를 받지 않고도 duplicate group, Live Photo completeness, provenance, archive plan을 다룰 수 있게 하는 것입니다. hash, content identifier, broad metadata dump, filename/path, preview, timestamp는 local process 안에 남고 agent는 opaque asset/group/plan ID와 semantic decision만 받습니다.

이 보장은 PhotoArchiveKit의 agent-safe interface에 적용됩니다. general-purpose AI shell에 개인 media를 직접 노출하면 이 경계를 우회할 수 있습니다. 자세한 내용은 [Privacy model](docs/PRIVACY.md)과 [Agent interface](docs/AGENT_INTERFACE.md)를 참고하십시오.

## Live Photo 안전 모델

Live Photo는 최소 두 resource를 가진 하나의 논리 asset입니다.

```text
Live Photo asset
├── photo          HEIC 또는 JPEG
└── paired_video   MOV 또는 MP4
```

PhotoArchiveKit은 basename이 같다는 이유만으로 pair라고 판단하지 않습니다. still-side identifier와 QuickTime content identifier를 로컬에서 비교한 뒤 paired video에 유효한 int8 `com.apple.quicktime.still-image-time` timed-metadata marker가 정확히 하나 있고 그 marker가 유효한 movie timeline 위치에 있는지까지 확인해야 occurrence를 complete로 인정합니다. marker payload 자체를 timestamp로 해석하지 않고 timed metadata sample의 위치를 evidence로 사용하며, local metadata reader 밖에는 keyed identifier fingerprint와 semantic validation status만 전달합니다.

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
