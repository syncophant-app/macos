#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -f .deps/.libssh2-1.11.1-openssl359 ]] || bash scripts/bootstrap.sh
proof_dir="$(mktemp -d /tmp/syncophant-sftp.XXXXXX)"
server_pid=''
agent_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$agent_pid" ]]; then kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true; fi
  rm -rf "$proof_dir"
}
trap cleanup EXIT
mkdir -p "$proof_dir/remote" "$proof_dir/bin" "$proof_dir/home/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$proof_dir/host"
ssh-keygen -q -t ed25519 -N '' -f "$proof_dir/client"
cp "$proof_dir/client.pub" "$proof_dir/home/.ssh/authorized_keys"
export SYNCOPHANT_TEST_AGENT_SOCKET="$proof_dir/agent.sock"
/usr/bin/ssh-agent -D -a "$SYNCOPHANT_TEST_AGENT_SOCKET" > "$proof_dir/agent.log" 2>&1 &
agent_pid=$!
for attempt in {1..50}; do
  [[ -S "$SYNCOPHANT_TEST_AGENT_SOCKET" ]] && break
  sleep 0.1
done
SSH_AUTH_SOCK="$SYNCOPHANT_TEST_AGENT_SOCKET" /usr/bin/ssh-add "$proof_dir/client" < /dev/null
export SYNCOPHANT_TEST_PROOF="$proof_dir"
export SYNCOPHANT_TEST_GSTAT="$(command -v gstat || true)"
printf '#!/bin/sh\nSYNCOPHANT_TEST_PROOF="%s"\n' "$proof_dir" > "$proof_dir/bin/sha256sum"
cat >> "$proof_dir/bin/sha256sum" <<'EOF'
printf 'checksum\n' >> "$SYNCOPHANT_TEST_PROOF/checksums"
exec /usr/bin/shasum -a 256 "$@"
EOF
printf '#!/bin/sh\nSYNCOPHANT_TEST_PROOF="%s"\nSYNCOPHANT_TEST_GSTAT="%s"\n' "$proof_dir" "$SYNCOPHANT_TEST_GSTAT" > "$proof_dir/bin/stat"
cat >> "$proof_dir/bin/stat" <<'EOF'
printf 'stat\n' >> "$SYNCOPHANT_TEST_PROOF/stats"
case "$(cat "$SYNCOPHANT_TEST_PROOF/stat-mode")" in
  bsd) exec /usr/bin/stat "$@" ;;
  gnu) exec "$SYNCOPHANT_TEST_GSTAT" "$@" ;;
  fallback) exit 127 ;;
esac
EOF
chmod 700 "$proof_dir/bin/sha256sum" "$proof_dir/bin/stat"
# Give every command an isolated HOME, including the real generic key-install path.
printf '#!/bin/sh\nproof="%s"\nexport HOME="%s/home"\nexport PATH="%s/bin:/usr/bin:/bin:/usr/sbin:/sbin"\n' "$proof_dir" "$proof_dir" "$proof_dir" > "$proof_dir/command"
cat >> "$proof_dir/command" <<'EOF'
# Deterministically mutate between a read's two revision/checksum checkpoints.
if [ -f "$proof/read-race" ]; then
  case "$SSH_ORIGINAL_COMMAND" in
    *race.bin*)
      count=$(cat "$proof/read-race")
      count=$((count + 1))
      printf '%s' "$count" > "$proof/read-race"
      if [ "$count" -eq 2 ]; then /usr/bin/python3 "$proof/mutate.py" "$proof/remote/race.bin" || exit 1; fi
      ;;
  esac
fi
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
EOF
cat > "$proof_dir/mutate.py" <<'EOF'
import os, sys
path = sys.argv[1]
before = os.stat(path)
with open(path, 'r+b') as file:
    file.write(b'other')
os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
EOF
chmod 700 "$proof_dir/command"
# Bind only to loopback; no system SSH settings, host keys or authorized_keys are changed.
export SYNCOPHANT_TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export SYNCOPHANT_TEST_ROOT="$proof_dir/remote"
export SYNCOPHANT_TEST_USER="$(id -un)"
export SYNCOPHANT_TEST_KEY="$proof_dir/client"
export SYNCOPHANT_TEST_FINGERPRINT="$(ssh-keygen -lf "$proof_dir/host.pub" -E sha256 | awk '{print $2}')"
cat > "$proof_dir/sshd_config" <<EOF
Port $SYNCOPHANT_TEST_PORT
ListenAddress 127.0.0.1
HostKey $proof_dir/host
PidFile $proof_dir/sshd.pid
AuthorizedKeysFile $proof_dir/home/.ssh/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowUsers $SYNCOPHANT_TEST_USER
SetEnv PATH=$proof_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin
ForceCommand $proof_dir/command
Subsystem sftp /usr/libexec/sftp-server
EOF
/usr/sbin/sshd -D -f "$proof_dir/sshd_config" -E "$proof_dir/sshd.log" &
server_pid=$!
for attempt in {1..50}; do
  if nc -z 127.0.0.1 "$SYNCOPHANT_TEST_PORT"; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$proof_dir/sshd.log" >&2; exit 1; fi
  sleep 0.1
done
mkdir -p .build
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  -I .build/debug -I .build/checkouts/AMSMB2/Dependencies/libsmb2/include \
  -Xcc -fmodule-map-file=.build/checkouts/AMSMB2/Dependencies/libsmb2/include/module.modulemap \
  -I Sources/CLibSSH2 -I Sources/CSQLite -Xcc -I.deps/include -L.deps/lib -lssh2 -lcrypto -lz \
  .build/debug/AMSMB2.o .build/debug/libsmb2.o \
  Sources/CoreKit/*.swift scripts/integration/sftp-check.swift -o .build/sftp-integration-check
for stat_mode in bsd gnu fallback; do
  if [[ "$stat_mode" == gnu && -z "$SYNCOPHANT_TEST_GSTAT" ]]; then
    echo 'GNU stat integration skipped: gstat is not installed.'
    continue
  fi
  printf '%s' "$stat_mode" > "$proof_dir/stat-mode"
  SYNCOPHANT_TEST_STAT_MODE="$stat_mode" .build/sftp-integration-check
done
