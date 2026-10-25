#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
kind=dev
if [[ "${SYNCOPHANT_DISTRIBUTION:-0}" == 1 ]]; then
  [[ -n "${SYNCOPHANT_TEAM_ID:-}" ]] || { echo 'Developer ID packaging requires SYNCOPHANT_TEAM_ID.' >&2; exit 1; }
  kind=signed-not-notarized
fi
# Set to a `notarytool store-credentials` profile name to notarize and staple.
if [[ -n "${SYNCOPHANT_NOTARY_PROFILE:-}" ]]; then
  [[ "$kind" == signed-not-notarized ]] || { echo 'Notarization requires SYNCOPHANT_DISTRIBUTION=1.' >&2; exit 1; }
  kind=notarized
fi
CONFIGURATION=Release bash scripts/build.sh
app="${SYNCOPHANT_DERIVED_DATA:-build/DerivedData}/Build/Products/Release/Syncophant.app"
codesign --verify --deep --strict "$app"
if [[ "$kind" != dev ]]; then
  for bundle in "$app" "$app/Contents/PlugIns/SyncophantProvider.appex" "$app/Contents/MacOS/SyncophantAgentRendezvous" "$app/Contents/Resources/syncophant-crypt"; do
    entitlements=$(codesign -d --entitlements :- "$bundle" 2>/dev/null)
    # Xcode build actions can inject debugger access even for Release configurations.
    if [[ "$(printf '%s' "$entitlements" | plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null || true)" == true ]]; then
      echo "Refusing to package debugger-enabled code: $bundle" >&2
      exit 1
    fi
  done
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
base="build/Syncophant-$version-$(uname -m)"
[[ "$kind" == notarized ]] || base+="-$kind"
dmg="$base.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Syncophant.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname Syncophant -srcfolder "$stage" -format UDZO "$dmg"
if [[ "$kind" != dev ]]; then
  codesign --force --sign "${SYNCOPHANT_SIGNING_IDENTITY:-Developer ID Application}" --timestamp "$dmg"
fi
if [[ "$kind" == notarized ]]; then
  # Notarizing the DMG also covers the app inside, so the app can be stapled for the ZIP too.
  xcrun notarytool submit "$dmg" --keychain-profile "$SYNCOPHANT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler staple "$app"
  spctl -a -t open --context context:primary-signature "$dmg"
fi
archive="$base.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" "$dmg" > "$base.sha256"
sources="build/Syncophant-$version-source.tar.gz"
tar --exclude='.DS_Store' --exclude='.git' -czf "$sources" \
  Package.swift Package.resolved Sources Tests scripts Config Assets LICENSE README.md DESIGN.md docs .github
third_party="build/AMSMB2-4.0.3-source.tar.gz"
[[ -f .build/checkouts/AMSMB2/Dependencies/libsmb2/lib/libsmb2.c ]] || swift package resolve
test -f .build/checkouts/AMSMB2/Dependencies/libsmb2/lib/libsmb2.c
tar --exclude='.git' --exclude='.build' --exclude='*.o' -czf "$third_party" -C .build/checkouts AMSMB2
shasum -a 256 "$sources" "$third_party" > "build/Syncophant-$version-sources.sha256"
echo "Packaged $PWD/$dmg and $PWD/$archive ($kind). Corresponding sources and checksums are in build/."
