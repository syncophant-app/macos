# Architecture and integration

CoreKit owns storage models, RemoteStore drivers, verified transfers and SQLite WAL metadata. HetznerKit owns explicit API operations. Both are MIT Swift Package products without UI or File Provider imports. The application and File Provider adapter are GPL-3.0-or-later.

The native SwiftUI shell and AppKit outline browser live in Sources/SyncophantApp. Sources/FileProviderExtension contains the extension-owned engine adapter, enumeration, change journal, hydration and cache enforcement. Sources/PlatformShared is compiled into both targets and owns app-group configuration, Keychain, local contact history and cache policy/status.

The app uses Swift 6 language mode. The Objective-C File Provider callback adapter currently uses Swift 5 language mode with the Swift 6 compiler; its remaining SDK concurrency warnings are not a completed Swift 6 migration.

## Paths and verification

Store paths are virtual paths relative to StorageConnection.rootPath. The browser root is always /; passing the configured remote root again would double-prefix it. Connection JSON contains no credentials.

`RemoteEntry.remoteRevision` carries optional opaque revision evidence. Local list/stat uses exact inode/ctime/mtime evidence; SFTP listings batch high-resolution GNU/BSD stat, with hash fallback when unsupported. HTTP stat uses metadata and strong ETags without downloading content. Refresh uses listing revisions where present. `contentHash` is actual SHA256 evidence; attaching it does not change a revision-backed identity. The bounded SFTP read window validates before and after returning bytes, including cache hits.

Hetzner API homes are relative to the main account. Port-23 SFTP exposes each account at `/home`, which becomes virtual `/` in the browser. `StorageBoxPath` validates setup paths and maps shares back to the main-account namespace; the transport's `/home` prefix must never be added to an API home directory.

UploadReceipt.remotePath is authoritative and may be a conflict-copy path. Its remoteVersion and checksum bind the verified claim to the observed content. A later listing must never transfer that claim to a different version at the same path. See [CoreKit API](../Sources/CoreKit/README.md).

## Metadata ownership

- refresh(store:path:) captures a durable revision, lists and enriches missing revisions, and reconciles only if no intervening mutation invalidated the result.
- snapshot() obtains revision and stored items from one SQL statement. Callback items, journal changes and returned anchors derive from that same snapshot without another await.
- move(store:id:to:trash:) coordinates remote moves with UUID/subtree updates across independent app/extension SQLite connections.
- withPublication fences the brief old-file/backup/new-file publication sequence. Publishers wait asynchronously without holding SQLite transactions across network calls. Confirmed settled failures release their fence; ambiguous remote mutations retain it for recovery.
- Explicit local moves preserve UUIDs and descendants. During overwrite the UUID stays at the requested path; a backup receives a new UUID on refresh. Arbitrary external SFTP renames cannot be identified reliably from paths alone.

Pin changes affect metadata versions and the change journal without changing content versions. Folder pins use downloadEagerlyAndKeepDownloaded; child policy is inherited. Observers share one poll per folder, released when the final observer invalidates.

## Transfers and cache

The app caches one transfer engine per connection, passes shared metadata, and persists job UUIDs/source URLs. Job UUIDs identify resumable partials; retries compare the local prefix with remote SHA256. Pause and aggregate speed limits apply at chunk boundaries.

The extension handles password/private-key Finder I/O when the app is closed. Delegated agent signing requires the running app; the rendezvous helper holds only its anonymous XPC endpoint. App transfers and backup schedules resume when the app next runs. Cache enforcement measures allocated bytes without reading content and retains pinned, pending, dirty or ambiguous items.

Store capabilities determine publication. S3 conditionally copies while retaining its source; matching replacement first verifies a backup and uses the exact target ETag. Successful publication is checked with stat, actual SHA256, then stat. HTTP/encrypted uploads privately stage bounded chunks before finish; resume covers completed remote checkpoints. See [driver limitations](STORAGE_PROTOCOLS.md).

BackupEngine opens its source through descriptor-confined LocalRemoteStore before awaiting remote work. TransferEngine duplicates that descriptor and uses logical-offset reads without reopening an absolute path.

## Shared configuration

Bundle IDs: app.syncophant.mac and app.syncophant.mac.provider. Both use group.app.syncophant.mac and a team-prefixed shared Keychain group. Unsigned UI builds fall back to Application Support and their default Keychain; this does not prove signed extension credential sharing.

Contact history stays local and is shared between processes. Streaming activity updates it at most once per minute. Optional GitHub checks default off. The explicit demo uses temporary local storage and bypasses shared configuration, Keychain and network operations.

See [status and release gates](STATUS.md) for verification boundaries and remaining 1.0 work.
