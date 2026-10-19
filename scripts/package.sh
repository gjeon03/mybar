#!/bin/bash
# Builds a universal (Apple silicon + Intel) MyBar.app and packages it as a
# drag-to-install disk image for sharing. Usage: scripts/package.sh [output-dir]
#
# With a Developer ID certificate and MYBAR_NOTARY_PROFILE (a profile saved with
# `xcrun notarytool store-credentials`), the disk image is also notarized and
# stapled, so it opens without Gatekeeper warnings.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-build}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
stage="build/dmg"
app="$stage/MyBar.app"
dmg="$out/MyBar-$version.dmg"

swift build -c release --arch arm64 --arch x86_64
bin=".build/apple/Products/Release/MyBar"

rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out"
cp "$bin" "$app/Contents/MacOS/MyBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
source scripts/signing.sh
sign "$app"
codesign --verify --strict "$app"

ln -s /Applications "$stage/Applications"
cp Resources/READ-ME-FIRST.txt "$stage/READ ME FIRST.txt"

rm -f "$dmg"
hdiutil create -volname "MyBar $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
if [ "$identity" != "-" ]; then
  sign "$dmg"
fi
if [ -n "${MYBAR_NOTARY_PROFILE:-}" ]; then
  [ "$identity" != "-" ] || { echo "Notarizing needs a Developer ID certificate" >&2; exit 1; }
  xcrun notarytool submit "$dmg" --keychain-profile "$MYBAR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
echo "Packaged $dmg, signed with '$identity'"
echo "Architectures: ($(lipo -archs "$app/Contents/MacOS/MyBar"))"
