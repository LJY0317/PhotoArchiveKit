# Security Policy

PhotoArchiveKit is an early prototype. Fixes are currently made on the latest `main` branch.

## Reporting a vulnerability

When GitHub private vulnerability reporting is enabled for this repository, use the **Report a vulnerability** button on the repository's Security page.

If that button is not available, open a minimal public issue that contains no sensitive details and ask the maintainer to establish a private channel. Do not include a real catalog database, media file, Takeout sidecar, access token, raw hash, Live Photo identifier, GPS coordinate, personal absolute path, or raw metadata dump in a public issue.

A useful private report includes the affected commit, a sanitized command, expected and actual behavior, and a synthetic reproduction when possible.

## High-priority report classes

Reports are especially important when they involve:

- path traversal outside a configured source or archive root;
- following symbolic links into unintended locations;
- an unavailable root being interpreted as deletion;
- a Live Photo operation affecting only one required resource;
- a plan applying after source files changed;
- corruption or partial commit during interruption;
- media, path, hash, GPS, identifier, or credential leakage;
- command injection through an optional subprocess adapter;
- malicious Takeout or sidecar filenames;
- upload or deletion against the wrong provider account.

## Current boundaries

The current core:

- makes no network request;
- does not modify scanned media;
- stores its working catalog locally;
- excludes raw hashes and Live Photo identifiers from reports;
- has no permanent-delete command;
- does not bundle third-party executables.

The SQLite catalog can contain paths and local integrity values. Keep it out of source control and public support requests. Future provider adapters and mutating commands must be reviewed as separate trust boundaries.
