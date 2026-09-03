# Roadmap

The roadmap favors small, verifiable layers. No phase depends on deleting existing originals.

## v0.1 — Read-only scanner and catalog

Status: initial implementation complete.

- [x] Swift package and lightweight CLI
- [x] Multiple configurable source roots
- [x] ImageIO and AVFoundation metadata probes
- [x] Live Photo pairing by embedded identifiers
- [x] Per-root completeness reporting
- [x] Local exact duplicate groups with opaque public IDs
- [x] SQLite schema for resources, assets, collections, providers, sessions, and events
- [x] Time-gap event suggestions
- [x] Human and sanitized JSON reports
- [x] Dependency-free synthetic self-test
- [x] Five-path disposable ingest fixture validation
- [ ] Strict validation of Live Photo still-image-time timed metadata
- [ ] Versioned sanitized JSONL catalog export and restore test
- [ ] Incremental scan optimization using stable file facts before re-probing
- [ ] Synthetic public Live Photo fixtures suitable for CI

## v0.2 — Automatic organization and immutable plans

- [ ] Canonical capture-time resolver with documented source priority
- [ ] Same-second and burst grouping
- [ ] Deterministic `YYYYMMDD_HHMMSS[_suffix]` rename proposals
- [ ] Original-name and reversible rename history
- [ ] Existing archive folder import as collection examples
- [ ] Event-level collection proposals
- [ ] Confidence bands and policy presets
- [ ] Immutable plan format with preconditions
- [ ] Finder-compatible shadow review folders or a lightweight generated review index
- [ ] No mutation by default; explicit plan validation command

The goal is to classify event groups rather than require one decision per photo.

## v0.3 — Safe archive application

- [ ] Verified root marker
- [ ] Copy to staging, local byte verification, and atomic finalization
- [ ] Live Photo resource-set transactions
- [ ] Resume interrupted sessions from checkpoints
- [ ] Quarantine rather than permanent deletion
- [ ] Catalog snapshot to archive metadata directory
- [ ] Replica policy and verification records
- [ ] Optional rclone adapter using user-installed `rclone`
- [ ] Never use `rclone sync` as an initial default

## v0.4 — Local visual classification

- [ ] Optional Apple Vision feature-print adapter
- [ ] Record Vision request revision and feature schema
- [ ] Event-level nearest-neighbor classification from existing folder examples
- [ ] Optional coarse Vision image labels
- [ ] Local-only feature cache with erase/rebuild controls
- [ ] No feature vectors or inferred face data in reports
- [ ] Optional Czkawka CLI candidate import for similar images/videos
- [ ] Similarity remains a review signal, never deletion authority

A simple first classifier should prefer familiar folders learned from the user's archive over a large universal taxonomy.

## v0.5 — Apple Photos projection

- [ ] Small Swift PhotoKit bridge
- [ ] Read assets and user albums with explicit authorization
- [ ] Import validated `.photo` + `.pairedVideo` resources
- [ ] Create albums from catalog collections
- [ ] Add/remove asset membership transactionally
- [ ] Test against an isolated Photos library before the system library
- [ ] Preserve original-resource guarantee separately from Apple adjustment history

## v0.6 — Provider exports and Google upload

- [ ] Fixture-driven Google Takeout parser
- [ ] Preserve sidecars and raw export layout before normalization
- [ ] Reconstruct album membership where the observed Takeout schema permits it
- [ ] Google Photos Picker import for user-selected items
- [ ] Google Photos Library API upload for supported simple media
- [ ] Capability report for app-created Google content and albums
- [ ] Do not claim public API Live Photo upload until an official composite mechanism or a verified safe route exists
- [ ] Permit upload-without-albums as a useful capability

Google adapter behavior must follow the current API, not assumptions that broader scopes will return.

## Later possibilities

- Lightweight SwiftUI or local web front end built on the same core
- Optional Immich/PhotoPrism projection reports
- Additional file-cloud replicas
- Multi-Mac catalog snapshot reconciliation
- Edited Live Photo derivative and adjustment-resource preservation
- Offline map/timezone enrichment with explicit privacy controls

## Explicitly deferred

- background filesystem watchers;
- always-on server infrastructure;
- browser automation as a core Google adapter;
- automatic permanent deletion;
- enterprise multi-user permissions;
- content-addressed user-facing storage;
- silent rewrite of original media metadata.
