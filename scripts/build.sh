#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .deps/.libssh2-1.11.1-openssl359 ]] || bash scripts/bootstrap.sh
export PKG_CONFIG_PATH="$PWD/.deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
bash scripts/build-crypt-helper.sh
build_root="${SYNCOPHANT_DERIVED_DATA:-build/DerivedData}"
if [[ -n "${SYNCOPHANT_TEAM_ID:-}" ]]; then
  signing_identity="${SYNCOPHANT_SIGNING_IDENTITY:-Apple Development}"
  if [[ "${SYNCOPHANT_DISTRIBUTION:-0}" == 1 ]]; then signing_identity="${SYNCOPHANT_SIGNING_IDENTITY:-Developer ID Application}"; fi
  codesign --force --sign "$signing_identity" --options runtime --timestamp .deps/bin/syncophant-crypt
fi
ruby scripts/generate-project.rb
signing_args=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${SYNCOPHANT_TEAM_ID:-}" ]]; then
  signing_args=("DEVELOPMENT_TEAM=$SYNCOPHANT_TEAM_ID")
fi
xcodebuild -project Syncophant.xcodeproj -scheme Syncophant -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath "$build_root" "ARCHS=$(uname -m)" ONLY_ACTIVE_ARCH=YES "${signing_args[@]}" build
app="$build_root/Build/Products/${CONFIGURATION:-Debug}/Syncophant.app"
if [[ -n "${SYNCOPHANT_TEAM_ID:-}" ]]; then
  SYNCOPHANT_SIGNING_IDENTITY="$signing_identity" bash scripts/sign.sh "$app"
else
  bash scripts/sign.sh "$app"
fi
echo "Built $PWD/$app"
