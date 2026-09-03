# Privacy-Safe Agent Interface

PhotoArchiveKit may be used with an AI agent, but the agent must sit outside the media-processing trust boundary.

## Boundary

```text
personal media
    -> local PhotoArchiveKit process
       -> hashes, metadata identifiers, Vision features
       -> local policy and SQLite
          -> sanitized report
             -> agent
```

The agent receives paths when the user permits them, logical asset IDs, statuses, confidence, and opaque group IDs. It does not receive media content or raw fingerprints.

## Current interface

The current CLI is suitable for read-only agent use:

```bash
photoarchive scan --json --inbox "/path/to/inbox"
```

The JSON report includes:

- scan/session identifiers;
- configured root labels and paths;
- file-relative paths and resource roles;
- logical Live Photo assets;
- per-root completeness;
- opaque exact duplicate groups;
- automatic event proposals;
- warnings.

It excludes:

- raw exact hashes;
- raw Live Photo identifiers;
- image pixels or thumbnails;
- video frames or audio;
- GPS coordinates;
- visual embeddings;
- provider credentials.

## Recommended future local tool surface

Read-only calls:

```text
scan_roots(roots, options)
get_session_summary(session_id)
list_incomplete_live_photos(session_id)
list_duplicate_groups(session_id)
list_event_suggestions(session_id)
get_asset_status(asset_id)
```

Planning calls:

```text
propose_archive_plan(session_id, policy)
propose_collection_assignments(session_id, confidence_policy)
validate_plan(plan_id)
export_sanitized_plan(plan_id)
```

Local-user-gated calls:

```text
apply_plan(plan_id, approval_token)
quarantine_assets(plan_id, approval_token)
project_to_apple(plan_id, approval_token)
```

The agent surface should not contain general-purpose file deletion, shell execution, hash printing, metadata dumping, or media-reading methods.

## Status instead of secrets

Bad response:

```json
{
  "sha256": "...",
  "livePhotoIdentifier": "...",
  "featureVector": [0.1, 0.2]
}
```

Good response:

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

## Agent decision limits

An agent may:

- explain warnings;
- choose between policy presets;
- propose collection mappings;
- consolidate low-risk event suggestions;
- generate a review report;
- request local validation of a plan.

An agent may not independently:

- permanently delete media;
- override a missing-root safety check;
- split a validated Live Photo resource set;
- promote a perceptual match to exact duplicate;
- upload private media to an unrelated service;
- reveal or export local fingerprints.

## Approval tokens

A future mutating helper should require a short-lived local approval token created after the user reviews a plan. The token should bind to:

- plan ID;
- exact operation digest;
- approved roots;
- expiry time;
- allowed operation classes.

Changing a plan invalidates the approval. An AI-generated string alone must not count as local approval.

## Logging

Agent logs should store:

- opaque session, asset, plan, and group IDs;
- operation classes and outcomes;
- sanitized paths when permitted;
- warning codes;
- capability states.

They should not store raw command output from ExifTool, ffprobe, Vision, hash tools, provider token responses, or crash dumps containing media buffers.
