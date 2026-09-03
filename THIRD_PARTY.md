# Optional Third-Party Interoperability

PhotoArchiveKit's required core does not contain, link, vendor, download, or redistribute the tools below. The CLI may detect user-installed executables, and future adapters may invoke them as separate processes after an explicit user command.

Mentioning an interoperable project by name is normal open-source practice. It is clearer than hiding an external dependency. Documentation and UI must not imply sponsorship, endorsement, or affiliation.

## rclone

- Purpose: optional off-site archive copy and verification.
- Integration model: invoke a user-installed `rclone` executable.
- Upstream: <https://rclone.org/>
- Upstream license: MIT.
- Bundled by PhotoArchiveKit: no.

The initial adapter should generate or execute conservative `copy` and `check` operations. It must not choose destructive `sync` behavior as a default.

## Czkawka CLI

- Purpose: optional additional exact-duplicate and perceptual-similarity candidate generation.
- Integration model: invoke a user-installed `czkawka_cli` executable and import a sanitized result.
- Upstream: <https://github.com/qarmin/czkawka>
- Applicable upstream license for `czkawka_core` and `czkawka_cli`: MIT.
- Bundled by PhotoArchiveKit: no.

Similarity output is a review signal. PhotoArchiveKit must never translate it directly into deletion.

## Krokiet

- Purpose: a user may independently use its GUI to inspect duplicate and similarity candidates.
- Integration model: no planned required integration; PhotoArchiveKit can interoperate through files or user decisions.
- Upstream: <https://github.com/qarmin/czkawka>
- Finished application license: GPL-3.0-only due to its GUI framework licensing, according to the upstream project.
- Bundled by PhotoArchiveKit: no.

PhotoArchiveKit should prefer the separately licensed Czkawka CLI for an automated optional subprocess adapter. It should not redistribute Krokiet inside an MIT release without a new packaging and license review.

## ExifTool

- Purpose: optional broad metadata diagnostics, migration investigations, and comparison with PhotoArchiveKit's native probes.
- Integration model: invoke a user-installed `exiftool` process.
- Upstream: <https://exiftool.org/>
- Upstream license: the same terms as Perl itself, as stated by upstream.
- Bundled by PhotoArchiveKit: no.

The initial design treats ExifTool as read-only. Rewriting Live Photo identifiers or source metadata is outside the first releases.

## FFmpeg / ffprobe

- Purpose: optional video stream and container diagnostics.
- Integration model: invoke a user-installed `ffprobe` process.
- Upstream: <https://ffmpeg.org/>
- Upstream license: generally LGPL 2.1 or later, but a build can become GPL depending on enabled components.
- Bundled by PhotoArchiveKit: no.

Because the license can depend on how a binary was built, PhotoArchiveKit does not redistribute a generic ffprobe binary in the initial project.

## Apple system frameworks

The Swift package links system-provided frameworks and libraries available on macOS:

- Foundation
- ImageIO
- AVFoundation
- CryptoKit
- SQLite3

These are platform requirements rather than vendored project dependencies.

## If bundling is considered later

Before adding any third-party binary or source distribution:

1. Identify the exact component and version.
2. Confirm its license and the license of the actual build configuration.
3. Add required copyright and notice files.
4. Document source availability and modification status where required.
5. Review trademark use and naming.
6. Keep the optional integration separable from the MIT core where practical.
7. Do not download or execute a binary silently.

This file is a project policy summary, not legal advice.
