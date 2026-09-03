# Changelog

All notable changes to PhotoArchiveKit will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Semantic versioning will begin once the public CLI and catalog format stabilize.

## [Unreleased]

### Added

- Local-first macOS Swift package with `PhotoArchiveCore`, `photoarchive`, and a dependency-free synthetic self-test.
- Read-only multi-root scanning for Inbox, archive, import, and reference sources.
- Live Photo grouping from embedded Apple identifiers, protected with a catalog-local keyed fingerprint.
- Per-root completeness reporting for complete, still-only, video-only, and ambiguous Live Photo occurrences.
- Local SHA-256 exact-resource duplicate grouping with stable opaque report IDs.
- Provider-neutral logical assets and time-gap event-folder suggestions.
- SQLite catalog for roots, resources, assets, collections, provider mappings, duplicate groups, events, and sessions.
- English/Korean documentation, CI, repository privacy checks, and optional-tool licensing guidance.

### Security

- No media rename, move, upload, quarantine, or deletion commands.
- No background daemon or network request in the core.
- Raw hashes and raw Live Photo identifiers remain outside normal reports.
