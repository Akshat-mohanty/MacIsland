#!/bin/bash
set -e

echo "🔨 Building MacIsland..."
pkill -x MacIsland 2>/dev/null || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacIsland.xcodeproj -scheme MacIsland -configuration Release -destination 'platform=macOS' -derivedDataPath .build_derived build -quiet

echo "📦 Installing single instance to /Applications/MacIsland.app..."
rm -rf /Applications/MacIsland.app ~/Applications/MacIsland.app 2>/dev/null || true
cp -R .build_derived/Build/Products/Release/MacIsland.app /Applications/MacIsland.app

echo "🚀 Launching MacIsland..."
pkill -x MacIsland 2>/dev/null || true
open /Applications/MacIsland.app
echo "✅ MacIsland is running from /Applications!"
