# Architecture

## 설계 목표

PhotoArchiveKit은 iPhone을 주 카메라로 사용하고 cloud backup은 상시 동작할 수 있지만, archive 작업은 사용자가 storage를 연결하고 명시적으로 command를 시작할 때만 수행하는 Mac-first workflow를 위해 설계한다.

핵심 우선순위:

1. original media resource와 Live Photo relationship을 보존한다.
2. PhotoArchiveKit 없이도 media가 ordinary file로 사용 가능하게 유지한다.
3. Google Photos, Apple Photos 등 provider와 독립적으로 organization을 보존한다.
4. deterministic 및 local machine-learning stage로 manual classification을 최소화한다.
5. media-derived secret은 로컬에 유지한다.
6. future mutation은 모두 reviewable, resumable, reversible하게 만든다.
7. background CPU, battery, filesystem cost를 피한다.

## 세 가지 truth layer

### Media truth

canonical byte는 일반 filesystem root에 둔다.

```text
Photo Archive/
├── 2026-09-04/
│   ├── 20260904_153012.HEIC
│   └── 20260904_153012.MOV
└── .photoarchive/
```

human-readable folder가 명시적 product requirement이므로 initial design은 user-facing storage를 content-addressed 방식으로 만들지 않는다. exact hash는 integrity evidence이지 filename이나 public ID가 아니다.

### Semantic truth

SQLite는 folder만으로 안전하게 표현하기 어려운 다음 상태를 기록한다.

- 하나의 logical asset과 여러 physical resource 관계
- Live Photo still/paired-video role
- copy와 provider-derived variant
- primary folder와 추가 many-to-many collection
- source/provenance observation
- rename 및 operation history
- duplicate decision
- provider object/album mapping
- scan/archive session

SQLite가 working database다. future versioned JSONL export는 portable interchange 및 disaster-recovery representation으로 사용한다. CSV는 report 용도에는 적합하지만 canonical relational model로 사용하지 않는다.

### Provider projection

Apple Photos, Google Photos, optional gallery software는 view 또는 delivery target이다. provider identifier는 mapping으로 저장하며 logical asset의 permanent identity로 사용하지 않는다.

provider adapter는 모든 operation이 가능하다고 가정하지 않고 capability를 선언한다.

```text
observe_library
upload_simple_media
upload_live_photo
create_album
add_existing_asset_to_album
remove_asset_from_album
```

capability state는 `supported`, `manual_only`, `unobservable`, `unverified`, `unsupported` 등이 될 수 있다.

현재 Google Photos Library API에서는 library/album management가 calling app이 생성한 media와 album 중심이므로, Google Photos에서 해당 상태를 observe/apply하지 못하더라도 desired album state는 로컬에 유지해야 한다.

## Resource와 asset model

```text
LogicalAsset
├── Resource(role: photo)
├── Resource(role: paired_video)
├── Resource(role: rendered_edit)        future
└── Resource(role: provider_derivative)  future
```

Live Photo는 filename이 아니라 embedded identifier로 pair한다. 현재 Apple-origin file에서 관찰되는 근거:

- image Exif MakerNote의 still-side identifier
- motion resource의 QuickTime content identifier

PhotoArchiveKit은 raw value를 로컬에서 비교하고 catalog-local random key를 사용한 HMAC-SHA-256 fingerprint로 변환한 뒤 raw value를 probe 후 제거한다. keyed fingerprint는 original identifier를 report에 노출하지 않고 local grouping을 가능하게 한다.

pairing은 두 level에서 평가한다.

- **Logical asset:** 같은 protected identifier를 가진 모든 known copy
- **Occurrence:** 한 source root 안에서의 completeness

이 구분이 중요하다. Image Capture root에 complete copy가 있어도 ordinary AirDrop root가 still image만 가진 사실을 숨겨서는 안 된다.

matching linkage metadata 없이 basename만 같으면 warning candidate일 뿐 자동 pair하지 않는다.

## Identity

logical asset은 opaque local ID를 사용한다. identity evidence에는 다음이 포함될 수 있다.

- protected Live Photo identifier
- exact resource hash
- provenance 및 observed source
- capture metadata
- future user-confirmed/provider-derived relation

filename, provider ID, capture timestamp, perceptual feature 하나만으로 permanent identity를 정하지 않는다.

byte-identical standalone resource는 하나의 logical asset에 mapping될 수 있다. 같은 scene의 다른 encoding은 derivation/equivalence relation이 확립되기 전까지 distinct asset으로 유지한다.

## Source root

data model은 simple UI가 default Inbox 하나로 시작하더라도 여러 root를 허용한다.

- `inbox`: unclassified incoming media
- `archive`: canonical long-term file
- `import_source`: Takeout 또는 다른 provider export
- `reference`: read-only comparison fixture 또는 old collection

의도한 model에서는 path를 identity가 아니라 configuration으로 취급한다. opaque root ID가 relative path를 소유하고 configured Inbox 또는 mount location은 바뀔 수 있다.

현재 read-only prototype은 canonical path로 existing root를 resolve하므로 configured root를 이동하면 새 root record가 생성된다. stable user-supplied root ID와 `.photoarchive-root` 같은 marker가 다음 root-identity milestone이다. future mutating command는 absence를 해석하거나 plan을 적용하기 전에 marker를 verify해야 한다. unavailable root를 mass deletion으로 해석해서는 안 된다.

## Session model

watcher나 sync daemon은 없다. 작업은 explicit session으로 진행한다.

```text
scan
  -> analyze
  -> propose
  -> plan
  -> verify preconditions
  -> apply to staging
  -> verify bytes and relationships
  -> commit catalog
  -> copy replica
  -> verify replica
  -> close session
```

현재 구현은 `scan`, `analyze`, `propose`, catalog persistence까지이며 media를 수정하지 않는다.

future plan은 immutable document이며 다음을 포함한다.

- operation ID/session ID
- source/destination resource set
- expected size 및 integrity precondition
- Live Photo atomicity constraint
- reason/confidence
- reversible rename information

interrupted session은 완료된 operation을 반복하지 않고 verified checkpoint에서 resume해야 한다.

## 자동 분류

manual drag-and-drop은 fallback이어야 하며 normal path가 되어서는 안 된다.

### Stage 1: deterministic grouping

현재 및 근시일 signal:

- trusted capture instant/local date
- timezone confidence
- Live Photo relationship
- burst/same-second sequence
- source session
- file provenance

### Stage 2: event segmentation

현재 구현됨. trusted capture time으로 asset을 정렬하고 configurable threshold보다 gap이 길면 event candidate를 분리한다. 첫 folder proposal은 보수적으로 date-based다.

### Stage 3: archive-guided classification

계획 단계. 기존 archive folder를 labeled example로 사용한다.

```text
known folder examples
       +
new event cluster
       -> nearest collection candidates
```

classifier는 각 frame이 아니라 event group 전체를 score해야 한다. 하나의 confident trip event가 수백 asset을 함께 assign할 수 있다.

### Stage 4: local visual feature

계획 단계이며 optional이다. Apple Vision으로 image feature print와 image classification을 로컬에서 생성할 수 있다. Live Photo는 still resource를 한 번 분석하고 결과를 logical asset 전체에 적용한다. 일반 classification을 위해 paired video frame extraction은 필요하지 않다.

feature vector, face geometry, inferred label은 media-derived private data다. 로컬에만 두고 normal agent output에 포함하지 않는다. feature-print distance는 algorithm revision 간 stable하다고 가정하지 않으므로 revision을 기록한다.

### Stage 5: confidence policy

권장 default:

- high confidence: automatically generated plan에 포함
- medium confidence: event-level review 1회
- low confidence: date-event folder 사용, alternative는 catalog에 보존

classifier result는 deletion을 authorize하지 않는다.

## Exact duplicate와 perceptual duplicate

### Exact resource duplicate

candidate file은 먼저 size로 group한다. matching size group에 한해 local process에서 SHA-256을 계산한다. report에는 digest 대신 `D000017` 같은 stable ID를 노출한다.

### Exact logical Live Photo duplicate

두 resource role이 모두 있어야 한다. identical still이 있어도 paired video가 missing/different하면 exact duplicate Live Photo occurrence가 아니다.

### Similar/derived copy

perceptual similarity, matching capture time, provider provenance는 review candidate를 만들 수 있지만 asset collapse나 automatic deletion 권한이 아니다.

## Optional interoperability

required core는 Apple system framework와 SQLite만 사용한다. optional subprocess adapter는 user-installed mature tool을 재사용할 수 있다.

- rclone: remote file replication/verification
- Czkawka CLI: additional duplicate/similarity candidate
- ExifTool: broad metadata diagnostic
- ffprobe: optional video diagnostic

이 방식은 설치를 작게 유지하면서 advanced user가 session을 확장할 수 있게 한다.

## 설계 참고점

mature photo system에서 얻은 boundary:

- external-library gallery는 original을 소유하지 않고 index할 수 있지만 metadata가 gallery DB에만 있으면 path 변경 시 유실될 수 있다. 따라서 portable semantic state와 stable logical ID를 gallery DB 밖에 유지한다.
- read-only mount는 유용한 safety boundary다. PhotoArchiveKit은 command level에서도 scan은 read-only, mutation은 별도 explicit plan/apply boundary로 분리한다.
- heavy indexing에는 job queue가 유용하지만 주기적으로 연결되는 personal archive에는 resident server가 필요하지 않다. resumable foreground session을 사용한다.

## 의도적으로 제외하는 것

initial architecture에서는 다음을 제외한다.

- server database
- content-addressed user-facing storage
- continuous filesystem observation
- browser UI automation
- permanent deletion
- implicit metadata rewriting
- cloud item별 DB row를 primary identity model로 사용하는 방식
