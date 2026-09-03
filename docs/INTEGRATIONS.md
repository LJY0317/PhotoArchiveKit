# Optional Integrations

PhotoArchiveKit's required runtime is deliberately self-contained. It uses Apple system frameworks, CryptoKit, and the macOS SQLite library. Optional tools may improve individual stages, but the core scanner, Live Photo grouping, exact-resource comparison, catalog, and event suggestions work without them.

## General policy

The normal integration pattern is:

1. The user installs and configures the upstream program independently.
2. PhotoArchiveKit discovers the executable through `PATH` or explicit configuration.
3. A small adapter invokes it as a separate process using an argument array.
4. The adapter parses only the minimum required result.
5. Agent-facing output contains paths, booleans, confidence, and opaque group IDs—not raw hashes, frames, or feature data.

PhotoArchiveKit does not silently download or copy optional binaries into its release.

Naming interoperable programs is normal open-source practice. Documentation should use the official name, link to the official project, state that the integration is optional and separately licensed, and avoid implying endorsement.

## rclone

Planned use:

- copy a completed archive and catalog snapshots to a file cloud;
- verify the remote copy;
- return a sanitized session result.

Safety defaults:

- prefer `rclone copy`, not `rclone sync`;
- follow with `rclone check`;
- never treat an unavailable local root as permission to delete remote files;
- reuse the user's existing configuration and OAuth storage;
- show the exact proposed operation before execution.

rclone is not bundled. Its upstream license is MIT.

## Czkawka CLI and Krokiet

PhotoArchiveKit already performs local exact-resource grouping. A future `czkawka_cli` adapter can add:

- perceptually similar image candidates;
- similar-video candidates;
- additional broken-file or duplicate diagnostics where supported.

Similarity is a review signal and must never become automatic deletion authority. Raw perceptual hashes, frames, and caches stay local.

The upstream repository contains components with different distribution boundaries. The CLI/core are suitable optional subprocess targets; Krokiet is not embedded or redistributed by PhotoArchiveKit. Users may still run its GUI independently.

## ExifTool

Planned use:

- extended read-only metadata diagnostics;
- migration-fixture comparison;
- timestamp candidates for formats not fully covered by the native adapter;
- Takeout sidecar investigation;
- future rename-plan dry runs.

Early releases should not use ExifTool to rewrite Live Photo metadata. Its output can include identifiers, GPS, serial numbers, and other sensitive fields, so an adapter must parse locally and emit only allowed summaries.

## ffprobe

A user-installed `ffprobe` can provide optional container, stream, duration, audio, and timed-metadata diagnostics. PhotoArchiveKit does not redistribute a generic FFmpeg build because the applicable license depends on its build configuration.

## Apple PhotoKit

PhotoKit is an Apple system framework, not a bundled third-party dependency. A future local macOS adapter can, with user authorization:

- read Photos assets, albums, and folders;
- obtain Live Photo resources;
- create a Live Photo from `.photo` plus `.pairedVideo` resources;
- create albums and update membership;
- work with a system Photos library synchronized through iCloud Photos.

The filesystem archive and neutral catalog remain authoritative.

## Google Photos

The first practical Google adapter should stay narrow:

- flat upload of supported ordinary media;
- record app-created provider objects;
- optionally manage app-created media and app-created albums;
- Picker-based, explicitly user-selected imports;
- capability reports for unsupported existing-library operations.

It must not use browser automation to imitate unavailable API capabilities. It must also block Live Photo flat upload until an official and verified composite-import path exists, rather than split one logical asset into unrelated cloud items.

## Google Takeout

Takeout is treated as a versioned import format, not a continuously queryable provider API. The parser must preserve unknown files and JSON fields and be driven by real disposable fixtures rather than guessed filename conventions.

## Gallery systems

Immich, PhotoPrism, Mylio, and similar systems are useful design references or optional views over the archive. They do not replace PhotoArchiveKit's portable semantic state. Metadata that exists only in a gallery database can become another lock-in point.

## Bundling checklist

Any future decision to bundle or link an upstream component requires a separate review of the exact version, transitive licenses, notices, source obligations, trademarks, signing/notarization, updates, vulnerabilities, privacy, and behavior when the dependency is absent.

See [THIRD_PARTY.md](../THIRD_PARTY.md) for current component-specific license notes.
