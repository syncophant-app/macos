---
name: Syncophant
description: Status-first native macOS 26 Liquid Glass storage drive. Glass for navigation only, solid surfaces for content; every state has a glyph and a colour first and words second.
colors:
  accent: "system accent (Color.accentColor)"
  safe: "system green; text #1A7F45 / dark #4CD07D"
  needs-you: "system orange; text #B45309 / dark #F0A24A"
  failed: "system red; text #B42318 / dark #FF7A70"
  history: "system purple; text #7E3FD6 / dark #D38CF7"
  schedule: "system teal; text #0E7A88 / dark #5ED3E6"
  fill: "primary at 7%, 12%, 18%"
typography:
  screen-title: "22–26 pt bold, tight tracking"
  window-title: "17 pt bold"
  headline: "13–15 pt semibold"
  body: "13 pt regular"
  caption: "11–12 pt regular"
  section-label: "11 pt semibold uppercase, tertiary"
  big-number: "20–26 pt bold, monospaced digits, numeric content transition"
rounded:
  card: "16–20px"
  row: "10px"
  icon-tile: "9–13px"
  chip-and-button: "capsule"
spacing:
  grid: "8px"
  tight: "4px"
---

# Design System: Syncophant

## Overview

Syncophant answers "is my stuff safe, and does anything need me?" in under a second, before any text is read. The source of the redesign is the Syncophant Redesign Spec (25 Oct 2026) and its canvas. Liquid Glass is the floating navigation layer only: the menu bar panel, toolbar groups, the system sidebar, pills, toasts, popovers and the command palette. Lists, cards, the inspector, forms and setup-window bodies are solid (`windowBackgroundColor` / `controlBackgroundColor`). No glass on glass; inside glass, group with flat fills. One `.glassProminent` action per view.

Mode: Operate. Light and Dark follow the system; the accent follows the person's system accent. Reduce Transparency, Increase Contrast and Reduce Motion are honoured by the system glass and by the motion tokens.

## App Icon

The icon is the brand mark, not an SF Symbol: the white elephant head whose ear gaps are cut as one clockwise sync loop (up arrow on the left, down arrow on the right), on a Syncophant Blue glass tile (`#4DA3FF` to `#0A5FDB`) with a thin light rim and a soft top sheen. The 16 and 32 px sizes use the small cut, whose wider gaps survive. It carries no text and is the one place the mark is blue or sits on a gradient. Source and export steps are in `Assets/README.md`.


## Colors

Status tones live in `Tone` (`StatusKit.swift`): `.color` (system colour, for glyphs and fills), `.text` (text-safe variant from `Palette`, 4.5:1 on its surface in both appearances) and `.soft` (status card tint, about 15%). Accent means activity, selection and the primary action; green safe; orange needs you; red failed or destructive; purple history (snapshots, versions, encryption); teal schedules and downloads. A status colour never travels alone: every state pairs a glyph with words.

## Typography

System font at system sizes. Live numbers use `.rollingNumber(_:)` (monospaced digits plus numeric content transition) so they never jitter. Hosts, fingerprints and keys use the monospaced design; labels never do. Copy is US English, sentence case for labels, Title Case for buttons and menu items. Hostnames, account IDs, raw snapshot names, "salt", "ZFS" and "allocations" stay out of primary text.

## Motion

Four tokens in `Motion`: snappy (0.3 s, presses, toggles, selection), smooth (0.4 s, rows, panes, rings), bouncy (0.6 s, success only) and morph (spring 0.5/0.8 with `glassEffectID` when a control changes role). Use `.motion(_:value:)`, which turns every move into a 0.2 s fade under Reduce Motion; loops (ping, rotate, flowing dashes) stop there and when hidden. Rows enter with `.rowEntrance(index)`.

## Layout

- **Menu bar panel** (`MenuBarView`, `StatusItemController`): `NSStatusItem` that accepts drags plus a non-activating `NSPanel`, 360 pt, 26 pt corners. Header with avatar, health and capacity; one hero state (transferring, all synced, needs you, offline); quick tiles; backups strip; search that opens the palette. Dropping files turns it into destination tiles (`MenuBarPanelDrop`).
- **Main window** (`MainWindow`): `NavigationSplitView`, 1360 × 820 default. Sidebar: storage switcher, Files, Activity, Time Travel, Backups (⌘1–⌘4), pinned folders, capacity card (only when the provider reports quota). Detail is solid.
- **Files**: folder browser with back/forward, breadcrumb, list or icon view, "Where it lives" column, hover actions, state-aware menus, inspector, activity pill.
- **Activity**: Needs you cards with in-place fixes, throughput chart, now/next/done list with reorder and per-item pause, connection and 24-hour cards.
- **Time Travel**: Past versions (snapshot timeline, folder as it was, compare and restore) and Recently deleted; the hidden-snapshots state turns the folder on through the Hetzner API.
- **Backups**: job cards with run history and countdown; the New backup window is one sentence of tokens with a real first-run scan.
- **Setup windows** (own `Window` scenes): Add storage (smart field), Connect Hetzner, Connect server, Encryption, Share, New backup.
- **Settings**: toolbar tabs General, Storage, Transfers, Privacy (network map from the real contact ledger), About.

## Components

`StatusKit.swift` holds every status view; use them rather than drawing new ones: `FileStateBadge`, `HealthOrb`, `SignalBars`, `ProgressRing`, `CapacityBar`, `ThroughputChart`, `Sparkline`, `RunHistoryDots`, `CountdownRing`, `SnapshotTimeline`, `HostKeyIdenticon`, `CacheDonut`, `StrengthMeter`, `StorageAvatar`, `StepDots`, plus `SectionLabel`, `IconTile`, `.contentCard()` and `.statusCard(_:)`. Problems carry their fix (`Issue.Fix` → `AppModel.resolve`), shown idle → working → fixed → collapsed.

## Do's and Don'ts

Do:
- Use system controls, SF Symbols and system colours first.
- Render cached rows before the network answers.
- Say what is true: "Checked 11:26 PM", "Not checked yet", "Not available in this version".
- Label demo mode on screen whenever it is active.

Don't:
- Show a verified badge, a speed, an ETA, a capacity or a file that came from nowhere.
- Use a colour alone to carry status.
- Put glass on rows, cards, forms or the inspector, or glass on glass.
- Show a hostname, account ID or raw snapshot name as a primary label.
- Fake glass with arbitrary opacity; use `glassEffect`, `GlassEffectContainer`, the glass button styles, or the system's own glass.
- Add custom switches, sketch illustrations, or glass that does not float.
- Present a setting as working when the engine ignores it.
