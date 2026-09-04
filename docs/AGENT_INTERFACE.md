# 개인정보 보호형 Agent Interface

PhotoArchiveKit은 AI agent와 함께 사용할 수 있지만, agent는 media-processing trust boundary 바깥에 있어야 한다. **정상 agent workflow에서 개인 media byte, raw fingerprint, filename/path, capture timestamp 같은 file-level private detail이 AI service로 전달되지 않는 것**을 제품 invariant로 삼는다.

## 경계

```text
personal media
    -> local PhotoArchiveKit process
       -> hashes, metadata identifiers, Vision features
       -> local policy and SQLite
          -> sanitized report
             -> agent
```

agent는 opaque root/logical asset/group/plan ID, provenance category, resource role, status, count, confidence만 받는다. filename/path, media content, raw fingerprint, capture timestamp는 받지 않는다.

## 현재 interface

현재 CLI는 read-only agent usage에 적합하다.

```bash
photoarchive scan --agent-json --inbox "/path/to/inbox"
```

agent-safe JSON report에는 다음이 포함된다.

- opaque scan/session/root identifier
- root kind와 provenance category
- resource role 및 count
- logical Live Photo asset
- root별 completeness
- opaque exact duplicate group
- opaque event/asset relation
- warning code

다음은 제외된다.

- raw exact hash
- raw Live Photo identifier
- image pixel 또는 thumbnail
- video frame 또는 audio
- GPS coordinate
- visual embedding
- provider credential
- filename/relative path/canonical path/catalog path
- exact byte size
- capture timestamp와 suggested folder name

## 권장 future local tool surface

Read-only call:

```text
scan_roots(roots, options)
get_session_summary(session_id)
list_incomplete_live_photos(session_id)
list_duplicate_groups(session_id)
list_event_suggestions(session_id)
get_asset_status(asset_id)
```

Planning call:

```text
propose_archive_plan(session_id, policy)
propose_collection_assignments(session_id, confidence_policy)
validate_plan(plan_id)
export_sanitized_plan(plan_id)
```

Local-user-gated call:

```text
apply_plan(plan_id, approval_token)
quarantine_assets(plan_id, approval_token)
project_to_apple(plan_id, approval_token)
```

agent surface에는 general-purpose file deletion, shell execution, hash printing, metadata dumping, media-reading, filename/path printing method를 두지 않는다. 사람이 로컬에서 보는 `--json` diagnostic output은 agent input으로 사용하지 않는다.

## Secret 대신 status

나쁜 response:

```json
{
  "sha256": "...",
  "livePhotoIdentifier": "...",
  "featureVector": [0.1, 0.2]
}
```

좋은 response:

```json
{
  "assetID": "A0042",
  "kind": "live_photo",
  "pairStatus": "complete",
  "exactDuplicateGroup": "D0017",
  "similarityGroup": "S0004",
  "classification": {
    "candidate": "Japan Trip",
    "confidenceBand": "high"
  }
}
```

## Agent 결정 한계

agent가 할 수 있는 일:

- warning 설명
- policy preset 선택
- collection mapping 제안
- low-risk event suggestion 통합
- review report 생성
- plan의 local validation 요청

agent가 독립적으로 해서는 안 되는 일:

- media permanent delete
- missing-root safety check override
- validated Live Photo resource set 분리
- perceptual match를 exact duplicate로 승격
- private media를 unrelated service에 upload
- local fingerprint reveal/export

## Approval token

future mutating helper는 사용자가 plan을 검토한 뒤 생성되는 short-lived local approval token을 요구해야 한다. token은 다음에 bind되어야 한다.

- plan ID
- exact operation digest
- approved root
- expiry time
- allowed operation class

plan이 바뀌면 approval은 무효화된다. AI가 만든 문자열만으로 local approval로 간주해서는 안 된다.

## Logging

agent log에는 다음을 저장할 수 있다.

- opaque session, asset, plan, group ID
- operation class와 outcome
- 허용된 경우 sanitized path
- warning code
- capability state

다음의 raw command output은 저장하지 않는다.

- ExifTool
- ffprobe
- Vision
- hash tool
- provider token response
- media buffer를 포함할 수 있는 crash dump
