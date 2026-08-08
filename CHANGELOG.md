# Changelog

Entries follow [Semantic Versioning](https://semver.org). While Deylee is pre-1.0 the
SQLite schema may still change, so a minor bump can carry a migration.

## 0.2.0 — 2026-08-09 (pre-release)

Integrity, top to bottom — because the store lives on a machine its owner controls,
and a tracker sold to companies has to be honest about what that means.

### The local store is now encrypted

- The SQLite file on disk is SQLCipher-encrypted with a key generated on this Mac and
  kept in the Keychain — never in the app, never on disk in the clear. Opening the
  file in a SQLite browser now shows random bytes, where before a row could be edited
  or deleted freely.
- An existing store migrates itself the first time this version opens it; a fresh
  install is encrypted from the start. Backups you export stay plaintext and portable,
  because a backup only this Mac could open would be no backup at all.
- The honest limit: the machine's owner can still recover the key from their own
  Keychain. Encryption stops the casual file edit, not its owner — which is why the
  server no longer takes the client's word for anything.

### The server stops trusting the client

- **Bounds.** Absurd hours are refused outright — a segment over sixteen hours, a
  time in the future.
- **Marks.** Editing or deleting hours that already synced, or filing hours days after
  the fact, leaves an indelible note in a place no client — not even one wielding its
  own token — can reach or erase. Editing stays allowed; it simply stops being
  invisible.
- **Witnessed time.** While a timer runs, the app quietly tells the server "still
  here", and the server records the time by its own clock. Hours a live client was
  seen working cannot be manufactured after the fact. What leaves the machine is still
  only hours — never app names, titles, or screenshots.

### Also

- Sign-in no longer occasionally hangs forever when the database is briefly
  unreachable; it fails cleanly and can be retried.

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
