#!/bin/bash
set -e

echo "🔨 Building MacIsland..."
pkill -x MacIsland 2>/dev/null || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacIsland.xcodeproj -scheme MacIsland -destination 'platform=macOS' -derivedDataPath .build_derived build -quiet

echo "🚀 Launching MacIsland..."
pkill -x MacIsland 2>/dev/null || true
open .build_derived/Build/Products/Debug/MacIsland.app
echo "✅ MacIsland is running!"
