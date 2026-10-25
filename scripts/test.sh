#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/http-fixture-self-check.py
[[ -f .deps/.libssh2-1.11.1-openssl359 ]] || bash scripts/bootstrap.sh
export PKG_CONFIG_PATH="$PWD/.deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
bash scripts/build-crypt-helper.sh
export SYNCOPHANT_CRYPT_HELPER="$PWD/.deps/bin/syncophant-crypt"
swift test "$@"
core_objects=(.build/debug/CoreKit.o)
if [[ ! -f "${core_objects[0]}" ]]; then
  core_objects=(.build/debug/CoreKit.build/*.o)
fi
dependency_flags=(-I .build/debug/Modules -I .build/checkouts/AMSMB2/Dependencies/libsmb2/include
  -Xcc -fmodule-map-file=.build/checkouts/AMSMB2/Dependencies/libsmb2/include/module.modulemap
  -L .build/debug -lAMSMB2 -Xlinker -rpath -Xlinker "$PWD/.build/debug")
swiftc Sources/FileProviderExtension/ProviderJournal.swift scripts/provider-self-check.swift -o .build/provider-self-check
.build/provider-self-check
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
  -I .build/debug -I Sources/CSQLite -I Sources/CLibSSH2 -I .deps/include \
  "${dependency_flags[@]}" -L .deps/lib -lssh2 -lssl -lcrypto -lz -lsqlite3 "${core_objects[@]}" \
  Sources/PlatformShared/*.swift Sources/FileProviderExtension/CacheBudget.swift \
  scripts/cache-self-check.swift -o .build/cache-self-check
.build/cache-self-check
swiftc -swift-version 6 -target "$(uname -m)-apple-macos26.0" \
  -I .build/debug -I Sources/CSQLite -I Sources/CLibSSH2 -I .deps/include \
  "${dependency_flags[@]}" -L .deps/lib -lssh2 -lssl -lcrypto -lz -lsqlite3 "${core_objects[@]}" \
  Sources/SyncophantApp/Models.swift Sources/SyncophantApp/Theme.swift Sources/SyncophantApp/StatusKit.swift \
  scripts/app-state-self-check.swift -o .build/app-state-self-check
.build/app-state-self-check
swiftc -swift-version 6 -target "$(uname -m)-apple-macos26.0" \
  Sources/SyncophantApp/MenuBarIcon.swift scripts/menu-bar-icon-self-check.swift -o .build/menu-bar-icon-self-check
.build/menu-bar-icon-self-check
swiftc -swift-version 6 -target "$(uname -m)-apple-macos26.0" \
  -I .build/debug -I Sources/CSQLite -I Sources/CLibSSH2 -I .deps/include \
  "${dependency_flags[@]}" -L .deps/lib -lssh2 -lssl -lcrypto -lz -lsqlite3 "${core_objects[@]}" \
  Sources/PlatformShared/*.swift scripts/ssh-credentials-self-check.swift -o .build/ssh-credentials-self-check
.build/ssh-credentials-self-check
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -application-extension \
  -I .build/debug -I Sources/CSQLite -I Sources/CLibSSH2 -I .deps/include \
  "${dependency_flags[@]}" -L .deps/lib -lssh2 -lssl -lcrypto -lz -lsqlite3 "${core_objects[@]}" \
  Sources/PlatformShared/*.swift Sources/FileProviderExtension/*.swift Sources/SyncophantApp/DriveManager.swift \
  scripts/finder-self-check.swift -o .build/finder-self-check
.build/finder-self-check
if [[ "${SYNCOPHANT_PROVIDER_LIFECYCLE_CHECK:-0}" == 1 ]]; then
  swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -D PROVIDER_RUNTIME_CHECK \
    -I .build/debug -I Sources/CSQLite -I Sources/CLibSSH2 -I .deps/include \
    "${dependency_flags[@]}" -L .deps/lib -lssh2 -lssl -lcrypto -lz -lsqlite3 "${core_objects[@]}" \
    Sources/PlatformShared/*.swift Sources/FileProviderExtension/*.swift \
    Tests/CoreKitTests/MetadataConcurrencyTests.swift -o .build/provider-runtime-check
  .build/provider-runtime-check
fi
