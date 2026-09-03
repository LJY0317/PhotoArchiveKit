# PhotoArchiveKit Project Instructions

## Product scope
- Keep PhotoArchiveKit local-first, session-based, and lightweight. Do not add a background daemon or filesystem watcher unless a later milestone explicitly requires one.
- The core must remain useful without third-party executables. Optional integrations may use tools already installed by the user.
- Treat a Live Photo as one logical asset with multiple resources. Never plan or apply a one-sided move, rename, quarantine, or deletion of a validated pair.

## Safety
- Read-only inspection is the default. Separate `scan` and `plan` from future mutating `apply` operations.
- Do not implement permanent deletion in the initial releases. Prefer copy, verify, catalog commit, and quarantine.
- An unavailable source or archive root is not evidence that files were deleted. Require a verified root marker before reconciling missing files.
- Preserve existing user changes and keep migrations reversible.

## Privacy
- Never commit personal media, Takeout exports, sidecars, catalog databases, credentials, provider tokens, raw hashes, perceptual hashes, feature vectors, GPS coordinates, Live Photo content identifiers, or absolute personal paths.
- Raw hashes and media-derived identifiers may be processed locally, but normal reports and agent-facing output must expose only booleans, confidence levels, and opaque group IDs.
- Repository fixtures must be synthetic, generated, or explicitly approved for public release.

## Dependencies and licensing
- Prefer Apple system frameworks and Swift standard libraries in the required core.
- Optional adapters may invoke user-installed tools through subprocesses. Do not vendor or redistribute third-party binaries without a separate licensing review.
- Name upstream tools accurately in documentation when describing optional interoperability; do not imply sponsorship or affiliation.

## Documentation and project state
- `README.md` is the primary English overview. Keep `README.ko.md` as the Korean counterpart and update both for user-visible behavior changes.
- Read `STATE.md` before resuming work. Update it only when the current state or next concrete step changes.
- Record expensive, reusable validation results in `MILESTONES.md` without personal paths, identifiers, hashes, or media details.
