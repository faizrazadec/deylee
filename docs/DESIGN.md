# Deylee — visual specification

Transcribed from the Claude Design project *“Deylee time tracker UI design”* (`deylee UI.dc.html`,
UI spec v1). This is the binding source for anything visual. Where it conflicts with the earlier
placeholder styling in `ARCHITECTURE.md` §12–13, **this document wins**.

> One visual language for macOS, Windows and Linux. Neutral greys, a single green accent reserved
> for the running state and an equally quiet amber for breaks. Dark is the primary theme.
> Divergence is limited to material and font.

---

## 1. Colour tokens

Emit as CSS variables on `:root` / `.dark`. Never hard-code a hex in a component.

| Token | Dark | Light | Use |
|---|---|---|---|
| `--surface-0` | `#141416` | `#f2f2ef` | Window base |
| `--surface-1` | `#232326` | `#ffffff` | Panel / card |
| `--surface-2` | `#2e2e33` | `#ececea` | Raised / hover fill |
| `--line` | `#35353a` | `#e0e0dc` | Hairline |
| `--text-1` | `#ebebef` | `#1c1c1e` | Primary |
| `--text-2` | `#a0a0a8` | `#6b6b70` | Secondary |
| `--text-3` | `#6e6e76` | `#98989e` | Tertiary |
| `--run` | `#4fbfa0` | `#2f8a72` | Accent — **running only** |
| `--break` | `#c79a54` | `#8c6a2a` | Break / paused |

Supporting values used by the mockups (dark → light):

| Token | Dark | Light | Use |
|---|---|---|---|
| `--text-dim` | `#8b8b93` | `#8e8e94` | Segment rows, muted body |
| `--text-faint` | `#57575e` | `#b5b5ba` | Caps labels inside panel, hints |
| `--text-ghost` | `#4a4a52` | `#c2c2c6` | Disabled numerals, weekend day numbers |
| `--btn-2-bg` | `#33333a` | `#f7f7f5` | Secondary button fill |
| `--btn-2-border` | `#47474e` | `#d8d8d4` | Secondary button border |
| `--btn-2-hover` | `#3c3c44` | `#ececea` | Secondary button hover |
| `--titlebar` | `#26262a` | `#ececea` | Framed-window title bar |
| `--titlebar-line` | `#33333a` | `#dcdcd8` | Title bar bottom border |
| `--detail-bg` | `#18181b` | `#f7f7f5` | History detail column |
| `--cell-bg` | `#1c1c20` | `#ffffff` | Calendar weekday cell |
| `--cell-bg-weekend` | `#17171a` | `#f7f7f5` | Calendar weekend cell |
| `--cell-border` | `#26262b` | `#e6e6e2` | Calendar cell border |
| `--cell-border-active` | `#57575e` | `#b5b5ba` | Today / selected cell |
| `--track` | `#2b2b30` | `#ececea` | Progress track |

**Vibrancy / material.** The panel and mini-window are translucent on macOS and opaque elsewhere:

- macOS panel: `background: rgba(30,30,33,.82)`, `backdrop-filter: blur(28px) saturate(140%)`,
  border `rgba(255,255,255,.09)`, internal dividers `rgba(255,255,255,.07)`,
  shadow `0 18px 44px rgba(0,0,0,.5)`.
- macOS mini: `rgba(30,30,33,.72)`, `blur(24px) saturate(140%)`, border `rgba(255,255,255,.12)`,
  shadow `0 12px 28px rgba(0,0,0,.45)`.
- Windows / Linux: opaque `--surface-1`, border `#3c3c42` (win) / `#3a3a3f` (linux), no blur.
- Light macOS panel: `#ffffff` at 82% + blur; light Win/Linux: solid `#ffffff`, border `#d3d3ce`,
  shadow `0 10px 30px rgba(0,0,0,.13)`.

The accent green appears **only** in the running state (and as the single arc on the app icon).
Nothing else in the UI is green.

## 2. Type

System stack per OS: macOS SF Pro (`-apple-system`), Windows `Segoe UI Variable Text`/`Segoe UI`,
Linux `Cantarell, Ubuntu, system-ui`. One shared stack in CSS covers all three.

| Role | Spec |
|---|---|
| hero | `300 52px/1`, `letter-spacing:-.02em`, tabular |
| hero-seconds | `26px`, `letter-spacing:0`, one contrast step down |
| day-hero (history detail) | `300 38px/1`, `-.02em`, tabular |
| mini | `400 22px/1`, tabular |
| window-title | `500 17px/1` (history header) / `500 15px/1` |
| body | `400 13px/1.4` |
| meta | `400 12px/1.5` |
| small | `400 11.5px/1.4` |
| caps | `600 10px/1`, `letter-spacing:.12em` (`.16em` for the `DEYLEE` wordmark) |

**Every** numeral that ticks or aligns uses `font-variant-numeric: tabular-nums`.

## 3. Space, radii, motion

- Space scale: 2, 4, 8, 12, 16, 20, 28.
- Radii: `4` chip · `6` control (Win/Linux) · `7` button (macOS) · `8` card (Win) ·
  `10` panel/window · `13` mini (macOS).
- Panel padding 18px; row rhythm 8/14; content column 284px inside the 320px panel.
- Motion: hover **120ms ease-out**, press **80ms**, state change **180ms**.
  No scale transforms, no bounce, no pulsing, no sound, no animation on the tray icon.
- Hover = surface-2 fill + text-2 → text-1. Press = fill one step darker + label 85% opacity.
  Calendar cells brighten their **border only**. Focus ring is the platform default, unstyled.

---

## 4. Main panel — 320 wide

Height is content-driven, 372–436. Structure, top to bottom:

1. **State hairline**, 2px, full bleed — *absent* when idle, solid `--run` when running,
   `repeating-linear-gradient(90deg, var(--break) 0 5px, transparent 5px 10px)` when paused.
2. **Header** `13px 18px 0`: `DEYLEE` (caps, `.16em`, `--text-3`) · right: `Mon 27 Jul` (11px, `--text-3`).
3. **Body** `16px 18px 18px`, `gap:16px`:
   - **Status row**, `gap:9px`:
     - idle — 9px ring, `1.5px solid --text-3`, label “Not started” (`500 12px`, `--text-2`).
     - running — 9px filled dot `--run` with `box-shadow: 0 0 0 3.5px rgba(79,191,160,.16)`,
       label “Running” in `--run`; right-aligned `since 13:30` (11px, `--text-3`).
     - paused — two 3×10px bars in `--break`, label “On break”; right `12m · since 15:04`.
   - **Hero**: `5:12` + `:38` in a smaller, dimmer span. Idle renders `0:00:00` in `--text-ghost`.
     Paused dims the whole thing to `--text-dim` / `--text-faint`.
   - **Sub-line** (11.5px, `--text-3`, space-between): left `5h 12m logged`, right
     `2h 48m to target` → `target met` once reached. Idle collapses to a single left string:
     `Nothing logged today — 8h target`.
   - **Progress**, 3px, radius 2, track `--surface-2`: solid `--run` when running;
     `repeating-linear-gradient(90deg,#7c7c84 0 4px,#5b5b62 4px 8px)` when paused; empty when idle.
   - **Actions**, 34px tall, `gap:8px`:
     - idle → one full-width primary “Start day”.
     - running → `[ ▮▮ Pause ]` secondary + `[ End day ]` ghost, `flex:1` each.
     - paused → `[ ▶ Resume ]` **primary** + `[ End day ]` ghost.
     - Primary = `--text-1` fill with `#18181a` label (dark) / `#1c1c1e` fill with white label (light).
     - Ghost = transparent, `--text-2` label, hover `--surface-2` + `--text-1`.
4. **Segment section**, divider above, `12px 18px 14px`:
   - Running/paused: caps `TODAY · N SEGMENTS`, then one row per segment
     (`12px/1.6`, `--text-dim`, space-between: range left, duration right). The *open* segment is
     `--text-1` with a 5px `--run` dot, or `--break` with pause bars when it is the break.
   - Idle: caps `YESTERDAY`, then a single row `Sun 26 Jul` / `7h 48m`. Omit the whole section
     when there is no prior day.
5. **Footer**, divider above, `9px 12px`, `gap:4px`: `History` · `Settings` · spacer · `Quit`
   (11.5px; first two hover to `--surface-2`, Quit is `--text-faint` hovering to `--text-2`).

## 5. Mini-window — 180 × 56

Radius 13 (macOS) / 8 (Windows) / 10 (Linux). Padding `0 13px`, `gap:11px`.

- Leading marker: 11px `--run` dot (running, with the same 3.5px halo on macOS) or two
  3.5×12px `--break` bars (paused).
- Centre column, `gap:4px`: `5:12:38` at `400 22px` tabular (`--text-1` running, `--text-dim`
  paused), and under it a **2px** progress hairline on a `#3a3a41` track — solid `--run` running,
  hatched `repeating-linear-gradient(90deg,#7c7c84 0 3px,#4a4a52 3px 6px)` paused.
- Trailing glyph is the only control: pause bars when running, a `▶` triangle when paused.
  It sits at **55% opacity and rises to 100% when the pointer is anywhere in the window**.
- Paused adds a **dashed** border in `rgba(199,154,84,.55)`.
- Draggable anywhere on the body; snaps to screen edges; double-click opens the panel.

## 6. History — 900 × 640, native title bar

**Month overview**

- Header `16px 22px 12px`: `‹` `›` 26px nav buttons, `July 2026` at `500 17px`, then right-aligned
  stat trio — each is a caps-ish 11px `--text-3` label over a `400 15px` `--text-1` value:
  `TOTAL`, `AVERAGE DAY`, `DAYS LOGGED`.
- Weekday header row: 7 columns, caps 10px `.1em`; weekend labels one step dimmer (`#3f3f46`).
- Grid: `repeat(7,1fr)`, `gap:6px`, cells **70px** tall, radius 7, padding `8px 9px`,
  `justify-content:space-between`. Day number top (11px, tabular; today `--text-1`, weekend
  `--text-ghost`, otherwise `--text-3`). Bottom: hours (`13.5px`, `#c8c8ce`) and a 2px bar on a
  `--track` rail — bar is `--run` when the target was met, `--text-dim` otherwise. Out-of-month
  cells are fully transparent. Today and the selected day take `--cell-border-active`.
  Hover brightens the border to `#4a4a52` only.
- Footer: legend (`— hours vs 8h target`, `— target met`), spacer, `Export CSV` button.
- Empty state: 44px ring, “No history yet”, then “Days appear here once you end your first day.
  Nothing is uploaded — the log lives in a local file.”

**Day expanded** — the calendar compacts and a detail column slides in:

- Left column: header `July 2026` + right `142h 18m · 21 days`; grid cells shrink to **52px**
  with `gap:5px`, showing only the day number and the 2px bar.
- Right column, **352px** fixed, `--detail-bg`:
  - Header `18px 22px 14px`: `Tuesday 14 July` + a 22px `✕` close button; then `8:04` at
    `300 38px` beside `target met · +4m` in `--run`; a 3px progress bar; and a meta row
    `08:58 – 18:12` · `4 segments` · `1h 10m break`.
  - `SEGMENTS` caps label, then the log: **no column headers, no rules between rows, no zebra.**
    Each row is `7px 0`, `gap:12px` — a 9px marker slot (work = 5px filled `--text-dim` dot,
    break = 5px hollow ring `--text-faint`), the range left, the duration right. Breaks drop a
    contrast step to `--text-3` so the eye skims worked segments first.
  - Footer row above a hairline: `Worked` / `8h 04m` in `--text-1`.

## 7. Settings — 560 wide, native title bar

Body `20px 24px 24px`, sections `gap:22px` separated by a top hairline + `padding-top:18px`.
Each section opens with a caps label. Each row is `display:flex; align-items:center; gap:14px`
with a `flex:1` label block (13px title, optional 11.5px `--text-3` description) and the control
on the right.

Controls:
- **Toggle** — 38×22 pill, radius 11, 16px knob. On: `--btn-2-border` track, `--text-1` knob.
  Off: `--surface-2` track with a `--btn-2-border` border and a `--text-3` knob.
- **Stepper** — bordered box, value `6px 10px` tabular, with stacked ▲/▼ in a divided column.
- **Select** — bordered box, value + a small caret triangle.
- **Segmented** — bordered, radius 6, dividers between items; the active item is `--text-1` fill
  with `#18181a` text, inactive `--text-2` hovering to `--surface-2`.
- **Button** — bordered, `6px 11px`, `--text-2`, hover `--surface-2` + `--text-1`.

Sections in the spec: **DAY** (daily target stepper; “Ask before ending the day” toggle) ·
**IDLE** (“Ask about idle time after” select) · **APPEARANCE** (menu-bar/tray label segmented
`h:mm` / `h:mm:ss` / `Icon only`; theme segmented `System` / `Light` / `Dark`; show mini-window
toggle) · **SYSTEM** (launch at login toggle; data folder with a `Reveal` button).

## 8. Menu bar / tray

**macOS** — template image (monochrome, auto-inverting) plus a live text label.
- Idle: **icon alone, no label.**
- Running / paused: `h:mm` (seconds are opt-in and add ~22px). Widest state `12:34` = 54px total.
- The label refreshes **once a minute** (or every second only when `h:mm:ss` is selected).
  The icon is redrawn only on a state change.

**Windows** — the icon carries the whole state; the tooltip carries the numbers:
```
deylee — Not started        /  Click to start today
deylee — Running, 5:12      /  Started 09:12 · 2h 48m to target
deylee — On break, 5:12     /  Paused 15:04 · break 12m
```

**Linux** — symbolic monochrome, 22/24px, `currentColor` so themes can tint it.

## 9. Icon geometry

**Shape carries state, never colour** — this is what makes the tray legible at 16px on any shell,
and it is why the tray art is monochrome rather than green/amber:

| State | Mark |
|---|---|
| idle | open ring |
| running | ring with a solid centre core |
| paused | two vertical bars |

Stroke weight is **10% of the box**, snapped to whole pixels. Ring/bar metrics per size:

| Box | Ring stroke | Core Ø | Bars (w × h, gap) |
|---|---|---|---|
| 16 | 1.6 | 6.5 | 4 × 13, 3 |
| 22 | 2.0 | 9 | 5 × 18, 4 |
| 24 | 2.2 | 10 | 6 × 20, 4 |
| 32 | 3.0 | 13 | 8 × 26, 6 |
| 48 | 4.0 | 20 | 12 × 40, 8 |

macOS ships pure-black-on-alpha template icons at 16 and 32. Windows `.ico` bundles 16/24/32/48.
Linux ships 22 and 24. Windows/Linux also ship a light-taskbar (dark ink) variant.

**App icon** — one mark: a grey dial with a **single accent arc at the twelve-to-two position**,
the only place the running green appears outside the running state. Ring stroke ≈ 12% of the dial,
dial ≈ 55% of the container, rotated 38°. Container silhouette changes per platform
(macOS 1024² squircle r≈24/104, Windows 256² r≈8/88, Linux 512² circle) over a `#212125` field
with a `#33333a` edge.

## 10. Prompts — 380 wide

Card: radius 12, `rgba(32,32,36,.94)` + `blur(24px)`, border `#3c3c42`,
shadow `0 24px 60px rgba(0,0,0,.55)`, padding 22, `gap:16`. A 26px ring icon sits beside a
`500 14px` title; body is `12.5px/1.6` `--text-2` with key values stepped up to `--text-1`.
Buttons stack: one full-width primary, then a row of two secondary (`--surface-2`, border `#47474e`).

**Idle** — amber ring + vertical tick. “You were away for 21 minutes”. Body: “No activity since
**14:32**. The timer kept running. What should happen to that time?”
Actions: `Keep the 21 minutes` / `Discard it` / `Break since 14:32`.
Footnote: “Esc keeps the time. The prompt never steals focus mid-typing — it waits for activity to
resume.”

**Crash recovery** — grey ring + horizontal tick. “deylee closed while the clock was running”.
Body: “Last saved at **13:47**, started **09:12**. That's **4h 35m** recovered.” Then a bordered
box previewing the recovered segments. Actions: `Continue from 13:47` / `End day at 13:47` /
`Discard`.

---

## 11. Decisions where the design and the build brief differ

1. **Heartbeat cadence.** The recovery card's footnote says state is flushed every 60s. The build
   brief specifies **30s**, which is strictly better for data loss, so the behaviour stays at 30s
   and the copy is written to match (“at most 30 seconds”).
2. **Idle now has three outcomes.** The design offers *Keep* / *Discard* / *Break since HH:MM*, so
   `IdleChoice` gains `convert-to-break` alongside `keep` and `discard`.
3. **Two new preferences** are implied by the Settings screen: `confirmBeforeEndDay` and
   `trayLabelFormat` (`'hm' | 'hms' | 'icon-only'`).
4. **Settings coverage.** The design's Settings is a v1 subset. The build brief also requires
   auto-pause on sleep/lock, the end-of-day reminder, week start and database backup. Those are
   added as further sections (`BREAKS`, `REMINDERS`, and a Back-up button in `SYSTEM`) in exactly
   the same visual language, and the window scrolls rather than growing past 640.
5. **Window sizes** follow this document — panel 320, history 900×640, settings 560 — replacing
   the placeholder sizes in `ARCHITECTURE.md` §5.
6. **“End day at HH:MM”** means the recovery choice `close-at-heartbeat` closes the open segment
   *and* finalises the day, matching the button's promise.
