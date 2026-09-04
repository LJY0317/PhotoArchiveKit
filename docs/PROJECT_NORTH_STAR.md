# PhotoArchiveKit의 초심과 범위 게이트

이 문서는 PhotoArchiveKit이 주변 기능으로 비대해지는 것을 막기 위한 최우선 제품 기준이다. 핵심 목표가 충분히 달성되기 전에는 이 목표와 직접 관련되지 않은 기능을 우선순위에 올리지 않는다.

## 최초 목적

PhotoArchiveKit을 만드는 이유는 새로운 사진 갤러리나 범용 사진 관리 앱을 만들기 위해서가 아니다.

핵심 문제는 iPhone 사진 앱, Mac, Google Photos, 외장 HDD 등에 동기화·내보내기·백업 때문에 여러 사본으로 존재하는 사진, 동영상, Live Photo를 안전하게 정리하는 것이다.

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

## 기본 provenance 우선순위

같은 logical asset의 보존 후보가 여러 개이고 바이트·Live Photo completeness 등 핵심 보존 품질이 동등하다면, provenance는 사용자 정책으로 선택한다.

현재 기본 정책은 다음과 같다.

```text
iPhone/Apple Photos에서 직접 추출한 원본 계열
> 검증된 Mac ingest
> Google Photos/Takeout에서 회수한 byte-identical 사본
> provider가 변환한 standalone representation
> 불완전한 Live Photo occurrence
```

이 순위는 "Google 사본의 바이트가 더 나쁘다"는 뜻이 아니다. 바이트가 같아도 어느 경로에서 직접 보존했는지를 사용자가 선호한다는 정책이다. 파일 내용만으로 provenance를 증명할 수 없는 경우 provenance는 source root와 ingest session에서 기록한다.

## 완료 기준

다음 항목이 실제 사진 라이브러리 규모에서 안정적으로 작동하기 전에는 핵심 목적이 완료된 것으로 보지 않는다.

- 대규모 multi-root read-only scan
- filename이 같아도 bytes가 다른 충돌 감지
- filename이 달라도 exact bytes가 같은 사본 감지
- Live Photo resource 관계 검증과 atomic handling
- Takeout과 Apple/iPhone 계열 source의 provenance 보존
- 사용자 provenance 우선순위를 반영한 preferred representation 제안
- exact duplicate group에 대한 안전한 keep/quarantine plan
- perceptual duplicate는 별도 review 후보로 유지
- 기존 폴더와 Inbox 폴더를 이용한 primary classification
- HDD archive destination plan 생성
- copy -> byte verify -> catalog commit 경로
- 중단 후 재개와 idempotent 재실행
- portable catalog snapshot/restore
- 최소 하나의 독립적인 verified replica

## 범위 게이트

위 완료 기준을 직접 진전시키지 않는 기능은 원칙적으로 보류한다.

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

- PhotoArchiveKit core의 exact comparison은 catalog identity와 안전한 archive 판단에 필요한 작고 결정론적인 기능으로 유지한다. 같은 byte-size 후보의 파일 전체 SHA-256이 일치할 때만 exact duplicate로 본다.
- Czkawka/Krokiet은 특히 perceptual image/video similarity 후보와 독립적인 exact cross-check에 활용한다. similarity는 deletion authority가 아니다.
- off-site file replica와 검증에는 rclone 같은 검증된 도구를 우선한다.
- broad/obscure metadata 진단이 필요해지면 ExifTool/ffprobe를 우선 평가하고 범용 parser를 새로 만들지 않는다.
- Apple media metadata와 Photos 연동은 공식 ImageIO/AVFoundation/PhotoKit이 요구를 충분히 충족하는 범위에서 공식 경로를 우선한다.
- osxphotos가 Apple Photos query/export/album 작업에서 자체 구현보다 더 완전하고 안정적인 경로를 제공하면 optional adapter로 활용할 수 있다. 같은 기능을 공식 PhotoKit이 더 잘 제공하면 PhotoKit이 우선이다.

그러나 외부 도구는 핵심 semantic truth를 소유하지 않는다. 최종 관계도와 사용자 결정은 portable filesystem + SQLite에 남긴다.

특히 duplicate cleanup에서는 다음 경계를 지킨다.

- Czkawka/Krokiet의 exact-duplicate 결과는 강한 resource-level evidence지만 곧바로 deletion authority가 되지 않는다.
- non-Takeout과 Google Takeout에 byte-identical resource가 함께 있으면 사용자 정책상 non-Takeout representation을 우선한다.
- standalone asset은 non-Takeout exact copy가 검증되면 Takeout occurrence를 redundant candidate로 자동 제안할 수 있다.
- Live Photo는 still과 paired video가 모두 complete하고 role별 exact copy가 non-Takeout에 존재할 때만 Takeout occurrence 전체를 automatic redundant candidate로 올린다.
- 한쪽 resource만 exact duplicate이거나 occurrence가 incomplete/ambiguous하면 review 대상으로 남긴다.
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
