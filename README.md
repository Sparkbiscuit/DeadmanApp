# Loom

Loom is a time-aware task manager built around one idea: big tasks don't get done in
one heroic sitting. You give Loom a task, a deadline, and an effort estimate; it
splits the work into manageable blocks and schedules them into the real free time
you have before the deadline — around your sleep, your classes and meetings, and a
daily focus limit if you set one.

## Features

- **Capture in seconds** — type or dictate a task, pick a context (School / Work /
  Personal), a deadline, and an effort estimate. Bulk entry handles a whole syllabus.
- **Right Now card** — the top of the Tasks tab always answers "what should I be
  doing this minute?": the running block (with elapsed/remaining) or the next one
  up, with a single big Start button. Opening the app never requires a decision.
- **First step** — optionally capture the very first physical action ("open the doc,
  paste the data table"). It shows in the Right Now card, the block-start
  notification, and the session timer, then clears itself once you've started.
- **Overdue triage** — tasks that slip past their deadline move into a "Needs a
  decision" queue with three kind exits: new deadline, done actually, or let it go.
  No guilt pile.
- **Auto-scheduling** — work is chunked into blocks (configurable min/max size) and
  placed into free slots that finish before your deadline, with a safety buffer.
- **Catch-up replanning** — blocks you miss are automatically replanned, and the
  whole schedule rebalances earliest-deadline-first, so an urgent task claims
  near slots from work that can wait.
- **Reminders** — one-off reminders with local notifications, alongside the
  scheduled tasks. They appear in the Up Next widget with your work blocks, and
  completed ones land in the Completed section where they can be restored.
- **Work sessions** — a focused timer per task with self-reported progress; finish at
  100% and the task completes with a small celebration. A Live Activity mirrors the
  running timer on the Lock Screen and in the Dynamic Island.
- **Honest progress** — checking off a time block logs the time you worked; how much
  of the task is actually done is always yours to say.
- **Schedule views** — a day timeline and a compact week grid, including recurring
  blocked times the scheduler works around.
- **Apple Calendar sync** — optional one-way export of your work blocks into a
  dedicated "Loom" calendar, and optional import that treats events from the
  calendars you choose as busy time the scheduler works around.
- **Widgets** — an Up Next widget for the Home Screen and Lock Screen, plus a
  Live Activity while a work session timer is running.

## Project

SwiftUI + SwiftData, iOS 17.5+. Open `Loom.xcodeproj` in Xcode and run the `Loom`
scheme. The visual system (colors, type, spacing, per-screen specs) lives in
`design-handoff/`.
