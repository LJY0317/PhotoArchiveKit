# 개인정보 보호형 Agent Interface

PhotoArchiveKit은 AI agent와 함께 사용할 수 있지만, agent는 media-processing trust boundary 바깥에 있어야 한다. **정상 agent workflow에서 개인 media byte, raw fingerprint, filename/path, capture timestamp 같은 file-level private detail이 AI service로 전달되지 않는 것**을 제품 invariant로 삼는다.

## 경계

```text
personal media
    -> local PhotoArchiveKit process
       -> hashes, metadata identifiers, optional future local-only features
       -> local policy and SQLite
          -> sanitized report
             -> agent
```

agent는 opaque root/logical asset/group/plan ID, provenance category, resource role, status, count, confidence만 받는다. filename/path, media content, raw fingerprint, capture timestamp는 받지 않는다.

## 현재 interface와 최종 CLI 목표

현재 prototype에서는 `--agent-json`을 명시해야 agent-safe output을 강제한다. `scan`과 `plan`은 read-only agent usage에 적합하고, `quarantine`도 `--agent-json`으로 path-free dry-run summary를 낼 수 있지만 실제 `--apply`는 local-user-gated mutation으로 취급한다.

최종 배포형 CLI의 목표는 **safe-by-default**다. 사용자가 agent에게 단순히 `PhotoArchiveKit을 사용해`라고 요청해도 추가 privacy prompt 없이 agent-safe surface가 정상 경로가 되어야 한다. 일반 `photoarchive` command의 기본 machine-readable output은 private filename/path/hash/metadata를 포함하지 않고, 사람이 로컬에서 private diagnostic을 정말 필요로 할 때만 명시적인 local-only opt-in을 요구하는 방향으로 interface를 발전시킨다. 장기적으로 PATH/Homebrew 등 일반적인 설치 방식, shell completion, stable command contract, agent/Skill integration을 제공해 rclone/Czkawka처럼 다른 agent가 먼저 발견·추천·호출하기 쉬운 standalone CLI가 되는 것을 목표로 한다.

```bash
photoarchive scan --agent-json --inbox "/path/to/inbox"
photoarchive plan --agent-json --local "/path/to/local" --takeout "/path/to/takeout"
photoarchive organize-plan --agent-json --local "/path/to/local"
photoarchive archive-index --agent-json "/path/to/user-managed/archive"
photoarchive archive-plan --agent-json --to "/path/to/archive" --output "/local/private/archive-plan.json" --local "/path/to/local"
photoarchive archive-copy --agent-json "/local/private/archive-plan.json"
photoarchive organize --agent-json --local "/path/to/local"
photoarchive quarantine --agent-json --to "/local/quarantine" --local "/path/to/local" --takeout "/path/to/takeout"
photoarchive restore-quarantine --agent-json "/local/quarantine/PhotoArchiveKit/<session>/manifest.json"
photoarchive cleanup-empty-dirs --agent-json "/local/operations/<session>/organization.json"
photoarchive catalog export --agent-json --output "/local/private/catalog.jsonl"
photoarchive catalog restore --agent-json --to "/local/private/restored.sqlite3" "/local/private/catalog.jsonl"
```

`plan`은 exact/provenance evidence를 opaque reconciliation item으로 만들고, `organize-plan`은 camera-style filename의 rename/flat-move를 opaque organization item으로 만든다. `archive-index`는 user-managed archive의 current folder hierarchy와 exact-hash cache를 local에서 갱신하고 agent에는 root ID, resource/folder count, cache-hit count, inventory-written boolean만 준다. persisted `.photoarchive/inventory-v1.jsonl`에는 relative path와 raw SHA-256 등이 있으므로 agent가 읽지 않는다. `archive-plan`은 media를 수정하지 않지만 catalog path, source/destination marker binding, relative path, byte size, expected SHA-256을 담은 local-private immutable plan schema v2를 작성하고 agent-safe output에는 opaque plan/item/asset ID, reason code, count만 반환한다. `archive-copy`도 기본 dry-run이며 current catalog/source/destination evidence를 재검증한 결과의 count/status만 agent에 보여 준다. apply 뒤 local manifest/snapshot/archived-plan path와 hash는 agent-safe report에서 제거된다. `organize`, `quarantine`, `restore-quarantine`, `cleanup-empty-dirs`, `catalog restore` 역시 기본 dry-run이며 agent-safe output에는 item/resource/directory/record count와 outcome만 반환한다. 실제 media/filesystem mutation gate는 사람이 local CLI에서 명시적으로 붙이는 `--apply`이고, organization/archive path는 stable root marker를 요구한다. `catalog export`, `archive-index` inventory, `archive-plan`, archive-copy manifest/snapshot의 persisted artifact 본문은 agent-safe surface가 아니므로 agent가 읽지 않는다. 장기적으로 real-library archive apply에는 short-lived approval token을 추가할 수 있다.

agent-safe JSON report에는 다음이 포함된다.

- opaque scan/session/root identifier
- root kind와 provenance category
- resource role 및 count
- logical Live Photo asset
- root별 completeness
- opaque exact duplicate group
- opaque event/asset relation
- warning code
- exact-hash cache hit count처럼 개인 file detail이 없는 performance count

다음은 제외된다.

- raw exact hash
- raw Live Photo identifier
- image pixel 또는 thumbnail
- video frame 또는 audio
- GPS coordinate
- visual embedding 또는 local-only pixel-derived feature
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

- 사용자의 explicit local approval 없이 `quarantine --apply` 실행
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
