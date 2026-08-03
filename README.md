# Dayly

A local-only time tracker that lives in the macOS menu bar. Start the day, pause for a
coffee, end the day — Dayly keeps the running total beside the clock glyph and the full
history in a SQLite file you own.

Native Swift, SwiftUI and AppKit. Dayly used to be an Electron app for macOS, Windows
and Linux; that build has been removed — it survives in git history alone. The app
lives in `macos/`, targets macOS only, and is specified in
[`docs/MAC_REWRITE_SPEC.md`](docs/MAC_REWRITE_SPEC.md), which is binding.

---

## Local-only, and that is the whole point

- **No accounts.** There is nothing to sign up for and nothing to sign in to.
- **No cloud.** Your hours never leave the machine they were recorded on.
- **No telemetry.** No analytics, no crash reporting, no "anonymous usage data".
- **No network requests at all.** The Electron build made exactly one — a
  preference-gated version check against GitHub Releases. The rewrite has not brought
  even that back yet: there is no update code in the Swift app and no other networking
  either. Grep `macos/Sources/` for `URLSession` and you will find nothing. If an
  update check returns it will be the same deal as before — a version comparison
  against a public feed, no identifier, no payload, off by a single preference — but
  today the honest statement is simpler: Dayly opens no sockets.

Everything lives in one SQLite file you own, can copy, can inspect with any SQLite
browser, and can delete.

### Where your data lives

The database is `~/Library/Application Support/dayly/dayly.sqlite` — and that path is
deliberate down to the lower-case `dayly`. It is exactly where the Electron build kept
its database, so an existing user's history opens untouched, with nothing to import
and nothing to migrate. The file is in WAL mode, so `dayly.sqlite-wal` and
`dayly.sqlite-shm` sidecars sit beside it while the app runs; the newest commits live
in the `-wal` file, which is why a copy of the `.sqlite` file alone can silently miss
them — copy all three, or use the online-backup API (see *Data model*).

Preferences moved: the Swift app stores them in `UserDefaults` under the
`me.faizraza.dayly` domain, validated and clamped on every read and write. The
`preferences.json` the Electron build wrote still sits beside the database, but the
app does not read it — it is a leftover.

---

## Requirements

- **macOS 14 or newer.**
- **The Xcode Command Line Tools** — `xcode-select --install`. Full Xcode is not
  needed; the package builds with the Command Line Tools alone.
- **Swift 6**, which current Command Line Tools ship.

That is the whole list. No Node.js, no C++ toolchain, no `better-sqlite3` to rebuild
against anyone's ABI. There are **zero third-party dependencies**: `Package.swift`
declares none, SQLite comes from the system (`import SQLite3`), and the UI is
SwiftUI and AppKit. Nothing to audit, nothing to bump, nothing that can drift.

## Getting started

```sh
cd macos
swift build            # compile DaylyKit and the app
./scripts/test.sh      # run the suite — NOT bare `swift test`, see below
./scripts/make-app.sh  # assemble dist/Dayly.app (release by default; pass `debug`)
```

`./scripts/test.sh` exists because the Command Line Tools ship `Testing.framework`
and `lib_TestingInterop.dylib` but do not put them on SwiftPM's search paths, so bare
`swift test` fails with `no such module 'Testing'`. The script passes the framework
and rpath flags explicitly; that is the environment, not the code.

The suite pins its time zones rather than inheriting the machine's: Europe/Berlin
(one 23-hour and one 25-hour day a year) and America/Santiago (a midnight that does
not exist), so DST is exercised on every run.

To point a development run at a throwaway store instead of your real history:

```sh
DAYLY_DATA_DIR=/tmp/dayly-test ./dist/Dayly.app/Contents/MacOS/Dayly
```

### Packaging

SwiftPM produces a bare binary, and a menu-bar app needs a bundle — `LSUIElement`
and the bundle id only apply inside one. `./scripts/make-app.sh` builds, copies
`Resources/Info.plist`, renders `AppIcon.icns` from the repo's generated icon master,
and ad-hoc signs the bundle so Gatekeeper and TCC treat it as a stable identity. The
result is `macos/dist/Dayly.app`.

---

## What is built, and what is not yet

Every surface is built. What is missing is everything downstream of shipping it.

| Surface | Status |
|---|---|
| `DaylyKit` — models, time maths, SQLite store, repository, timer engine | Complete, with the test suite ported |
| Menu-bar item — live `H:MM` title, tooltip, context menu | Built |
| Panel — timer, target progress, today's segments | Built |
| History window — calendar, roll-ups, manual edits, CSV/JSON export | Built |
| Settings window | Built |
| Mini window | Built |
| Recovery / idle / wake prompt modals, end-day confirmation | Built |
| System notifications | Not built — every prompt opens the panel instead, which was always the reliable path |
| Update checking | Not built, and it needs a signed build to be worth anything |
| Signing, notarisation, distribution | Not started — see *Releasing* |

None of it has been through real use yet. The core is covered by tests; the windows
have been compiled and launched, not lived with.

---

## Architecture

```
macos/
  Sources/DaylyKit/     platform-free core: models, time maths, SQLite, repository, engine
  Sources/Dayly/        the app: status item, panel, SwiftUI views, idle/power monitors
  Tests/DaylyKitTests/  the core's suite (Swift Testing)
  scripts/              test.sh, make-app.sh
```

- **Two targets, one boundary.** `DaylyKit` is the core — segment and day models,
  DST-correct day-boundary maths, a dependency-free wrapper over the system SQLite,
  the repository, and the timer engine. It is deliberately free of AppKit and
  SwiftUI: that is what would let an iOS companion sit on the same core later, and it
  is why the engine is testable without a window. `Dayly` owns everything with a
  lifetime — the `NSStatusItem`, the non-activating panel, the idle and power
  monitors, the login item.
- **IPC collapsed away.** The Electron build was a main process, a preload bridge and
  four renderers, with every payload narrowed at a channel boundary. The Swift app is
  one process: the engine pushes snapshots into an `@Observable` model and views
  observe it. No channels, no serialisation, no trust boundary inside the app.
- **Totals are always derived from segments, never stored.** There is no counter to
  drift and no total to go stale. Every number you see is the sum of stored spans,
  recomputed from timestamps on a 1-second tick — a SwiftUI `TimelineView` in the
  panel, a timer for the menu-bar title — which is what makes the display correct
  across a crash, a restart, a machine sleep or a clock change.

## The awkward cases, and what Dayly does about them

- **Crash or force-quit.** While a segment is open the app writes a heartbeat every
  30 seconds, and once more first thing on a clean quit. On the next launch, an open
  segment that carried less than a second of time is dropped silently rather than
  interrupting you. The three-way choice for anything longer — resume it, close it at
  the last heartbeat, discard it — is asked before anything else on screen, and the
  question cannot be dismissed without answering it.
- **Midnight.** A segment that crosses local midnight is split into one piece per
  calendar day, so every stored segment belongs to exactly one day. A 1-second timer
  on the main run loop performs the split even if you never touch the app — a timer
  aimed at midnight itself would sleep through it.
- **Time zones and DST.** Instants are stored as UTC epoch milliseconds and *only*
  rendered in local time. Day boundaries are computed with `Foundation.Calendar`
  local-calendar arithmetic, so a 23-hour or 25-hour DST day is handled correctly
  rather than by adding 86,400,000 ms.
- **Overlaps.** Segments may never overlap. Intervals are half-open (`[start, end)`),
  so pause/resume closing one segment and opening the next at the same instant is the
  normal shape, not a conflict. The validation that rejects a bad manual edit with a
  readable message naming the colliding segment names it exactly as it always did.
- **Sleep and lock.** Sleeping closes the open work segment at the moment it happened
  (locking too, if you opt in — off by default, because a lock during a call is not
  always a break); an open break is left alone, since it already accounts for the
  gap. Sleep and wake come from `NSWorkspace` notifications, lock and unlock from the
  `com.apple.screenIsLocked` distributed notifications — and because none of those is
  guaranteed to arrive, a wall-clock watchdog ticks every 10 seconds and treats a
  tick that lands more than a minute late as a sleep nobody announced. On wake the
  panel opens and asks whether the gap was a break; either answer starts work again.
- **Idle.** While the timer runs, system idle time is read from `CGEventSource` every
  15 seconds and compared against your threshold. Detection is edge-triggered — one
  absence, one report, re-armed only when you return. Past the threshold the panel
  opens and asks whether to keep the idle stretch as work or drop it; dropping ends
  the segment where you stopped and opens a fresh one now, so the gap is simply absent
  from the day rather than recorded as anything.
- **Installing an older build over a newer database.** Migrations run forwards only,
  so an older build cannot understand a file a newer one wrote. Rather than opening
  it anyway, Dayly refuses to start with a dialog saying which schema version the
  file is at and which this build understands. Your history is untouched; install the
  newer build again, or move the `.sqlite` file aside to start fresh. The protocol is
  shared with the Electron build, so the two can never corrupt each other's files.
- **Two copies of the app.** LaunchServices treats an app bundle as one instance;
  opening Dayly again — from the Dock, Finder or Spotlight — just surfaces the panel.
- **Closing windows.** The panel hides when you click elsewhere; nothing quits. Quit
  lives in the menu-bar item's right-click menu.

## Data model

The schema is unchanged from the Electron build — the same file opens under either
app. Two tables carry the data:

- `days` — one row per local calendar date, with the daily target snapshotted at
  creation and an `ended_at` that is set by *End Day* and cleared if you start again.
- `segments` — one row per span of `work` or `break`, with `ended_at NULL` meaning
  "still open". At most one segment is open app-wide at a time.

Plus two bookkeeping tables: `app_state` (the heartbeat) and `schema_version`, which
drives ordered, transactional, idempotent migrations — and which is also the downgrade
guard described above.

**Export** is not available yet: it belongs to the History window, which is not
built to the formats pinned down in
[`docs/MAC_REWRITE_SPEC.md`](docs/MAC_REWRITE_SPEC.md), so a spreadsheet built on an
Electron-era export still reads. Any SQLite browser reads the file directly too.

**Backup** exists as an API (`DataStore.backup`) built on SQLite's online backup, so
it is safe to take while the timer is running and while WAL is active — unlike a
plain file copy, which can miss the newest commits sitting in the `-wal` sidecar.
Restoring is a file copy: quit Dayly, drop the `.sqlite` file back into the data
folder, start it again.

---

## Releasing

Commits are still Conventional Commits, enforced by `commitlint` in a husky hook —
the types and scopes are in [CLAUDE.md](CLAUDE.md).

Distribution of the native app is unresolved, and it is worth being precise about
why. The open prerequisite is signing and notarisation with an Apple Developer ID:
the Electron build shipped unsigned, which is exactly why it could never auto-update
— Squirrel.Mac refuses to apply an update to an unsigned build — and shipping the
rewrite unsigned would repeat that mistake. The old release pipeline
(`.github/workflows/release.yml`) still targets the retired Electron build and does
not build the Swift app. Until that is settled there is no download to point at;
build from source as described under *Getting started*.

---

## Troubleshooting

**`no such module 'Testing'` when running `swift test`.**
Expected with the Command Line Tools: they ship `Testing.framework` but do not put it
on SwiftPM's search paths. Run `./scripts/test.sh` instead, which passes the
framework and rpath flags explicitly.

**Dayly refuses to start, saying the database was written by a newer version.**
You installed an older build over a database a newer one wrote, and it stopped rather
than corrupt your history. Install the newer version again — your data is exactly as
you left it. If you genuinely want the older build, move `dayly.sqlite` out of
`~/Library/Application Support/dayly/` first; it will start with an empty database
and you can keep the old file as an archive.

**Nothing was tracked while I was away.**
That is deliberate. Dayly records only what it can account for — see *The awkward
cases* above for what a sleep, lock or idle gap becomes.

---

## Licence

MIT © Muhammad Faiz Raza — see [LICENSE](LICENSE).
