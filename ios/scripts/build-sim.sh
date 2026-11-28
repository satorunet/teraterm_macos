#!/bin/bash
# シミュレーターで組み立てて動かす: ./scripts/build-sim.sh [機種名 (既定 "iPhone 11")] [--no-run]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEV="${1:-iPhone 11}"
cd "$HERE"
python3 scripts/gen-project.py >/dev/null
xcodebuild -project TeraSP.xcodeproj -scheme TeraSP -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEV" -derivedDataPath build/dd build 2>&1 \
  | grep -E "error:|warning: .*TeraSP/App|BUILD (SUCCEEDED|FAILED)" | grep -v PluginLoading || true
APP="build/dd/Build/Products/Debug-iphonesimulator/TeraSP.app"
[ -d "$APP" ] || { echo "no app"; exit 1; }
[ "${2:-}" = "--no-run" ] && exit 0
xcrun simctl boot "$DEV" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$DEV" "$APP"
xcrun simctl launch "$DEV" net.satoru.teraterm
