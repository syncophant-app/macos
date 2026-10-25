#!/bin/bash
set -euo pipefail
app="${1:?App bundle path is required}"
identity="${SYNCOPHANT_SIGNING_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then sign_args+=(--options runtime --timestamp); fi

sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
  codesign "${sign_args[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
  codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  codesign "${sign_args[@]}" "$sparkle/Versions/B/Autoupdate"
  codesign "${sign_args[@]}" "$sparkle/Versions/B/Updater.app"
  codesign "${sign_args[@]}" "$sparkle"
fi
for framework in "$app"/Contents/Frameworks/AMSMB2.framework "$app"/Contents/PlugIns/SyncophantProvider.appex/Contents/Frameworks/AMSMB2.framework; do
  [[ ! -d "$framework" ]] || codesign "${sign_args[@]}" "$framework"
done
codesign "${sign_args[@]}" "$app/Contents/Resources/syncophant-crypt"
codesign "${sign_args[@]}" "$app/Contents/PlugIns/SyncophantProvider.appex/Contents/Resources/syncophant-crypt"
codesign "${sign_args[@]}" --identifier app.syncophant.mac.agent-rendezvous "$app/Contents/MacOS/SyncophantAgentRendezvous"
codesign "${sign_args[@]}" --preserve-metadata=entitlements,identifier "$app/Contents/PlugIns/SyncophantProvider.appex"
codesign "${sign_args[@]}" --preserve-metadata=entitlements,identifier "$app"
codesign --verify --deep --strict "$app"
