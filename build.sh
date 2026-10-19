#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=PRWatcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PRWatcher "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP — run: open $APP"
