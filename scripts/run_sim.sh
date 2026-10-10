#!/bin/bash
# Installs the last simulator build and launches it, optionally with launch
# arguments, e.g.  scripts/run_sim.sh -demoScenario paired
set -euo pipefail
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/CoupleNotes-cli}"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/CoupleNotes.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted "$BUNDLE_ID" "$@"
