# Changelog

Entries follow [Semantic Versioning](https://semver.org). While Deylee is pre-1.0 the
SQLite schema may still change, so a minor bump can carry a migration.

## 0.1.0 — 2026-08-08 (pre-release)

The first build of Deylee to leave the machine it was written on. Pre-release means
exactly that: it is signed ad hoc, not notarised, so macOS will warn before the first
launch, and it is for people who were handed it knowingly — not an announcement.

### The app

- A menu-bar timer: start, pause and end a working day from the tray or the panel,
  with a floating mini timer for keeping the clock in view.
- Day targets with a live countdown; totals are recomputed from stored segments, so
  sleep, clock changes and midnight cannot drift them.
- A history window over every recorded day.
- Everything works offline, always. The store is SQLite on this machine; no feature
  waits on the network.

### Accounts and sync

- Sign in with Google, or create an account with an email address and a six-digit
  code mailed to it. The two link: either route into the same address lands on the
  same account.
- Signing in is asked for when a day starts, not at launch, and can be declined —
  the timer keeps working locally and the first sign-in claims that history.
- Background sync to the Deylee API, so a log follows its owner between machines.
  Only hours ever leave the machine — no app names, no titles, no screenshots.

### Known limits, honestly

- Google sign-in is restricted to invited test accounts until the OAuth consent
  screen is published; email sign-up is open.
- No auto-update. A newer build replaces the app by hand.
