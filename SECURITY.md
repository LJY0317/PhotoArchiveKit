# Security Policy

PhotoArchiveKit is an early prototype. Fixes are currently made on the latest `main` branch.

## Private reports

Use GitHub private vulnerability reporting for issues that could expose personal media, local integrity values, metadata, provider credentials, or unintended filesystem changes. Do not post a real catalog database, media file, Takeout sidecar, access token, or raw metadata dump in a public issue.

A useful private report includes the affected commit, a sanitized command, expected and actual behavior, and a synthetic reproduction when possible.

## Current boundaries

The current core:

- makes no network request;
- does not modify scanned media;
- stores its working catalog locally;
- excludes raw hashes and Live Photo identifiers from reports;
- has no permanent-delete command;
- does not bundle third-party executables.

The SQLite catalog can contain paths and local integrity values. Keep it out of source control and public support requests. Future provider adapters and mutating commands must be reviewed as separate trust boundaries.
