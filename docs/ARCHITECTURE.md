# Architecture

## 설계 목표

PhotoArchiveKit은 iPhone을 주 카메라로 사용하고 cloud backup은 상시 동작할 수 있지만, archive 작업은 사용자가 storage를 연결하고 명시적으로 command를 시작할 때만 수행하는 Mac-first workflow를 위해 설계한다.

핵심 우선순위:

1. 정상 AI agent workflow에서 media byte, raw fingerprint/identifier, filename/path, GPS, capture timestamp 같은 private detail이 local trust boundary를 벗어나지 않게 하고 agent에는 opaque semantic result만 제공한다.
2. original media resource와 Live Photo relationship을 복원 가능한 graph로 보존한다.
3. PhotoArchiveKit 없이도 media가 ordinary file로 사용 가능하게 유지한다.
4. Google Photos, Apple Photos 등 provider와 독립적으로 organization을 보존한다.
5. deterministic 및 local machine-learning stage로 manual classification을 최소화한다.
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

SQLite가 authoritative working database다. 기본 위치는 Mac의 Application Support이고, removable HDD의 live SQLite를 기본 source of truth로 삼지 않는다. versioned JSONL `catalog export`는 portable interchange 및 disaster-recovery representation으로 사용한다. 현재 snapshot은 absolute root path, raw exact hash, keyed Live Photo fingerprint, filesystem identifier, capture timestamp, provider object ID, generated scan/event cache를 제외하고 root provenance/marker binding, opaque resource·asset relationship, current/history relative path, original filename, collection hierarchy/membership을 보존한다. 따라서 raw/cache 값을 제거한 **portable sanitized snapshot**이지만 relative path·filename·collection label을 포함하는 local-private 파일이며 agent-safe/share-safe report는 아니다.

사용자가 이미 수동으로 관리하는 removable archive에는 별도의 root-scoped `.photoarchive/inventory-v1.jsonl`을 둘 수 있다. 이 파일은 전체 semantic catalog의 복제본이 아니라 **그 archive root 자체의 portable structure/hash cache**다. stable marker, relative path, current folder hierarchy, opaque asset/resource role, byte size, modification time, SHA-256 evidence를 담으므로 `catalog export`보다 민감하고 agent-safe가 아니다. 새 컴퓨터의 local SQLite가 비어 있어도 marker + path + size + mtime이 맞는 resource는 이 inventory hash를 재사용할 수 있다. mutation authority는 inventory/cache가 아니라 실행 직전 fresh byte verification이 가진다.

`catalog restore`는 snapshot을 기존 SQLite 위에 merge하지 않고 새 catalog에만 복원한다. 기본은 dry-run이고 `--apply`에서만 새 DB를 만든다. stable root marker가 있는 root는 marker key -> root ID binding을 복원하고, marker가 없는 root는 restore 시 `ROOT_ID=PATH` binding으로 현재 local path에 연결할 수 있다. restored resource/asset은 raw hash나 Live Photo fingerprint를 snapshot에서 되살리지 않고 placeholder semantic key로 seed하며, 다음 정상 scan이 파일에서 fresh hash/linkage evidence를 다시 계산했을 때 같은 restored resource set이면 원래 opaque asset ID를 재사용한다.

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
- **Occurrence:** 한 source root 안에서 실제 한 번의 still + paired-video representation을 이루는 resource set

같은 identifier가 한 Takeout root의 연도 folder와 album folder 등에 반복되면 `2 still + 2 video`를 하나의 ambiguous occurrence로 뭉개지 않고 여러 physical occurrence로 partition해야 한다. partitioning은 embedded identifier를 authority로 유지하면서 directory/co-location, basename, source/export structure, exact-resource equivalence 같은 신호를 **경계 추정용 hint**로만 사용한다.

다만 외부 non-Takeout root에 complete canonical Live Photo가 있고, 특정 Takeout logical asset의 모든 resource가 role별로 그 canonical pair의 exact copy임이 증명되면 어느 반복 copy가 어느 occurrence인지 먼저 확정하지 않아도 Takeout 전체를 redundant로 판단할 수 있다. 이를 **canonical coverage**라고 한다.

이 구분이 중요하다. Image Capture root에 complete copy가 있어도 ordinary AirDrop root가 still image만 가진 사실을 숨겨서는 안 되며, 반대로 여러 export folder의 반복 copy를 하나의 손상된 Live Photo로 오해해서도 안 된다.

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

현재 scanner는 path match를 유지하면서 optional `.photoarchive-root` marker key를 catalog root ID에 bind한다. marker가 있는 root directory가 다른 path로 이동하면 marker key로 기존 root ID를 찾아 canonical path만 갱신한다. marker가 없는 기존 root는 여전히 path 기반이므로 relocation 전에 `photoarchive root init --apply PATH`가 필요하다. unavailable root를 mass deletion으로 해석해서는 안 된다.

`archive` root는 canonical bytes가 반드시 PhotoArchiveKit이 만든 folder layout에 있어야 한다는 뜻이 아니다. `photoarchive archive-index PATH`는 사용자가 직접 만든 nested folder tree를 그대로 읽고, supported media가 있는 directory와 parent hierarchy를 `user_archive_folder` collection으로 기록한다. Finder에서 수동 move가 발생한 뒤 재index하면 current hierarchy를 다시 계산하고 stale user-archive membership/collection을 제거한다. empty directory처럼 indexed media와 관계없는 structure는 semantic collection으로 만들지 않는다.

현재 user-managed archive workflow에서는 Finder를 통한 수동 HDD copy/분류를 정상 경로로 허용한다. `archive-index`는 **그 archive root 하나의 현재 상태**를 갱신하고, `archive-coverage`는 Mac/Takeout/archive/reference 등 **그 session에 등록한 root들 사이의 현재 보존 관계**를 다시 계산한다. 등록·scan한 적 없는 임의 source folder는 catalog가 자동으로 발견하지 않는다.

`archive-coverage`는 exact duplicate group을 이용해 root별 exact-covered/exact-unique resource 수와 root pair별 exact overlap을 계산한다. Live Photo는 file 하나의 hash coverage만으로 안전하다고 간주하지 않고 같은 logical asset의 다른 root occurrence가 `complete`, partial/ambiguous, still-only, video-only, none 중 어디에 해당하는지를 별도로 보고한다. 이 report는 media-read-only이며 mutation authority가 아니다.

## Session model

watcher나 sync daemon은 없다. 작업은 explicit session으로 진행한다.

GUI가 생기더라도 current-state truth는 동일한 session/rescan model을 유지하는 것이 기본이다. 앱 실행, 사용자의 Refresh, 외장 root attach 같은 시점에 등록 root만 재검사할 수 있다. 미래에 macOS FSEvents를 사용하더라도 그것은 "어느 등록 hierarchy가 바뀌었는지" 알려주는 invalidation hint로만 취급하고, catalog truth는 targeted/full rescan으로 확정한다. 전역 filesystem을 상시 감시하거나 등록되지 않은 폴더를 자동 수집하는 모델은 기본값이 아니다.

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

현재 구현은 read-only scan/reconciliation/organization planning, local-private immutable `archive-plan`, resumable verified `archive-copy`, 제한된 reversible mutation(`quarantine`, marker-gated `organize`)까지 포함한다. archive-plan schema v2는 working catalog path, source/destination stable marker binding, canonical representation, Live Photo atomic resource set, destination relative path, byte size, fresh SHA-256 precondition을 고정한다. archive-copy는 plan을 current catalog evidence와 source byte에 다시 대조한 뒤 hidden staging -> final full-hash verification -> destination archive scan/catalog reconciliation -> archive-local portable snapshot 순서로 commit한다. 실제 개인 library의 외장 HDD apply는 아직 별도 validation으로 남아 있다.

future plan은 immutable document이며 다음을 포함한다.

- operation ID/session ID
- source/destination resource set
- expected size 및 integrity precondition
- Live Photo atomicity constraint
- reason/confidence
- reversible rename information

interrupted session은 완료된 operation을 반복하지 않고 verified checkpoint에서 resume해야 한다.

### Foreground progress

Long-running foreground scans expose structured `ScanProgress` events from the core rather than making the CLI infer progress from logs. Enumeration is intentionally indeterminate until recursive discovery is complete; metadata and hashing become determinate once their work lists are known. The CLI renders progress on stderr so JSON/stdout remains a stable machine interface. TTY output redraws one line, while non-TTY output is throttled by stage/percentage/time to avoid log spam. Progress reporting does not add a second filesystem pre-count pass and can be disabled with `--no-progress`.

## 자동 분류

manual drag-and-drop은 fallback이어야 하며 normal path가 되어서는 안 된다.

위의 user-managed HDD workflow와 달리, 아래 자동 분류 단계에서 말하는 manual drag-and-drop 최소화는 **새 Inbox를 프로그램이 자동 분류하는 문제**에 대한 원칙이다. 사용자가 archive의 최종 folder taxonomy와 copy 대상을 직접 결정하는 현재 HDD workflow까지 자동화해야 한다는 뜻은 아니다.

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

기본 `automatic`/`native` path는 candidate file을 먼저 size로 group한 뒤 matching size group에 대해 full-file SHA-256을 계산한다. unchanged resource는 root/path + byte size + modification time이 같고, local filesystem identifier가 양쪽에 존재할 경우 그 identifier도 같은 때 local SQLite의 기존 SHA-256을 재사용한다. archive root는 동일한 marker가 확인된 portable inventory의 path/size/mtime hash cache도 local cache miss 뒤 사용할 수 있다. 이 cache는 performance accelerator일 뿐 destructive authority가 아니며 `archive-index --fresh`는 local/portable cache를 모두 우회해 모든 media byte를 다시 읽는다. agent-safe report에는 digest 대신 `D000017` 같은 opaque ID와 cache-hit count만 노출한다.

선택적 `czkawka` exact engine은 Czkawka의 size -> prehash -> cached full-hash pipeline으로 candidate group을 먼저 찾고, PhotoArchiveKit이 cache miss인 candidate file을 native SHA-256으로 검증한다. raw Czkawka hash/cache는 agent에 노출하지 않는다. real-library benchmark에서는 이전의 이중 검증 경로가 native-only보다 빨라지지 않았고 native incremental hash cache도 이제 구현되어 있으므로 `automatic`은 현재 native를 유지하고 Czkawka exact는 독립 cross-check 용도로 둔다.

### Exact logical Live Photo duplicate

일반적인 occurrence 비교에서는 두 resource role이 모두 있어야 한다. identical still이 있어도 paired video가 missing/different하면 exact duplicate Live Photo occurrence가 아니다.

### Canonical keeper와 intentional replica

exact duplicate 발견과 실제 replica 제거는 분리한다. PhotoArchiveKit은 등록된 모든 storage root를 하나의 deduplicated pool로 축소하지 않는다. `archive`와 `reference` root는 backup/baseline 역할로 보고 automatic removal에서 보호한다. `local_library` primary root는 같은 root 안에서 겹치는 physical representation을 줄일 수 있지만 root 간 독립 replica 자체는 보존한다. `import_source`는 exact counterpart가 이미 보존되어 있거나 provider/source-folder semantics가 먼저 catalog에 보존된 경우 cleanup 후보가 될 수 있다.

keeper tie-break는 semantic safety를 먼저 사용한다. Live Photo는 complete occurrence가 incomplete/ambiguous occurrence보다 우선하며 pair 전체를 선택한다. 같은 primary root의 standalone exact copy는 capture evidence confidence를 먼저 비교하고, 동률이면 더 얕은 relative path를 선호한 뒤 stable path/ID 순서로 deterministic하게 결정한다. filesystem creation fallback이 더 오래됐다는 이유만으로 embedded/provider metadata를 덮어쓰지는 않는다. keeper 결정은 byte mutation authority가 아니며 quarantine executor가 candidate와 keeper를 fresh full-file hash로 다시 확인해야 한다.

향후 GUI의 duplicate inspector는 local-private surface로 구성한다. 한 exact group 아래 모든 physical location을 root/path와 함께 표시하고 protected replica, selected keeper, automatic candidate, review reason을 같은 화면에서 보여준다. agent-safe surface에는 이 path/filename을 보내지 않고 기존 opaque group/root ID와 count/status만 유지한다.

예외적으로 canonical coverage가 성립하면 repeated Takeout occurrence의 내부 pairing ambiguity를 먼저 풀지 않아도 된다. non-Takeout complete pair가 보존되고, 제거하려는 Takeout asset의 모든 still/video resource가 역할별 exact copy로 완전히 cover될 때만 해당 Takeout set 전체를 automatic redundant candidate로 만들 수 있다.

### Preferred-representation reconciliation

read-only `photoarchive plan`은 exact evidence와 provenance를 asset-level decision으로 승격한다.

- standalone exact group에 non-Takeout과 Takeout copy가 함께 있으면 non-Takeout representation을 preferred로 두고 Takeout resource를 automatic redundant candidate로 제안한다.
- Live Photo는 complete non-Takeout canonical occurrence를 먼저 선택한다.
- canonical still/video와 같은 role의 exact group이 모든 Takeout resource를 cover하면 repeated Takeout occurrence의 내부 pairing이 ambiguous해도 canonical coverage로 Takeout set 전체를 automatic redundant candidate로 제안한다.
- complete preferred occurrence가 없거나 canonical pair가 cover하지 못하는 exact variant가 있으면 review에 남긴다.
- plan 자체는 read-only다. mutation authority는 별도 quarantine/apply layer가 fresh precondition을 다시 검증한 뒤에만 가진다.

### Quarantine mutation boundary

현재 첫 mutation은 same-session `photoarchive quarantine`으로 제한한다. command는 scan -> reconciliation plan -> fresh verification을 같은 invocation에서 수행하며 기본은 dry-run이다. `--apply`가 있을 때만 `automatic_redundant` candidate를 user-supplied local quarantine으로 move한다.

apply precondition:

- source와 preferred counterpart가 여전히 regular file인지 확인
- symlink로 registered root 밖으로 빠지지 않는지 확인
- scan 당시 byte size와 현재 size가 같은지 확인
- candidate와 preferred counterpart를 fresh full-file SHA-256으로 다시 비교
- Live Photo item은 해당 candidate resource 전체가 검증된 뒤에만 첫 move 수행
- destination collision이 있으면 mutation 전 중단

이 quarantine은 오래된 persisted plan을 replay하지 않는다. session 도중 move가 실패하면 같은 quarantine session에서 이미 이동한 resource 전체를 reverse order로 원위치 rollback한다. successful apply는 quarantine target 안에 source/destination mapping을 가진 local restore manifest를 남긴다. permanent delete는 없다.

`photoarchive restore-quarantine`은 이 manifest를 역방향 mutation authority로 사용하되 기본은 dry-run이다. original source가 비어 있어야 하고, quarantined file은 expected size뿐 아니라 local SQLite에 보존된 원래 exact SHA-256과 fresh하게 다시 일치해야 한다. 적용 중 실패하면 이미 source로 돌아간 resource를 다시 quarantine으로 rollback한다. agent-safe restore report에는 manifest/source/destination path나 hash가 포함되지 않는다. 현재 두 real quarantine의 legacy v1 manifest까지 dry-run 호환성을 검증했으므로, 별도의 더 복잡한 quarantine recovery subsystem은 실제 실패 사례가 생기기 전까지 추가하지 않는다.

stable root marker 기능은 구현됐지만 existing root에는 자동으로 marker를 쓰지 않는다. `archive-plan`의 AUTO item은 scan 때 기록한 source marker key가 plan 순간에도 그대로이고 fresh source SHA-256이 같은 scan/catalog의 exact evidence와 일치할 때만 생성된다. destination도 marker를 필수로 요구하고 existing path collision을 deterministic suffix로 피한다. `archive-copy`는 replay 때 plan의 source resource/root/path/asset/role/size/hash를 current catalog와 다시 비교하고 source/destination marker와 byte를 재검증한다. root가 이동했다면 같은 marker를 가진 explicit rebind만 허용한다. `.photoarchive/plans`, pending/complete operation manifest, verified staging/final state가 checkpoint이며 complete manifest 이후에는 archive-local catalog snapshot hash도 재검증한다. missing-root reconciliation은 user-initialized marker 없이는 수행하지 않는다.

### Organization mutation boundary

`photoarchive organize-plan`은 local/Apple-direct root의 `IMG_####` / `IMG_E####` camera-style resource만 대상으로 capture wall-clock 기반 flat rename proposal을 만든다. custom filename은 자동 변경하지 않는다. timezone이 빠진 EXIF `DateTimeOriginal`은 파일명에 local wall-clock을 쓰는 데는 충분하지만 filesystem creation fallback은 automatic rename authority가 아니다.

`photoarchive organize`는 기본 dry-run이고 `--apply` 전에 stable root marker를 요구한다. same-volume filesystem resource identifier와 byte size를 pre/post move에서 확인하며, Live Photo는 complete still+paired-video 두 resource가 같은 destination basename을 공유해야 한다. 모든 move 검증이 끝나면 stable resource ID를 기준으로 `resources.relative_path`와 `resource_locations` history를 SQLite transaction으로 직접 commit하므로 두 번째 full media scan/hash pass가 필요 없다. catalog commit까지 성공해야 operation이 완료되며, commit 실패 시 filesystem move 전체를 reverse-order rollback하고 final manifest도 제거한다. 최초 filename과 old/new location은 SQLite history에 보존된다.

### Takeout source-folder semantics before physical collapse

Takeout-only standalone exact duplicates may represent the same bytes repeated in year folders and album-like folders. Before reducing those copies to one physical representation, PhotoArchiveKit records the source-folder hierarchy as local `collections` and the logical asset's membership in each observed folder. Folder names and paths stay inside the local catalog and are not included in agent-safe output. Once every involved Takeout root reports `sourceFolderSemanticsCaptured`, the planner may keep one exact physical copy and quarantine only the excess copies; this does not claim every Takeout folder is a confirmed Google album, only that the original source organization has been preserved losslessly enough for later interpretation.

### User-managed archive folder semantics

기존 HDD의 사용자 분류 tree는 Takeout의 source-history와 다르게 **현재 사용자가 의도한 archive organization**으로 취급한다. `archive-index`는 media를 재배치하지 않고 현재 leaf folder membership을 catalog에 반영하며 parent hierarchy를 collection으로 보존한다. manual move 뒤 old membership은 history처럼 누적하지 않고 current structure에 맞게 prune한다. 이 root의 portable inventory는 다른 host가 local SQLite 없이도 current structure와 exact-hash cache를 빠르게 재구성하는 보조 state다.

### Similar/derived copy

perceptual similarity, matching capture time, provider provenance는 review candidate를 만들 수 있지만 asset collapse나 automatic deletion 권한이 아니다.

## Optional interoperability

required core는 Apple system framework와 SQLite만 사용한다. optional subprocess adapter는 user-installed mature tool을 재사용할 수 있다.

- rclone: remote file replication/verification
- Czkawka CLI: large-library exact candidate acceleration/cross-check 및 perceptual image/video similarity candidate
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
