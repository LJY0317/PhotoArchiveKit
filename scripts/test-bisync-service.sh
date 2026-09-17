#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/.."

if ! command -v rclone >/dev/null 2>&1; then
    printf '%s\n' 'SKIP: rclone is not installed; bisync adapter is optional.'
    exit 0
fi

version=$(rclone version | sed -n '1p')
if [ "$version" != 'rclone v1.75.0' ]; then
    printf '%s\n' "SKIP: app-service JSON parser is qualified for rclone v1.75.0, found: $version"
    exit 0
fi

swift run photoarchive-bisync-selftest
