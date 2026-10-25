#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .deps/bin
destination="$PWD/.deps/bin/syncophant-crypt"
(
  cd scripts/crypt-helper
  CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$destination" .
)
chmod 755 "$destination"
