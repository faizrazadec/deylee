# Dayly

A local-only desktop time tracker that lives in your tray. Start the day, pause for a
coffee, end the day — Dayly keeps the running total in the menu bar or system tray and
the full history in a window you can edit.

macOS, Windows and Linux, from one Electron codebase.

---

## Local-only, and that is the whole point

- **No accounts.** There is nothing to sign up for and nothing to sign in to.
- **No cloud.** Your hours never leave the machine they were recorded on.
- **No telemetry.** No analytics, no crash reporting, no "anonymous usage data".
- **Exactly one network request, and it is yours to switch off.** Dayly checks GitHub
  Releases for a newer version. That is the whole of its network activity. It is a
  version comparison against a public feed: it sends nothing about you, no identifier,
  no payload, and it downloads nothing until you say so. Settings → **Updates** turns it
  off, and with it off Dayly opens no sockets at all.
- **The UI cannot reach the network even so.** Packaged renderers run under a
  Content-Security-Policy with `connect-src 'none'`; the update check lives in the main
  process, where you can read it.
- **No hidden capabilities.** Every permission request (camera, microphone, geolocation,
  …) is refused outright by the main process.

Everything lives in one SQLite file you own, can copy, can inspect with any SQLite
browser, and can delete.

### Where your data lives

The database sits in Electron's `userData` directory:

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/dayly` |
| Windows | `%APPDATA%\dayly` (i.e. `C:\Users\<you>\AppData\Roaming\dayly`) |
| Linux | `~/.config/dayly` |

Inside it:

- `dayly.sqlite` — every day and every segment. WAL mode, so you will also see
  `dayly.sqlite-wal` and `dayly.sqlite-shm` while the app is running.
- `preferences.json` — settings, written by `electron-store`.

Settings → **Data** shows the folder, reveals it in Finder/Explorer/your file manager,
and takes a one-click backup.

---

## Requirements

- **Node.js 22 or newer** (Vite 7 and electron-vite 5 need `^20.19` or `>=22.12`).
- **A C++ toolchain**, because `better-sqlite3` is a native addon compiled against
  Electron's ABI:
  - **macOS** — Xcode Command Line Tools: `xcode-select --install`
  - **Windows** — [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/)
    with the *Desktop development with C++* workload
  - **Linux** — `sudo apt install build-essential python3` (or your distro's equivalent)

## Getting started

```sh
npm install      # postinstall runs `electron-builder install-app-deps`, which rebuilds
                 # better-sqlite3 against Electron's V8 ABI rather than the host Node's
npm run icons    # generates build/icon.png and resources/tray/** (committed, so this is
                 # only needed after changing the generator)
npm run dev      # electron-vite dev, with HMR in all four renderer windows
```

Then, before you commit anything:

```sh
npm run typecheck   # tsc over the node (main + preload) and web (renderer) projects
npm test            # vitest, pinned to Europe/Berlin so DST days are exercised
npm run build       # typecheck + electron-vite build into out/
```

### All scripts

| Script | What it does |
|---|---|
| `npm run dev` | Dev server + Electron with HMR |
| `npm start` | `electron-vite preview` — runs the built output without packaging |
| `npm run build` | Typecheck, then build `out/main`, `out/preload`, `out/renderer` |
| `npm run typecheck` | `typecheck:node` + `typecheck:web` |
| `npm test` / `npm run test:watch` | Vitest over `tests/` |
| `npm run icons` | Regenerate the app icon and tray artwork (pure Node, no deps) |
| `npm run rebuild` | Rebuild native modules for the current Electron version |
| `npm run dist` | Build + package for the current OS |
| `npm run dist:mac` / `:win` / `:linux` | Build + package for that OS |
| `npm run dist:dir` | Package unpacked only — fastest way to smoke-test a real build |
| `npm run release:dry` | Show the version the next release would cut, and why |
| `npm run release` | Bump `package.json`, write `CHANGELOG.md`, commit, tag |

---

## Packaging

Artefacts land in `release/`.

```sh
npm run dist:mac     # dmg, arm64 and x64
npm run dist:win     # NSIS installer + portable exe, x64 and arm64
npm run dist:linux   # AppImage + deb, x64
```

| Command | Produces |
|---|---|
| `dist:mac` | `Dayly-0.1.0-arm64.dmg`, `Dayly-0.1.0.dmg`, plus `mac-arm64/Dayly.app` and `mac/Dayly.app` |
| `dist:win` | `Dayly Setup 0.1.0.exe` (one installer covering both architectures), `Dayly 0.1.0.exe` (portable), plus `win-unpacked/` and `win-arm64-unpacked/` |
| `dist:linux` | `Dayly-0.1.0.AppImage`, `dayly_0.1.0_amd64.deb`, plus `linux-unpacked/` |

The number in every filename is `version` in `package.json`, so it moves with each
release.

**Build each platform on that platform.** electron-builder cannot cross-compile to macOS
or Windows from another OS without extra tooling — macOS targets need macOS (for the
codesign toolchain and `hdiutil`), and Windows targets need Windows or Wine. Use three
machines, or three CI runners.

Signing is unconfigured, on purpose and at a cost — see *Updates and signing* below. With
no certificate in the keychain, macOS builds are left unsigned and Gatekeeper needs a
right-click → Open on first launch. If you opt into ad-hoc signing (`mac.identity: "-"`)
you will also need `com.apple.security.cs.disable-library-validation` in
`build/entitlements.mac.plist`, because hardened runtime then rejects the pre-signed
Electron framework.

---

## Releasing

The version is derived from commit messages, so releasing starts at commit time:
Conventional Commits, enforced by `commitlint` in a husky hook. The types, the scopes and
what each one bumps are in [CLAUDE.md](CLAUDE.md) — read it before your first commit, not
before your first release.

```sh
npm run release:dry     # show the version it would cut, and why
npm run release         # bump package.json, write CHANGELOG.md, commit, tag
git push --follow-tags  # the tag is what triggers CI
```

Never hand-edit `version` in `package.json` and never hand-edit `CHANGELOG.md` —
`commit-and-tag-version` owns both.

Pushing the `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds on macOS, Windows and Linux runners and publishes, to the GitHub Release,
the installers **and** the `latest.yml` / `latest-mac.yml` / `latest-linux.yml` manifests
that electron-updater polls.

> **Never upload artifacts to a Release by hand.** Those manifests are the entire update
> feed. A Release that has installers but no `latest*.yml` looks complete on the Releases
> page and updates nobody — every existing install keeps reporting itself up to date.

### Version numbers

Dayly starts at **0.1.0** and stays pre-1.0 for one reason: the SQLite schema can still
change. While the major is `0`, a breaking change bumps the minor rather than the major,
which is the honest signal that on-disk compatibility is not yet promised. **1.0.0 gets
cut when the schema stabilises**, and from then on a schema change is a major bump.

## Updates and signing

Dayly ships unsigned, which is free and has a specific, unglamorous price:

| Platform | Auto-update | What it costs to fix |
|---|---|---|
| **Windows** | Works, unsigned. But SmartScreen warns on first install ("Windows protected your PC" → *More info* → *Run anyway*), and the warning reappears for a while after each new signing identity. | An OV code-signing certificate, roughly **$200–400/year**, or **Azure Trusted Signing** at about **$10/month** for an individual or small business. |
| **macOS** | **Does not work at all.** Squirrel.Mac, which is what electron-updater drives on macOS, refuses to apply an update to a build that is not signed and notarised. Until that changes, Dayly's update panel links to the Releases page and you drag the new `.dmg` across yourself. | An **Apple Developer Program membership, $99/year**, plus notarisation in CI (an app-specific password or an API key, and a few minutes per build). |
| **Linux** | The **AppImage auto-updates fine**, unsigned. The **`.deb` has no updater** — reinstall the new package to upgrade. | Nothing. |

The update check itself is a preference (Settings → **Updates**) and is a check only: a
download starts when you click, and installing is a second click. On the platforms that
cannot self-update, Dayly says so rather than pretending — no silent no-op progress bar.

---

## How it behaves on each OS

**macOS** — a true menu-bar app. `LSUIElement` is set and the dock icon is hidden, so
Dayly never appears in the dock or in Cmd-Tab. The menu-bar item shows a template icon
plus a live `H:MM` label that ticks every second while you are working.

**Windows** — the tray icon itself encodes the state, because it is the only thing
always on screen: a hollow ring when idle, a filled ring while running, a ring with a
pause bar when paused. The numbers live in the tooltip
(`Dayly — 6:24 worked · 0:45 break`), refreshed every 30 seconds.

**Linux** — the tray uses StatusNotifierItem. Because plenty of desktops ship without a
host for it, Dayly probes for one at startup; if none is found it turns the always-on-top
mini-window on automatically and tells you once why. Nothing is lost — the mini-window
carries the same timer and primary action.

The mini-window is on by default on Windows and Linux, off on macOS (the menu-bar label
already does that job). It remembers its position per display.

---

## Architecture

```
src/shared/   types, the IPC contract, local-calendar time maths
src/domain/   pure logic: durations, midnight splitting, overlap rules, recovery plans
src/main/     Electron main process — db, services, tray, windows, IPC handlers
src/preload/  the contextBridge, exposing exactly one object on window.dayly
src/renderer/ four independent React roots: panel, mini, history, settings
```

- **Main / preload / renderer are strictly separated.** Every window runs with
  `contextIsolation: true`, `nodeIntegration: false` and `sandbox: true`. Renderers never
  import `electron` or a Node built-in; the only thing they can reach is `window.dayly`,
  whose surface is declared once in `src/shared/ipc.ts`. The IPC handlers are the trust
  boundary: they validate every argument and never throw across the bridge.
- **The `Platform` abstraction owns every OS difference.** All `process.platform`
  branching in the codebase lives in `src/main/platform/`, behind one interface —
  tray rendering, window quirks, login items, revealing a folder. Nothing else asks
  which OS it is on.
- **Totals are always derived from segments, never stored.** There is no counter to
  drift and no total to go stale. Every number you see is the sum of stored spans,
  recomputed on a 1-second tick from timestamps, which is what makes the display correct
  across a crash, a restart, a machine sleep or a manual edit.

## The awkward cases, and what Dayly does about them

- **Crash or force-quit.** While a segment is open the main process writes a heartbeat
  every 30 seconds. On the next launch, an open segment is surfaced with the choice to
  resume it, close it at the last heartbeat (keeping the time up to that point), or
  discard it. A segment that was open for less than a second is dropped silently rather
  than interrupting you.
- **Midnight.** A segment that crosses local midnight is split into one piece per
  calendar day, so every stored segment belongs to exactly one day. A 1-second timer in
  the main process performs the split even if you never touch the app.
- **Time zones and DST.** Instants are stored as UTC epoch milliseconds and *only*
  rendered in local time. Day boundaries are computed with local calendar arithmetic, so
  a 23-hour or 25-hour DST day is handled correctly rather than by adding 86,400,000 ms.
- **Overlaps.** Segments may never overlap — not from the timer, not from a manual edit.
  Intervals are half-open (`[start, end)`), so one segment ending exactly when the next
  begins is the normal pause/resume shape, not a conflict. Rejected edits come back as a
  readable message naming the segment they collide with.
- **Sleep, lock and idle.** Sleeping or locking closes the open work segment; on wake you
  choose whether the gap was a break or nothing at all. Going idle past your threshold
  prompts to keep or drop the idle stretch. Both prompts appear in the panel as well as
  in a system notification, so dismissing a notification never loses the decision.
- **Installing an older build over a newer database.** Migrations run forwards only, so
  an older build cannot understand a file a newer one wrote. Rather than opening it
  anyway — writing rows the newer schema no longer matches and quietly discarding columns
  it does not know about — Dayly refuses to start and says which version wrote the file.
  Your history is untouched; install the newer build again, or move the `.sqlite` file
  aside to start fresh.
- **Two copies of the app.** A single-instance lock means launching Dayly again just
  focuses the existing panel.
- **Closing windows.** Closing every window does not quit — it is a tray app. Quit from
  the tray menu.

## Data model

Two tables carry the data:

- `days` — one row per local calendar date, with the daily target snapshotted at
  creation and an `ended_at` that is set by *End Day* and cleared if you start again.
- `segments` — one row per span of `work` or `break`, with `ended_at NULL` meaning
  "still open". At most one segment is open app-wide at a time.

Plus two bookkeeping tables: `app_state` (the heartbeat) and `schema_version`, which
drives ordered, transactional, idempotent migrations — and which is also the downgrade
guard: a stored version *higher* than the running build supports is refused rather than
migrated backwards.

**Export** (History → Export) writes the visible range as:

- **CSV** — `date, segment_type, started_at_local, ended_at_local, duration_minutes,
  started_at_utc_ms, ended_at_utc_ms, note`. Both local and UTC columns are present so a
  spreadsheet is readable and a re-import is exact.
- **JSON** — `{ exportedAt, range, days: [{ date, targetMinutes, totals, segments }] }`,
  pretty-printed.

**Backup** (Settings → Data) uses SQLite's online backup API, so it is safe to take while
the timer is running and while WAL is active. Restoring is a file copy: quit Dayly, drop
the `.sqlite` file back into the data folder, start it again.

---

## Troubleshooting

**`NODE_MODULE_VERSION` mismatch when the app starts.**
better-sqlite3 was compiled for a different ABI — usually after upgrading Electron or
Node, or after copying `node_modules` between machines. Rebuild it:

```sh
npm run rebuild
```

**Dayly refuses to start, saying the database was written by a newer version.**
You installed an older build over a database a newer one wrote, and it stopped rather
than corrupt your history. Install the newer version again — your data is exactly as you
left it. If you genuinely want the older build, move `dayly.sqlite` out of the data
folder first (see *Where your data lives*); it will start with an empty database and you
can keep the old file as an archive.

**No tray icon on Linux.**
Your desktop has no StatusNotifierItem host. Dayly switches the mini-window on
automatically, but to get the real tray back install the AppIndicator support package:

```sh
sudo apt install libayatana-appindicator3-1     # Debian / Ubuntu
```

On GNOME you will also need the *AppIndicator and KStatusNotifierItem Support*
extension. Log out and back in afterwards.

**The deb installs but the app will not start.**
The `.deb` declares the GTK and notification libraries it needs; if `apt` skipped
recommends, install them explicitly with the command above.

**Nothing was tracked while I was away.**
That is deliberate. Dayly records only what it can account for — see *The awkward cases*
above for the sleep, lock and idle prompts that decide what a gap becomes.

---

## Licence

MIT © Faiz Raza
