#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=$(/bin/sh "$SCRIPT_DIR/build-app.sh")

open "$APP_DIR"
