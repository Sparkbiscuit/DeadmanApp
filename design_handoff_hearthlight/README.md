# Handoff: Filuma "Hearthlight" App Redesign

## Overview
The full visual language and screen-by-screen redesign for **Filuma**, a deadline-first iOS task manager, built around a "held flame / hearth" metaphor: a warm ambient glow behind every screen, rising ember particles, a glowing ring that represents time-in-session, a glowing thread connecting "now" to "next," and a new **Weave** tab that visualizes two weeks of shown-up effort as a woven tapestry. This is the chosen direction that came out of an earlier exploration file (`Filuma Magic Directions.dc.html`, not included here) — treat it as the current, final visual system for the app.

**Relationship to any earlier handoff**: if a `design_handoff_filuma_redesign` package also exists in this repo, it documents an earlier, flatter redesign pass (no Weave tab, no ember/glow language). This Hearthlight package supersedes its colors, backgrounds, and card treatments. That earlier package's screen-structure notes for **Capture sheet, Bulk Entry, Blocked Times, and Task Completion/Celebration** still apply as-is (Hearthlight doesn't touch those) — just re-skin them with the tokens below instead of the older orange-on-white ones.

## About the Design Files
`Filuma Hearthlight App.dc.html` is a **design reference built in HTML** — not production code. It renders inside a proprietary design tool (custom `<x-import>` tags + a `support.js` runtime) and **will not run standalone** in a browser or Xcode. `ios-frame.jsx` is only the phone-bezel chrome used to preview the screens — it is not part of the app UI. Use this README as the implementation spec.

**Target environment: SwiftUI (iOS)**, the same existing Xcode project this was derived from. Recreate every screen below using SwiftUI idioms already established in that codebase — do not introduce a new UI framework, and do not ship the HTML.

## Fidelity
**High-fidelity.** Colors, gradients, radii, type, and animation timings below are final values. Sample task titles/dates/numbers are placeholder data.

---

## Design Tokens

### Accent (tweakable brand hue — pick one, or make it a user preference)
The prototype exposes accent as a swappable variable; all four are fully designed:
- **Ember (default)** — `#C1571F`
- Indigo — `#5A78E0`
- Sage — `#3FA372`
- Violet — `#8B5AD6`

Every other "glow" color is derived from the chosen accent at render time:
- `accentHi` = `color-mix(in oklab, <accent> 78%, white)` — used for icon strokes/labels on the accent color, brightest highlights
- `accentSoft` = `color-mix(in oklab, <accent> 52%, white)` — used for most glow text, active-tab icon, ring highlight
- `accentDeep` = `color-mix(in oklab, <accent> 72%, black)` — reserved, not heavily used in current screens

In SwiftUI, precompute these three derived shades per accent (HSB blend toward white/black) rather than using `color-mix` (CSS-only).

### Surfaces (dark mode only — this redesign is dark-first; no light variant was built)
| Token | Hex |
|---|---|
| App/canvas background | `#0E0E10` |
| Screen background (Tasks/Schedule/Settings) | `#0F0F12` |
| Screen background (Work Session) | `#0D0D10` |
| Screen background (Weave) | `#0E0E11` |
| Card surface | `#19191D` / `#1A1A1E` |
| Card surface (hero/session, gradient) | `linear-gradient(160deg, accent@22% → #1A1A1E 58%)` |
| Hairline border | `rgba(255,255,255,0.05–0.09)` |
| Text primary | `#F5F5F7` |
| Text subtle | `#9A9AA2` |
| Text faint | `#6E6E76` |

### Context colors (task categories — unchanged from existing app)
| Context | Display / text | Fill (bars, dots) |
|---|---|---|
| School | `#8FA5EC` | `#5A78E0` |
| Work | `#E8BE62` | `#E0A020` |
| Personal | `#6FC49A` | `#3FA372` |
| Urgent (deadline text only) | `#E2434A` | — |

### Typography
- **Nunito** (400, 600, 700, 800, 900) — all UI text.
- **JetBrains Mono** (500, 600, 700) — every numeric/time value: countdowns, clock times, mono stats, "23:14," "12:07," date numerals, budget/percent labels. This split (rounded humanist font for words, monospace for numbers) is a deliberate, consistent rule across all 5 screens — keep it everywhere new numeric UI is added.

Key sizes used: greeting label 13px/700, screen title 28–32px/900 with a 2-color gradient (`#F5F5F7` → `accentSoft`, left-to-right, ~100deg), card title 17px/800, list item title 14px/800, meta/caption 11–12px/700, big session timer 36px/700 mono, tab label 9px/700–800.

### Radii
| Element | Radius |
|---|---|
| Hero/session cards | 20–24px |
| List/timeline rows | 14px |
| Settings row-group containers | 18px |
| Widgets (small/medium) | 24px |
| Widget (Live Activity) | 26px |
| Lock-screen widget | circular (50%) |
| Tab bar / pills / chips / toggles | 999px (full capsule) |

### Glow / elevation pattern
Nearly every "active" or "highlighted" element gets a matching soft glow: `box-shadow: 0 Npx Mpx color-mix(in srgb, accent X%, transparent)`, where N/M scale with element size (10px blur for small dots, 24–60px for hero cards). In SwiftUI: `.shadow(color: accent.opacity(0.2–0.6), radius: 10–30)`. This is the single most repeated visual signature of the redesign — apply it consistently to: active tab icon, FAB, in-progress task/session cards, the progress ring, the "now" line dot, and widget rings.

---

## Screens

### 1. Tasks (home)
- Greeting ("Good afternoon," accent-tinted) + gradient "Your Tasks" title, top-right an active-count pill (flame glyph + count, capsule, accent-tinted bg/border + glow).
- **Hero "Right now" card**: gradient accent→dark background; left a 74px circular progress ring (conic-gradient arc in `accentSoft`→`accent`, glowing blurred duplicate behind it, pulsing outer halo) with mono countdown + "LEFT" label centered inside; right the current task title + first-step subtext. Full-width gradient "Continue session" button below (play glyph).
- **"Up next" list**: a vertical glowing thread (gradient line, `accentSoft`→transparent) runs down the left edge connecting 3 rows; each row has a small colored dot (context color, glow) breaking through the thread, task title, meta line (context · due date · % progress), and a mono time badge on the right.
- Bottom tab bar (see Navigation below) + circular FAB.

### 2. Schedule (Day view)
- Gradient "Schedule" title + Day/Week segmented control (Day active, capsule background). *(Week view, if it exists in the codebase, is unchanged by this redesign — just re-skin it with these tokens.)*
- 7-day horizontal date strip; selected day gets an accent-tinted card + glow; days with tasks get a small dot indicator.
- Vertical timeline: past items dimmed + strikethrough + checkmark; a **"now" line** — a thin glowing gradient bar with a breathing dot marking current time — sits between past and future items; the in-progress task renders as a glowing gradient card with a breathing status dot and "In session · Xm left" subtext; future items are plain dark rows with a context capsule tag; calendar-imported busy blocks render dashed-border with a clock glyph and no color tag.

### 3. Work Session (full-screen modal)
- Header: "Close" (dismiss) / "Work Session" title / spacer.
- Context capsule tag + task title + mono "budget used" line.
- **Held-flame ring**, 200px: pulsing outer glow halo, conic-gradient progress arc (`accentSoft`→`accent`) with a blurred glow duplicate, inner disc (radial dark gradient) showing a large mono countdown timer + a breathing dot + "weaving" status label.
- A small accent-tinted pill surfaces a "10-minute dare met — keep going?" micro-encouragement (a lightweight momentum nudge; exact copy/trigger logic is a product decision, not fully speced here — flag for PM/eng review).
- Footer: "Pause" (outline/ghost button) + "Stop & log progress" (wide, gradient CTA) — stopping should reveal the existing progress-report step inline, unchanged from current behavior.

### 4. Weave (**new tab** — no existing counterpart)
Visualizes ~2 weeks of session activity as a woven tapestry. This is a genuinely new screen/tab, not a re-skin.
- Gradient "Your Weave" title, subtitle "Two weeks of showing up."
- **Tapestry card**: a grid-lined bar chart, one column per day (14 columns, labeled W T F S S M T W T F S S M T across two rows of weekday initials below). Each day column can stack up to 2 rounded capsule bars (one per context that had logged time that day), heights proportional to minutes logged; days with no logged time show a single small dot instead of a bar ("rest days hold the cloth together"). Today's column gets a glowing accent-tinted background + its bar rendered in the accent gradient instead of a context color.
  - **On-appear animation**: bars scale up from `scaleY(0)` with a slight overshoot, staggered ~0.05–0.9s across columns (fastest, most recent days first) — plays once per visit, not looped.
  - **On-appear light sweep**: a soft diagonal band of light sweeps once across the whole grid overlay (~3.8s, ease-in-out, single pass) after the bars finish animating in — a one-time "just wove itself" reveal, not a continuous effect.
- Three stat tiles below: total hours woven (mono), session count (mono), day-streak (mono, personal-green).
- **"This week's threads" card**: 1–2 short checkmark bullet lines surfacing specific recent wins (e.g. finished a task early, attendance ratio for the week). These should be generated from real session/completion data, not fixed text — see State Management below for the underlying rule.

### 5. Settings
- Gradient "Settings" title.
- Three grouped list sections in rounded (18px) containers, `#19191D` background, hairline dividers between rows:
  1. **Planning** — Work hours (value + chevron), Default block length (value + chevron), Catch-up replanning (toggle).
  2. **Calendar** — Import busy times (toggle, on), Export blocks to Calendar (toggle, off).
  3. **Notifications** — Block start reminders (toggle, on), Celebrate finished tasks (toggle, on).
- Each row: 30×30px icon tile (accent- or context-tinted background, line icon), label, trailing control (value+chevron for nav rows, or a toggle switch — accent gradient track + glow when on, flat gray track + gray thumb when off).
- Footer caption: version string, centered, mono, faint.

### 6. Widgets (WidgetKit — 4 families)
- **Today (systemSmall, 170×170)**: mini progress ring top-left ("3/5" mono), flame+streak pill top-right, bottom-anchored "Next · [time]" label + task title + "N blocks left today."
- **Up Next (systemMedium, 364×170)**: "Up next" label + the same glowing-thread list pattern as the home screen, 4 rows, current item in accent color with "Now" instead of a time.
- **Lock Screen (accessoryCircular, 76×76)**: **monochrome only** (iOS renders lock-screen widgets in a single tint) — progress ring + "3/5" + flame glyph, all one color, no accent/context colors.
- **Live Activity / Dynamic Island (expanded, 364×92)**: held-flame ring with mono countdown on the left, "Weaving now" + task title + block-end time in the middle, a round pause/stop button on the right.

---

## Navigation
Tab bar order: **Tasks · Schedule · Weave · Settings**, plus a center-floating circular FAB (opens Capture sheet) that sits slightly proud of the bar. The bar itself is a floating blurred capsule (`rgba(25,25,29,0.82)`, 20px blur, hairline border) inset 20px from both edges and 24px from the bottom, not edge-to-edge/system-default. The active tab gets an accent-tinted pill background behind its icon+label plus a small glowing dot beneath it. **Weave is a new tab** — it needs to be added to the existing `TabView`/navigation shell alongside a new `WeaveView`.

## Interactions & Behavior
- Ember particles, ring pulses, and the "now" line's breathing dot are continuous ambient animations, present on every screen, all screens.
- The Weave tab's bar-growth and light-sweep animations are **one-shot on appear**, not looping — don't replay them on every re-render, only on tab entry (e.g. once per session, or once per calendar day — pick whichever matches how "surprising"/precious you want the reveal to feel; flagging as a product call).
- Two motion-related dials were used to build/tune this prototype and are worth deciding on as real settings (or not) rather than shipping as fixed values:
  - **Ambient intensity** (0–100%): scales the opacity of all glows/embers/pulses uniformly.
  - **Motion** (on/off): globally pauses every animation.
  Recommendation: don't expose "Motion" as a separate app toggle — instead respect the system **Reduce Motion** accessibility setting to pause embers/pulses/sweeps automatically. "Ambient intensity" is a nice-to-have, not required; ship at a fixed 100% unless there's appetite for a user-facing "hearth glow" slider in Settings.

## State Management
No new data model beyond what's already needed for Tasks/Schedule/Sessions:
- Reuses existing `FilumaTask`, `ScheduledBlock`, `WorkSession`, `BlockedTime`, `UserSettings`.
- **New, for the Weave tab**: a per-day aggregation (trailing 14 days) of minutes logged per context, derived from `WorkSession` records — this feeds the tapestry bars. Also derive: current day-streak (consecutive days with ≥1 session), total hours + session count over the range, and the 1–2 "this week's threads" highlight lines (simple rule-based: most recent task completed ahead of its deadline; ratio of days-with-a-session over the last 7 vs. days planned).
- The Work Session "10-minute dare met" nudge implies some lightweight in-session milestone state (e.g. "has this session crossed a 10-minute-since-last-check-in threshold") — not modeled in the existing schema; likely a transient view-state timer rather than persisted data.

## Assets
**None required.** Every visual — embers, glows, rings, the tapestry grid, the light sweep — is built from CSS gradients/blur/box-shadow/mask, not images. Recreate with SwiftUI equivalents: `RadialGradient`/`AngularGradient` for the glows and progress rings, `.blur()` + `.shadow(color:radius:)` for glow halos, and a masked `LinearGradient` sweeping across a `TimelineView` for the once-per-visit light sweep on Weave. Icons throughout are simplified line-SVGs standing in for SF Symbols — swap in the real SF Symbol set (e.g. `flame.fill`, `list.bullet`, `calendar`, `gearshape`, `checkmark.circle`, `chart.bar`) in the actual build.

## Files
- `Filuma Hearthlight App.dc.html` — the full click-through prototype: Tasks, Schedule, Work Session, Weave, Settings, and all 4 widget families, with a live Accent/Ambient/Motion tweak panel.
- `ios-frame.jsx` — phone-bezel chrome used only to preview the screens in the design tool; not app UI, no need to reference it for implementation.
- Requires the design tool's `support.js` runtime to render — **not runnable by double-clicking**. Use this README as the spec instead of trying to open the file directly.
