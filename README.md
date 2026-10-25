# Syncophant

A native Mac app for your own storage. Connect Hetzner, SFTP, WebDAV, S3-compatible or SMB storage, browse it from a menu bar app, and add it to Finder through a Replicated File Provider extension.

**Early development build.** This repository implements working storage, UI and Finder integration code. It has not passed the product plan's real Hetzner, signed File Provider, multi-Mac or performance release gates. Keep another copy of important files. See [implementation status](docs/STATUS.md) for the remaining work.

- App ID: `app.syncophant.mac`
- Website: <https://syncophant.app>
- Repository: <https://github.com/syncophant-app/macos>
- App: GPL-3.0-or-later. Reusable CoreKit and HetznerKit: MIT.

## Build and run

Requires macOS 26+, Xcode with the macOS 26 SDK or newer, Go, CMake, pkg-config, and Ruby with the `xcodeproj` gem. On a development machine:

```sh
brew install go cmake pkg-config ruby
gem install xcodeproj --no-document
bash scripts/bootstrap.sh
bash scripts/build.sh
open build/DerivedData/Build/Products/Debug/Syncophant.app
```

Bootstrap downloads checksum-pinned libssh2 1.11.1 and OpenSSL 3.5.9 sources, builds static libraries for the host architecture with a macOS 26 deployment target, and keeps them in `.deps/`. The app does not depend on Homebrew libraries at runtime.

For a safe local tour with explicitly labeled sample files and no storage connections:

```sh
open -n build/DerivedData/Build/Products/Debug/Syncophant.app --args --demo
```

The default build is ad-hoc signed for local UI testing. Finder activation requires matching signed app/extension provisioning for `app.syncophant.mac`, `app.syncophant.mac.provider`, app group `group.app.syncophant.mac`, and the shared Keychain group. Open `Syncophant.xcodeproj`, choose your Apple Developer team and configure both targets. `SYNCOPHANT_TEAM_ID` can pass a configured team to `scripts/build.sh`; it does not create identifiers or provisioning profiles. Nothing is uploaded, notarized or published by the build script.

`ruby scripts/generate-project.rb` regenerates the Xcode project after source additions. CoreKit and HetznerKit are also Swift Package Manager library products.

## Use

Add storage from the sidebar or menu bar. Hetzner setup accepts an API token, lists your actual boxes, and can create a subaccount for an explicit relative folder (`Syncophant` by default). Choose the main account for the whole box. New subaccount DNS may need time to propagate; retry the host-key step without restarting setup. SFTP supports passwords, private keys and agents, with passive SSH-config import. Approve the fingerprint after comparing it independently; changed keys are rejected before authentication. Credentials are saved only in Keychain.

The SSH endpoint must support SFTP and `sha256sum` execution. Hetzner normally provides this on port 23. Servers without checksum execution fail closed rather than claiming verified uploads. A server-side subaccount/chroot is the boundary against concurrent malicious remote symlink changes.

Upload from the toolbar, menu bar, or file drop target. Uploads verify SHA256 before and after publication and preserve conflicts. S3 uses conditional copy/replacement with retained backups, not atomic rename; its rename/trash actions are disabled. Cancel preserves the source; pause stops at chunk boundaries. The queue persists across restarts and verifies resume prefixes. Auto, 20 MB/s and unlimited modes are available. Supported deletion moves items to recoverable remote trash.

The browser uses an AppKit outline view and cached SQLite metadata. Search finds cached entries. Finder provides dataless files, aligned ranges, native thumbnails for supported files up to 32 MiB and pin/evict. Cache defaults to 5 GB per domain and retains unsafe-to-evict data. Hetzner snapshot restore-copy requires server permissions. Backups are add-only; schedules run while the app runs. Optional encryption uses rclone crypt with a bundled native helper; Go/rclone are unnecessary at runtime. See [protocol requirements](docs/STORAGE_PROTOCOLS.md).

## Privacy

No analytics, account service, crash uploads or project-owned server. The app contacts configured storage; Hetzner's API only when you supply a token and use its features; GitHub only for an explicit update check or if you enable daily checks. Automatic update checks default off. Settings → Privacy shows a local shared activity ledger for the app and extension. Streaming activity updates the ledger at most once per minute. Diagnostics are exported locally, with host and username redaction.

## Verification

```sh
bash scripts/test.sh
bash scripts/integration/sftp.sh
bash scripts/build.sh
CONFIGURATION=Release bash scripts/build.sh
```

Tests cover the API client, path confinement, metadata identity, conflict preservation, cancellation, verified upload evidence, and File Provider journal/range calculations. The SFTP integration script creates an ephemeral loopback-only OpenSSH server and keys, tests actual libssh2 operations, and removes its fixture on exit. It does not change system SSH settings or contact external storage.

Source architecture and product acceptance targets are in [the supplied plan](docs/PRODUCT_PLAN.md). Library contracts are in [CoreKit](Sources/CoreKit/README.md).
