# Loom

Loom is a time-aware task manager built around one idea: big tasks don't get done in
one heroic sitting. You give Loom a task, a deadline, and an effort estimate; it
splits the work into manageable blocks and schedules them into the real free time
you have before the deadline — around your sleep, your classes and meetings, and a
daily focus limit if you set one.

## Features

- **Capture in seconds** — type or dictate a task, pick a context (School / Work /
  Personal), a deadline, and an effort estimate. Bulk entry handles a whole syllabus.
- **Auto-scheduling** — work is chunked into blocks (configurable min/max size) and
  placed into free slots that finish before your deadline, with a safety buffer.
- **Catch-up replanning** — blocks you miss are automatically replanned from now, so
  the schedule never quietly rots.
- **Work sessions** — a focused timer per task with self-reported progress; finish at
  100% and the task completes with a small celebration.
- **Schedule views** — a day timeline and a compact week grid, including recurring
  blocked times the scheduler works around.
- **Apple Calendar export** — optional one-way export of your work blocks into a
  dedicated "Loom" calendar.

## Project

SwiftUI + SwiftData, iOS 17.5+. Open `Loom.xcodeproj` in Xcode and run the `Loom`
scheme. The visual system (colors, type, spacing, per-screen specs) lives in
`design-handoff/`.
