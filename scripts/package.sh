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

# One build per architecture, merged with lipo: a single `--arch arm64 --arch x86_64`
# build goes through Xcode's build system, which rejects the app target's Swift 5
# language mode ("given: [5], supported: []") with Xcode 16.3.
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch"
done

rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out"
lipo -create -output "$app/Contents/MacOS/MyBar" \
  "$(swift build -c release --arch arm64 --show-bin-path)/MyBar" \
  "$(swift build -c release --arch x86_64 --show-bin-path)/MyBar"
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
