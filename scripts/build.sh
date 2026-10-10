#!/bin/bash
# Builds (or tests) the app for the simulator.
#   scripts/build.sh                 build
#   scripts/build.sh test            run unit + UI tests
#   scripts/build.sh test -only-testing:CoupleNotesTests
#
# Build products are kept outside the project folder on purpose: when the
# project lives somewhere Finder decorates with extended attributes (Desktop,
# Documents, iCloud Drive), codesign refuses to sign products built in place.
set -euo pipefail
cd "$(dirname "$0")/.."
ACTION="${1:-build}"; shift || true
DEVICE="${SIMULATOR_NAME:-iPhone 17}"
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/CoupleNotes-cli}"
[ -d CoupleNotes.xcodeproj ] || xcodegen generate
xcodebuild -project CoupleNotes.xcodeproj -scheme CoupleNotes \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" "$ACTION" "$@"
