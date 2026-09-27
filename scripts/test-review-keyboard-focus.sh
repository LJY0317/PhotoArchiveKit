#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_DIR"
mkdir -p .build
swiftc -swift-version 6 -parse-as-library \
    Sources/photoarchive-review/ReviewKeyboardFocusState.swift \
    Sources/photoarchive-review/ReviewToolbarSearchField.swift \
    Tests/PhotoArchiveReviewTests/KeyboardFocusTests.swift \
    -o .build/review-keyboard-focus-selftest
.build/review-keyboard-focus-selftest
