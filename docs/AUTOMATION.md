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

## 촬영 후 curation과 archive ingest의 경계

PhotoArchiveKit은 "같은 촬영 장면에서 어느 한 장이 가장 잘 나왔는가"를 자체적으로 자동 판정하려고 하지 않는다. 이 문제는 exact duplicate 제거와 다르고, 잘못된 선택 비용이 높기 때문에 human-in-the-loop curation으로 취급한다.

권장 순서는 다음과 같다.

```text
iPhone 촬영
  -> Google Photos backup
  -> Google Photos Photo Stack / Top pick을 사람이 검토
     -> 마음에 들면 "Keep this, delete rest"로 근접 후보 정리
     -> 마음에 들지 않거나 여러 후보를 남기고 싶으면 그대로 보존
  -> Mac으로 살아남은 원본/후보 ingest
  -> 필요할 때 Krokiet/Czkawka Similar Images/Videos로 잔여 유사 후보 검색
     -> 사람이 최종 선택
  -> PhotoArchiveKit exact reconciliation + Live Photo graph + archive plan
```

역할은 명확히 분리한다.

- **exact byte-identical duplicate:** PhotoArchiveKit이 local hash/byte evidence와 Live Photo completeness를 이용해 agent-safe automatic decision을 만들 수 있다. 사람에게 사진 내용을 보여줄 필요가 없다.
- **Google Photos Top pick:** 같은 subject를 짧은 시간에 찍은 nearly-identical stack의 대표 후보를 Google Photos가 제안하고, 사용자가 최종적으로 어떤 한 장을 남길지 승인하는 upstream curation 단계다. PhotoArchiveKit은 Google의 proprietary ranking을 재구현하거나 permanent truth로 취급하지 않는다.
- **Krokiet/Czkawka similarity:** byte가 다른 residual near-duplicate image/video를 로컬에서 찾는 review 후보 생성기다. perceptual group 자체가 best-shot ranking이나 deletion authority가 아니다.

Google Photos에서 culling을 끝낸 뒤 Mac ingest를 하는 현재 사용자 workflow는 바람직하다. archive가 처음부터 모든 burst-like 후보를 영구 보존할 필요가 줄어들고, PhotoArchiveKit은 살아남은 자산의 provenance·Live Photo 관계·exact copy reconciliation에 집중할 수 있다. 다만 Top pick을 사용했다고 해서 batch가 similarity-free라고 가정하지 않으며, 필요하면 Mac ingest 후 Krokiet/Czkawka review를 추가한다.

### Optional second-pass Google curation loop

Mac에서 Krokiet/Czkawka가 residual near-duplicate 후보를 좁힌 뒤 Google Photos의 Top pick UI를 한 번 더 활용하는 것은 **선택적 human curation loop**로 허용할 수 있다. 다만 Google Photos는 임의의 사용자 후보 set에 대해 Top pick을 강제로 실행하는 general-purpose ranking API가 아니다. Photo Stacks는 Google이 backed-up photos 중 같은 subject를 짧은 시간에 찍은 nearly-identical 사진이라고 자동 판단한 경우에 생성되므로, 후보를 다시 upload했다고 해서 반드시 새 stack이 생기거나 ranking이 다시 실행된다고 가정하지 않는다.

권장 방식은 Google을 **data transport가 아니라 decision UI**로 사용하는 것이다.

```text
Mac original candidates
  -> Krokiet/Czkawka로 residual similarity group 축소
  -> 필요하면 Google Photos에 curation용 후보를 보여 줌
  -> Google Photos가 stack/Top pick을 제공하면 사람이 검토
  -> 선택된 Top pick에 대응하는 Mac의 original resource/Live Photo pair를 KEEP
  -> 나머지 local candidates를 PhotoArchiveKit review/quarantine 대상으로 표시
```

가능하면 Google에서 선택된 파일을 다시 다운로드해 canonical archive copy로 삼지 않는다. 이미 Mac에 original candidate가 있다면 Google의 선택은 **어느 local original을 남길지 결정하는 신호**로만 사용한다. 이 원칙은 provider round-trip에서 발생할 수 있는 re-encoding, metadata 변화, filename 변화, Live Photo paired-video 누락 위험을 피한다. 특히 Live Photo는 Google에서 보이는 still 하나가 아니라 선택된 still에 대응하는 local still + paired-video resource graph 전체를 보존해야 한다.

이 second-pass는 기본 automatic pipeline이 아니다. 다음 조건에서만 유용하다.

- 첫 Google Top-pick pass 뒤에도 사람이 보기에 비슷한 후보가 여러 장 남아 있음
- Krokiet/Czkawka가 그 후보를 작은 group으로 좁혀 줌
- Google Photos가 실제로 그 후보를 stack으로 인식함
- 사용자가 Google의 추천을 다시 검토하고 승인함

Google Photos가 stack을 만들지 않으면 그 사실을 오류로 보지 않고 Mac local review로 끝낸다. PhotoArchiveKit은 Google Top pick을 permanent truth나 deletion authority로 저장하지 않으며, 향후 외부 curation 결과를 받더라도 `user_confirmed_survivor` 같은 provider-neutral decision으로만 기록하는 방향을 선호한다.

Google Photos에서 사진을 실제 삭제하는 operation은 cloud view만 숨기는 작업이 아니므로 upstream app의 현재 deletion semantics를 사용자가 이해한 상태에서 수행해야 한다. PhotoArchiveKit은 이 curation 단계의 삭제를 자동으로 대신하지 않는다.

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
