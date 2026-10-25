# Syncophant

<!-- impeccable:product-schema 1 -->

## Platform
Native macOS 26 and later.

## Stack
Swift 6, SwiftUI and AppKit; Replicated File Provider with the storage engine inside the extension. Reusable CoreKit and HetznerKit Swift packages. libssh2 1.11, OpenSSL 3, SQLite WAL.

## Users
People who own a Hetzner Storage Box or SFTP server and want to use it from Finder without operating a sync client.

## Product Purpose
Make remote storage feel local, with honest file status and checksum-verified atomic uploads. Files remain accessible when the menu bar app closes.

## Capabilities and Constraints
The supplied product plan is the implementation brief. The first release targets Hetzner and generic SFTP; WebDAV, S3, encryption, scheduled jobs, mobile companions and FSKit belong to later releases. Never describe an unverified upload as safe. Preserve both sides of conflicts. Host key trust must be explicit. Credentials belong in Keychain, never settings or logs.

## Brand Commitments
Name: Syncophant. Bundle ID: app.syncophant.mac. Website: https://syncophant.app. Repository: https://github.com/syncophant-app/macos. Free, no accounts, paywalls, telemetry, crash uploads or project-owned servers. Update checks off by default. App GPL-3.0-or-later; reusable libraries MIT.

## Evidence on Hand
User-supplied BYO-Storage Mac Drive Product Plan and Storage Drive Mocks HTML (five screens: menu bar, connect, browser, settings/privacy, snapshots). Performance figures in the plan are targets requiring real hardware and storage measurements, not established results.

## Product Principles
Render local state before networking. Show verified facts. Recover without losing data. Use native controls and keyboard access. Keep resource use and network destinations visible.

## Accessibility & Inclusion
System type, semantic labels, full keyboard operation, Dark Mode, Reduce Motion, and status conveyed with text as well as color.
