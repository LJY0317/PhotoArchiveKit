#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/.."
mkdir -p .build
swiftc -swift-version 6 -parse-as-library \
    Sources/photoarchive-review/ReviewRootList.swift \
    Tests/PhotoArchiveReviewTests/RootListTests.swift \
    -o .build/review-roots-selftest
.build/review-roots-selftest
