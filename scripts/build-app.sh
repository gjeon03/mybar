#!/bin/bash
# Builds MyBar.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
config="${1:-release}"
app="build/MyBar.app"

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/MyBar"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MyBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

source scripts/signing.sh
sign "$app"
codesign --verify --strict "$app"
echo "Built $app ($config, signed with '$identity')"
