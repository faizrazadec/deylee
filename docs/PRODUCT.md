# Deylee — what this product is

The binding statement of what Deylee is, who buys it, and what we will not build.
`MAC_REWRITE_SPEC.md` says how the app behaves and
`SYNC_PROTOCOL.md` says how clients talk to the server; this file says **why either
of them is shaped that way**. Where a feature request conflicts with this document,
this document wins until it is deliberately amended.

Amend it in the open. Every claim below is a promise somebody can check, and a
promise that quietly stops being true is worse than one never made — which is most of
the reason this repository is public at all: a privacy claim nobody can verify is a
marketing line.

Roadmap ordering, competitor pricing and go-to-market sit in `docs/STRATEGY.md`, which
is deliberately untracked. None of it constrains the software; all of it would only
help somebody selling against us.

---

## 1. The product in one paragraph

Deylee is a time tracker for people who are paid for their hours and resent being
watched. It lives in the menu bar, opens a day, counts work and breaks, and closes
the day — one timer, no configuration before the first start. An account is required
to begin, and required once: every write then lands in SQLite on the user's own
machine and the interface reads only from there, so a signed-in Mac tracks a full day
with no network at all. Sync carries the log between machines and gives companies a
shared view of who logged what. **Only hours cross the network, unless
the user switches on something that sends more — which is off by default and theirs
alone to enable (§3).**

## 2. Who it is for

Two different people, and confusing them is the fastest way to build the wrong
thing.

**The user** is an individual doing billable or accountable work on a Mac —
contractor, agency employee, consultant, in-house engineer on a night shift. They
have usually been tracked by something they disliked. They will abandon a tracker
that is fiddly, that loses time, or that makes them feel surveilled. They are the
one who chooses to keep it running, and no amount of buyer enthusiasm survives their
refusal.

**The buyer** is a manager, agency owner or operations lead who needs to know where
hours went — to invoice a client, to cost a project, to run payroll, to decide
staffing. They pay per seat. They do not care about the timer; they care about the
report. Historically they have bought surveillance tooling because that is what the
market offered, and then absorbed the morale cost.

Deylee's whole thesis is that these two can be served by the same product, and that
every competitor has picked one and taxed the other. Time Doctor and Hubstaff serve
the buyer and impose on the user. Timemator, Tyme and Session serve the user and
offer the buyer nothing. **We are betting the overlap is real and currently empty.**

## 3. The load-bearing claim

> Nothing leaves your machine that you did not choose to send.

By default, that is hours and nothing else: segments, days and their timestamps. No
window titles, no document or file names, no application names, no URLs, no keystroke
or mouse activity, no productivity score, no telemetry of any kind. Install Deylee,
sign in, and a manager sees durations. They cannot see the screen.

The claim used to be "records what you worked, never how you worked", and screenshots
were refused outright. That changed, and the honest version of why matters more than
the slogan did.

**The line was never really about pixels. It was about who decides.** What makes a
tracker hated is not that it can capture a screen — it is that somebody else switches
that on, for you, and you cannot switch it off. That is the thing every review of
Time Doctor and Hubstaff is actually describing, and it is the thing this product
refuses.

So screen capture exists in Deylee under conditions that cannot be quietly relaxed:

- **Off by default**, on every install, forever. Not off-until-configured — off.
- **Only the person being recorded can turn it on**, from their own Settings, on their
  own machine. There is no admin switch, no policy flag, no server-side enable. A
  buyer cannot turn it on for their staff, and adding a way for them to would be the
  refusal in §5 — not a feature request to weigh.
- **They can turn it off, and delete what was captured, at any moment**, without asking
  anybody.
- Captures are held in the encrypted local store like everything else, and sync only
  while the setting is on.

Be clear-eyed about the residual risk, because pretending it away is how a promise
rots: in a workplace, "optional" is doing some work. An employer can *ask* staff to
switch it on, and asking is not nothing. What we can guarantee is that the request has
to be made out loud, to the person's face, and that the person can refuse it and
revoke it from their own machine — instead of it arriving silently as an admin
setting they never see. That is a real difference, and it is the whole difference.

**Any feature that widens what leaves the machine *without the user choosing it* is
refused by default**, however much a buyer asks for it.

Two consequences worth stating, because they are the parts people forget:

- Local-first is not local-only, and the distinction is load-bearing. Sync is a
  background reconciliation on top of a store that already works. A timer that stops
  working on a train would be worse than one that never synced.
- If automatic activity capture ever ships, the captured activity is a **local
  suggestion and never a synced row**. The user confirms a duration; the duration
  syncs; the evidence stays on the disk it was observed on.

**This claim is repeated in four places, and they drift.** Change one and change all
four in the same commit:

| Where | What it says |
|---|---|
| `MAC_REWRITE_SPEC.md` §1 | the binding non-goal, and the exhaustive list of network requests |
| `MAC_REWRITE_SPEC.md` §5.5 | the Data section's user-facing copy |
| `Sources/Deylee/SettingsView.swift` | the string a user actually reads |
| the website's `privacy.html` | the version read by people who cannot open this repo |

The failure mode is not malice, it is lag: sync shipped, the app's copy was corrected,
and the spec kept promising "nothing is ever uploaded" for weeks. A claim that outlives
its truth costs more than one never made, because it is evidence of the second kind of
dishonesty — the kind a customer finds on their own.

## 4. What Deylee is not

- **Not employee monitoring.** No keystroke or mouse logging, no idle-faking
  detection, no productivity scoring, no ranking people against each other. Screen
  capture exists, but only as something a person switches on for themselves (§3);
  there is no way for anybody else to switch it on for them, and building one is
  refused (§5).
- **Not a project manager.** It records time against work; it does not plan the
  work, assign it, or track its completion. It integrates with the tools that do.
- **Not an invoicing suite.** It will produce the hours and the rates that an
  invoice is built from, and export them. Accounting belongs to accounting software.
- **Not a general-purpose analytics platform.** Totals are derived by summing
  segments, always, on every client, on every tick. Nothing aggregated is stored or
  transmitted. There is no dashboard we would build that requires breaking that.
- **Not free-tier-led.** Clockify gives away unlimited users and projects; we will
  not win a race to zero and should not enter it.

## 5. What we will not build

Keystroke or mouse logging. Activity scoring. Idle faking detection. Anything that
ranks employees. If a deal depends on one of these, the answer is no and the reason
is §3.

And the one that will be asked for most, once screen capture exists: **an admin
control that enables capture for somebody else.** Remote enablement, an enforced
policy, a default-on for a team, a report that shows a manager who has it switched
off. Every one of those converts a tool a person chose into a tool used on them,
which is the exact product we are not building. The answer is no, and it stays no at
any contract value — this is the refusal that keeps §3 true rather than decorative.

## 6. The test for any new feature

Ask, in this order:

1. Does it widen what leaves the machine? If yes, it may only ship as something the
   user switches on for themselves, off by default, revocable by them alone (§3). If
   it cannot be built that way, refuse it.
2. **Can anybody other than the person recorded turn it on, or see that it is off?**
   If yes, refuse it outright. This is the question screen capture makes load-bearing,
   and the one a buyer will push hardest on.
3. Does it require a stored total or a running counter? If yes, refuse it — derive it
   from segments instead.
4. Does it break the app when the network is gone? If yes, redesign it as local-first
   with reconciliation on top.
5. Would the **user** switch it off if they could? If yes, we have built something for
   the buyer at the user's expense, which is the failure mode of every competitor.
6. Does the buyer pay more because it exists? If no, it goes below the things that
   do.
