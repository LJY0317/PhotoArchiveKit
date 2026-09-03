# Privacy Model

PhotoArchiveKit은 유용한 automation을 위해 personal media나 media-derived fingerprint를 AI service로 보낼 필요가 없도록 설계한다.

## 기본 network posture

현재 core는 network request를 하지 않는다. scan은 local file을 읽고 선택된 local SQLite catalog에 쓰며 report를 출력한다.

future cloud adapter는 provider-specific authorization과 capability documentation을 가진 별도 opt-in command여야 한다. adapter enable이 telemetry, remote classification, unrelated service upload를 조용히 enable해서는 안 된다.

## Data class

### Public project data

commit 가능한 항목:

- source code
- schema migration
- documentation
- generated 또는 명시적으로 승인된 synthetic fixture
- synthetic fixture만으로 만든 report

### Private local catalog data

local SQLite catalog에 저장될 수 있는 항목:

- configured source-root path
- relative file path/filename
- file size와 capture-time metadata
- provider object mapping
- raw exact-file hash
- keyed Live Photo identifier fingerprint
- future perceptual feature vector
- collection decision과 operation history

catalog는 private application state다. `.gitignore`로 제외하며 sanitization 없이 issue에 첨부하지 않는다.

### 일반 report에 절대 포함하지 않는 항목

- image/video byte
- thumbnail/extracted frame
- audio sample
- raw SHA-256/BLAKE3 value
- raw Live Photo content identifier
- Exif MakerNote dump
- perceptual hash/Vision feature vector
- face geometry/biometric template
- precise GPS coordinate
- OAuth access/refresh token
- cloud client secret

## Live Photo identifier 보호

scanner는 still image와 motion resource가 같은 identifier를 가지는지 판단해야 하지만 identifier 자체를 reveal할 필요는 없다.

현재 process:

1. local process memory에서 각 resource identifier를 읽는다.
2. 주변 whitespace만 normalize한다.
3. 해당 catalog를 위해 만든 random key로 HMAC-SHA-256을 계산한다.
4. fingerprinting 직후 in-memory probe object에서 raw identifier를 clear한다.
5. SQLite에는 keyed fingerprint만 저장한다.
6. report에는 logical asset ID와 match/completeness status만 노출한다.

HMAC key는 catalog-local이므로 서로 다른 catalog의 fingerprint를 비교하는 용도로 쓰지 않는다. accidental cross-dataset correlation을 줄이기 위함이다.

## Exact hash

reliable incremental duplicate detection에는 stable content fingerprint가 필요하므로 raw exact-file hash는 로컬에 유지한다. CLI report는 equality를 다음과 같은 opaque group으로 변환한다.

```json
{
  "groupID": "D000017",
  "members": [
    {"rootLabel": "Inbox", "relativePath": "IMG_0001.HEIC"},
    {"rootLabel": "Takeout", "relativePath": "IMG_0001.HEIC"}
  ]
}
```

digest는 출력하지 않는다. self-test는 synthetic fixture의 known local SHA-256 value가 encoded report에 나타나지 않는지 확인한다.

## Agent-facing boundary

agent는 다음과 같은 sanitized operation만 호출해야 한다.

```text
scan_roots
list_incomplete_live_photos
list_duplicate_groups
propose_archive_plan
validate_plan
```

interface에는 다음 general-purpose operation을 노출하지 않는다.

```text
read_media_bytes
extract_frame
show_thumbnail
print_hash
print_makernote
print_feature_vector
```

safe agent-facing asset record 예:

```json
{
  "assetID": "A0042",
  "kind": "live_photo",
  "pairStatus": "complete",
  "exactDuplicateGroup": "D0017",
  "captureTimeStatus": "trusted",
  "collections": ["Trip"],
  "providerState": {
    "apple": "in_sync",
    "google": "unobservable"
  }
}
```

underlying hash, content identifier, GPS coordinate, media preview, embedding을 포함해서는 안 된다.

## Optional local visual analysis

automatic organization은 나중에 Apple Vision 또는 local Core ML model을 사용할 수 있다. cloud classifier보다 private하지만 output 자체도 sensitive하다.

visual feature rule:

- 기본적으로 Live Photo still resource에 대해 동작
- pixel, frame, label, embedding을 upload하지 않음
- model/request revision 기록
- feature는 protected local application state에만 저장
- normal JSON, log, crash report, support bundle에서 제외
- feature export보다 regeneration을 우선
- feature cache disable/erase option 제공

## Credential

future OAuth token은 macOS Keychain에 저장한다. 다음에는 두지 않는다.

- repository
- configuration example
- 별도 key-management design 없이 SQLite
- process listing에 노출될 수 있는 CLI argument
- normal log/report

## Destructive operation

AI agent에 unrestricted deletion authority를 주지 않는다.

future policy layer는 agent가 proposal을 만들 수 있게 하되 local helper가 다음을 enforce해야 한다.

- verified archive root identity
- complete Live Photo resource set
- verified canonical copy
- deletion-eligible content에 대해 최소 하나의 independently verified replica
- permanent deletion 대신 quarantine
- irreversible action에 대한 explicit local approval

## Issue/support hygiene

report 공유 전:

1. sanitized output을 위해 설계된 `--json`을 우선한다.
2. filename/path는 의도적으로 visible하므로 review한다.
3. SQLite catalog를 첨부하지 않는다.
4. personal Takeout sidecar/media를 첨부하지 않는다.
5. 가능하면 synthetic fixture로 bug를 reproduce한다.
