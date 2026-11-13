#!/usr/bin/env bash
# Builds the native v0.2 app and its release artifacts: policy check, tests,
# universal .app, .dmg, .zip and SHA256SUMS in dist/<version>/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MAC="$ROOT/macos"
APPNAME="AWS DB Backup Manager"
"$MAC/scripts/policy-check-native.sh"
(cd "$MAC" && swift test)
"$MAC/scripts/make-app.sh"
APP="$MAC/build/$APPNAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
lipo -info "$APP/Contents/MacOS/ADBMApp"
codesign --verify --deep --strict "$APP" && echo "codesign: valid (ad-hoc)"
OUT="$ROOT/dist/$VERSION"; ART="AWS-DB-Backup-Manager-$VERSION-macos-universal"
mkdir -p "$OUT"; rm -rf "$OUT/dmg-staging" "$OUT/$ART.dmg" "$OUT/$ART.zip"
mkdir -p "$OUT/dmg-staging"
ditto "$APP" "$OUT/dmg-staging/$APPNAME.app"
ln -s /Applications "$OUT/dmg-staging/Applications"
hdiutil create -volname "$APPNAME" -srcfolder "$OUT/dmg-staging" -fs HFS+ -format UDZO -ov "$OUT/$ART.dmg" >/dev/null
rm -rf "$OUT/dmg-staging"
hdiutil verify "$OUT/$ART.dmg" >/dev/null && echo "dmg: verified"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ART.zip"
(cd "$OUT" && shasum -a 256 "$ART.dmg" "$ART.zip" > SHA256SUMS && cat SHA256SUMS)
