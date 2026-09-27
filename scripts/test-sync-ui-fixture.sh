#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=$(/bin/sh "$SCRIPT_DIR/build-app.sh")
result=$(mktemp "${TMPDIR:-/tmp}/photoarchive-sync-ui.XXXXXX")
rm -f "$result"
trap 'rm -f "$result"' EXIT

open -n -W "$APP_DIR" --args \
    --sync-ui-fixture \
    --sync-ui-fixture-validate \
    --sync-ui-fixture-result "$result"

grep -Fq 'passed' "$result"
printf '%s\n' 'PhotoArchiveKit isolated sync UI fixture passed.'
