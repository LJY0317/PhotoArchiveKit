# PhotoArchiveKit의 초심과 범위 게이트

이 문서는 PhotoArchiveKit이 주변 기능으로 비대해지는 것을 막기 위한 최우선 제품 기준이다. 핵심 목표가 충분히 달성되기 전에는 이 목표와 직접 관련되지 않은 기능을 우선순위에 올리지 않는다.

## 최초 목적

PhotoArchiveKit을 만드는 이유는 새로운 사진 갤러리나 범용 사진 관리 앱을 만들기 위해서가 아니다.

핵심 문제는 iPhone 사진 앱, Mac, Google Photos, 외장 HDD 등에 동기화·내보내기·백업 때문에 여러 사본으로 존재하는 사진, 동영상, Live Photo를 안전하게 정리하는 것이다.

## 핵심 가치 우선순위

**Live Photo atomicity는 모든 mutation에 적용되는 최상위 safety invariant다.** 하나의 Live Photo에 속한 still + paired-video resource 중 하나를 copy, move, rename, quarantine, delete, archive 또는 provider projection하려는 operation은 해당 logical asset/occurrence의 완전한 resource set으로 확장하거나 실패해야 한다. provenance preference, exact-duplicate 판단, performance optimization, 외부 도구의 개별-file 동작보다 이 규칙이 우선한다.

PhotoArchiveKit의 첫 번째 핵심 제품 가치는 **AI agent가 개인 media를 분류·정리하는 동안 media byte와 media/file-derived private data를 agent나 AI service가 읽을 필요가 없게 하는 local privacy boundary**다. hash, Live Photo identifier, GPS, MakerNote, perceptual fingerprint, filename/path, exact byte size, capture timestamp 같은 값은 필요한 경우 local process가 처리하고, agent에는 opaque root/asset/group/plan ID와 provenance category, role, status, count, confidence, warning code 같은 최소 semantic result만 전달한다. 정상 agent workflow는 `--agent-json` 같은 privacy-minimized surface를 사용한다.

두 번째 핵심 제품 가치는 **Live Photo를 단순한 두 파일이 아니라 복원 가능한 logical asset/resource graph로 보존하면서 HDD와 일반 file-cloud replica에 사람이 읽을 수 있는 파일 형태로 백업하는 것**이다. still + paired video 관계와 provenance를 catalog에 유지하고, copy/move/rename/quarantine/archive/projection은 asset 단위로 계획한다. cloud drive는 byte replica 역할을 하며, 미래 Apple/Google API가 더 나은 Live Photo import/projection을 제공하면 보존된 resource graph에서 다시 복원·projection할 수 있어야 한다.

그 다음 가치가 exact/perceptual duplicate reconciliation, preferred representation, folder organization, verified replica, provider-neutral migration state다. 주변 편의 기능은 이 순서를 뒤집지 않는다.

최종적으로 다음 상태를 만드는 것이 목적이다.

1. 동일한 촬영물을 나타내는 여러 사본을 찾아 하나의 logical asset으로 묶는다.
2. Live Photo의 still + paired video 관계를 잃지 않는다.
3. 동일하거나 사실상 같은 사본이 여러 곳에 있으면 사용자가 정한 provenance 우선순위에 따라 가장 보존 가치가 높은 representation을 선택할 수 있다.
4. exact duplicate와 perceptual similarity를 구분한다. similarity만으로 자동 삭제하지 않는다.
5. 사진과 동영상은 평범하고 사람이 읽을 수 있는 폴더 구조로 외장 HDD에 보존한다.
6. SQLite에는 파일만으로 표현하기 어려운 관계도, provenance, collection membership, duplicate 판단 근거, provider mapping을 저장한다.
7. 향후 Apple/Google API가 바뀌어도 다시 사진을 전부 분류하지 않도록 provider-neutral desired state를 보존한다.
8. 사용자의 수작업은 개별 사진 수가 아니라 정말 애매한 event/duplicate group 수에 비례하도록 만든다.
9. 백업된 파일은 특정 앱이 없어도 Finder와 일반 파일 도구로 읽을 수 있어야 한다.
10. 모든 파괴적 작업은 검증 가능한 plan과 안전한 복사본을 전제로 한다.
11. AI agent가 CLI/API로 archive를 다룰 때 개인 media byte, raw hash/identifier, filename/path, GPS, capture timestamp 같은 file-level private detail을 AI service에 보내지 않고 opaque asset/group/plan ID와 상태만으로 작업할 수 있어야 한다.

## provenance 정책

provenance는 중요한 semantic/safety evidence지만 **generic exact-copy keeper의 암묵적인 품질 점수로 사용하지 않는다.** 특히 같은 `staging` 역할의 root끼리는 `local_library`, `unknown`, `google_web` 같은 provenance category만으로 한 사본을 더 좋은 keeper라고 판단하지 않는다. Downloads처럼 하나의 root에 여러 ingest 경로가 섞일 수 있기 때문이다.

대신 provenance는 Google Takeout folder/sidecar semantics, provider 변환 여부, import cleanup 가능성처럼 실제 source-specific 안전 규칙에 사용한다. 사용자가 명시적으로 "Apple direct를 우선" 같은 provenance preference를 설정한 경우에만, byte identity와 Live Photo completeness 같은 핵심 보존 품질이 동등하다는 전제 아래 preferred-representation 정책으로 적용할 수 있다.

기본 generic exact-copy keeper는 usage-role retention gate를 먼저 지키고, 그 안에서는 copy 표식, 알아보기 쉬운 source filename, Finder `Date Added`, 구조/capture/path 같은 file-level evidence를 사용한다. provenance가 알려지지 않았다는 이유만으로 사본을 열등하게 취급하지 않는다.

## Registered root 역할

저장장치나 provider 전체에 하나의 정책을 강제로 붙이지 않는다. **사용자가 등록한 root마다** `staging`, `primary_library`, `archive`, `import_source`, `reference` 중 하나의 usage role을 지정한다. 같은 Mac, HDD, 또는 미래의 file-cloud provider 안에서도 서로 다른 하위 root가 서로 다른 역할을 가질 수 있다.

- `staging`: 아직 장기 보관이 끝나지 않은 작업/임시 위치. 다른 장기 보호 root의 완전한 검증 전에는 반드시 보존한다.
- `primary_library`: 사용자가 계속 유지하려는 주 라이브러리. 다른 replica가 있어도 이 root 자체를 offload cleanup 대상으로 보지 않는다.
- `archive`: 장기 보관/protection target. 같은 root 내부의 불필요한 exact duplicate는 대표 사본 하나를 그 archive 안에 남기고 정리할 수 있지만, 다른 root에 replica가 있다는 이유만으로 이 archive의 보존 사본 자체를 제거하지 않는다.
- `import_source`: Takeout/export/camera dump 같은 입수처. 같은 root 내부 exact dedupe도 가능하되 Google Takeout처럼 folder/collection semantics가 필요한 source는 그 의미가 먼저 보존되어야 한다. 별도 retained copy를 근거로 한 더 큰 cleanup도 기존 coverage/semantics gate를 통과해야 한다.
- `reference`: 비교 전용. PhotoArchiveKit mutation 대상이 아니며 다른 root를 자동 cleanup하기 위한 retention authority로도 사용하지 않는다.

usage role은 provenance/provider capability와 별개다. 예를 들어 Google Drive의 서로 다른 folder를 archive/import/reference로 각각 등록할 수 있어야 한다. 역할 변경은 catalog policy만 바꾸며 그 순간 media를 move/delete하지 않는다. 실제 mutation은 새 역할에 따른 plan과 기존 fresh verification gate를 다시 통과해야 한다. executor도 current role과 keeper 위치를 독립 재검증한다. `archive`는 same-root exact dedupe만 허용하고 generic cross-root replica collapse는 거부하며, `reference`는 모든 reconciliation/organization mutation을 거부한다. 등록된 archive-copy destination은 current role이 `archive`여야 한다.

## 삭제와 임시 격리 destination

제품의 일반적인 duplicate cleanup은 가능한 플랫폼에서 OS가 제공하는 Trash/Recycle Bin을 **기본 reversible destination**으로 사용한다. 이 선택은 AI prompt가 아니라 PhotoArchiveKit의 local product setting으로 저장한다. 사용자가 별도의 임시 휴지통/quarantine 폴더를 지정한 경우에는 그 app-managed 위치를 사용할 수 있으며, restore/audit가 중요한 workflow에서는 manifest를 가진 app-managed quarantine이 더 적합할 수 있다. 개발자 개인 경로나 특정 머신의 폴더를 제품에 hard-code하지 않는다.

OS Trash를 사용할 수 없거나 volume/network 제약 때문에 안전한 reversible move를 보장할 수 없으면 자동으로 permanent unlink/remove로 fallback하지 않는다. 명시적인 user-configured quarantine을 요구하거나 operation을 중단한다. 초기 release의 permanent delete 부재 원칙은 그대로 유지한다.

duplicate cleanup apply가 성공한 뒤에는 **그 operation의 source candidate가 있던 parent chain만** empty-directory cleanup 대상으로 삼는다. registered root 자체, package/symlink boundary, 다른 항목이 남은 directory는 제거하지 않는다. 모든 candidate move가 성공하기 전에는 empty-directory cleanup을 시작하지 않는다.

## Curation과 archive의 역할 분리

PhotoArchiveKit은 exact duplicate 제거와 "가장 잘 나온 한 장" 선택을 같은 문제로 취급하지 않는다.

- byte-identical exact duplicate는 local integrity evidence와 Live Photo asset completeness가 충분하면 AI agent가 media 내용을 보지 않고도 automatic plan으로 처리할 수 있어야 한다.
- 같은 장면의 여러 근접 후보 중 best shot을 고르는 일은 human-in-the-loop curation이다. 사용자가 이미 Google Photos Photo Stack/Top pick을 적극적으로 쓰는 workflow에서는 그 단계를 archive ingest보다 앞에 둔다.
- Google Photos가 제안한 Top pick은 사용자가 승인하는 upstream curation signal일 뿐 PhotoArchiveKit의 permanent asset identity나 deletion evidence가 아니다.
- Google Photos에서 여러 후보를 남겼거나 stack이 잡지 못한 잔여 near-duplicate는 Mac ingest 후 Krokiet/Czkawka Similar Images/Videos 같은 local review 도구를 활용할 수 있다.
- PhotoArchiveKit은 Google의 proprietary best-shot ranking이나 Czkawka의 perceptual engine을 재구현하지 않고, 그 결과 이후의 Live Photo-aware reconciliation과 archive safety를 소유한다.

## 완료 기준

다음 항목이 실제 사진 라이브러리 규모에서 안정적으로 작동하기 전에는 핵심 목적이 완료된 것으로 보지 않는다.

- 대규모 multi-root read-only scan
- filename이 같아도 bytes가 다른 충돌 감지
- filename이 달라도 exact bytes가 같은 사본 감지
- Live Photo resource 관계 검증과 atomic handling
- Takeout과 Apple/iPhone 계열 source의 provenance 보존
- 사용자 provenance 우선순위를 반영한 preferred representation 제안
- registered root별 user-changeable usage role과 역할 기반 retention/cleanup policy
- exact duplicate group에 대한 안전한 keep/quarantine plan
- perceptual duplicate는 별도 review 후보로 유지
- 기존 폴더와 Inbox 폴더를 이용한 primary classification
- HDD archive destination plan 생성
- copy -> byte verify -> catalog commit 경로
- 중단 후 재개와 idempotent 재실행
- portable catalog snapshot/restore
- 최소 하나의 독립적인 verified replica

## 범위 게이트와 stop rule

위 완료 기준을 직접 진전시키지 않는 기능은 원칙적으로 보류한다.

또한 **완료 기준을 충족한 문제는 완료된 것으로 취급하고 멈춘다.** 더 높은 정확도, 더 많은 metadata, 더 세밀한 분류가 가능하다는 사실만으로 구현을 계속하지 않는다. 이미 핵심 workflow가 안전하고 재현 가능하게 동작한다면 추가 작업은 다음 중 하나가 있어야만 다시 연다.

- 실제 사용자/real-library에서 재현되는 실패 사례
- 측정된 성능·배터리·I/O 병목
- Live Photo atomicity, privacy, 복원 가능성, verified archive를 막는 명확한 blocker
- 기존 완료 기준을 만족하지 못한다는 새로운 증거

그 외의 개선은 `nice-to-have` 또는 future experiment로 남기고 현재 milestone을 닫는다. 특히 얼굴·인물 인식, 범용 pixel semantic classification, 세밀한 사진 taxonomy는 현재 핵심 목적을 달성하기 위한 필수 조건이 아니므로 blocker가 되기 전에는 구현하지 않는다.

특히 다음은 핵심 기능보다 앞서 구현하지 않는다.

- 자체 사진 갤러리/뷰어
- 대규모 GUI 프레임워크
- background daemon 또는 filesystem watcher
- 범용 얼굴 인식·OCR·검색 제품
- 소셜 공유 기능
- 브라우저 자동화를 통한 provider 조작
- 자체 cloud storage 서비스
- 일반적인 사진 편집 기능
- provider별 편의 기능 때문에 core identity/catalog 모델을 복잡하게 만드는 작업

예외는 핵심 workflow를 실제로 사용 가능하게 만드는 아주 얇은 UI, 진단 도구, import/export adapter이다.

## 외부 도구 활용 원칙

PhotoArchiveKit은 이미 잘 해결된 문제를 다시 구현하지 않는다. 선택 기준은 단순한 "dependency 최소화"가 아니라 **공식 지원성, 정확성, 성숙도, 재현성, privacy, 유지보수 비용**이다.

우선순위:

1. 요구 기능을 Apple 또는 provider의 공식 framework/API가 충분히 제공하면 공식 경로를 우선한다.
2. 공식 경로가 없거나 부족하고 PhotoArchiveKit의 고유 semantic 영역이 아니라면, 널리 사용되고 검증된 best-of-breed open-source 도구를 우선 평가한다.
3. 자체 구현은 Live Photo asset graph, provenance, preferred representation, archive plan/transaction처럼 우리가 반드시 소유해야 하는 부분이나 외부 선택지가 요구조건을 충족하지 못할 때만 한다.

현재 역할 분담:

- PhotoArchiveKit core의 exact comparison은 dependency-free fallback과 destructive-operation 재검증을 위해 유지한다. 같은 byte-size 후보의 파일 전체 SHA-256이 일치할 때만 exact duplicate로 본다.
- 대규모 library에서 `czkawka_cli`가 설치되어 있으면 size/prehash/cached full-hash pipeline을 exact candidate discovery accelerator로 우선 활용할 수 있다. PhotoArchiveKit은 candidate를 local에서 자체 검증하고 asset graph로 승격한다.
- Czkawka/Krokiet의 가장 중요한 장기 역할은 perceptual image/video similarity다. similarity는 deletion authority가 아니다.
- off-site file replica와 검증에는 rclone 같은 검증된 도구를 우선한다.
- broad/obscure metadata 진단이 필요해지면 ExifTool/ffprobe를 우선 평가하고 범용 parser를 새로 만들지 않는다.
- Apple media metadata와 Photos 연동은 공식 ImageIO/AVFoundation/PhotoKit이 요구를 충분히 충족하는 범위에서 공식 경로를 우선한다.
- osxphotos가 Apple Photos query/export/album 작업에서 자체 구현보다 더 완전하고 안정적인 경로를 제공하면 optional adapter로 활용할 수 있다. 같은 기능을 공식 PhotoKit이 더 잘 제공하면 PhotoKit이 우선이다.

그러나 외부 도구는 핵심 semantic truth를 소유하지 않는다. 최종 관계도, Live Photo atomicity, provenance preference, canonical coverage, archive plan과 사용자 결정은 portable filesystem + SQLite에 남긴다. 외부 tool의 raw hash/cache/metadata output은 local adapter 안에서만 처리하고 agent-safe output에는 전달하지 않는다.

특히 duplicate cleanup에서는 다음 경계를 지킨다.

- Czkawka/Krokiet의 exact-duplicate 결과는 강한 resource-level evidence지만 곧바로 deletion authority가 되지 않는다.
- non-Takeout과 Google Takeout에 byte-identical resource가 함께 있으면 사용자 정책상 non-Takeout representation을 우선한다.
- standalone asset은 non-Takeout exact copy가 검증되면 Takeout occurrence를 redundant candidate로 자동 제안할 수 있다.
- 일반적인 Live Photo occurrence 비교에서는 still과 paired video가 모두 complete하고 role별 exact copy가 non-Takeout에 존재할 때 occurrence 전체를 automatic redundant candidate로 올린다.
- 같은 identifier가 한 Takeout root 안에 여러 번 반복되더라도 non-Takeout에 complete canonical pair가 있고 **그 logical asset의 모든 Takeout resource가 역할별 exact copy로 완전히 cover**되면 내부 occurrence pairing을 먼저 확정하지 않아도 Takeout set 전체를 automatic redundant candidate로 올릴 수 있다. 이를 canonical coverage라고 한다.
- canonical coverage가 성립하지 않고 한쪽 resource만 exact duplicate이거나 occurrence가 incomplete/ambiguous하면 review 대상으로 남긴다.
- Takeout 내부에서 동일 media가 연도 folder와 album folder 등에 반복되어도 collection/album 의미를 catalog로 옮기기 전에는 단순히 한 파일만 남기고 제거하지 않는다.

ExifTool은 broad metadata diagnostic의 optional 도구다. required core가 사용하는 촬영시각·QuickTime·Live Photo linkage의 좁은 범위는 Apple system framework로 처리하되, ExifTool 전체 기능을 재구현하지 않는다. osxphotos도 required dependency가 아니라 Apple Photos library query/export/album interoperability를 위한 optional bridge이며, 장기적인 공식 write path는 PhotoKit을 우선한다.

## 기능 추가 질문

새 기능을 제안할 때마다 먼저 다음을 묻는다.

1. 이 기능이 여러 provider/source에 흩어진 같은 촬영물을 더 정확히 합치는가?
2. Live Photo를 더 안전하게 보존하는가?
3. 가장 좋은 representation을 선택하는 데 직접 도움이 되는가?
4. 폴더형 HDD archive와 verified replica를 더 안전하게 만드는가?
5. 사용자가 개별 사진을 수작업으로 처리해야 하는 양을 실제로 줄이는가?
6. 미래 provider migration에서 재분류를 피하게 해 주는가?

대부분이 아니면 현재 milestone 밖으로 미룬다.
