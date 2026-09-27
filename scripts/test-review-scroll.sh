#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_DIR"
mkdir -p .build
swiftc -swift-version 6 -parse-as-library \
    Sources/photoarchive-review/ReviewComparisonScrollView.swift \
    Sources/photoarchive-review/ReviewWindowLayout.swift \
    Tests/PhotoArchiveReviewTests/ComparisonScrollTests.swift \
    -o .build/review-scroll-selftest
.build/review-scroll-selftest
