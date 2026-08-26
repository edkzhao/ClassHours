# ClassHours

A macOS app that totals how many hours a month of calendar events adds up to.
Rebuilt from `Time++`, with a new interface.

With Calendar permission, ClassHours can create, edit, and delete sessions from
its own calendar view. Those changes are applied to the selected local calendar.

## Build and run

The app lives at `/Applications/ClassHours.app`. To rebuild and update it:

```bash
./build.sh
```

That builds, quits the app if it's running, and replaces the installed copy —
so afterwards you just open ClassHours as usual. Pass `--no-install` to build
into `build/` without touching `/Applications`.

Sandboxed and ad-hoc signed. No Xcode project; `swiftc` compiles the sources and
assembles the bundle directly.

Settings and feedback checkboxes live in the sandbox container, keyed by bundle
ID, so they survive rebuilds and moving the app around.

> **After a rebuild, macOS may ask for Calendar access again.** Ad-hoc signing
> derives the app's identity from the binary itself, so changing the code
> changes that identity and the permission no longer matches. Click **Grant
> Access** and allow — your settings and checkboxes are untouched, since those
> are keyed by bundle ID rather than signature. A Developer ID certificate would
> avoid it; ad-hoc signing can't.

## Renaming the app

The display name lives in exactly one place: `Brand.name` in
[Sources/Theme.swift](Sources/Theme.swift). Change it, then update
`CFBundleName` / `CFBundleExecutable` in `Resources/Info.plist` and the `APP`
variable in `build.sh` if you want the binary renamed too.

## The two rules that are easy to get wrong

**Month-boundary clipping.** An event straddling a month boundary contributes
only its in-month portion, and appears in *both* months. A 2-hour session
running 22:10 → 00:10 on the 31st puts 1h 50m in the first month and 10m in the
next. This is always applied, independent of every other setting.

Such a row shows the event's **real** date and times, with the duration counted
for that month only, and an ⓘ next to it. Viewed in August, a session carried in
from July reads:

```
Fri 31 Jul   Sample Event   22:10   00:10   (i) 10m
```

The date is the event's real start day, not the clipped one. Otherwise a daily
recurring class would show identical `22:10 → 00:10` rows under the same date —
the carried-in occurrence and the 1st's own occurrence would look like a
duplicate when they are two different sessions.

Hovering the ⓘ shows, immediately:

```
Overlapping Event
Duration:   2h 00m
Counted:       10m
```

This is a custom hover card, not `.help()` — the system tooltip has a fixed
~2 second delay that can't be configured, which is far too slow for a glance.
The card opens downward on a month's first row and upward on its last, since
those are exactly where spanning events land and a fixed direction would clip
against the header or the footer.

**`Count <30m`.** Off by default, and set **per calendar** — a calendar of short
admin blocks wants different treatment from one full of two-hour classes. When off, events shorter than 30 minutes are
still listed — flagged with ⏱️ on their duration — but excluded from the total,
the event count, the average, and the chart, and they get no feedback checkbox.
When on, they behave like any other event with no extra marks.

The 30-minute test reads the event's **real** length, never the clipped
fragment. The 10-minute tail above still counts, because the event it came from
is 2 hours long. A session is only "short" if it is genuinely short.

The core calendar rules and other pure logic are covered by `Tests/main.swift`:

```bash
swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework SwiftUI -framework EventKit -framework AppKit \
  -o build/logictests \
  $(find Sources -name '*.swift' ! -name 'ClassHoursApp.swift' -print) \
  Tests/main.swift && ./build/logictests
```

## Feedback checkboxes

The first time a given calendar + month is opened, every event **before today**
is marked done. Months of history don't need clicking through. Today and
everything after it start unchecked.

Seeding writes real values and runs once per calendar+month, so:

- unchecking something seeded stays unchecked, across relaunches;
- a month already seeded won't re-seed as days pass — yesterday's sessions stay
  unchecked until you check them, which is what makes *Unchecked feedback*
  useful for tracking what you still owe;
- short events are seeded too, so toggling `Count <30m` reveals boxes that
  already match your record instead of resetting anything.

Column visibility is **per calendar**. Checkbox state is stored per calendar.

### What *Unchecked feedback* counts

Unchecked sessions that have **already finished** — measured against the real
clock, not the start of the day. A class still in progress straddles now and is
not yet feedback you owe, and neither is anything later today. The number
re-evaluates once a minute while the window is open.

For a session split across two months, both rows use the real event end, so
they flip together rather than one going stale at the month boundary.

## Other behaviour

- Rows are always chronological. There is no sorting.
- All-day and cancelled events are excluded.
- Recurring occurrences are deduplicated on event / external / calendar /
  occurrence identity.
- Calendars are grouped by source and ordered like Calendar.app's sidebar.
- Search and the metrics operate on the same filtered set — searching recomputes
  the total.
- **Today** scrolls the first event of today to a quarter down the viewport, so
  a little of yesterday stays visible above and most of the day sits below.
  Launching the app and switching calendars both land there too, rather than at
  the top of the month. If today has no events, it falls forward to the next day
  that does.
- **Chart bars** deepen in colour with hours, so shade reinforces height rather
  than splitting the month into weekdays and weekends. Today's bar is amber.
- **Clicking a chart bar** jumps to that day; **clicking *Unchecked feedback***
  jumps to the oldest session still awaiting it. Both give the destination rows
  a single slow pulse — the same soft wash used to mark today, behind the text
  so nothing is tinted over. Today's own jump doesn't pulse: it happens on every
  launch, and a flash there would just be noise.

## Editing branches

A ClassHours series can contain several schedules. The Event editor has an
**Apply to** switch beside the event name, defaulting to **Series**. Change it
to **Branch** before editing when the change should stay on the matching weekday
and time range — for example, Thursday 19:00–21:00 rather than a Monday
10:00–12:00 branch in the same series.

Titles, times, notes, roles, deletion, and calendar moves use that switch and
then ask for an occurrence range only when one is meaningful. Repeat boundaries
can be edited as an occurrence count or an inclusive end date; they always apply
to the whole selected branch/series and therefore save without another range
question. An existing one-off event joins a branch automatically when its
weekday and time range match.

New and edited events list future overlaps in a height-limited, scrollable
preview. The macOS Dock badge mirrors the unchecked feedback count in the
currently selected Hours report.

## Sidebar

Collapsible, so the window can be dragged genuinely small. Toggle it with the
button at the top-left, `⌥⌘S`, or View ▸ Hide Sidebar.

Below **900 pt** of window width it folds away on its own. That override is
temporary and doesn't overwrite your choice — widen the window again and the
sidebar comes back if that's how you left it.

Minimum window size is 680×560.

## Keyboard

| | |
|---|---|
| `⌘←` / `⌘→` | previous / next month |
| `⌘T` | today |
| `⌘R` | refresh |
| `⌘F` | search |
| `⌥⌘S` | show / hide sidebar |

## Layout

| File | |
|---|---|
| `Sources/Theme.swift` | Brass palette, type scale, app name |
| `Sources/Models.swift` | records, month interval, duration formatting |
| `Sources/EventMonthCalculator.swift` | EventKit fetch, filter, dedupe, clip |
| `Sources/AppState.swift` | state, persistence, derived metrics |
| `Sources/Components.swift` | readout, stat cards, chart, controls |
| `Sources/ContentView.swift` | sidebar, toolbar, summary, table |

## Palette

Deep pine-teal ground, brass-gold accent. The accent appears in exactly one
place — the month total — so it always means the number you came for. A separate
warm tone (`mark`) carries today and interactive state, so the two never blur.

Swapping palettes means editing the values in `Palette`; every component reads
through those tokens.
