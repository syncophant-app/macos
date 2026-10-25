# BYO-Storage Mac Drive: Product Plan

Oct 24, 2026 · @Amruth Pillai

## Summary and decisions

Build a free, open-source Mac app that turns your own Hetzner Storage Box, and later any SFTP, WebDAV, S3 or NAS storage, into a Finder drive. It streams files on open, proves every upload landed, and sets itself up in under a minute. There are no paywalls, no tracking, and no request to any server of ours.

| Decision | Choice |
| --- | --- |
| Product | Finder drive + menu bar app, Hetzner Storage Box first |
| Platform | Mac only, macOS 26+ recommended. Core packages stay portable so Windows/Linux remain possible |
| Finder technology | Replicated File Provider with partial fetch, engine inside the extension. FSKit later |
| SFTP stack | libssh2 1.11 + OpenSSL 3, benchmarked against Citadel in the first spike |
| Price | Free. Every feature, no tiers, no accounts |
| Privacy | No analytics, no crash uploads, no server of ours. The app talks only to your storage, to Hetzner's API if you add a token, and to GitHub if you turn on update checks |
| Distribution | GitHub Releases + Homebrew cask; Developer ID signed and notarised; Sparkle update checks off by default |
| Code licence | App: GPL-3.0-or-later. Libraries: MIT |
| What sets it apart | Checksum-verified uploads, Hetzner self-setup, snapshots as undo, stream-on-open from your own storage, silent reconnect, and being the only polished open-source option |
| Biggest risk | Panic's Transmit 6, which brings back a File Provider Finder drive |

The sections below hold the evidence: who the competitors are, what their users complain about, how their apps are built, and the feature set and plan that follow from it.

## Competitor landscape

Seven apps already put your own storage in Finder through File Provider, and Panic's Transmit 6 is about to join them. None of them knows anything about Hetzner. As a free, open-source app with no tracking, it would stand alone: ExpanDrive is free but closed, and MFuse is open but early. Prices were checked 24 Oct 2026.

### Finder drives

| App | Finder tech | Protocols | Price | What it does best |
| --- | --- | --- | --- | --- |
| [Transmit 6](https://heise.de/-11311407) (Panic, [beta closed Sep 2026](https://help.panic.com/transmit/transmit-beta/)) | File Provider ("Transmit Disk" returns), macOS 26+ | SFTP, S3, WebDAV, many clouds | Transmit 5 is $45 one-time; v6 pricing not announced | The polish and transfer-speed benchmark; menu bar scheduled syncs |
| [Mountain Duck 5](https://mountainduck.io/buy/) | File Provider ("Integrated") + NFS modes | SFTP, FTP, WebDAV, S3, SMB, clouds | $49 per user per major version; [App Store](https://apps.apple.com/us/app/mountain-duck/id1024974133) $5.99/mo or $59.99/yr | Breadth; Keep Offline; 14 Finder actions; saves the previous version before overwrite; Activity window; Cryptomator vaults |
| [SteadyMount](https://apps.apple.com/app/id6760929849) | File Provider, sandboxed | SFTP, WebDAV, FTP | 1 connection free; $27.99 once | Imports `~/.ssh/config`; trust-on-first-use host keys; CLI and URL scheme; recovers when macOS pauses the extension |
| [CloudMounter 4](https://cloudmounter.net/cloud-mounter-purchase.html) | File Provider + Finder Sync | SFTP, FTP, WebDAV, S3, many clouds | $74 lifetime per Mac or $29/yr | Feels light; pinning and folder eviction; per-folder encryption |
| [ExpanDrive](https://www.expandrive.com/now-free) | File Provider | SFTP, WebDAV, S3, Google Drive, OneDrive, more | Free for personal use and teams up to 10 | Free; Spotlight, tags and Quick Look |
| [Driio](https://apps.apple.com/us/app/driio-network-drive-client/id6757922119) | File Provider (Finder and Files) | SMB, SFTP, FTP, WebDAV, S3, NFS, Dropbox, OneDrive | $1.99/mo, $14.99/yr or $39.99 lifetime | One app across Mac, iPhone, iPad and Vision Pro |
| [FileZilla Pro RemoteDrive](https://apps.apple.com/us/app/filezilla-pro-remotedrive/id6502180430) | File Provider | FTP, SFTP, WebDAV, S3, clouds | $12.99/yr per Apple Account | Stable FTP; editing in place |
| [S3 Files](https://apps.apple.com/us/app/s3-client-files-location/id6447647340) / [Secure ShellFish](https://apps.apple.com/us/app/ssh-client-secure-shellfish/id1336634154) | File Provider | S3 / SSH | $14.99 / $29.99 lifetime | Handles edge cases and retries; 200 GB+ files; Shortcuts; presigned links |
| [Helumi](https://www.helumi.app/) | FSKit volume, macOS 26+ | Its own Cloudflare R2 cloud, not BYO | 5 GB free, then $10/TB/month | Plays video seconds after opening; end-to-end encryption; 30-day undelete; share links and file requests |
| [NetDrive 3](https://www.netdrive.net/store/) | macFUSE (kernel extension) | Many | $69.95 lifetime | Wide protocol list, but needs a kext and an account |

### Tools people use instead

| App | What it is | Price | What it does best |
| --- | --- | --- | --- |
| [Transmit 5](https://panic.com/transmit/) | Transfer client, no drive | $45 once | Sync with clear change previews; fast SFTP |
| [ForkLift 4](https://binarynights.com/store) | Dual-pane file manager | $19.95 per Mac with 1 year of updates | Range of protocols; batch rename; workspaces |
| [Cyberduck](https://cyberduck.io/) | Transfer client (GPL) | Free, donation key | Protocol breadth, Cryptomator, CLI |
| [Commander One](https://mac.eltima.com/commander-one-purchase.html) | Dual-pane manager, NFS loopback mounts | $29.99 once | Queueing; hotkeys |
| [Rclone UI](https://rcloneui.com/) / rclone `nfsmount` | rclone GUI, NFS loopback mount | Free (Apache-2.0); paid unlocks from $7 | Any backend; sparse range cache |
| [RcloneView](https://rcloneview.com/src/pricing.html) | rclone GUI, macFUSE mounts | $19.80/yr (2 devices) or $99.80 lifetime (3 devices) | One app instead of several mounts |
| [Arq 7](https://www.arqbackup.com/pricing/) | Backup to your own storage | $59.99 per computer + $25/yr for updates | Open format, end-to-end encryption, native UI |

[odrive](https://forum.odrive.com/t/important-odrives-free-tier-will-be-discontinued-march-31-2026/10593) left the consumer market (free tier ended 31 Mar 2026). Nextcloud's Mac client uses File Provider, but it needs a Nextcloud server. Hetzner's own July 2026 Mac tutorial points users to Cyberduck or an experimental rclone `nfsmount` ([Hetzner Community](https://community.hetzner.com/tutorials/storage-box-access-webdav-macos)). That is the gap in one sentence.

## What customers say is missing or broken

The loudest complaints are not about missing features. They are about trust: pricing that changes after purchase, drives that silently drop after sleep, and files that look uploaded but aren't. Themes are ranked by how often they came up across App Store reviews, Setapp, Trustpilot, Capterra, vendor changelogs, GitHub issues and forums (2023–2026). Reddit and MacRumors threads couldn't be read automatically and are worth a manual pass.

| Theme | What users say | Who it hits | Our answer |
| --- | --- | --- | --- |
| Pricing changes after purchase | "the license I previously purchased has been invalidated" ([Mountain Duck, App Store, Dec 2025](https://apps.apple.com/us/app/mountain-duck/id1024974133)); "constant pop-up every 30 minutes to upgrade" ([CloudMounter, Jun 2026](https://apps.apple.com/us/app/cloudmounter-cloud-manager/id1130254674)); perpetual licence "re-charged" ([ExpanDrive, Trustpilot](https://www.trustpilot.com/review/expandrive.com)) | Mountain Duck, CloudMounter, ExpanDrive, FileZilla RemoteDrive, ForkLift, Arq | Free and open source: no price to change, nothing to nag about |
| Hangs and stalls | OneDrive on Tahoe hangs Finder and open/save dialogs until reboot ([Microsoft Q&A, 2026](https://learn.microsoft.com/en-us/answers/questions/5873033/onedrive-hangs-macos-tahoe-26-4-1)); Cyberduck SFTP transfers hang and won't quit ([#18392](https://github.com/iterate-ch/cyberduck/issues/18392)); "it freezes very frequently" ([ForkLift, Setapp](https://setapp.com/apps/forklift/customer-reviews)) | Almost everyone | Every call has a timeout; enumeration fails fast with `serverUnreachable` instead of blocking Finder |
| Drops after sleep or network change | "I have to restart the app/remount every time" ([CloudMounter, App Store GB](https://apps.apple.com/gb/app/cloudmounter-cloud-manager/id1130254674)); Mountain Duck 5.0.2 fixed not resuming after wake ([changelog](https://mountainduck.io/changelog/)); Driio added auto-reconnect only in 2.2 ([App Store](https://apps.apple.com/us/app/driio-network-drive-client/id6757922119)) | CloudMounter, Mountain Duck, Driio | Engine in the extension; reconnect in under 3 s with no user action |
| Data that isn't really there | "a file looked safe in the cloud but simply did not exist" ([CloudMounter, Oct 2025](https://apps.apple.com/us/app/cloudmounter-cloud-manager/id1130254674)); empty files uploaded (Mountain Duck 5.0.4); rename-during-upload loss and SFTP corruption on longer saves (Driio 2.5, 2.7.2) | CloudMounter, Mountain Duck, Driio | Atomic `.partial` + rename; checksum-verified "On your box" state; property-based sync tests |
| Opaque status and errors | "doesn't give useful errors, just does nothing at all" (CloudMounter, Jul 2026); Mountain Duck shows Idle while burning 380% CPU ([#18430](https://github.com/iterate-ch/cyberduck/issues/18430)); users have "no idea of the total number or size of files currently pinned" ([Eclectic Light](https://eclecticlight.co/2024/09/30/how-icloud-has-changed-in-sequoia-pinning-and-more/)) | CloudMounter, Mountain Duck, FileZilla, iCloud | Issues list with one fix button each; real per-file queue state; pinned and cached totals |
| CPU and disk churn | 100–300% CPU and the Mac wouldn't sleep (Mountain Duck, Jun 2026); a 1.23 TB cache ([CloudMounter, Setapp](https://setapp.com/de/apps/cloudmounter/customer-reviews)); 540 GB written to the SSD while idle ([ShellFish](https://apps.apple.com/us/app/ssh-client-secure-shellfish/id1336634154)) | Mountain Duck, CloudMounter, ShellFish, `fileproviderd` | Idle budgets enforced in CI; capped, visible cache; rate-limited enumeration |
| Setup friction | pasted port "will not save" ([ExpanDrive, Trustpilot](https://www.trustpilot.com/review/expandrive.com)); repeated passphrase prompts for unencrypted keys (CloudMounter); no ECDSA keys ([SteadyMount](https://www.hunted.space/product/steadymount)); WebDAV 401s on long or umlaut passwords ([Duplicati forum](https://forum.duplicati.com/t/webdav-connect-to-hetzner-storage-box-fails/22003)) | ExpanDrive, CloudMounter, SteadyMount, S3 Files | Pre-flight checks with fixes; `~/.ssh/config` import; Ed25519, ECDSA, RSA, `sk-` keys and agents |
| Apps that break on dataless files | Photos and Final Cut libraries unsupported ([Dropbox](https://help.dropbox.com/installs/macos-support-for-expected-changes)); Xcode projects stuck "Loading…" in iCloud Drive on 26.5.2 ([Apple Community](https://discussionsjapan.apple.com/thread/256324666)) | All File Provider drives | Detect libraries, `.git`, `node_modules` and catalogs; offer to keep them local or warn |
| Case and name mangling | case-only names collide (SteadyMount); renaming "310a" to "310A" fails (ExpanDrive); "www.example.com" and "www.example.com-old-server" both shown as "www.example" ([FileZilla RemoteDrive](https://apps.apple.com/us/app/filezilla-pro-remotedrive/id6502180430)) | SteadyMount, ExpanDrive, FileZilla, CloudMounter | Detect case clashes and suffix them; two-step case renames; never parse dots as extensions for folders |
| Buried location | `~/Library/CloudStorage` breaks scripts and shared paths ([TidBITS](https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/)) | All File Provider drives | `~/StorageBox` symlink; Copy path; Open in Terminal |
| Storage Box limits | "Unable to startup channel" until connections were cut to 5 ([FreeFileSync forum](https://freefilesync.org/forum/viewtopic.php?p=43908)); uploads over 2–3 GB dropping ([LowEndTalk, 2023](https://lowendtalk.com/discussion/comment/3719204/)); SMB blocked on port 445 by ISPs | Anyone on a Storage Box | Connection broker; chunked, resumable SFTP; SFTP by default, not SMB |
| Spotlight, tags, Quick Look | "Spotlight, Finder search, tags, do not return search results" ([Box](https://support.box.com/hc/en-us/articles/360043695774)) | Box, Google Drive, Nextcloud | Index metadata; thumbnails; preserve tags and xattrs |
| Support goes quiet | "Support ghosted me" ([ExpanDrive, Trustpilot](https://www.trustpilot.com/review/expandrive.com)); the counterexample is Anders Borum shipping a fix "within 48 hours" | ExpanDrive, CloudMounter | Public changelog; a diagnostics bundle the user exports and attaches to an issue |

### Needs no app meets today

- **Proof that a file is on the server**, shown per file. Nobody does this.
- **Video that streams on open from your own storage.** Only Helumi pitches it, and Helumi isn't BYO.
- **Recovery after sleep, Wi-Fi changes or a paused extension with no user action**, demonstrated and not just claimed.
- **Good behaviour against case-sensitive Linux servers.**
- **A Storage Box that sets itself up:** sub-accounts, External Reachability, port 23, key install, snapshots as undo.
- **Low idle CPU and disk use while still showing everything that's happening.**
- **Multi-Mac editing that is visibly safe.** Only vendor claims exist so far.

## How the apps work under the hood

The three serious BYO drives all use a Replicated File Provider extension, but each one keeps its real engine in the main app. Helumi is the outlier: it is an FSKit volume. These findings come from static inspection of the current vendor downloads (24 Oct 2026). Nothing was executed; we only read the plists, entitlements, load commands and library strings.

| App · version | Finder integration | Where the engine runs | UI stack | SSH / transfer stack | Updates · crash reports |
| --- | --- | --- | --- | --- | --- |
| Helumi 0.3.3 | FSKit module (`com.apple.fskit.fsmodule`) + Finder Sync for badges + root mount daemon | FSKit module | Swift, SwiftUI, menu bar only | Own HTTPS API, CryptoKit AES-GCM | Sparkle 2.10 · MetricKit to own API |
| Mountain Duck 5.3.2 | Replicated File Provider with partial fetch, plus NFS loopback modes | Java 21 main process; the extension is a thin XPC proxy | Java + Rococoa bridge to AppKit | sshj, BouncyCastle, AWS SDK for Java, smbj | Sparkle 2.9 · own crash server |
| CloudMounter 4.18 | Replicated File Provider with partial fetch and thumbnails, plus Finder Sync | Main app over XPC | Objective-C + Swift | libssh2, OpenSSL 3, libsodium, several cloud SDKs | Sparkle 2.9 · own feedback reporter |
| ExpanDrive 2026.10 | Replicated File Provider, no partial fetch found | Main app over CFMessagePort/XPC, C++ core | Swift/SwiftUI + AppKit (not Electron) | libssh2 1.11 + OpenSSL, SQLite | Sparkle 1.24 · none found |
| Transmit 5.11.7 | None | n/a | Objective-C/AppKit | Panic's own kit on libssh2 1.11 + OpenSSL 3 | Sparkle 2.10 · Sentry + TelemetryDeck |
| ForkLift 4.7.7 | None | n/a | Swift + SwiftUI | libssh2 1.11 + OpenSSL | Sparkle 2.10 · none found |
| Cyberduck 9.5.4 | None | n/a | Java + Rococoa | sshj, AWS SDK for Java | Sparkle 2.9 · own crash server |
| [MFuse](https://github.com/lollipopkit/mfuse) (open source) | Replicated File Provider, no partial fetch | Extension | SwiftUI | Citadel (swift-nio-ssh), Soto for S3 | n/a |

What stood out:

- **Helumi proves FSKit ships outside the App Store.** Its FSKit entitlement comes from a Developer ID provisioning profile. The cost is visible too: macOS 26 minimum, a System Settings toggle the user must flip, and a privileged mount helper.
- **Thin extensions are why drives "die" when the app quits or hangs.** Mountain Duck, CloudMounter and ExpanDrive all relay from the extension to the main app. That is also the likeliest source of the reconnect-after-sleep complaints in the next section.
- **Mountain Duck's defaults are a cheat sheet.** It filters a long list of temp files from uploads (`.DS_Store`, `._*`, Office and Adobe lock files, browser partial downloads). It uses a 30-day, 5 GB LRU cache, 25 MB read-ahead, 32-deep transfer pipelines, 14 Finder actions and 13 status badges.
- **libssh2 1.11 + OpenSSL 3 is the industry default for SFTP.** Transmit, ForkLift, ExpanDrive, CloudMounter and Commander One all ship it. It supports hardware security keys (`sk-ed25519`) and the SSH agent. Cyberduck runs 64 outstanding SFTP reads with 32 KiB write chunks.
- **Build hygiene varies.** Mountain Duck's release build keeps `get-task-allow` (debuggable). ExpanDrive ships a debug dylib and a Sparkle 1.x feed whose URL contains literal quotes.
- **MFuse is a useful reference with known gaps:** remote paths as item identifiers (renames break identity), whole-file downloads, and one SSH connection per domain with no pool.
- **[Rclone UI](https://github.com/rclone-ui/rclone-ui)** mounts on macOS through rclone's `nfsmount`, so no macFUSE. That NFS loopback is also how Mountain Duck, CloudMounter and Commander One build their non-File Provider modes.

## Combined feature set

Take Helumi's stream-on-open feel, Mountain Duck's Finder depth, SteadyMount's SSH ergonomics and Transmit's polish. Add what nobody has: checksum-verified uploads, a Storage Box that sets itself up, and snapshots as undo. The Phase column is a dropdown, so change it as priorities move.

| Area | Feature | Taken from | Phase |
| --- | --- | --- | --- |
| Finder drive | Dataless files in Finder under Locations | Mountain Duck, CloudMounter, ExpanDrive | MVP (1.0) |
| Finder drive | Stream on open: range reads + read-ahead, video plays in \~1.5 s | Helumi, rclone's sparse cache | MVP (1.0) |
| Finder drive | Keep on this Mac (recursive folder pins) and Remove download, with pinned and cached totals shown | Mountain Duck, CloudMounter, iCloud's gap | MVP (1.0) |
| Finder drive | Badges for every state, including Verified | Mountain Duck's 13 decorations | MVP (1.0) |
| Finder drive | Finder actions: Keep offline, Remove download, Refresh, Retry, Copy path, Open in Terminal | Mountain Duck's 14 actions | MVP (1.0) |
| Finder drive | Thumbnails and Quick Look for remote files | CloudMounter | MVP (1.0) |
| Finder drive | Spotlight-friendly metadata; tags and xattrs preserved | ExpanDrive, Mountain Duck 5 | 1.x |
| Finder drive | `~/StorageBox` symlink and Copy path | Fix for the buried CloudStorage path | MVP (1.0) |
| Finder drive | Guardrails for Photos/Final Cut libraries, `.git`, `node_modules` | Fix for Dropbox and iCloud complaints | 1.x |
| Finder drive | Case-clash detection and two-step case renames | Fix for SteadyMount and ExpanDrive bugs | MVP (1.0) |
| Transfers | Atomic uploads (`.partial` + rename) verified by server-side `sha256sum` | New, uses Hetzner's port-23 shell | MVP (1.0) |
| Transfers | Resumable chunked uploads; one failed file never fails the batch | Helumi, S3 Files | MVP (1.0) |
| Transfers | Bandwidth throttle with an Auto mode that backs off when latency rises | Helumi | MVP (1.0) |
| Transfers | Temp-file filter (`.DS_Store`, `._*`, Office and Adobe lock files) | Mountain Duck | MVP (1.0) |
| Transfers | Conflict copies named by Mac and date, both kept | Mountain Duck, Helumi | MVP (1.0) |
| Transfers | Previous version saved before every overwrite | Mountain Duck's Custom Versioning | 1.x |
| Transfers | Remote trash with 30-day retention | Helumi's undelete | MVP (1.0) |
| Transfers | Scheduled sync and backup jobs from the menu bar | Transmit 6 | 2.0 |
| Setup | Hetzner one-click setup: token, box, sub-account, reachability, key, host key, speed test | New | MVP (1.0) |
| Setup | `~/.ssh/config` import; SSH agents (1Password, Secretive); Ed25519, ECDSA, RSA and `sk-` keys | SteadyMount, Transmit | MVP (1.0) |
| Setup | Host keys pinned on first use and checked against Hetzner's published fingerprints | SteadyMount + Hetzner docs | MVP (1.0) |
| Setup | Pre-flight checks with fixes (reachability, blocked ports, password characters) | New | MVP (1.0) |
| Setup | Connection broker sized to each provider's limits | New, from Storage Box forum pain | MVP (1.0) |
| Setup | WebDAV, S3-compatible and SMB drivers (generic SFTP ships in 1.0) | Mountain Duck, Driio | 2.0 |
| Setup | CLI and URL scheme for mounting and scripting | SteadyMount | 1.x |
| Setup | Optional settings sync through your own iCloud, off by default; secrets only with a separate opt-in | MFuse, Driio; ShellFish's silent-sync complaint | 1.x |
| Status | Menu bar: transfers with ETA, pause and throttle, drop target, search | Helumi, Transmit | MVP (1.0) |
| Status | Issues list: plain-language cause and one fix button | New | MVP (1.0) |
| Status | Global search (⌃⌥Space) and ⌘K command palette | Helumi, Raycast | MVP (1.0) |
| Status | Diagnostics bundle the user exports for an issue; never uploaded automatically | Driio and S3 Files adding logs | 1.x |
| Safety | Snapshot "Time Travel": browse, preview, restore one file or folder | New, uses Hetzner snapshots | 1.x |
| Safety | Optional end-to-end encryption in an rclone-crypt-compatible format | Helumi, Cryptomator, CloudMounter | 2.0 |
| Sharing | Share links: presigned URLs (S3) or a read-only sub-account (Storage Box) | Helumi, S3 Files | 2.0 |
| Platform | iPhone and iPad companion via File Provider | Driio, S3 Files | Later |
| Platform | FSKit live-volume mode | Helumi | Later |

Deliberately not copied:

- Helumi's hosted cloud and web access, which need a server we don't run.
- Telemetry, crash uploads, accounts and paywalls of any kind.
- Kernel extensions and NFS loopback mounts.
- A bundled Java runtime.

## UX principles and signature flows

The UX bet: the user never wonders where a file is, whether it is safe, or whether the app is still working. Each principle below answers a complaint that comes up again and again in competitor reviews.

### Principles

1. **Never wait on the network to draw.** Every window, menu and Finder listing renders from the local SQLite cache first and reconciles when the server answers.
2. **Status you can trust.** Every file has a visible, *verified* state. "On your box" appears only after the server-side `sha256sum` (port 23) matches the local hash. This answers the strongest fear in competitor reviews: files that look uploaded but aren't.
3. **Heal silently.** Sleep, wake, Wi-Fi changes and macOS pausing the extension trigger a reconnect with no user action. The menu bar mentions a problem only if it lasts longer than about 10 seconds.
4. **Finder is the main UI, and it uses system parts.** Standard toolbars, sidebars, menus and controls, so Liquid Glass, the macOS 27 opacity slider, Dark Mode and accessibility work without custom drawing.
5. **Calm on resources.** Idle CPU near 0%. The cache has a size cap the user sets and can see. Nothing churns the SSD while idle.
6. **Private by construction.** The app talks only to the user's storage, plus Hetzner's API if they add a token. No analytics, no crash uploads, and no update pings unless they're switched on.
7. **Keyboard first, never keyboard only.** A command palette and shortcuts for everything, with the same actions reachable by right-click.

### Signature flows

1. **Connect a Hetzner Storage Box in under 60 seconds.** Paste a Hetzner API token, then pick a box from a list with live capacity bars. Press "Set up this Mac" and watch a checklist tick through:
   1. create a sub-account for this Mac;
   2. enable SSH and External Reachability;
   3. generate a key and install it in both formats Hetzner needs;
   4. pin the host key against Hetzner's published fingerprints;
   5. run a speed test that shows real numbers.

   Each step is retryable on its own. Other SFTP servers get a host/user/port form, an import from `~/.ssh/config`, and SSH agent support (1Password, Secretive).
2. **Open a 20 GB video from Finder.** The file is dataless and plays within about 1.5 s. Scrubbing fetches only the ranges needed. The menu bar quietly shows how much is cached.
3. **Drop files on the menu bar icon.** A destination picker of recent folders appears, and progress shows in under 100 ms. Each file walks Queued → Uploading → Verifying → On your box. Pause and per-file cancel (with undo) are always visible.
4. **Something goes wrong.** One Issues list states the cause in plain words with one fix button. For example: "Your box isn't reachable from outside Hetzner → Turn on External Reachability."
5. **Undo with snapshots.** Right-click a file or folder → Restore from snapshot… → scrub dates → Quick Look → Restore copies it back. A full-box rollback sits behind a destructive-confirmation sheet.
6. **See every connection.** Settings → Privacy lists every host the app has contacted and when. It should only ever show the user's storage, plus Hetzner's API and GitHub when those are switched on.

### Keyboard map

| Shortcut | Action |
| --- | --- |
| ⌃⌥Space (global, configurable) | Search everything |
| ⌘K | Command palette: go to folder, pin, pause, snapshots |
| Space | Quick Look |
| ⌘⌥P / ⌘⌥E | Keep on this Mac / Remove download |
| ⌘⇧S | Snapshots for selection |
| ⌘. | Cancel transfer |
| ⌘, | Settings |

### Performance budgets (enforced in CI)

| Metric | Budget |
| --- | --- |
| Cold launch to menu bar ready | < 300 ms |
| Browser window first paint from cache | < 150 ms |
| Scrolling a 100k-row list | 120 fps on ProMotion, no frame > 8 ms |
| Search keystroke to results (SQLite FTS5, 1M rows) | < 30 ms |
| Video first frame from a dataless file (Hetzner, \~30 ms RTT) | < 1.5 s |
| Reconnect after wake or network change | < 3 s, no user action |
| Idle CPU / memory (app + extension) | \~0% / < 150 MB |

## Architecture

A Swift 6 app plus a Replicated File Provider extension, with the sync engine running inside the extension so the drive keeps working when the app is closed. This is the main departure from Mountain Duck, CloudMounter and ExpanDrive, whose drives depend on the main app staying alive.

&#91;embedded content: architecture · app, extension, remote services\]

Finder goes through macOS's `fileproviderd`, which launches our extension. The extension holds the whole engine and talks SSH to the box. The app handles setup, the Hetzner API and agent signing. Nothing else leaves the Mac.

### Targets

| Target | Job | Key frameworks |
| --- | --- | --- |
| App (menu bar + windows) | Onboarding, menu bar, browser/search, Issues, snapshots, settings, Hetzner API calls | SwiftUI shell, AppKit `NSOutlineView` for every list, `MenuBarExtra` |
| File Provider extension | Enumerate, fetch, partial fetch, create/modify/delete, thumbnails, badges, custom actions | `NSFileProviderReplicatedExtension`, `NSFileProviderPartialContentFetching`, `NSFileProviderThumbnailing` |
| File Provider UI extension | Sheets for actions like Restore from snapshot… and Copy share link | FileProviderUI |
| `CoreKit` (shared framework) | `RemoteStore` drivers, connection broker, transfer scheduler, sync engine, metadata DB, chunk cache, hash verifier | GRDB (SQLite WAL), libssh2 + OpenSSL 3 |
| `HetznerKit` (package) | Client for `api.hetzner.com`: boxes, sub-accounts, access settings, snapshots, stats | URLSession, async/await |

### Decisions

- **SFTP library: libssh2 1.11 + OpenSSL 3, wrapped in a Swift actor.** Five of the inspected apps ship exactly this. It supports hardware-key (`sk-ed25519`) and agent auth. Citadel stays the alternative in the week 4–6 benchmark. Pick on measured throughput and seek latency against a real BX11.
- **SSH agent keys go through the app.** The extension must be sandboxed and can't reach agent sockets. Keys the app generates live in a shared Keychain access group, so the extension signs with them on its own. For 1Password or Secretive agent keys, the extension asks the unsandboxed app over XPC to sign the auth challenge. Only agent users need the app running.
- **Stable item identifiers.** Each item gets a UUID mapped to its remote path in SQLite, so renames and moves keep identity (MFuse's path IDs don't).
- **Partial fetch from day one.** Answer each request with a 4–16 MB aligned range. Keep one warm SSH session reserved for reads. Detect sequential access and read ahead (Mountain Duck triggers at 25 MB). Pipeline 32–64 outstanding SFTP reads.
- **Connection broker sized for Hetzner.** Cap the main account at 6 of its 10 connections, and default to a per-Mac sub-account, which gets its own budget. Multiplex SFTP channels over few SSH sessions.
- **Atomic, verified uploads.** Write `name.partial-<uuid>`, resume from its size, check `sha256sum` on port 23, then rename into place. Conflicts use a version token (mtime + size, or the hash) and keep both copies.
- **Temp-file filter.** Never upload `.DS_Store`, `._*`, Office/Adobe lock and save files or browser partial downloads. Start from Mountain Duck's list.
- **Remote change detection by tiered polling.** Folders that are open or pinned every 15–30 s, recently used folders every few minutes, a full crawl nightly. A per-directory listing hash means unchanged folders cost one `readdir`.
- **Filesystem semantics.** File Provider presents a case-insensitive view, so detect case-only name clashes on the server and show both files with a clear suffix. Do case-only renames in two steps.
- **Reachable paths.** Finder shows the drive under Locations. Add an optional `~/StorageBox` symlink and "Copy path" and "Open in Terminal" actions, so scripts don't have to dig through `~/Library/CloudStorage`.
- **Bounded cache.** A size cap and age limit the user can see and set (Mountain Duck's defaults are 5 GB and 30 days), plus user-controlled eviction. The cache never fills the disk.
- **Updates and diagnostics.** Sparkle 2 with EdDSA-signed appcasts on GitHub Releases, automatic checks off by default. MetricKit reports and logs stay on the Mac for the user to export. Ship release builds without `get-task-allow` or debug dylibs.

## Free, open source and private

The app is free and open source, and it never calls home. There are no paywalls, accounts, analytics or crash uploads, and no server of ours anywhere. The only hosts it contacts are ones the user configured or switched on.

### Commitments

- **No paywalls.** Every feature for everyone. No tiers, trials, "pro" badges or donation prompts in the app.
- **No accounts.** Nothing to sign up for.
- **No telemetry of any kind.** No analytics, usage statistics or automatic crash reports. No SDK that could add them: no Sentry, TelemetryDeck, Firebase or the like.
- **No server of ours.** Nothing in the app depends on infrastructure we run, so it keeps working if the project goes quiet.
- **Diagnostics stay on the Mac.** Logs and MetricKit reports are kept locally. A user can export a redacted diagnostics bundle and attach it to a GitHub issue themselves.

### Network policy

| Destination | When | What is sent |
| --- | --- | --- |
| The user's storage (Storage Box, SFTP, WebDAV, S3, NAS) | While the drive is in use | Files and listings, over SSH or TLS |
| `api.hetzner.com` | Only after the user pastes a Hetzner API token: during setup, and when opening snapshots or quota | API calls for boxes, sub-accounts, access settings and snapshots |
| GitHub Releases | Only if the user turns on update checks (off by default), or picks Check for Updates… | A plain HTTPS request for the appcast; Sparkle's system profiling stays off |
| The user's own iCloud | Only if settings sync is turned on | Connection settings; secrets only with a separate opt-in |

macOS's own Gatekeeper checks are the operating system's, not the app's. The notarisation ticket is stapled to the download so first launch doesn't need to look it up.

### Keeping the promise checkable

- **Settings → Privacy lists every host the app has contacted, with times.** It should only ever show the rows above.
- **CI egress test.** Integration and UI tests run behind a proxy that fails the build on any connection to a host the test didn't configure.
- **Dependency rule.** No analytics, crash-reporting or ad SDKs. Every new dependency is reviewed for network calls before it's added.
- **Builds from tagged commits.** GitHub Actions builds from a tag, signs and notarises the app, and publishes checksums with each release.

### Updates without phoning home

- **Homebrew cask** for people who manage apps with `brew`. Homebrew does the update checking they already chose.
- **Direct download from GitHub Releases**, Developer ID signed, notarised and stapled.
- **Sparkle 2 is built in, with automatic checks off.** The last onboarding step asks once: "Check GitHub for updates once a day?" The menu item Check for Updates… always works on demand.

### Costs and funding

- **The fixed costs are yours.** The Apple Developer Program ($99/year) is needed for Developer ID signing and notarisation; without it Gatekeeper blocks the app for most people. A BX11 test box is €3.20/month.
- **Optional:** a GitHub Sponsors link in the README and the About window, with no prompts in the app. Sponsorship income is taxable, which is one question for a Steuerberater.

## Software licence

**Decision: GPL-3.0-or-later for the app; MIT for the reusable libraries (`HetznerKit`, the `RemoteStore` and SFTP layer).** Copyleft means every distributed version must publish its source, so anyone can check that no build quietly adds tracking. The libraries stay easy for any Swift developer to adopt.

| Licence | Closed forks allowed | Third-party App Store copies | Can reuse MFuse's AGPL code | Fit |
| --- | --- | --- | --- | --- |
| **GPL-3.0-or-later** | No: every distributed fork must publish its source | No, in the FSF's view; VLC was pulled in 2011 ([Engadget](https://www.engadget.com/2011-01-09-the-gpl-the-app-store-and-you.html)) | Yes, under GPLv3 section 13 | Best |
| MIT | Yes: anyone can add tracking, close it and sell it | Yes | No | Good and simplest; matches Reactive Resume |
| Apache-2.0 | Yes | Yes | No | Like MIT, plus a patent grant |
| MPL-2.0 | Only changed files must stay open | Yes | No | A middle ground |
| AGPL-3.0 | No | No | Yes | No gain over GPL for a desktop app |

Why GPL:

- **The privacy promise is the product.** "No tracking" can only be checked if every build people run has public source. GPL makes that a condition of distribution.
- **It stops quiet repackaging.** Under MIT, a third party could legally ship the app with ads or analytics added. Under GPL they would have to publish those changes, and App Store copies are ruled out.
- **It lets you borrow from MFuse.** GPLv3 section 13 allows combining GPL code with AGPL-3.0 code, so you can reuse parts of the closest open File Provider codebase, with attribution, instead of rewriting them.
- **The cost is small here.** Once outside contributions land without a CLA, you can't ship to the Mac App Store yourself. Distribution is GitHub and Homebrew anyway, and the App Store sandbox would block SSH agent access.
- **Precedent:** Cyberduck, Cryptomator and IINA are GPL Mac apps.

If you'd rather match Reactive Resume, MIT works too. You give up the fork guarantee and the MFuse reuse.

Ground rules:

- **Contributions:** a DCO sign-off, no CLA.
- **Trademark:** keep the name and icon protected, since the GPL grants no trademark rights. Forks have to rebrand, so users can tell official builds apart.
- **Dependencies are all GPLv3-compatible:** libssh2 (BSD-3), OpenSSL 3 (Apache-2.0, which is compatible with GPLv3 but not GPLv2), GRDB and Sparkle (MIT). Their notices go in About → Acknowledgements.
- **Keep the MIT libraries clean.** They live in their own packages and must never include MFuse or other GPL/AGPL code.

## Keeping the door open for Windows and Linux

Build for the Mac only. The one rule that keeps a port possible later costs nothing now: platform code stays at the edges.

- **Core packages import Foundation only.** `RemoteStore` and its drivers, the sync and transfer engine, the metadata schema and the Hetzner API client live in Swift packages with no AppKit, SwiftUI or FileProvider imports.
- **One adapter per OS integration.** On the Mac that adapter is the File Provider extension. On Windows the matching system API is the Cloud Files API (placeholders and hydration, the same model OneDrive uses), so a later Windows adapter maps cleanly onto the same engine. Linux has no equivalent, so a Linux version would be a FUSE mount with its own cache.
- **Pick portable building blocks when it's free to do so.** Prefer `swift-crypto`, which exposes the CryptoKit API on other platforms, and keep Keychain access behind a small `SecretStore` protocol.
- **Don't share UI.** If a Windows or Linux version ever happens, write native UI there too, because the native feel is the product. That is a later decision, not a constraint on Mac work today.

## Risks, open questions and admin

The biggest risks are timing and sustainability. Transmit 6 brings Panic's polish to File Provider drives soon, and a free app lives or dies by how little support it needs.

### Risks

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Transmit 6 ships first | Panic sets the polish bar, and it already has a loyal user base | Lead with what Transmit lacks: Hetzner self-setup, verified uploads, snapshots as undo, open source, zero tracking, free |
| File Provider platform bugs | `fileproviderd` hangs and macOS regressions hit every app in the category | Test every macOS beta seed; keep extension calls fast; file Feedback reports early |
| Partial-fetch timeouts on slow links | The system gives up when time-to-first-byte is around 3 s | Large aligned ranges, a warm read session, full fetch below a size threshold |
| Hetzner changes | API fields were deprecated in Apr 2026; the shell command list could change | Feature-detect at connect; nightly integration tests against a real BX11 |
| Debugging without telemetry | No crash report arrives by itself | Rich local logs; one-click diagnostics export; issue templates that ask for it; reproduce against Docker OpenSSH + Toxiproxy |
| Maintainer load | A popular free app gets issues faster than one person can answer | Discussions for questions, Issues for bugs; a written scope of what's out; grow co-maintainers from DCO contributors |
| Look-alike forks | Someone ships a modified build under a similar name | GPL forces them to publish source; trademark the name; one official download page with checksums |

### Open questions

- **Licence final call:** GPL-3.0-or-later (recommended), or MIT to match Reactive Resume?
- **Minimum macOS:** recommend macOS 26. It matches Liquid Glass, Transmit 6 and Helumi, and it halves the design and test matrix. macOS 15 would widen the audience.
- **Update checks:** off by default with one onboarding prompt (recommended), or Homebrew and manual checks only?
- **Sponsorship:** a GitHub Sponsors link, or nothing at all?
- **Name:** pick one and run a DPMA/EUIPO trademark search before buying the domain.
- **Reddit check:** r/hetzner, r/macapps and r/selfhosted threads still need a manual read.

### German admin checklist

This is not legal or tax advice.

- [ ] Check your employment contract's side-job and IP clauses, and tell your employer about the project in writing. Software written as part of your job belongs to the employer ([§ 69b UrhG](https://www.gesetze-im-internet.de/urhg/__69b.html)). Build on your own time and hardware.
- [ ] Join the Apple Developer Program for Developer ID signing and notarisation.
- [ ] If you accept sponsorship money, ask a Steuerberater how to declare it.
- [ ] If the project gets its own website, add an Impressum to be safe. The duty covers business-like digital services ([§ 5 DDG](https://www.gesetze-im-internet.de/ddg/__5.html)), and sponsorship can tip a hobby page into that.

## Roadmap

About 24 weeks of focused work reaches 1.0, past three go/no-go gates. At side-project pace, expect it to take longer; the weeks are estimates, not sourced figures.

&#91;embedded content: roadmap · 8 phases, 3 gates\]

The first gate is the one that matters most. If a dataless video won't play quickly from a real Storage Box by week 6, fix the streaming design before building anything else on it.

## Sources

Most sources are also linked inline next to the claims they support. The bundle teardown covered the vendor downloads of Helumi 0.3.3, Mountain Duck 5.3.2, ExpanDrive 2026.10.02, CloudMounter 4.18, Transmit 5.11.7, ForkLift 4.7.7, Cyberduck 9.5.4 and Commander One 3.18, taken on 24 Oct 2026.

**Products and pricing**

- [Helumi](https://www.helumi.app/), its [security page](https://www.helumi.app/security), [changelog](https://www.helumi.app/changelog) and [TrustMRR listing](https://trustmrr.com/startup/helumi)
- [Mountain Duck buy page](https://mountainduck.io/buy/), [changelog](https://mountainduck.io/changelog/) and [Integrated mode docs](https://docs.mountainduck.io/mountainduck/connect/integrated/)
- [SteadyMount on the App Store](https://apps.apple.com/app/id6760929849) and [vendor page](https://www.forethought-studio.com/steadymount/)
- [CloudMounter pricing](https://cloudmounter.net/cloud-mounter-purchase.html) and [ExpanDrive "now free"](https://www.expandrive.com/now-free)
- [Driio](https://apps.apple.com/us/app/driio-network-drive-client/id6757922119) and [FileZilla Pro RemoteDrive](https://apps.apple.com/us/app/filezilla-pro-remotedrive/id6502180430)
- [Transmit](https://panic.com/transmit/), the [Transmit 6 beta page](https://help.panic.com/transmit/transmit-beta/) and [heise on Transmit 6](https://heise.de/-11311407)
- [MFuse](https://github.com/lollipopkit/mfuse), [Rclone UI](https://github.com/rclone-ui/rclone-ui) and [rclone nfsmount docs](https://rclone.org/commands/rclone_nfsmount/)

**Hetzner**

- [Storage Box general docs](https://docs.hetzner.com/storage/storage-box/general), [snapshots](https://docs.hetzner.com/de/robot/storage-box/snapshots) and the [macOS WebDAV tutorial (Jul 2026)](https://community.hetzner.com/tutorials/storage-box-access-webdav-macos)

**Platform behaviour**

- [TidBITS on File Provider's forced location](https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/), [Eclectic Light on pinning](https://eclecticlight.co/2024/09/30/how-icloud-has-changed-in-sequoia-pinning-and-more/) and [Dropbox's macOS limitations](https://help.dropbox.com/installs/macos-support-for-expected-changes)

**Licences and German law**

- [GNU GPL v3 text](https://www.gnu.org/licenses/gpl-3.0.txt), including section 13 on combining with AGPL-3.0 code
- [Engadget on the GPL, the App Store and VLC](https://www.engadget.com/2011-01-09-the-gpl-the-app-store-and-you.html)
- [§ 69b UrhG](https://www.gesetze-im-internet.de/urhg/__69b.html) and [§ 5 DDG](https://www.gesetze-im-internet.de/ddg/__5.html)
