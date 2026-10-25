#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
kind=dev
if [[ "${SYNCOPHANT_DISTRIBUTION:-0}" == 1 ]]; then
  [[ -n "${SYNCOPHANT_TEAM_ID:-}" ]] || { echo 'Developer ID packaging requires SYNCOPHANT_TEAM_ID.' >&2; exit 1; }
  kind=signed-not-notarized
fi
CONFIGURATION=Release bash scripts/build.sh
app="${SYNCOPHANT_DERIVED_DATA:-build/DerivedData}/Build/Products/Release/Syncophant.app"
codesign --verify --deep --strict "$app"
if [[ "$kind" == signed-not-notarized ]]; then
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
archive="build/Syncophant-$version-$(uname -m)-$kind.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
sources="build/Syncophant-$version-source.tar.gz"
tar --exclude='.DS_Store' --exclude='.git' -czf "$sources" \
  Package.swift Package.resolved Sources Tests scripts Config Assets LICENSE README.md DESIGN.md docs .github
third_party="build/AMSMB2-4.0.3-source.tar.gz"
test -f .build/checkouts/AMSMB2/Dependencies/libsmb2/lib/libsmb2.c
tar --exclude='.git' --exclude='.build' --exclude='*.o' -czf "$third_party" -C .build/checkouts AMSMB2
shasum -a 256 "$sources" "$third_party" > "build/Syncophant-$version-sources.sha256"
echo "Packaged $PWD/$archive (not notarized). Corresponding sources and checksums are in build/."
