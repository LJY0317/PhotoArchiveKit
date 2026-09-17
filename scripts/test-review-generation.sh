#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/.."
mkdir -p .build
swiftc -swift-version 6 -parse-as-library \
    Sources/photoarchive-review/ReviewGenerationGate.swift \
    Tests/PhotoArchiveReviewTests/GenerationGateTests.swift \
    -o .build/review-generation-selftest
.build/review-generation-selftest
