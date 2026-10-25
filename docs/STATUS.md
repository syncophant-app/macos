# Implementation and verification status

Updated October 25, 2026. Version 0.1.0 contains working 1.0 and 2.0 features.
The ARM release package is notarized and stapled; the product acceptance gates
below remain open. Local fixtures, signing and live Finder acceptance are
separate evidence.

## Implemented

- Native Liquid Glass browser, menu bar, onboarding, settings, command palette,
  issues, transfer queue, backups, sharing and remote-trash screens.
- Local, SFTP, WebDAV, S3-compatible and SMB stores. HTTPS/strong conditional
  validators and server-required SMB3 encryption/signing are prerequisites.
- Pinned SSH trust before authentication, password/private-key/agent choices,
  passive SSH-config import, durable per-Mac Ed25519 keys and a signed XPC
  agent bridge for Finder. Agent signing requires the running app.
- Hetzner setup with an explicit relative subaccount folder (`Syncophant` by
  default), `/home` as the port-23 SFTP root, snapshots and read-only shares.
  Main-account setup gives access to the whole box.
- SQLite WAL identities/search, coherent anchors, cross-process mutation and
  publication fences, explicit recovery, version-bound SHA256 verification,
  no-clobber publication and retained conflicts.
- Cheap filesystem/HTTP revisions, batched SFTP stat with hash fallback and
  bounded validated readahead. ETags are revisions, never checksums.
- Verified resumable uploads, durable app queue, pause and aggregate adaptive
  or fixed bandwidth controls. S3 uses conditional copy/replacement with retained
  sources/backups; atomic rename and trash are disabled there.
- Finder full/partial fetches, pin/evict, six context actions, native thumbnails
  for supported files up to 32 MiB and a recent upload-destination picker.
- Cache budgets retaining unsafe-to-evict data; manifest-backed remote trash,
  original-path restore, retention cleanup and explicit mutation recovery.
- Optional rclone-compatible encryption through a bundled native helper with
  private pipes, ciphertext-only staging, bounded buffers and cancellation.
- One-way add-only backup jobs with mandatory previews, retained versions and
  schedules while the app runs. Source descriptors stay pinned across awaits.
- S3 expiring links and confirmed Hetzner read-only folder accounts. Encrypted
  storage cannot be shared. Secrets stay in Keychain; diagnostics stay local.
  Sparkle update checks default off.

## Current proof

- Full tests: **78 Swift Testing tests in 13 suites and 12 Hetzner XCTest
  tests**, plus journal/range, cache, queue, credential and Finder self-checks.
  The two-enumerator polling lifecycle check also passed. Default tests skip
  the gated real SMB fixture.
- Development-signed app, extension, crypt helper and rendezvous helper built
  under team 654ASRW868; deep/strict signature verification passed.
- Apple accepted the Developer ID Release archive, submission
  `0e93212c-4f2e-4bf5-98c5-bcfd14c6724c`, with no reported issues. The ticket was
  stapled before creating `Syncophant-0.1.0-arm64.zip`. A fresh ZIP extraction
  passed strict/deep signatures, ticket validation and Gatekeeper assessment
  (`source=Notarized Developer ID`). This does not establish fresh-Mac runtime
  acceptance or the deferred live checks below.
- Live Hetzner setup created its scoped subaccount, enabled access, approved a
  published host key, installed/proved the generated key, verified/removed its
  1 MiB preflight file and saved the connection.
- The new subaccount DNS initially returned authoritative NXDOMAIN, then
  propagated. Retrying the host-key step reused the existing setup.
- Finder activation initially selected stale unsigned build registrations.
  Removing only those registrations and re-registering the signed build let the
  existing setup finish; no account recreation was needed.
- The signed extension uploaded a generated 4 MiB file in a new acceptance
  folder. Its remote SHA256 receipt matched. Remove Download produced a
  zero-allocated-byte dataless placeholder. With the app quit, reading through
  CloudStorage hydrated it with the same SHA256 in **3.82 seconds**. This is not
  the large-video startup or reconnect performance gate.
- The encryption owner completed independent **20 GiB interoperability both
  ways**, including full decrypted SHA256 checks: exit 0, 23m31s, conservative
  sampled aggregate Swift/helper RSS peak 94.5 MiB. Earlier stopped runs are
  not successful proofs. Focused crypt tests and `go vet` passed.
- Earlier implementation owners reported isolated OpenSSH BSD/GNU/hash-fallback,
  native Samba and signed XPC broker fixtures passing. These remain fixture
  evidence, distinct from live Hetzner/Finder and external-agent acceptance.
- Browser light/dark/minimum-size harness renders were checked during design.
  Final forms, Reduce Transparency and the real menu-bar popover still need an
  interactive acceptance pass.

## Open release gates

- Live pin/evict policy, deletion/restore, reconnect, sleep/wake, multi-Mac edits,
  snapshots and large remote-file streaming. The native trash configuration fix
  still needs its live acceptance check.
- Bundled agent-service approval and sandboxed Finder using an actual external
  agent such as 1Password/Secretive.
- Real video-start, large-directory/search and idle-resource measurements.
  Target timings must not be marketed as measured results.
- Developer ID packaging includes corresponding application/LGPL sources,
  notices and rebuild instructions, and refuses debugger-enabled release code.
  Notarization/stapling passed; signed appcast and Homebrew publication remain
  open. No commit, push or release publication has been performed.
- Finder tags/xattrs, iCloud settings sync and CLI/URL automation from the broader
  plan are not implemented and must not be represented as shipped.

## Commands

```sh
bash scripts/test.sh
SYNCOPHANT_PROVIDER_LIFECYCLE_CHECK=1 bash scripts/test.sh
bash scripts/integration/sftp.sh
sh scripts/test-smb-fixture.sh
bash scripts/integration/crypt.sh
SYNCOPHANT_TEAM_ID=654ASRW868 SYNCOPHANT_DERIVED_DATA=build/Provisioned bash scripts/build.sh
```

See [architecture](INTEGRATION.md), [protocol limitations](STORAGE_PROTOCOLS.md)
and [the product plan](PRODUCT_PLAN.md).
