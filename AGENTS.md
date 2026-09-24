# Agent rules — Deylee

A local-first macOS menu-bar time tracker. One SwiftPM package at the repo root, two
targets, no remote dependencies. Read [README.md](README.md) for what the app does;
this file is only what an agent needs before touching the code.

## Commands

```sh
swift build                  # compile DeyleeKit and the app
./scripts/test.sh            # the suite — NEVER bare `swift test`
./scripts/make-app.sh        # dist/Deylee.app (release; pass `debug` for loopback API)
```

`swift test` fails with `no such module 'Testing'`: the Command Line Tools ship
`Testing.framework` but leave it off SwiftPM's search paths, and `scripts/test.sh`
passes the framework and rpath flags. That is the environment, not the code — do not
"fix" it in the package manifest.

Run a build against a throwaway database, never your real history:

```sh
DEYLEE_DATA_DIR=/tmp/deylee-test ./dist/Deylee.app/Contents/MacOS/Deylee
```

The real store is `~/Library/Application Support/deylee/deylee.sqlite`, lower-case
`deylee` deliberately — it is the Electron build's path, so existing history opens
untouched. Never migrate it, rename it, or write test data into it.

## Layout and the one boundary

```
Sources/DeyleeKit/     platform-free core: models, time maths, SQLite store, engine
Sources/Deylee/        the app: status item, panel, windows, idle/power monitors
Sources/CSQLCipher/    vendored SQLCipher amalgamation
Tests/DeyleeKitTests/  the core's suite (Swift Testing)
docs/                  MAC_REWRITE_SPEC.md (binding), DESIGN.md (binding, visual)
```

**`DeyleeKit` imports no AppKit and no SwiftUI.** That is what keeps the engine
testable without a window and leaves an iOS companion possible. Anything with a
lifetime — `NSStatusItem`, panels, monitors, the login item — lives in `Deylee`.

Both `docs/MAC_REWRITE_SPEC.md` and `docs/DESIGN.md` are binding. User-visible strings
and window dimensions quoted there are exact; reproduce them verbatim rather than
improving them.

## Rules that are not negotiable

- **No remote dependencies.** `Package.swift` resolves nothing over the network:
  SQLCipher is vendored as C, Sparkle as a prebuilt xcframework in `Vendor/`. Adding a
  `.package(url:)` breaks a clean build with the Command Line Tools alone. The manifest
  is also read on Linux, so macOS-only targets stay inside `#if os(macOS)`.
- **No telemetry, no analytics, no crash reporting.** Sync sends days and segments —
  start, end, work or break — and nothing else. Screen captures have no upload path;
  keep it that way.
- **Totals are derived, never stored.** Sum stored segments on every tick. Do not add a
  counter to accumulate — that is what drifts across sleep, a clock change and midnight.
- **Instants are UTC epoch milliseconds; local time is a rendering concern only.** Day
  boundaries use `Foundation.Calendar` arithmetic. Never add 86,400,000 ms to get the
  next day — a DST day is 23 or 25 hours and the suite will catch you.
- **Segments never overlap, and intervals are half-open `[start, end)`.** One segment
  open app-wide at a time.
- **No colour literals outside `Sources/Deylee/DesignTokens.swift`.** Add a token there.
  The green accent is reserved for the running state and appears nowhere else.
- **Migrations run forwards only.** They are ordered, transactional and idempotent, and
  the schema is shared with the Electron build. Never edit a migration that shipped.

## Tests

Swift Testing (`@Test`, `#expect`), in `Tests/DeyleeKitTests/`. The suite pins its time
zones — Europe/Berlin for the 23- and 25-hour days, America/Santiago for a midnight that
does not exist — rather than inheriting the machine's. Build expected instants from
calendar components, never by adding fixed offsets: adding offsets is the bug these
tests exist to catch.

Non-trivial domain logic lands with a test. UI does not.

## Commits, branches, pull requests

Work happens on a branch and lands through a pull request. **Never commit to `main`.**

- `feat/<short-name>` for a feature, `fix/<short-name>` for a bug, `docs/<short-name>`
  for documentation. One branch per change; open the PR into `main`.
- Conventional Commits, enforced by the dependency-free `.husky/commit-msg` hook.
  Types: `feat fix perf refactor docs test chore build ci style revert`.
  Scopes: `mac server web db domain timer tray platform windows panel mini history
  settings updater icons build deps docs ci`.
- Header ≤ 72 characters, description in lower case, no trailing full stop, body lines
  ≤ 100 characters. The description becomes a changelog entry, so its shape is not
  cosmetic.
- **No AI attribution anywhere in git history** — no `Co-Authored-By` trailer, no
  "generated with" footer in a commit or a PR body. The hook rejects them.
- `CHANGELOG.md` is written by hand, in prose, for users rather than for developers.
  Update it for anything a user would notice; skip it for refactors and docs.

## The sync API

The Python sync API is in `server/` — its own package (uv, Docker), deployed at
`api.faizraza.me`. It moved here from the `deylee-ios` monorepo with its history, so
an auth or wire change to the app and the API can land in one pull request.

```sh
./server/scripts/dev-db.sh       # throwaway Postgres on 127.0.0.1:5433, full schema
DEYLEE_TEST_DB_URL='postgresql://deylee_api_user:devpassword@127.0.0.1:5433/postgres' \
  ./server/scripts/test-server.sh
```

Without `DEYLEE_TEST_DB_URL` the database suites skip rather than fail, so a green run
without it proves nothing about row-level security or the auth functions. Point it at
the restricted login, never `postgres`, which bypasses RLS and passes everything.

Migrations in `server/supabase/migrations/` follow the same rule as the app's: forwards
only, never edit one that shipped. Changing a function's arguments means a new migration
that drops the old signature, and giving the new argument a default keeps an API that
has not deployed yet working against it.

## The other repository

The marketing site and the product docs are still in the `deylee-ios` monorepo, checked
out beside this one at `../deylee`:

```
web/               the Next.js marketing site
docs/PRODUCT.md    what the product is, who buys it, what we refuse to build
docs/SYNC_PROTOCOL.md   the binding wire contract, shared by every client
apps/macos/        STALE — a snapshot from the monorepo split; this repo is the app
server/            STALE — moved here; the copy there is no longer the source
```

`docs/SYNC_PROTOCOL.md` over there binds anything touching `SyncService.swift`,
`APIClient.swift`, `AuthService.swift` or `server/` — read it before changing a payload.
Never read `apps/macos/` or `server/` there for current behaviour.

A debug bundle points at `http://127.0.0.1:8081` and a release at
`https://api.faizraza.me`; `scripts/make-app.sh` writes the value into the bundle's
`Info.plist`, so the plist in git is not the answer to which API a build talks to.

## Notes about one machine

This file is shared. Anything true only of one person's setup — where Docker runs, a
toolchain that is missing, a local path — goes in `AGENTS.local.md` at the repository
root, which is gitignored; `CLAUDE.local.md` imports it for Claude Code the way
`CLAUDE.md` imports this file. Read it if it exists, and never copy it in here.
