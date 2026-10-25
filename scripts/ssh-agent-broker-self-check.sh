#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Uses production identity requirements and disposable fixtures; no credential/config writes or SMAppService enrollment.
signing_identity="${SYNCOPHANT_TEST_SIGNING_IDENTITY:-Developer ID Application: Raja Rajan Ashokan (654ASRW868)}"
proof_dir="$(mktemp -d /tmp/syncophant-agent-xpc.XXXXXX)"
label="app.syncophant.mac.agent-proof.$$"
domain="gui/$(id -u)"
app_pid=''
agent_pid=''
fixture_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$agent_pid" ]]; then kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true; fi
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -rf "$proof_dir"
}
trap cleanup EXIT
# A developer must stop the real broker before running this isolated discovery check.
if launchctl print "$domain/app.syncophant.mac.agent-rendezvous" >/dev/null 2>&1; then
  echo 'Stop the running Syncophant SSH-agent helper before this check.' >&2; exit 1
fi
build_dir="${SYNCOPHANT_TEST_BUILD_DIR:-.build/debug}"
swift_flags=(-swift-version 6 -target "$(uname -m)-apple-macosx26.0"
  -I "$build_dir" -I Sources/CSQLite -I Sources/CLibSSH2 -I .deps/include
  -I .build/checkouts/AMSMB2/Dependencies/libsmb2/include
  -Xcc -fmodule-map-file=.build/checkouts/AMSMB2/Dependencies/libsmb2/include/module.modulemap)
swiftc "${swift_flags[@]}" -parse-as-library -whole-module-optimization -emit-module -emit-object \
  -module-name CoreKit -emit-module-path "$proof_dir/CoreKit.swiftmodule" \
  Sources/CoreKit/*.swift -o "$proof_dir/CoreKit.o"
swiftc -I "$proof_dir" "${swift_flags[@]}" \
  -L .deps/lib -lssh2 -lssl -lcrypto -lz -lsqlite3 \
  "$proof_dir/CoreKit.o" "$build_dir/AMSMB2.o" "$build_dir/libsmb2.o" \
  Sources/PlatformShared/*.swift scripts/ssh-agent-broker-self-check.swift -o "$proof_dir/check"
for role in app provider foreign helper; do
  cp "$proof_dir/check" "$proof_dir/$role"
  case "$role" in
    app) identifier=app.syncophant.mac ;;
    provider) identifier=app.syncophant.mac.provider ;;
    helper) identifier=app.syncophant.mac.agent-rendezvous ;;
    foreign) identifier=app.syncophant.mac.unrelated-proof ;;
  esac
  codesign --force --sign "$signing_identity" --identifier "$identifier" --timestamp=none "$proof_dir/$role"
done
ssh-keygen -q -t ed25519 -N '' -f "$proof_dir/client"
export SYNCOPHANT_TEST_AGENT_SOCKET="$proof_dir/agent.sock"
/usr/bin/ssh-agent -D -a "$SYNCOPHANT_TEST_AGENT_SOCKET" > "$proof_dir/agent.log" 2>&1 &
agent_pid=$!
for attempt in {1..50}; do [[ -S "$SYNCOPHANT_TEST_AGENT_SOCKET" ]] && break; sleep 0.1; done
SSH_AUTH_SOCK="$SYNCOPHANT_TEST_AGENT_SOCKET" ssh-add "$proof_dir/client" < /dev/null
python3 - "$proof_dir/client.pub" "$proof_dir/public-blob" <<'PY'
import base64, pathlib, sys
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(pathlib.Path(sys.argv[1]).read_text().split()[1]))
PY
"$proof_dir/provider" --parser "$proof_dir/public-blob"
for mode in bad-agent timeout; do
  python3 - "$proof_dir/$mode.sock" "$mode" <<'PY' &
import socket, sys, time
with socket.socket(socket.AF_UNIX) as server:
    server.bind(sys.argv[1]); server.listen(1)
    connection, _ = server.accept()
    with connection:
        connection.recv(5)
        if sys.argv[2] == 'bad-agent': connection.sendall(b'\xff\xff\xff\xff')
        else: time.sleep(3)
PY
  fixture_pid=$!
  for attempt in {1..50}; do [[ -S "$proof_dir/$mode.sock" ]] && break; sleep 0.1; done
  "$proof_dir/provider" "--$mode" "$proof_dir/$mode.sock"
  kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fixture_pid=''
done
cat > "$proof_dir/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$proof_dir/helper</string><string>--helper</string></array>
<key>MachServices</key><dict>
<key>group.app.syncophant.mac.ssh-agent.register</key><true/>
<key>group.app.syncophant.mac.ssh-agent.lookup</key><true/>
</dict>
<key>StandardOutPath</key><string>$proof_dir/helper.log</string>
<key>StandardErrorPath</key><string>$proof_dir/helper.log</string>
</dict></plist>
EOF
launchctl bootstrap "$domain" "$proof_dir/agent.plist"
start_app() {
  rm -f "$proof_dir/ready"
  "$proof_dir/app" --app "$proof_dir/ready" > "$proof_dir/app.log" 2>&1 &
  app_pid=$!
  for attempt in {1..100}; do
    [[ -f "$proof_dir/ready" ]] && return
    if ! kill -0 "$app_pid" 2>/dev/null; then cat "$proof_dir/app.log"; return 1; fi
    sleep 0.1
  done
  cat "$proof_dir/app.log"; return 1
}
"$proof_dir/provider" --unavailable
start_app
"$proof_dir/provider" --provider
"$proof_dir/foreign" --foreign
kill "$app_pid"; wait "$app_pid" 2>/dev/null || true; app_pid=''
sleep 0.3
"$proof_dir/provider" --unavailable
start_app
"$proof_dir/provider" --provider
echo 'Signed isolated SSH-agent XPC checks passed: actual signature, peer/role rejection, app death and restart.'
