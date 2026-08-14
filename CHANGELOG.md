# Changelog

Entries follow [Semantic Versioning](https://semver.org). While Deylee is pre-1.0 the
SQLite schema may still change, so a minor bump can carry a migration.

## 0.4.1 — 2026-08-14 (pre-release)

A maintenance release. The app itself is unchanged from 0.4.0 — what was fixed is how
updates reach you and how reliably the server stays up.

- **The update dialog was showing an empty Release Notes pane.** It fetched them from a
  web page that did not exist yet at the moment the update was published. The notes
  travel with the update now, so they are always there.
- **An update could have been undownloadable for hours.** Publishing briefly exposed a
  missing-file error to the CDN in front of the download, which then served that error
  for four hours while the file sat there perfectly fine. Each release is now published
  at an address that has never been requested, so a stale answer cannot be waiting.
- **Sign-in and sync could stop working for an hour at a time.** The server reached its
  database over a route that any VPN could sever, and when that happened the service
  looked healthy while failing every request. It now takes a route that does not depend
  on it.

If you are on 0.4.0 there is nothing new in the app, and nothing you need to do.

## 0.4.0 — 2026-08-14 (pre-release)

### An account is now required to start a day

Pressing Start while signed out raises sign-in and no longer opens a day if you dismiss
it. Earlier versions let a dismissed sign-in start the timer anyway; that changed
deliberately, and this note is the announcement rather than a footnote.

Required **once**, not continuously. The check reads a stored session rather than making
a request, so once you are signed in Deylee opens days, counts work and closes them with
no network at all — on a train, on a plane, with the wifi off. Nothing about local-first
changed.

If you are already signed in you will not notice this at all.

### Screen capture — off unless you turn it on

Deylee can now take a picture of your screen every few minutes **while the timer is
running**, if you switch it on yourself in Settings.

- **Off on every install.** While it is off nothing runs — macOS is never even asked for
  screen-recording permission, so leaving it alone means never being prompted about it.
- **Only you can turn it on.** There is no admin switch, no policy flag, no server-side
  enable, and there will not be one. Your employer cannot turn this on for you.
- **Only while you are working.** Never on a break, never while paused, never while the
  timer is stopped.
- **You can see everything it took.** Settings → Screen capture → Review shows the images
  themselves, a day at a time; open one to view it full size or delete it. "Delete all"
  clears the lot.
- **Stored encrypted on your Mac**, in the same database as your hours, and kept for 90
  days by default. Exported backups deliberately contain none of them.

### Also

- Development builds keep their own credentials, so testing a build no longer signs you
  in as yourself or touches your real database.
- Fixes: the capture setting would not stay switched on; turning it on appeared to do
  nothing; captures could reach a plaintext backup.

### Upgrading

Replace the app; your history and your session carry over. This version upgrades the
local database, so an older Deylee will refuse to open it afterwards — it says so plainly
rather than writing rows it does not understand.

## 0.3.0 — 2026-08-10 (pre-release)

**Deylee updates itself now.** Until this version there was no way for the app to tell
you a newer one existed — and the releases page Settings pointed at is in a private
repository, so even that instruction did not work for the people it was written for.

- Deylee checks its own update feed, offers a new version when one appears, and
  installs it for you. Nothing is downloaded without asking, and the check can be
  turned off in Settings.
- **Every update is cryptographically signed.** The app carries only the public half
  of a signing key and refuses any download that half cannot verify — so an archive
  that has been altered in transit, or served by something pretending to be Deylee's
  feed, is rejected rather than installed. The signing key itself never leaves the
  machine releases are cut on.

One catch, once: **0.2.1 and earlier cannot update themselves to this version**,
because the machinery that does it arrives *in* this version. This is the last time
you have to download Deylee by hand. From 0.3.0 onward it keeps itself current.

## 0.2.1 — 2026-08-10 (pre-release)

- **A backup no longer says whose it is.** Exported backups carried the account the
  store belongs to and the id this install reports to the server. Neither is any use
  to somebody reading their own hours, and together they were the only thing in the
  file identifying its owner — in the one copy of this data that is deliberately
  plaintext, so that it can be opened anywhere, and the one copy that leaves the
  machine. Both are withheld now, and the file is vacuumed rather than merely having
  the table dropped, because a dropped table's pages linger in a file with no
  encryption to hide them.

Nothing else changed. If you are on 0.2.0 and never exported a backup, this release
does nothing for you; if you did, that file still carries the identifiers and is worth
replacing.

## 0.2.0 — 2026-08-09 (pre-release)

Sync works now. In 0.1.0 it did not, and that is the headline: everything the app
itself wrote stayed on the machine that wrote it. The rest of this release is
integrity — the store lives on a machine its owner controls, and a tracker sold to
companies has to be honest about what that means.

### Sync actually syncs

- **Nothing the app created ever reached the server.** New days and segments were
  written without a sync identity, so the push queue held them for ever without ever
  offering them; edits were not flagged as changed, so a corrected time stayed local
  while the server handed the old one back; and deletes removed the row outright,
  leaving nothing to send, so the next pull returned what you had just deleted. All
  three are fixed.
- **The history stranded by that bug is rescued on upgrade.** Everything already on
  disk is given an identity and queued, ordered by when it was actually lived rather
  than all at the instant of the upgrade. Rows the server already has are left alone,
  so nothing arrives twice.
- A failed sync now backs off instead of retrying in a tight loop, a row the server
  will always refuse stops being pushed for ever, and a row this build cannot read is
  kept rather than dropped.
- **History shows the entries the server would not accept**, so a rejected row is
  something you can see and fix rather than a silent gap.

### Your hours stay yours

- **Sync now filters by account in the query as well as in the database.** The
  application layer was trusting row-level security alone; one misconfigured database
  URL would have been enough for one customer's sync to read and tombstone another's
  rows. Three independent layers now, and a test that asserts a second customer can
  neither see nor delete the first's.
- Signing out ends the session everywhere, and changing a password ends every other
  session — a revoked session's access token is refused straight away rather than
  honoured for the rest of its hour.
- Sign-in costs the same whether or not the address exists, so the clock can no longer
  be used to discover who has an account, and repeated attempts on one account are
  capped.
- The Google sign-in callback is bound to the request that started it, and the API
  refuses to start at all against a database connection it cannot verify.

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
- Dates and times are parsed as ASCII digits only, so a date carrying digits from
  another script cannot be read as a day it is not.
- A release build now takes its API address at assembly time and drops the
  plaintext-HTTP exemption a development build needs, so which server a bundle talks
  to is decided when it is built rather than by whatever a committed file last said.

### Upgrading from 0.1.0

Replace the app; your history and your session carry over. On first launch the store
encrypts itself, and anything the old sync could never send is queued and sent. If you
signed in on 0.1.0 and saw nothing arrive on another device, this is why — and it
should arrive now.

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
