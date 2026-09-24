# Contributing to Deylee

Thanks for looking. Deylee is pre-1.0 and every surface is built but barely lived with, so
bug reports from real use are worth more than features right now.

## Reporting a bug

Open an issue with your macOS version, how you installed the app, and what the timer did
versus what you expected. If it involves a total that looks wrong, say what time zone you
are in and whether the day crossed midnight or a DST change — that is where the awkward
cases live.

Please do not paste your `deylee.sqlite`; it is your entire work history. A CSV export of
the affected day, from the History window, is enough.

## Setting up

```sh
git clone https://github.com/faizrazadec/deylee.git
cd deylee
git config core.hooksPath .husky   # enables the commit-message check
swift build
./scripts/test.sh
```

You need macOS 14 or newer and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode is not needed, and nothing is fetched at build time.

Run a development build against a throwaway database rather than your own history:

```sh
./scripts/make-app.sh debug
DEYLEE_DATA_DIR=/tmp/deylee-test ./dist/Deylee.app/Contents/MacOS/Deylee
```

Use `./scripts/test.sh`, not bare `swift test` — the Command Line Tools ship
`Testing.framework` but leave it off SwiftPM's search paths, and the script passes the
flags that fix it.

## Where things go

| | |
|---|---|
| `Sources/DeyleeKit/` | the core: models, time maths, SQLite, repository, timer engine. No AppKit, no SwiftUI. |
| `Sources/Deylee/` | the app: status item, panel, windows, idle and power monitors. |
| `Tests/DeyleeKitTests/` | the core's suite, Swift Testing. |
| `docs/` | [`MAC_REWRITE_SPEC.md`](docs/MAC_REWRITE_SPEC.md) is binding on behaviour, [`DESIGN.md`](docs/DESIGN.md) on visuals, [`INTERNALS.md`](docs/INTERNALS.md) explains the reasoning. |

Two constraints worth knowing before you write anything:

- **`DeyleeKit` stays platform-free.** The boundary is what makes the engine testable
  without a window, and what would let an iOS companion reuse it later.
- **No remote dependencies.** `Package.swift` resolves nothing over the network. SQLite is
  vendored C and Sparkle is a checked-in xcframework. A pull request that adds a package
  dependency needs to argue for it first, in an issue.

## Commits

Conventional Commits, checked by `.husky/commit-msg` — a plain shell script, no Node. The
rules it enforces:

- `<type>(<optional scope>): <description>`
- types: `feat fix perf refactor docs test chore build ci style revert`
- scopes: `mac server web db domain timer tray platform windows panel mini history settings updater icons build deps docs ci`
- the header is at most 72 characters
- the description starts in lower case and does not end with a full stop
- body lines are at most 100 characters, except a bare URL
- no AI attribution trailers

The description becomes the changelog entry, so write it as the line a user would read.

## Pull requests

- One change per pull request, and say what it does in the body rather than leaving the
  diff to explain itself.
- Anything touching `DeyleeKit` needs a test. Time maths especially: the suite pins
  Europe/Berlin and America/Santiago so DST and a missing midnight are exercised on every
  run, and a change that survives those is a change that survives a user's calendar.
- `./scripts/test.sh` passes.
- Behaviour that contradicts [`docs/MAC_REWRITE_SPEC.md`](docs/MAC_REWRITE_SPEC.md) needs
  the spec changed in the same pull request, with the reasoning. The spec is binding; it is
  not a record of what the code happens to do.
- [CHANGELOG.md](CHANGELOG.md) is maintained by hand, so add an entry for a user-visible
  change.

## Licence

Contributions are MIT, the same as the rest of the project.
