#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
proof_dir="$(mktemp -d /tmp/syncophant-crypt-proof.XXXXXX)"
trap 'rm -rf "$proof_dir"' EXIT
mkdir -p "$proof_dir/remote" .build
export SYNCOPHANT_CRYPT_PROOF="$proof_dir"
export SYNCOPHANT_CRYPT_HELPER="$PWD/.build/syncophant-crypt"
export SYNCOPHANT_CRYPT_STREAM_BYTES="${SYNCOPHANT_CRYPT_STREAM_BYTES:-8388645}"
(
  cd scripts/crypt-helper
  go build -trimpath -o "$SYNCOPHANT_CRYPT_HELPER" .
)
swiftc -O -swift-version 6 -target "$(uname -m)-apple-macosx26.0" \
  Sources/CoreKit/Models.swift Sources/CoreKit/PathRules.swift Sources/CoreKit/LocalUploadSource.swift Sources/CoreKit/LocalRemoteStore.swift \
  Sources/CoreKit/CryptBridge.swift Sources/CoreKit/CryptStore.swift \
  scripts/integration/crypt-check.swift -o .build/crypt-integration-check
.build/crypt-integration-check
python3 - <<'PY'
import hashlib, os, subprocess
from pathlib import Path

proof = Path(os.environ['SYNCOPHANT_CRYPT_PROOF'])
rclone = '/usr/local/bin/rclone'
assert subprocess.check_output([rclone, 'version']).splitlines()[0] == b'rclone v1.72.1'
# Public fixture values only; stdin/env keep even these out of argv and config files.
def obscure(value):
    return subprocess.check_output([rclone, 'obscure', '-'], input=value.encode()).decode().strip()
env = dict(os.environ, RCLONE_CONFIG_PROOF_TYPE='crypt', RCLONE_CONFIG_PROOF_REMOTE=str(proof/'remote'),
           RCLONE_CONFIG_PROOF_PASSWORD=obscure('syncophant-public-fixture-password'),
           RCLONE_CONFIG_PROOF_PASSWORD2=obscure('syncophant-public-fixture-salt'),
           RCLONE_CONFIG_PROOF_FILENAME_ENCRYPTION='standard', RCLONE_CONFIG_PROOF_DIRECTORY_NAME_ENCRYPTION='true')
command = [rclone, '--config', '/dev/null', '--log-level', 'ERROR']
reader = subprocess.Popen(command + ['cat', 'proof:Archive/interop.bin'], stdout=subprocess.PIPE, env=env)
digest, count = hashlib.sha256(), 0
while True:
    chunk = reader.stdout.read(1024*1024)
    if not chunk:
        break
    digest.update(chunk)
    count += len(chunk)
assert reader.wait() == 0
assert count == int(os.environ['SYNCOPHANT_CRYPT_STREAM_BYTES'])
assert digest.hexdigest() == (proof/'sha256').read_text()
print('CryptStore -> independent rclone content and filename decryption passed.')
writer = subprocess.Popen(command + ['rcat', 'proof:Archive/rclone-write.bin'], stdin=subprocess.PIPE, env=env)
chunk = bytes(index % 251 for index in range(1024*1024))
remaining = count
while remaining:
    piece = chunk[:min(len(chunk), remaining)]
    writer.stdin.write(piece)
    remaining -= len(piece)
writer.stdin.close()
assert writer.wait() == 0
PY
SYNCOPHANT_CRYPT_PHASE=verify .build/crypt-integration-check
if [[ "${SYNCOPHANT_CRYPT_SKIP_TESTS:-0}" != 1 ]]; then
  export PKG_CONFIG_PATH="$PWD/.deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  swift test --filter crypt
fi
