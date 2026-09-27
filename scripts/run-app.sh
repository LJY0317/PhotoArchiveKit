#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=$(/bin/sh "$SCRIPT_DIR/build-app.sh")

# Always hand off to the newly built bundle. Do not leave an older
# photoarchive-review process running alongside it.
if pgrep -x photoarchive-review >/dev/null 2>&1; then
    pkill -TERM -x photoarchive-review || true
    attempts=0
    while pgrep -x photoarchive-review >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 50 ]; then
            printf '%s\n' "PhotoArchiveKit did not quit cleanly; not starting a second copy." >&2
            exit 1
        fi
        sleep 0.1
    done
fi

open "$APP_DIR"
