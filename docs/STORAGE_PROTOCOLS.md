# WebDAV, S3 and SMB integration

CoreKit uses native URLSession for WebDAV/S3 and native NetFS for SMB filesystem
I/O. SMB atomic rename uses AMSMB2 4.0.3 and its pinned libsmb2 source. It does
not use rclone, private Apple APIs, check-then-rename, or a local-path stand-in
for network storage.

## Construction and credentials

```swift
let dav = try WebDAVStore(endpoint: url, username: username, password: password)
let s3 = try S3Store(endpoint: url, bucket: bucket, region: region,
                     accessKey: accessKey, secretKey: secretKey,
                     sessionToken: token, rootPath: root)
let smb = try SMBStore(server: host, share: share, username: username,
                       password: password, rootPath: root)
```

SMB initialization is synchronous; the first async operation mounts privately.
`SMBStore.mount(...) async throws` eagerly connects when needed. Secrets stay in
memory; the caller owns typed Keychain persistence. No credential UI is opened.
WebDAV's endpoint includes its configured root. S3 supports path-style endpoints;
its bucket, region and root prefix are separate fields. All operation paths are
virtual paths under that root and pass PathRules. HTTPS is mandatory, with normal
platform certificate validation. Embedded URL credentials, query/fragment and
traversal are rejected. HTTP redirects are refused before any credentials can be
forwarded. Explicit `allowInsecureLoopback: true` is for local HTTP fixtures only.

SMB requires a server share configured to **require SMB3 encryption and signing**.
The driver checks macOS's `smbutil statshares -m <owned mount> -f JSON` evidence
before exposing the mount: SMB3, ENCRYPTION_REQUIRED and SIGNING_ON must be set.
The second, persistent rename connection explicitly requires SMB3 encryption and
validates the supplied credentials before NetFS can reuse OS authentication.
Older or insecure shares fail closed; Syncophant never edits system SMB settings.
NetFS uses a new authenticated session, no UI, a private canonical mount point and
hidden/noexec/nosuid/nodev soft-mount flags. macOS must allow network volume access
for the signed application/extension. Kernel SMB I/O uses macOS soft-mount timeout
semantics; cancelling a task cannot immediately interrupt a blocked kernel call.

## Revisions, checksums and ranges

HTTP regular-file stat uses HEAD/PROPFIND only. A strong quoted ETag is required;
weak or missing validators fail closed. ETags are opaque revision evidence, **not
SHA256**, including multipart S3 ETags. Listings and stat leave contentHash nil.
Checksum explicitly streams conditional GET into a private temporary file, checks
exact size and coherent before/after metadata, then computes SHA256 in bounded
memory. Range reads require HTTP 206 and exact Content-Range and byte count;
servers that ignore ranges are refused. SMB uses descriptor-confined native I/O
and filesystem revisions plus explicit streamed SHA256.

## Chunked uploads and retry behavior

`prepareUpload(path:)`, chunked `write`, `finishUpload(path:)` is the efficient
upload lifecycle. WebDAV/S3 spool to private 0700/0600 local storage and fsync
each chunk. Opaque encrypted filenames are supported. Finish performs one
conditional upload, preserving an existing object's ETag or creating only when
absent. Files above 64 MiB use S3 multipart uploads, with conditional completion,
bounded-memory part files and abort on failure. HTTP 200 completion bodies are
parsed for embedded errors. No mutating HTTP operation is automatically retried.

Unprepared direct range writes use conditional read/modify/PUT and preserve bytes
outside the range. Callers sending a file in chunks must use the lifecycle above
to avoid repeatedly transferring the existing prefix. Local disk usage is
proportional to the file, with an additional current multipart part. Cancellation
or removal cleans owned staging; an actor's deinit removes its remaining spool.
The engine resumes from the last **completed remote object checkpoint**. In-flight
local chunks/multipart IDs are not a cross-process resume record. A crash can
leave a private local spool or an uncompleted server multipart upload; server-side
multipart lifecycle expiration should be configured. S3 single-object size is
limited to five TiB by this implementation.

## Publication and data preservation

WebDAV file MOVE uses Overwrite:F. Atomic collection MOVE is unavailable, so
supportsDirectoryMove is false. Directory DELETE first obtains an exclusive
depth-infinity lock, checks the complete unfiltered listing, then sends DELETE
with the lock-token precondition. A server without that locking support cannot
safely delete directories through this driver. File deletion uses If-Match.

S3 publicationMode is copyPreservingSource. `publish(from:to:)` snapshots the
source with If-Match GET, checks its size/revision, then creates the destination
with conditional PUT/completion If-None-Match:*. It never deletes the source.
`replace(from:to:expectedVersion:)` checks the fresh target revision and uses its
exact ETag in If-Match PUT/completion. TransferEngine must verify a retained
old-content conflict backup before replacement and verify the new destination
before deleting its owned upload partial. Precondition rejection preserves the
intervening writer. A lost response remains ambiguous and must retain the
publication fence. Source-copy publication downloads and reuploads the object;
this is a bandwidth cost, not a server-side atomic rename. S3 `move` refuses the
operation and supportsDirectoryMove is false. Rename/trash UI must reflect that.

SMB native renameatx_np(RENAME_EXCL) and linkat both returned ENOTSUP in the actual
Samba fixture. The pinned library's public move calls smb2_rename_async, whose
FileRenameInformation has **replace_if_exist = 0**. The fixture verifies free and
occupied destinations. Filesystem I/O remains anchored to the native root
descriptor. Wire rename checks observed source/parent types before using
share-relative paths. Like SFTP, SMB cannot exclude an uncooperative remote actor
swapping an ancestor after validation; use a dedicated share rooted at the
intended boundary for hard server-enforced confinement. Neither protocol can
protect against a malicious server violating its own conditional/rename rules.

`S3Store.presignedGET(path:expires:)` signs a read URL, with expiry restricted to
1...604800 seconds. Temporary credentials can expire sooner. A signed URL is a
bearer secret and must not be logged.

## Verification

`swift test --filter NetworkStoreTests` starts independent Python standard-library
HTTP fixtures on ephemeral loopback ports. They validate SigV4 independently and
exercise conditional reads/writes/copies/replacement, source mutation, destination
races, actual TransferEngine update/conflict branches, WebDAV methods/lock safety,
cheap stat, range validation, redirects, root escapes, opaque staged names and
multipart embedded-error/abort behavior. No real storage or credentials are used.

`sh scripts/test-smb-fixture.sh` starts an owned, disposable, pinned Samba 4.23.8
container on loopback port 445, with a throwaway account and required encryption/
signing. It runs the actual NetFS + encrypted libsmb2 integration and removes the
container. Port 445 must be free; no host daemon settings are changed. Normal
`swift test` skips the gated SMB integration test unless SYNCOPHANT_SMB_FIXTURE=1.
These fixtures are separate evidence from signed Finder/extension and real NAS
validation.

## Dependency and distribution

AMSMB2 4.0.3 is pinned to 1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0;
its libsmb2 submodule is aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03.
Both are LGPL 2.1 libraries. The license text is in
`docs/licenses/AMSMB2-LGPL-2.1.txt`; upstream copyright/source notices and all
libsmb2 component licenses must accompany distribution. AMSMB2's SwiftPM product
is dynamic; the application and extension builds must embed/sign that product
and preserve the recipient's LGPL modification/relink rights. Ship corresponding
source (including the libsmb2 submodule), build instructions and notices alongside
each distributed version. Root owns release packaging, signing and verification
of the actual app/extension bundles; a passing SwiftPM test does not prove those
distribution steps.
