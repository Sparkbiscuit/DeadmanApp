# Handoff: Loom Design System + UI Kit

## Overview
A visual redesign and interaction system for **Loom** (working repo name "Deadman"), a deadline-first iOS/SwiftUI task manager. This package covers the full color/type/component system plus a click-through prototype of every core screen, including one new addition: a **Week view** for Schedule.

## About the Design Files
The two `.dc.html` files in this folder are **design references built in HTML** — not production code. They render inside a proprietary design tool (custom `<sc-if>`/`<sc-for>`/`<x-import>` tags + a `support.js` runtime) and **will not run standalone** in a normal browser or in Xcode. Treat them as an interactive spec: open them only if you have access to the design tool project; otherwise rely on this README plus the screenshots (see bottom) for exact values.

**Target environment: SwiftUI (iOS/macOS)**, existing Xcode project. This is the same codebase this design was derived from (`AppTheme.swift`, `TaskListView.swift`, `TaskRowView.swift`, `CaptureSheetView.swift`, `ScheduleView.swift`, `WorkSessionView.swift`, `SettingsView.swift`, `BulkEntryView.swift`, `BlockedTimeView.swift`, `ConfettiView.swift`, `Models.swift`). Recreate the designs below using SwiftUI idioms already established in that codebase (the `AppFont` / `Color` extensions, `.cardStyle()` / `.contextTag()` view modifiers, `@Model` SwiftData types) — do not introduce a new UI framework.

## Fidelity
**High-fidelity.** Colors, type, spacing, and radii below are final values, ready to drop into `AppTheme.swift`. Copy is close to final; treat sample task titles/dates as placeholder data.

---

## Design Tokens

### Color — Brand (new)
Derived from the existing app icon (burnt-orange woven mark). Replaces reliance on `systemRed` as the sole brand color; `systemRed`'s role narrows to "urgent/destructive" only.

| Token | Hex |
|---|---|
| brand.100 | `#FBE4D4` |
| brand.300 | `#EFA36C` |
| brand.500 (primary) | `#C1571F` |
| brand.600 (pressed) | `#A64715` |
| brand.700 | `#8A3A10` |

Two alternate brand hues are wired as a tweak in the prototype (not required, just explored): Indigo `#5A78E0` and Sage `#3FA372`.

### Color — Semantic / Context (mostly unchanged from `AppTheme.swift`)
| Role | Hex |
|---|---|
| Urgent / destructive (`loomRed`) | `#E2434A` (pressed `#C93039`) |
| School (`schoolColor`) | `#5A78E0` |
| Work (`workColor`) | `#E0A020` *(shifted slightly warmer/lighter than current `#D98033` to stay distinct from the new brand orange)* |
| Personal (`personalColor`) | `#3FA372` |

### Color — Surfaces
| Token | Dark | Light |
|---|---|---|
| Background | `#121214` | `#F4F4F6` |
| Surface (`loomCard` / `loomCardLight`) | `#1C1C1F` | `#FFFFFF` |
| Surface 2 (tertiary fill) | `#29292D` | `#EAEAEF` |
| Surface 3 | `#333338` | `#DEDEE3` |
| Border | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.07)` |
| Text primary | `#F5F5F7` | `#1C1C1E` |
| Text subtle (`loomSubtle`) | `#9A9AA2` | `#6E6E76` |
| Text faint | `#6E6E76` | `#9A9AA2` |

### Typography — **font change**
Replace `.system(design: .rounded)` and `.system(design: .monospaced)` with:
- **Nunito** (400/600/700/800/900) — display, heading, body, caption. Google Font; bundle the `.ttf` files in the app and register via `Info.plist` (`UIAppFonts`) + `Font.custom("Nunito-*", size:)`.
- **JetBrains Mono** (500/600/700) — all numeric/time displays (countdown, effort, timer). Same bundling approach.

Scale (unchanged sizes from `AppFont`, just new families):
| Style | Size | Weight |
|---|---|---|
| Display | 34 | 800 |
| Heading | 20 | 700 |
| Body | 16 | 400 |
| Caption | 13 | 700 |
| Mono | 14–16 | 600 |

### Spacing scale (px)
`4, 8, 12, 16, 20, 24, 32, 40` — matches existing padding conventions in the codebase (16 card padding, 20 screen horizontal padding, etc.) — no change needed.

### Corner radii
| Token | Value |
|---|---|
| sm | 8 |
| button | 14 |
| card | 16 |
| sheet / modal | 24 |
| capsule | 999 (full) |

An alternate "crisp" scale (sm 2 / button 6 / card 6 / sheet 10) exists as an unused tweak in the prototype — ignore unless you want a sharper-cornered variant.

### Elevation
- Card: `0 1px 2px rgba(0,0,0,0.06), 0 8px 20px rgba(0,0,0,0.05)` (light mode only — dark mode relies on surface contrast, no shadow)
- Sheet/modal: `0 20px 40px rgba(0,0,0,0.25)`
- FAB: color-matched — `0 10px 20px {brand.500}55`

---

## Screens

### 1. Tasks (home) — `TaskListView.swift` / `TaskRowView.swift`
Mostly a re-skin, not a structural change: greeting + "Your Tasks" title, stat pills (active / today / unblocked), sections grouped by context (School/Work/Personal), FAB. Task card: title + colored deadline text + context capsule tag; next-scheduled-block row (clock icon) OR red "Not blocked" warning row; linear progress bar + %; time-spent row (mono, orange "over" label if over budget) + Start/Working session pill + complete-circle button.
- Apply new palette/type tokens above.
- No new components needed here.

### 2. Capture sheet — `CaptureSheetView.swift`
Title field + mic toggle (existing `SFSpeechRecognizer` logic — keep as is, just re-skin), context picker (3 capsule buttons), effort picker (30m/1h/2h/3h+ chips), "Schedule it" button.
- **New**: add a "Bulk add" text link in the sheet header (top-right, brand-colored) that pushes to `BulkEntryView` — currently `BulkEntryView.swift` exists in the codebase but nothing navigates to it. Wire it up here.

### 3. Bulk Entry — `BulkEntryView.swift`
Unchanged structurally (row list: name field, context menu chip, effort menu chip, deadline picker, delete button; footer: "Add Row" + "Schedule All"). Re-skin only.

### 4. Work Session — `WorkSessionView.swift`
Unchanged structurally: context tag + title + budget label, large mono timer, Start/Stop circular button, then a progress-report step (title "Nice work!", session length, slider from current progress to 100%, "Save Progress"). Re-skin only.

### 5. Schedule — `ScheduleView.swift` — **structural addition**
Existing Day view (horizontal day-pill strip + vertical timeline of `BlockCard`/`BlockedTimeCard`) is unchanged.
**New: Week view.** Add a segmented control ("Day" / "Week") next to the "Schedule" title.
- Week view is a compact 7-column time grid, 7 AM–10 PM, ~22pt per hour.
- Each day column header shows day-of-week + date; tapping it jumps to Day view for that date.
- Each `ScheduledBlock`/`BlockedTime` occurrence renders as a solid color block positioned by `startTime`/`durationMinutes` (context color for tasks, neutral gray for blocked time) — **no text label inside the block** (we tried labels; at this column width they clipped/wrapped awkwardly, so the block itself is tappable and jumps to that day's Day view instead).
- Data source: same `allBlocks` / `allBlockedTimes` queries already in `ScheduleView`, just grouped per weekday and converted to a top/height offset instead of a list row.

### 6. Settings — `SettingsView.swift`
Unchanged structurally. Re-skin list sections (Daily Schedule, Blocked Times nav row, Block Size steppers, Daily Focus, Buffer, Calendar export toggle, About).

### 7. Blocked Times — `BlockedTimeView.swift`
Unchanged structurally. Re-skin only.

### 8. Task Completion celebration — `ConfettiView.swift` / `TaskCompletionView`
Unchanged structurally (checkmark badge in context color, "Task Complete!" + title, stat rows, "Done" button, confetti burst). Just re-skin colors/type; confetti palette should include the new brand orange alongside existing context colors.

### New components with no existing counterpart (flagged for design review, not yet built in the app)
- **Empty state** pattern (icon-in-circle + heading + subtext + ghost CTA) — used for e.g. "Nothing in Personal."
- **Info/alert banner** pattern (e.g. "Synced with Canvas · 2 minutes ago") beyond the existing scheduling-warning alert.
- **Onboarding** flow (3 steps: Capture → Auto-scheduled → Stay on pace) — entirely new, no existing screen.

---

## Interactions & Behavior
- Tab bar (Tasks / Schedule / Settings) — standard `TabView`, unchanged from whatever navigation shell already exists.
- Sheets present from the bottom, ~78–90% height depending on content, standard `.sheet()` / `.presentationDetents()`.
- FAB → Capture sheet.
- Work session timer ticks every second while running (`Timer.scheduledTimer`, already implemented — no change).
- Stopping a session reveals the progress slider inline in the same sheet (not a second nested sheet).
- Day/Week toggle in Schedule is a simple two-state segmented control; switching or tapping a week-column header does not require a network/data refetch, just a different projection of the same query results.

## State Management
No new state shapes — this maps entirely onto the existing SwiftData models in `Models.swift` (`LoomTask`, `ScheduledBlock`, `WorkSession`, `BlockedTime`, `UserSettings`). The only new local UI state is:
- `scheduleView: .day | .week` in `ScheduleView`
- Selected week-day index (can reuse the existing `selectedDate` state)

## Assets
- `assets/loom-mark.png` — existing app icon artwork (from `Loom.icon/Assets/loomicon.png`), used as the wordmark lockup in the prototype's chrome. No new asset needed; it's already in `Assets.xcassets`/`Loom.icon`.
- Iconography in the prototype is simplified line/fill SVG standing in for SF Symbols (`book.fill`, `briefcase.fill`, `person.fill`, `clock.fill`, `mic`, `exclamationmark.triangle.fill`, `timer`, `checkmark.circle`, `calendar.badge.clock`, etc.) — use the actual SF Symbols in the real app, this was just a web substitution.

## Files
- `Loom Design System.dc.html` — foundations + component reference (color, type, spacing, radii, buttons, chips, cards, alerts, empty/onboarding/celebration patterns). Light/dark toggle in the top bar.
- `Loom UI Kit.dc.html` — full click-through prototype of all screens listed above, including the new Schedule Week view.
- Both require the design tool's runtime to render (`support.js`, `ios-frame.jsx` bundled alongside for reference) — **not runnable by double-clicking**.
- `screenshots/design-system-*.png` (9 images) — foundations doc: hero/brand colors, semantic colors + surface tokens (light & dark), typography, spacing/radii/elevation, buttons, chips/cards/alerts, empty/onboarding/celebration, and the in-context phone screens (light & dark).
- `screenshots/ui-kit-*.png` (13 images) — the click-through flow in order: Tasks home → Capture sheet → Bulk Entry → Work Session (idle) → timer running → progress prompt → Celebration → Schedule Day → Schedule Week → Settings → Blocked Times → Settings in light mode.
