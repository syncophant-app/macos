# CoreKit

MIT reusable storage layer for macOS 26+, Swift 6. Imports Foundation, CryptoKit,
Darwin, SQLite and libssh2; no app or File Provider frameworks. `CSQLite` and
`CLibSSH2` are system-library modules; the containing build owns library versions,
OpenSSL 3 linkage, packaging and signing.

## Public contract

`StorageProvider` (`hetzner`, `sftp`, `webdav`, `s3`, `smb`, and the OAuth cloud drives `dropbox`, `onedrive`, `box`, `googledrive`), `StorageConnection`, `RemoteEntry`,
`StoredItem`, `UploadReceipt` and `RemoteStore` follow `docs/INTEGRATION.md`.
All public model initializers are available outside the module. Connections contain
no credentials. `RemoteEntry.contentHash: String?` is optional SHA256 evidence.
`remoteRevision` carries filesystem identity, size and nanosecond modification/change
times when available. A revision-backed `version` stays unchanged when checksum
evidence is attached. `contentHash` means an actual SHA256 calculation only.
Local listings/stat use descriptor-relative high-resolution metadata. SFTP probes
GNU/BSD `stat` formats and batches up to 16 regular files per listing command;
unsupported or coarse formats fall back to hashing on `stat`, rather than listing.

All paths passed to stores are **virtual paths relative to the configured root**:
`/folder/file` means `root/folder/file`, regardless of the host filesystem path.
Relative input is accepted and canonicalized to `/...`. Traversal components,
control characters, backslashes, oversized components and paths are rejected.
`/` can be listed/stat'ed but cannot be moved, removed or uploaded to.

`RemoteStore` has async throwing `list`, `stat`, `read`, `write`,
`createDirectory`, `move`, `remove`, and `checksum`. Byte offsets are nonnegative;
each read/write is bounded to 16 MiB. Reads stop at EOF, writes preserve bytes
outside the given range and create a missing file (without truncation).
`stat` returns a high-resolution revision or SHA256-backed regular-file version.
Reads and checksums validate observed revisions before returning. SFTP keeps one
bounded 4 MiB warm range window, including version checks on cache hits; larger
reads bypass it. `move` is an atomic **no-clobber** rename: destination replacement is forbidden.
`remove` handles files and empty directories; it refuses nonempty directories.
Listings omit temporary files, symlinks and nonregular filesystem objects.
Direct store writes can create temporary names for transfer staging.

### Stores and SSH trust

```swift
let local = try LocalRemoteStore(root: directoryURL)
let fingerprint = try await SFTPStore.probeHostKey(host: host, port: 22)
// Present the fingerprint for explicit approval, then persist that approved value.
let remote = SFTPStore(connection: pinnedConnection, password: password,
                       privateKey: nil)
```

`LocalRemoteStore` is for deterministic tests and explicit developer demos. It
anchors operations to an open root descriptor, walks parent directories with
`openat(O_NOFOLLOW)`, refuses symlink targets, uses descriptor-relative filesystem
operations and publishes with `renameatx_np(RENAME_EXCL)`.

`SFTPStore` is a Swift actor owning one libssh2 session. Its initializer accepts
`connection`, `password: String?`, `privateKey: String?` and optional `passphrase`.
`privateKey` means **private-key contents**, not a filename; if supplied, it takes
precedence over password auth. Secrets remain in memory; callers own Keychain
storage. `disconnect()` releases the session; the next operation reconnects.

Authentication also supports explicit SSH agent sockets, including agent signing
callbacks. Shared callers provide a session-budget directory: six file-locked
slots per host cover both app and extension processes. Generated Mac keys and
credential envelopes are owned by PlatformShared, outside CoreKit.

The probe performs SSH key exchange only, without authenticating. Operations
require an exact OpenSSH `SHA256:<base64-without-padding>` pin and compare it
**before any authentication**. Missing/mismatched pins fail closed. Probing is
never implicit approval. Private-key auth uses libssh2's memory API; password auth
uses the SSH encrypted transport after pin verification.

SFTP v3 supplies no immutable snapshot. Trusted-server revision/checksum checkpoints
detect observed mutations but cannot defeat every uncooperative filesystem race;
a server-side chroot remains the hard confinement boundary.

`RemoteTrash` records original paths and deletion dates remotely, restores with
no-clobber moves, and expires recorded deletions after 30 days. Older unrecorded
trash is restorable at the root and never expires automatically. Interrupted
namespace mutations retain their durable fence until an explicit recovery review;
the app disconnects Finder and backs up cached metadata before acknowledgement.
Verified receipts are persisted in the metadata database and decorations are
valid only while the current remote version matches that receipt.

DNS/TCP connection attempts have a 15-second total caller deadline, key exchange
and authentication/setup each have a 15-second deadline, and connected operations
have a 30-second total deadline. Nonblocking libssh2 EAGAIN retries wait on socket
directions and check cancellation at most every 100 ms while waiting. macOS's
uncancellable system DNS resolver may finish on its utility thread after the
caller times out. Timeout/cancellation discards incomplete SSH state. No network
retry silently repeats a mutating request.

SFTP resolves the configured root once and rejects observed symlinks in every
root/path component before operations. **SFTP v3 has no descriptor-relative
`openat`/`O_NOFOLLOW` equivalent**: a concurrent remote actor replacing a directory
with a symlink between validation and operation cannot be excluded by this client.
Use a server-side chroot/subaccount for a hard remote security boundary. The local
test backend uses descriptor-relative operations and does not have this path-walk
race. All server operations assume a conforming SFTP server.

`checksum` executes `sha256sum -- '<safely quoted full path>'` over a separate SSH
channel in the authenticated session. Stdout/stderr are drained with a 64 KiB
combined cap, exit status is checked and exactly a valid 64-hex digest is required.
The configured SSH port must support exec (Hetzner normally port 23). There is no
unverified fallback if the command is unavailable.
Regular-file `stat` also requires this command and can cost a full server-side file
read. Listings never hash every file. SFTP provides neither a snapshot read nor
strong mutation counters: an uncooperative writer changing content while preserving
mtime/size can race hashing. Evidence describes the observed checksum checkpoint,
not a promise that a file cannot change after the call.

### Metadata

`MetadataStore(url:)` owns a SQLite connection with WAL, `synchronous=FULL`, a
5-second busy timeout, indexed parent lookup, and FTS5 filename/path search where
available (literal path search otherwise). Search returns at most 500 results;
an empty query returns `[]`. Search text is quoted, not executed as FTS syntax.

`reconcile(_:parentPath:)` accepts a **complete direct-child listing**, validates
the full input before changing anything, filters temporary entries, preserves UUIDs
and pins at unchanged paths, and removes stale subtrees in one transaction.
`item(id:)`, `items(parentPath:)` and `search(_:)` return `StoredItem`s.
`move(id:to:)` transactionally updates the selected path and all descendant paths
while preserving every UUID/pin and rejecting destination collisions. Call it
after an application-controlled remote rename and before reconciling that new
listing. Out-of-band server renames cannot reliably be identified from SFTP
mtime/size metadata and are treated as delete/create. `setPinned(id:_:)` persists
pin state; the caller implements caching/download policy.

Integration must persist/restore optional `contentHash` with metadata for strong
version checks. Nil hashes in listings/older metadata are not verification
evidence; fetch a fresh `stat` before checks requiring content identity. The
metadata schema's hash persistence is being integrated by the root owner.

### Verified transfers and progress

```swift
let receipt = try await TransferEngine(store: remote).upload(
    localURL: fileURL,
    remotePath: "/Documents/report.pdf",
    expectedVersion: previousVersion,
    progress: { event in
        // @Sendable synchronous callback; hop to MainActor to update UI.
        switch event {
        case .uploading(let completed, let total): break
        case .verifying: break
        case .verified(let receipt): break
        }
    }
)
```

Exact signature:

```swift
public func upload(
    localURL: URL,
    remotePath: String,
    expectedVersion: String? = nil,
    resumeID: UUID? = nil,
    progress: (@Sendable (UploadProgress) -> Void)? = nil
) async throws -> UploadReceipt

public enum UploadProgress: Sendable, Equatable {
    case uploading(completed: Int64, total: Int64)
    case verifying
    case verified(UploadReceipt)
}
```

The nil default preserves existing call sites. Uploading starts at zero and
increments only after each 1 MiB chunk's store write completes; total is the source
file's initial byte size. `.verifying` starts before remote hashing. `.verified`
is emitted **only after checksum comparison, successful publication, and a fresh
strong stat confirming the destination still has the uploaded digest/size**, and its
receipt is the returned receipt. Callback delivery is synchronous on the transfer
task, not MainActor. It must be fast and thread safe. Errors/cancellation are
reported by the thrown error, never as invented successful progress. Source-file
size/mtime/ctime changes invalidate the upload.

`UploadReceipt.remoteVersion: String` is the **actual published strong version**,
and `checksum` is the uploaded content digest. Retain that pair from the receipt.
After a directory reload, never assign the old checksum to the reloaded entry's
version. Compare a fresh regular-file `stat`'s version with `receipt.remoteVersion`
and require its `contentHash == receipt.checksum` before showing that the observed
current content matches. A listing with nil `contentHash` provides no such proof.
Subsequent replacement cannot inherit verification merely by preserving mtime and
size. If replacement is detected during publication confirmation, upload throws
`CoreKitError.itemChanged(path)` without emitting `.verified`; the path may have
been published and then changed, so the error does not claim nothing was written.

Uploads stream from the source descriptor to a UUID-named hidden partial in the
destination directory, compute incremental SHA256, require matching server SHA256
and size, then publish through no-clobber rename. Zero-byte files follow the same
verification. The local source is never removed. A failed/cancelled transfer
attempts cleanup in an uncancelled task; unreachable servers may leave hidden
partials. With a stable `resumeID`, connection/timeouts retain the partial and retries
verify the local prefix against its remote SHA256 before continuing. Corrupt or
oversized partials are removed and rejected; retry starts fresh. Explicit cancellation
cleans the owned partial. Duplicate active resume IDs are rejected within an engine.
Automatic orphan deletion is not implemented.

If the destination exists without a matching expected version, the incoming file
is published under a visible `name (conflict UUID).ext` path. If the expected
version matches, the previous file is first moved to a conflict name, then the new
file is published at the requested path. **The previous copy is retained even on
matching updates**: SFTP has no atomic version-conditional replacement. Failed
publication attempts restore the previous file only into a free original name;
an intervening writer is never replaced. Consequently matching updates have a
brief gap at the original path, and a process crash during that gap may leave the
previous copy under its conflict name. Data is retained, not silently discarded.
The returned `remotePath` is authoritative and can differ from the requested path.

## Helpers and limitations

`PathRules.normalize`, `parent(of:)`, `name(of:)`, `isTemporary`,
`isVisible(path:)`, and `displayNames(for:)` are public. Display collision mapping
suffixes case-insensitive duplicate names without changing server paths/IDs.
`maximumReadLength` is 16 MiB. `CoreKitError` is Sendable, Equatable and
LocalizedError and distinguishes missing items, existing destinations, invalid or
unsafe paths, authentication/trust, timeout, checksum/source changes, database and
transport failures. Error text never includes credential contents.

The engine supports `setPaused(_:)` and `setBandwidthLimit(bytesPerSecond:)`, using
a monotonic aggregate budget across uploads in the same engine. Changes take effect
at chunk boundaries; nil means unlimited. Latency-adaptive Auto mode is not implemented.
Pass the shared metadata store to `TransferEngine(store:metadata:)` to fence publication
against cross-process refresh. The app persists its queue and resume IDs. File Provider
owns Finder hydration and pinning. A provider-wide connection broker, parallel SFTP
pipelining and a dedicated chunk cache are not implemented. Performance budgets and
real Hetzner SSH behavior require separate integration/hardware measurements.

## Tests

`swift test --filter CoreKitTests` exercises LocalRemoteStore and deterministic
SQLite cases: range reads/writes, exclusive moves, symlink/traversal confinement,
temporary filtering, case display collisions, checksum mismatch, chunked/empty
uploads, conflicts/matching updates, concurrent publication, cancellation cleanup,
maximum-length names, honest progress, stable subtree UUIDs/pins, persistence,
FTS search, transactional validation, missing-pin rejection before networking,
same-mtime/same-size replacement identity, and rejection of publication-time
replacement without verified progress.
These tests do not authenticate to an external SSH server.
