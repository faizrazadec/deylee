# Agent rules — Deylee

A local-first macOS menu-bar time tracker. The app is one SwiftPM package at the repo
root with no remote dependencies; the Python sync API behind it is in `server/`. Read
[README.md](README.md) for what the app does; this file is only what an agent needs
before touching the code.

## Commands

```sh
swift build                  # compile DeyleeKit and the app
./scripts/test.sh            # the suite — NEVER bare `swift test`
./scripts/make-app.sh        # dist/Deylee.app (release; pass `debug` for loopback API)
./server/scripts/test-server.sh   # the API's suite — see "The sync API" for the DB gate
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
server/                the Python sync API (see "The sync API" below)
docs/                  MAC_REWRITE_SPEC.md (binding), DESIGN.md (binding, visual),
                       SYNC_PROTOCOL.md (binding, wire), PRODUCT.md (what we build)
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
- **No telemetry, no analytics, no crash reporting.** Exactly three things leave the
  machine: sync (days and segments — start, end, work or break), a heartbeat carrying
  only the device id every 30 seconds while a timer runs, and feedback the user chooses
  to send. Screen captures have no upload path. Keep it that way, and if any of it
  changes, change the privacy sections of `README.md` and `docs/INTERNALS.md` with it.
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

Non-trivial domain logic lands with a test. UI does not. A change under `server/` lands
with a server test, run against the dev database (see "The sync API").

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

**Two schemas have to agree:** `Sources/DeyleeKit/Migrations.swift` for the local store
and `server/supabase/migrations/` for the server. Change a column in one and not the
other and sync breaks in a way that is awkward to trace.

The API reads `server/.env` (untracked; `server/.env.example` documents every variable).
`DEYLEE_ENV_FILE` names the file and defaults to `./.env`, which from the repository root
is the wrong one:

```sh
DEYLEE_ENV_FILE=$PWD/server/.env uv run --project server python -m deylee_api
```

Two commands care where you stand: `supabase db push` runs from `server/`, and the image
builds from the repository root, which is the context the Dockerfile's `COPY` lines and the
root `.dockerignore` are written against. `compose.yaml` at the root is how production
builds and runs the API and its tunnel (`docker compose build api`, then
`docker compose up -d --no-deps api`). Its project name is pinned to `deylee-s` so it
adopts the running stack; do not change it.

### Production is not yours to touch

**Never build, rebuild, stop, restart or redeploy the production API, or push a
migration to the production database, unless the person you are working for asks for
it in those words.** It serves every customer's sync and the appcast every installed
copy of the app updates from; taking it down stops people working and stops the product
being able to fix itself. Writing a Dockerfile is not permission to run it, and a green
suite or a certainly-correct fix is not permission to ship it. The same goes for editing
the production `.env`: it is untracked, and a wrong value there shows in no diff. Prove a
change on the dev API and the dev database; how production itself is run belongs in the
operator's local notes, not in this file.

## The wire contract, and the other repository

`docs/SYNC_PROTOCOL.md` binds anything touching `SyncService.swift`, `APIClient.swift`,
`AuthService.swift` or `server/` — six clients implement it, so read it before changing
a payload, and change it in the same pull request as any behaviour that departs from it.
`docs/PRODUCT.md` says what the product is and what it refuses to build; the code cites
its sections, so keep the numbering.

Only the marketing site is still elsewhere, in the private `deylee-ios` monorepo checked
out beside this one at `../deylee`. Everything else there is stale:

```
web/               the Next.js marketing site — the one live thing left there
apps/macos/        STALE — a snapshot from the split; this repository is the app
server/            STALE — moved here with its history
docs/              STALE — SYNC_PROTOCOL.md and PRODUCT.md moved here
```

This repository is public and that one is not. Nothing from there comes here without
being read for what it would publish: strategy stays in the gitignored
`docs/STRATEGY.md`, and operator details — hosts, local paths, how production is run —
stay in local notes.

A debug bundle points at `http://127.0.0.1:8081` and a release at
`https://api.faizraza.me`; `scripts/make-app.sh` writes the value into the bundle's
`Info.plist`, so the plist in git is not the answer to which API a build talks to.

## Notes about one machine

This file is shared. Anything true only of one person's setup — where Docker runs, a
toolchain that is missing, a local path, how production is operated — goes in
`AGENTS.local.md` at the repository root (any `*.local.md` is gitignored);
`CLAUDE.local.md` imports it for Claude Code the way `CLAUDE.md` imports this file. Read
it if it exists, and never copy it in here.
