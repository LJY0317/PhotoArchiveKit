# 자동 분류 전략

PhotoArchiveKit은 수동 작업량이 개별 사진 수가 아니라 **ambiguous event 수**에 비례하도록 설계한다.

큰 ingest session에서 원하는 결과는 다음과 같다.

```text
수천 개 resource
  -> exact-copy reconciliation
  -> logical asset
  -> 소수의 event group
  -> high-confidence folder proposal
  -> uncertain event group만 review
```

automatic classification은 deletion을 authorize하지 않는다. organization과 provider projection state만 제안한다.

## Canonical organization model

각 logical asset은 다음을 가질 수 있다.

- final archive folder로 표현되는 primary filesystem collection 1개
- SQLite에 저장되는 추가 logical collection 0개 이상
- provider album projection 0개 이상
- copy가 발견된 모든 source의 provenance observation

예:

```text
primary folder:   미국 여행
collections:      미국 여행, 가족, 2026 Best
Google Photos:    album projection 없이 flat upload 가능
Apple Photos:     logical collection을 album membership으로 반영 가능
```

추가 collection마다 filesystem copy를 만들지 않는다. many-to-many membership은 catalog data로 유지하고 이를 지원하는 provider에 나중에 projection할 수 있다.

## Classification pipeline

### 1. Resource를 logical asset으로 정규화

classification 전에 PhotoArchiveKit은:

- embedded identifier로 Live Photo resource를 pair하고
- source root별 completeness status를 유지하고
- byte-identical resource를 로컬에서 group하고
- complete Live Photo와 still-only copy를 구분하고
- equivalence가 확립되기 전에는 transformed/re-encoded version을 별도 representation으로 유지한다.

이렇게 해야 duplicate copy가 classifier에서 여러 표를 행사하지 않는다.

### 2. Asset을 event로 분할

event-level decision이 manual work를 가장 크게 줄인다. 현재 구현은 trusted capture time을 configurable time gap으로 group하고 보수적인 date folder를 제안한다.

향후 event evidence:

- capture instant와 local calendar date
- timezone confidence
- short gap과 overnight boundary
- burst와 same-second sequence
- neighboring Live Photo/photo/video
- source import session
- 로컬에서 계산하는 optional coarse location cell

강한 evidence가 없는 한 event는 하나의 unit으로 유지한다.

### 3. 기존 archive에서 학습

기존 archive folder가 labeled example이다. 사용자가 선택하지 않는 한 `Travel`, `People`, `Nature` 같은 universal taxonomy를 강요하지 않는다.

각 known folder에 대해 local model은 다음과 같은 feature를 요약할 수 있다.

- typical date 또는 recurring calendar period
- event duration 및 asset count distribution
- camera/source characteristic
- enable된 경우 locally derived location region
- optional local visual feature centroid
- user-confirmed alias와 hierarchy

새 event를 folder profile과 비교해 하나의 unexplained answer가 아니라 explicit evidence와 confidence를 가진 candidate를 반환한다.

```text
Event E000142
candidate: 일본 여행
confidence: high
reasons:
  - confirmed example과 같은 local region
  - existing trip event와 인접한 날짜
  - confirmed event cluster와 visual similarity
```

agent-facing report에는 raw GPS coordinate, feature vector, face representation, perceptual hash, image-derived embedding을 포함하지 않는다. coarse reason과 confidence만 노출할 수 있다.

### 4. Optional local visual analysis

visual classification은 optional이며 local-only다. future macOS adapter는 Apple Vision/Core ML로 media를 upload하지 않고 image feature print와 coarse label을 계산할 수 있다.

규칙:

- Live Photo는 기본적으로 motion video를 sampling하지 않고 representative still 하나를 분석한다.
- feature를 model/revision identifier와 함께 로컬 cache한다.
- complete cache deletion과 deterministic rebuilding을 허용한다.
- vector, thumbnail, frame, face geometry를 agent/cloud에 보내지 않는다.
- initial classifier에서는 face recognition을 enable하지 않는다.
- visual similarity를 identity 또는 deletion decision으로 사용하지 않는다.

이미 `czkawka_cli`를 가진 사용자는 similar-image/video candidate group을 optional하게 import할 수 있다. 이는 별도 subprocess adapter이며 core requirement가 아니다.

### 5. Confidence policy

권장 default policy:

| Confidence | Default action |
| --- | --- |
| High | proposed folder와 collection membership을 immutable plan에 추가 |
| Medium | asset별이 아니라 event-level decision 1회 요청 |
| Low | neutral date-event folder를 사용하고 ranked alternative를 SQLite에 보존 |
| Conflict | 해당 event만 중지하고 conflicting evidence 설명 |

모든 proposal에 approval을 요구하는 stricter preset을 선택할 수 있지만 default product 방향은 automatic-first다.

## Correction에서 학습

correction은 hidden global model을 만들지 않고 future event decision을 개선해야 한다.

```text
proposal: 일상
user correction: 가족
```

PhotoArchiveKit은 다음을 기록한다.

- event와 선택된 primary collection
- rejected candidate
- classifier version
- 사용된 evidence category
- optional user-visible note

portable report에 raw media-derived value를 보존할 필요는 없다. local feature cache는 필요할 때 archive file에서 rebuild할 수 있다.

## Classification 전 duplicate policy

exact copy는 event scoring 전에 reconcile한다. preferred representation을 고를 때 다음 순서의 ranking을 제안할 수 있다.

1. incomplete occurrence보다 complete logical asset
2. transformed export보다 validated camera-origin resource
3. metadata completeness가 높은 representation
4. original dimension/duration
5. trusted provenance
6. user override

byte size가 크다는 이유만으로 superior하다고 판단하지 않는다. archive와 independent replica가 verify되고 사용자가 quarantine을 승인하기 전까지 non-preferred copy를 제거하지 않는다.

## Prior-art에서 선택적으로 채택한 교훈

PhotoArchiveKit은 다른 제품의 replacement implementation이 아니지만 mature system은 유용한 boundary를 보여준다.

- **Mylio Photos**는 compact catalog를 유지하면서 original-quality file을 여러 Vault device에 둘 수 있다. PhotoArchiveKit도 작은 semantic catalog와 ordinary original file을 분리하고 complete copy 위치를 기록한다.
- **Immich**는 duplicate detection과 review utility를 분리하고 XMP sidecar를 사용할 수 있다. PhotoArchiveKit도 similarity를 review evidence로 취급하고 original을 silent modification하지 않고 portable catalog export를 계획한다.
- **PhotoPrism**은 Live Photo를 포함한 related resource를 stack으로 group한다. PhotoArchiveKit도 multi-resource logical asset concept을 사용하지만 shared basename을 Live Photo pairing authority로 인정하지 않는다.

References:

- [Mylio Photos protection and Vault devices](https://support.mylio.com/how-does-mylio-photos-protect-my-photos)
- [Immich duplicate review](https://docs.immich.app/features/duplicates-utility/)
- [Immich XMP sidecars](https://docs.immich.app/features/xmp-sidecars/)
- [PhotoPrism stacks](https://docs.photoprism.app/user-guide/organize/stacks/)

이 제품과 project는 design reference일 뿐 bundled dependency나 compatibility guarantee가 아니다.

## 계획된 command

의도한 lightweight command flow:

```text
photoarchive scan
photoarchive learn
photoarchive classify
photoarchive plan
photoarchive verify-plan
photoarchive apply
photoarchive verify
```

현재는 `scan`만 존재한다. `classify`와 `plan`은 read-only로 유지한다. archive-root identity, precondition, rollback record, Live Photo transaction boundary, copy verification이 구현되기 전에는 `apply`를 추가하지 않는다.

## Automatic-first가 의미하지 않는 것

다음을 의미하지 않는다.

- 첫 scan에서 파일을 조용히 move
- perceptually similar asset을 자동 삭제
- classification을 위해 private media upload
- 모든 archive에 하나의 predefined folder taxonomy 강제
- 하나의 logical asset을 이루는 resource를 독립적으로 classify
- provider-generated label을 permanent truth로 취급
- uncertain decision 숨김

strong evidence에서는 적극적으로 동작하되, mistake cost가 큰 경우에는 보수적이어야 한다.
