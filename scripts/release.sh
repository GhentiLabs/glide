#!/bin/zsh
# Builds a signed Glide DMG in build/. Notarizes and staples it when NOTARY_PROFILE names a
# notarytool keychain profile (create one with: xcrun notarytool store-credentials <name>).
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
rm -rf build/Glide.xcarchive build/export
xcodebuild -project Glide.xcodeproj -scheme Glide -configuration Release -derivedDataPath build/dd \
  -archivePath build/Glide.xcarchive archive -quiet
xcodebuild -exportArchive -archivePath build/Glide.xcarchive -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath build/export -quiet

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/export/Glide.app/Contents/Info.plist)
dmg="build/Glide-$version.dmg"
rm -f "$dmg"
create-dmg --volname Glide --window-size 540 360 --icon-size 128 --icon Glide.app 140 170 \
  --app-drop-link 400 170 --no-internet-enable "$dmg" build/export/Glide.app
codesign --sign "Developer ID Application" --timestamp "$dmg"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
  echo "NOTARY_PROFILE not set: $dmg is signed but not notarized, so Gatekeeper will block it on other Macs."
fi
echo "$dmg"
