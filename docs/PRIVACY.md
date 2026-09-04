# Privacy Model

PhotoArchiveKit의 **첫 번째 핵심 제품 가치**는 AI agent가 사용자의 사진 archive를 다루더라도 개인 media와 media-derived/file-level private detail이 AI service로 전달되지 않게 하는 것이다. local process가 raw data를 읽고 계산할 수는 있지만, 정상 agent workflow는 opaque semantic result만 받아야 하며 raw media/hash/identifier/path를 읽을 이유가 없어야 한다.

이 보장은 PhotoArchiveKit의 agent-safe interface 안에서 제공한다. 사용자가 별도의 general-purpose shell/file tool로 개인 media나 diagnostic output을 직접 AI agent에 노출하면 이 경계를 우회할 수 있으므로, agent automation은 PhotoArchiveKit의 privacy-minimized CLI/API surface를 사용한다.

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

### Agent-safe report에 절대 포함하지 않는 항목

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
- filename과 relative/canonical path
- catalog path
- exact byte size
- capture timestamp와 GPS-derived place
- user folder/album name처럼 media organization에서 직접 유래한 private label

## Live Photo identifier 보호

scanner는 still image와 motion resource가 같은 identifier를 가지는지 판단해야 하지만 identifier 자체를 reveal할 필요는 없다.

현재 process:

1. local process memory에서 각 resource identifier를 읽는다.
2. 주변 whitespace만 normalize한다.
3. 해당 catalog를 위해 만든 random key로 HMAC-SHA-256을 계산한다.
4. fingerprinting 직후 in-memory probe object에서 raw identifier를 clear한다.
5. SQLite에는 keyed fingerprint만 저장한다.
6. agent-safe report에는 logical asset ID와 match/completeness status만 노출한다.

HMAC key는 catalog-local이므로 서로 다른 catalog의 fingerprint를 비교하는 용도로 쓰지 않는다. accidental cross-dataset correlation을 줄이기 위함이다.

## Exact hash

reliable duplicate detection에는 stable content fingerprint가 필요하므로 raw exact-file hash는 로컬에 유지할 수 있다. 사람이 자기 Mac에서 보는 diagnostic report는 path를 포함할 수 있지만 AI agent용 report는 equality를 opaque relation으로만 전달한다.

```json
{
  "groupID": "D000017",
  "memberCount": 2,
  "rootIDs": ["R0002", "R0007"],
  "roles": ["photo"]
}
```

raw digest와 path는 agent-safe output에 출력하지 않는다.

## Human diagnostic와 agent-safe output 분리

`--json`은 사람이 로컬에서 troubleshooting할 때 쓰는 diagnostic output이다. path와 filename 같은 개인 file detail을 포함할 수 있으므로 AI agent에 그대로 전달하지 않는다.

`--agent-json`은 AI agent용 privacy-minimized output이다. 현재 다음을 제거한다.

- catalog/root/file path
- root label과 filename
- exact byte size
- capture timestamp
- suggested folder name
- raw hash/identifier/metadata dump

대신 다음과 같은 최소 semantic result만 제공한다.

- opaque session/root/asset/group ID
- provenance category
- resource role
- Live Photo completeness/status
- duplicate relation
- count
- warning code
- 향후 plan decision/confidence

self-test는 synthetic fixture의 known local SHA-256 value, filename, root path, catalog path가 agent-safe encoded report에 나타나지 않는지 확인한다.

## Agent-facing boundary

agent는 다음과 같은 privacy-minimized operation만 호출해야 한다.

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
print_filename
print_path
print_capture_timestamp
```

safe agent-facing asset record 예:

```json
{
  "assetID": "A0042",
  "kind": "live_photo",
  "pairStatus": "complete",
  "exactDuplicateGroup": "D0017",
  "provenancePreference": "local_over_takeout",
  "decision": "redundant_candidate",
  "confidence": "automatic"
}
```

## Optional local visual analysis

automatic organization은 나중에 Apple Vision 또는 local Core ML model을 사용할 수 있다. cloud classifier보다 private하지만 output 자체도 sensitive하다.

visual feature rule:

- 기본적으로 Live Photo still resource에 대해 동작
- pixel, frame, label, embedding을 upload하지 않음
- model/request revision 기록
- feature는 protected local application state에만 저장
- agent-safe JSON, log, crash report, support bundle에서 제외
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
- complete Live Photo resource set 또는 보존이 증명된 canonical coverage
- verified canonical copy
- deletion-eligible content에 대해 최소 하나의 independently verified replica
- permanent deletion 대신 quarantine
- irreversible action에 대한 explicit local approval

## Logging

agent-safe log에는 다음을 저장할 수 있다.

- opaque session, root, asset, plan, group ID
- provenance category
- resource role와 completeness/status
- operation class와 outcome
- warning code
- capability state

path/filename은 agent-safe log에 기본적으로 저장하지 않는다. 사람이 명시적으로 troubleshooting을 위해 opt-in한 local-only diagnostic에서만 별도로 다룬다.

## Issue/support hygiene

report 공유 전:

1. AI agent 또는 외부 AI service에는 `--agent-json`만 사용한다.
2. `--json`은 path/filename이 필요한 local human diagnostic으로 취급하며 그대로 공유하지 않는다.
3. SQLite catalog를 첨부하지 않는다.
4. personal Takeout sidecar/media를 첨부하지 않는다.
5. 가능하면 synthetic fixture로 bug를 reproduce한다.
