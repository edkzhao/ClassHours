import Foundation

// Standalone checks for the two rules that are easy to get wrong and hard to
// observe from the UI: month-boundary clipping, and what counts as "short".
// Compiled against Models.swift only -- no EventKit, no calendar data needed.

var failures = 0

func check(_ label: String, _ actual: String, _ expected: String) {
    if actual == expected {
        print("  ok    \(label)  ->  \(actual)")
    } else {
        failures += 1
        print("  FAIL  \(label)  ->  got \(actual), expected \(expected)")
    }
}

var cal = Calendar(identifier: .gregorian)
cal.locale = Locale(identifier: "en_US_POSIX")
cal.timeZone = TimeZone(identifier: "UTC")!

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Mirrors the clipping EventMonthCalculator performs.
func clip(start: Date, end: Date, into interval: HalfOpenMonthInterval) -> EventOccurrenceRecord? {
    guard interval.overlaps(start: start, end: end) else { return nil }
    let cs = max(start, interval.start)
    let ce = min(end, interval.end)
    guard ce > cs else { return nil }
    return EventOccurrenceRecord(
        id: "t", title: "t", startDate: start, endDate: end,
        countedStart: cs, countedEnd: ce,
        countedSeconds: Int(ce.timeIntervalSince(cs).rounded()),
        fullSeconds: Int(end.timeIntervalSince(start).rounded()),
        isClipped: cs > start || ce < end
    )
}

let august = HalfOpenMonthInterval.make(year: 2026, month: 8, calendar: cal)!
let september = HalfOpenMonthInterval.make(year: 2026, month: 9, calendar: cal)!

print("\nMonth-boundary split (2h event, 22:10 on Aug 31 -> 00:10 on Sep 1)")
let spanStart = date(2026, 8, 31, 22, 10)
let spanEnd = date(2026, 9, 1, 0, 10)

let inAugust = clip(start: spanStart, end: spanEnd, into: august)!
let inSeptember = clip(start: spanStart, end: spanEnd, into: september)!

check("August portion",      DurationFormatter.string(inAugust.countedSeconds),    "1h 50m")
check("September portion",   DurationFormatter.string(inSeptember.countedSeconds), "10m")
check("portions sum to full",
      DurationFormatter.string(inAugust.countedSeconds + inSeptember.countedSeconds),
      DurationFormatter.string(inAugust.fullSeconds))
check("visible in August",    "\(inAugust.isClipped)",    "true")
check("visible in September", "\(inSeptember.isClipped)", "true")

print("\nShort test reads the REAL length, never the clipped fragment")
check("10m fragment of a 2h event is not short", "\(inSeptember.isShort)", "false")
check("1h50m fragment of a 2h event is not short", "\(inAugust.isShort)",  "false")

let genuinelyShort = clip(start: date(2026, 8, 12, 15, 40),
                          end:   date(2026, 8, 12, 16, 0), into: august)!
check("a real 20m event is short", "\(genuinelyShort.isShort)", "true")

let exactly30 = clip(start: date(2026, 8, 12, 15, 30),
                     end:   date(2026, 8, 12, 16, 0), into: august)!
check("exactly 30m is NOT short (boundary)", "\(exactly30.isShort)", "false")

let just29 = clip(start: date(2026, 8, 12, 15, 31),
                  end:   date(2026, 8, 12, 16, 0), into: august)!
check("29m is short (boundary)", "\(just29.isShort)", "true")

print("\nDock feedback count mirrors the visible report")
let finishedUnchecked = clip(start: date(2026, 8, 12, 10, 0), end: date(2026, 8, 12, 11, 0), into: august)!
let finishedChecked = clip(start: date(2026, 8, 13, 10, 0), end: date(2026, 8, 13, 11, 0), into: august)!
let unfinished = clip(start: date(2026, 8, 20, 10, 0), end: date(2026, 8, 20, 11, 0), into: august)!
let badgeCount = FeedbackCounter.uncheckedCount(
    records: [finishedUnchecked, finishedChecked, unfinished, genuinelyShort],
    now: date(2026, 8, 15, 12, 0),
    countShortEvents: false,
    isChecked: { $0.startDate == finishedChecked.startDate })
check("only finished unchecked visible feedback counts", "\(badgeCount)", "1")

print("\nHalf-open interval [start, end)")
let atMidnight = date(2026, 9, 1, 0, 0)
check("Sep 1 00:00 is not in August", "\(august.contains(atMidnight))",    "false")
check("Sep 1 00:00 is in September",  "\(september.contains(atMidnight))", "true")

let endsExactlyAtBoundary = clip(start: date(2026, 8, 31, 23, 0), end: atMidnight, into: september)
check("event ending exactly at midnight does not leak into September",
      endsExactlyAtBoundary == nil ? "nil" : "leaked", "nil")

print("\nOnly finished sessions count as owed feedback")
let now = date(2026, 8, 10, 14, 0)
let ended     = clip(start: date(2026, 8, 10, 12, 0), end: date(2026, 8, 10, 13, 30), into: august)!
let inProgress = clip(start: date(2026, 8, 10, 13, 30), end: date(2026, 8, 10, 15, 0), into: august)!
let upcoming  = clip(start: date(2026, 8, 10, 16, 0), end: date(2026, 8, 10, 17, 0), into: august)!
let endsNow   = clip(start: date(2026, 8, 10, 13, 0), end: now, into: august)!

check("finished session counts",           "\(ended.hasFinished(asOf: now))",      "true")
check("session in progress does not",      "\(inProgress.hasFinished(asOf: now))", "false")
check("upcoming session does not",         "\(upcoming.hasFinished(asOf: now))",   "false")
check("session ending exactly now counts", "\(endsNow.hasFinished(asOf: now))",    "true")

// The clipped fragment is judged on the real end, so both months' rows flip
// together rather than one going stale.
let beforeRealEnd = date(2026, 9, 1, 0, 5)
check("clipped row is not finished before the real event ends",
      "\(inAugust.hasFinished(asOf: beforeRealEnd))", "false")
check("clipped row is finished after the real event ends",
      "\(inAugust.hasFinished(asOf: date(2026, 9, 1, 0, 15)))", "true")

print("\nNotes round-trip through Apple Calendar")
var n = SeriesNotes()
n.set(.coordinator, "Adam")
n.set(.advisor, "Sofia")
n.text = "Prefers worked examples."
check("encodes only the roles that are set", n.encoded(),
      "Coordinator: Adam\nAdvisor: Sofia\n---\nPrefers worked examples.")

let back = SeriesNotes.decode(n.encoded())
check("decodes coordinator", back.name(.coordinator), "Adam")
check("decodes advisor",     back.name(.advisor),     "Sofia")
check("decodes free text",   back.text,               "Prefers worked examples.")
check("manager stays empty", back.name(.manager),     "")

var pair = SeriesNotes()
pair.set(.advisor, "Sofia")
pair.set(.manager, "Jordan")
check("manager displaces advisor", pair.name(.advisor), "")
check("manager is kept",           pair.name(.manager), "Jordan")

var cleared = SeriesNotes()
cleared.set(.coordinator, "Adam")
cleared.set(.coordinator, "")
cleared.text = "just text"
check("an unset role writes no line at all", cleared.encoded(), "just text")

let plain = SeriesNotes.decode("just some notes I typed in Calendar")
check("unstructured notes survive", plain.text, "just some notes I typed in Calendar")
check("and claim no roles", "\(plain.hasAnyRole)", "false")

print("\nBulk entry expansion")
var gcal = Calendar(identifier: .gregorian)
gcal.timeZone = TimeZone(identifier: "UTC")!
var draft = SeriesDraft()
draft.start = date(2026, 8, 3, 0, 0)            // a Monday
// Thu + Sun, 10:10-12:10, 8 occurrences
draft.slots = [slot(days: [5, 1], at: 610, for: 120)]
draft.end = .count(8)
var occ = draft.occurrences(calendar: gcal)
check("count rule yields exactly 8", "\(occ.count)", "8")
check("first is the Thursday", "\(gcal.component(.day, from: occ[0].date))", "6")
check("total duration", DurationFormatter.string(occ.reduce(0){ $0 + $1.span.minutes } * 60), "16h 00m")

// Two different times in one draft
draft.slots = [
  slot(days: [2], at: 600, for: 120),      // Mon 10-12
  slot(days: [5], at: 840, for: 90),       // Thu 14-15:30
]
draft.end = .until(date(2026, 8, 31, 0, 0))
occ = draft.occurrences(calendar: gcal)
check("until rule stays inside August",
      "\(occ.allSatisfy { gcal.component(.month, from: $0.date) == 8 })", "true")
check("slots interleave chronologically",
      "\(zip(occ, occ.dropFirst()).allSatisfy { $0.0.date <= $0.1.date })", "true")
check("both slot times are present",
      "\(Set(occ.compactMap { $0.span.start }).sorted())", "[600, 840]")

print("\nTime parsing")
check("10:10 parses",     "\(TimeText.minutes("10:10") ?? -1)", "610")
check("bad text rejected","\(TimeText.minutes("25:00") ?? -1)", "-1")
check("formats back",     TimeText.hhmm(610), "10:10")

print("\nBranches are a weekday plus a time range")
let thuSeven = date(2026, 8, 6, 7, 0)       // Thursday
let thuNine = date(2026, 8, 6, 9, 0)
let branch = BranchSignature(start: thuSeven, end: thuNine, calendar: cal)!
check("same Thursday and time joins", "\(branch.matches(start: date(2026, 8, 13, 7, 0), end: date(2026, 8, 13, 9, 0), calendar: cal))", "true")
check("Monday stays another branch", "\(branch.matches(start: date(2026, 8, 3, 7, 0), end: date(2026, 8, 3, 9, 0), calendar: cal))", "false")
check("different start stays another branch", "\(branch.matches(start: date(2026, 8, 13, 8, 0), end: date(2026, 8, 13, 10, 0), calendar: cal))", "false")
check("different duration stays another branch", "\(branch.matches(start: date(2026, 8, 13, 7, 0), end: date(2026, 8, 13, 8, 30), calendar: cal))", "false")
let movedBranch = BranchSignature(start: date(2026, 8, 6, 8, 0), end: date(2026, 8, 6, 10, 0), calendar: cal)!
check("destination time identifies an existing one-off", "\(movedBranch.matches(start: date(2026, 8, 13, 8, 0), end: date(2026, 8, 13, 10, 0), calendar: cal))", "true")

print("\nRepeat editing allocates a series count chronologically")
let mondayPattern = WeeklyRepeatPattern(id: "monday", firstStart: date(2026, 8, 3, 8, 0),
                                        weekdays: [2], startMinutes: 8 * 60, durationMinutes: 120)
let wednesdayPattern = WeeklyRepeatPattern(id: "wednesday", firstStart: date(2026, 8, 5, 8, 0),
                                           weekdays: [4], startMinutes: 8 * 60, durationMinutes: 120)
let repeatEight = RepeatPlanner.occurrences(patterns: [mondayPattern, wednesdayPattern],
                                            end: .count(8), calendar: cal)
check("series total is eight", "\(repeatEight.count)", "8")
let allocated = RepeatPlanner.countsByPattern(patterns: [mondayPattern, wednesdayPattern],
                                              total: 8, calendar: cal)
check("four Mondays are retained", "\(allocated["monday"] ?? 0)", "4")
check("four Wednesdays are retained", "\(allocated["wednesday"] ?? 0)", "4")
let mondayEight = RepeatPlanner.occurrences(patterns: [mondayPattern], end: .count(8), calendar: cal)
check("branch count is independent", "\(mondayEight.count)", "8")
check("eighth Monday lands in September", "\(cal.component(.day, from: mondayEight.last!.start))", "21")

print("\nDuration formatting")
check("90 min",  DurationFormatter.string(90 * 60),  "1h 30m")
check("60 min",  DurationFormatter.string(60 * 60),  "1h 00m")
check("25 min",  DurationFormatter.string(25 * 60),  "25m")
check("decimal", DurationFormatter.decimal(173 * 3600 + 10 * 60), "173.17")

print("\nTitle normalisation for tidy-up")
check("Jonny becomes Johnny",        TidyUp.normalize("Jonny-Python"),      "Johnny-Python")
check("case insensitive",            TidyUp.normalize("JONNY Calculus"),    "Johnny Calculus")
check("only whole words",            TidyUp.normalize("Jonnyson"),          "Jonnyson")
check("already correct is untouched",TidyUp.normalize("Johnny-Python"),     "Johnny-Python")
check("whitespace collapsed",        TidyUp.normalize("  Kate   Calculus "),"Kate Calculus")
check("unrelated titles untouched",  TidyUp.normalize("SAT Math"),          "SAT Math")

print("\nDetached-occurrence keys resolve back to their series")
// Taken verbatim from the app's stored data: editing one occurrence made
// EventKit hand back "<UID>/RID=<timestamp>".
let masterUID = "1E77A890-FF78-402F-852C-4A62E0EDBFFA"
check("detached key strips the RID suffix",
      SeriesKey.normalize(masterUID + "/RID=805784400"), masterUID)
check("a second detach maps to the same series",
      SeriesKey.normalize(masterUID + "/RID=805957200"), masterUID)
check("both detaches agree",
      "\(SeriesKey.normalize(masterUID + "/RID=805784400") == SeriesKey.normalize(masterUID + "/RID=805957200"))",
      "true")
check("an untouched key is unchanged", SeriesKey.normalize(masterUID), masterUID)
check("empty stays empty", SeriesKey.normalize(""), "")

// MARK: - The calendar's opening band

print("\nTime Range accepts a forward span inside one day")

do {
    check("the default band", "\(DayRange.isValid(start: 8*60, end: 23*60))", "true")
    check("a half hour start", "\(DayRange.isValid(start: 8*60+30, end: 23*60))", "true")
    check("midnight to midnight is the whole day",
          "\(DayRange.isValid(start: 0, end: 24*60))", "true")
    check("24:00 is a valid end", "\(DayRange.isValid(start: 22*60, end: 24*60))", "true")

    check("24:00 is not a valid start", "\(DayRange.isValid(start: 24*60, end: 24*60))", "false")
    check("past the end of the day is rejected",
          "\(DayRange.isValid(start: 8*60, end: 24*60+30))", "false")
    check("a backwards range is rejected", "\(DayRange.isValid(start: 20*60, end: 9*60))", "false")
    check("a zero-length range is rejected", "\(DayRange.isValid(start: 9*60, end: 9*60))", "false")
    check("a negative start is rejected", "\(DayRange.isValid(start: -60, end: 9*60))", "false")

    check("a valid pair comes back", "\(DayRange.clamped(start: 510, end: 1380)?.start ?? -1)", "510")
    check("an invalid pair does not",
          "\(DayRange.clamped(start: 1380, end: 510).map { _ in "yes" } ?? "nil")", "nil")
}

// MARK: - Hiding the calendar name prefix

print("\nA calendar's own name comes off the front of its events")

do {
    check("fullwidth colon", TitlePrefix.strip("考而思：高培-科学推理", prefix: "考而思"), "高培-科学推理")
    check("ascii colon", TitlePrefix.strip("考而思: Zhu-Statistics", prefix: "考而思"), "Zhu-Statistics")
    check("a hyphen also separates", TitlePrefix.strip("思拓-Kate Calculus", prefix: "思拓"), "Kate Calculus")
    check("spaces around it are eaten", TitlePrefix.strip("新东方 ： Lily", prefix: "新东方"), "Lily")

    // Guards: nothing else may be trimmed.
    check("a different prefix is left alone",
          TitlePrefix.strip("考而思：高培", prefix: "新东方"), "考而思：高培")
    check("no separator means no prefix",
          TitlePrefix.strip("考而思高培", prefix: "考而思"), "考而思高培")
    check("a longer word is not a prefix match",
          TitlePrefix.strip("Mathsy: X", prefix: "Math"), "Mathsy: X")
    check("an empty prefix does nothing",
          TitlePrefix.strip("考而思：高培", prefix: ""), "考而思：高培")
    check("a title that is only the prefix is kept",
          TitlePrefix.strip("考而思：", prefix: "考而思"), "考而思：")
    check("an unrelated title is untouched",
          TitlePrefix.strip("MATH 50:640:115", prefix: "考而思"), "MATH 50:640:115")
}

// MARK: - Holiday feeds

print("\nSubscribed holiday feeds are read straight from the .ics")

do {
    let feedID = UUID()
    let ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260704
    SUMMARY:Independence Day
    DESCRIPTION:Observed nationwide\\, with fireworks.
    END:VEVENT
    BEGIN:VEVENT
    DTSTART:20261126T000000Z
    SUMMARY:Thanksgiving
     Day
    END:VEVENT
    BEGIN:VEVENT
    SUMMARY:No date at all
    END:VEVENT
    END:VCALENDAR
    """

    let found = ICSParser.parse(ics, feedID: feedID)
    check("two usable entries", "\(found.count)", "2")
    check("a DATE start becomes a day", found[0].day, "2026-07-04")
    check("summary is read", found[0].title, "Independence Day")
    check("escapes are undone", found[0].detail, "Observed nationwide, with fireworks.")
    check("a timestamped start also becomes a day", found[1].day, "2026-11-26")
    check("folded lines are rejoined", found[1].title, "ThanksgivingDay")

    // A feed with no date must be dropped rather than landing on day zero.
    check("an entry with no date is skipped",
          "\(found.contains { $0.title == "No date at all" })", "false")

    check("webcal is fetched over https",
          HolidayFeed(url: "webcal://example.com/a.ics").fetchURL?.absoluteString ?? "-",
          "https://example.com/a.ics")
    check("an https link is usable", "\(HolidayFeed(url: "https://x/a.ics").isUsable)", "true")
    check("a bare word is not", "\(HolidayFeed(url: "holidays").isUsable)", "false")
    check("the alias names the feed", HolidayFeed(url: "https://x/a.ics", alias: "US").displayName, "US")
    check("without one, the host does", HolidayFeed(url: "https://x/a.ics").displayName, "x")
}

// MARK: - Links in notes

print("\nLinks in notes are detected for opening")

do {
    let text = "Zoom: https://zoom.us/j/123 and notes at example.com/plan"
    let found = LinkScanner.links(in: text)
    check("both links are found", "\(found.count)", "2")
    check("the first is the zoom link", found[0].url.absoluteString, "https://zoom.us/j/123")
    check("plain text has none", "\(LinkScanner.links(in: "no links here").count)", "0")
    check("empty text has none", "\(LinkScanner.links(in: "").count)", "0")
}

/// Builds a complete slot the way the panel does.
func slot(days: Set<Int>, at start: Int, for minutes: Int) -> SeriesSlot {
    var s = SeriesSlot()
    s.weekdays = days
    s.span.start = start
    s.span.duration = minutes
    return s
}

// MARK: - Title matching

print("\nTyping a class name finds it in either script")

do {
    let mixed = "考而思：Zhu-Statistics"

    check("English half matches", "\(TitleSearch.matches("zhu", title: mixed))", "true")
    check("case is ignored", "\(TitleSearch.matches("STAT", title: mixed))", "true")
    check("Chinese half matches", "\(TitleSearch.matches("考而思", title: mixed))", "true")
    check("pinyin reaches the Chinese half", "\(TitleSearch.matches("kaoer", title: mixed))", "true")
    check("full pinyin with no spaces matches", "\(TitleSearch.matches("kaoersi", title: mixed))", "true")
    check("pinyin initials reach it too", "\(TitleSearch.matches("kes", title: mixed))", "true")
    check("spaced pinyin matches", "\(TitleSearch.matches("kao er", title: mixed))", "true")
    check("an unrelated query does not match", "\(TitleSearch.matches("calculus", title: mixed))", "false")
    check("empty query matches nothing", "\(TitleSearch.matches("", title: mixed))", "false")

    check("新东方 romanises", TitleSearch.romanised("新东方"), "xin dong fang")
    check("initials of a romanisation", TitleSearch.syllableInitials("kao er si"), "kes")

    // A literal hit must outrank a romanised one, or every 思 buries the class
    // actually spelt "Si".
    let literal = TitleSearch.score("si", title: "Si-Physics") ?? 99
    let viaPinyin = TitleSearch.score("si", title: "考而思：Chem") ?? 99
    check("a literal hit outranks a romanised one", "\(literal < viaPinyin)", "true")
}

// MARK: - Incomplete slots create nothing

print("\nA half-filled When section produces no occurrences")

do {
    var d = SeriesDraft()
    d.start = date(2026, 8, 3, 0, 0)
    d.end = .count(4)

    d.slots = [SeriesSlot()]
    check("no day and no time yields nothing", "\(d.occurrences(calendar: cal).count)", "0")

    var dayOnly = SeriesSlot(); dayOnly.weekdays = [2]
    d.slots = [dayOnly]
    check("a day with no time yields nothing", "\(d.occurrences(calendar: cal).count)", "0")

    var timeOnly = SeriesSlot(); timeOnly.span.start = 600
    d.slots = [timeOnly]
    check("a time with no day yields nothing", "\(d.occurrences(calendar: cal).count)", "0")

    let full = slot(days: [2], at: 600, for: 120)
    d.slots = [full]
    check("a complete slot does produce them", "\(d.occurrences(calendar: cal).count)", "4")

    // One usable slot alongside an empty one must not be blocked by it.
    d.slots = [full, SeriesSlot()]
    check("an empty extra row is ignored", "\(d.occurrences(calendar: cal).count)", "4")
}

// MARK: - Duration, midnight, and Sessions mode

print("\nDuration decides the end, and carries a class past midnight")

do {
    var span = TimeSpan()
    span.start = 11 * 60 + 10
    span.duration = 90
    check("a preset sets the end", span.endLabel ?? "-", "12:40")
    check("length is the duration", "\(span.minutes)", "90")
    check("an ordinary class stays on its day", "\(span.crossesMidnight)", "false")

    span.start = 23 * 60
    span.duration = 120
    check("23:00 for 2h reads as 01:00", span.endLabel ?? "-", "01:00")
    check("and is flagged as the next day", "\(span.crossesMidnight)", "true")
    check("its length is still two hours", "\(span.minutes)", "120")
    check("the offset runs past 24h", "\(span.resolvedEnd ?? -1)", "\(25 * 60)")

    // Custom: the end is typed, and an earlier end means tomorrow.
    var custom = TimeSpan()
    custom.duration = nil
    custom.start = 22 * 60 + 30
    custom.end = 30
    check("a typed end before the start is the next day", "\(custom.minutes)", "120")
    check("custom crossing is flagged too", "\(custom.crossesMidnight)", "true")
    custom.end = 23 * 60 + 30
    check("a normal typed end is same-day", "\(custom.minutes)", "60")
    check("and is not flagged", "\(custom.crossesMidnight)", "false")

    // Adopting a real event picks the preset only when one fits exactly.
    check("90 minutes matches a preset", "\(TimeSpan.matching(minutes: 90).duration ?? -1)", "90")
    check("70 minutes falls back to custom",
          "\(TimeSpan.matching(minutes: 70).duration.map(String.init) ?? "custom")", "custom")
    check("a preset is labelled", TimeSpan.label(90), "1h 30m")
    check("two hours is the default", "\(TimeSpan().duration ?? -1)", "120")
    check("a quarter hour is labelled", TimeSpan.label(15), "0h 15m")
}

print("\nSessions mode takes dates that follow no pattern")

do {
    var d = SeriesDraft()
    d.mode = .sessions

    // The case that could not be entered before: one Saturday, one Wednesday.
    var sat = SeriesSession(); sat.date = date(2026, 8, 15, 0, 0)
    sat.span.start = 14 * 60; sat.span.duration = 120
    var wed = SeriesSession(); wed.date = date(2026, 8, 19, 0, 0)
    wed.span.start = 12 * 60; wed.span.duration = 90
    d.sessions = [wed, sat]        // deliberately out of order

    let occ = d.occurrences(calendar: cal)
    check("both sessions are produced", "\(occ.count)", "2")
    check("they come back in date order",
          "\(cal.component(.day, from: occ[0].date))", "15")
    check("each keeps its own length", "\(occ.map(\.span.minutes))", "[120, 90]")
    check("the pattern's Starting/Ends are ignored", "\(d.totalMinutes)", "210")

    d.sessions = [SeriesSession()]
    check("a session with no time yields nothing", "\(d.occurrences(calendar: cal).count)", "0")

    // Switching back must not pick up the sessions.
    d.mode = .repeats
    d.slots = []
    check("repeats mode ignores sessions", "\(d.occurrences(calendar: cal).count)", "0")
}

// MARK: - Today ring geometry

print("\nToday ring: arcs are shares of the day, fill is taught minutes")

/// Fractions compared at ring resolution -- a ring is ~290pt around, so
/// anything under 1e-6 of a turn is far below a pixel.
func checkF(_ label: String, _ actual: Double, _ expected: Double) {
    if abs(actual - expected) < 1e-9 {
        print("  ok    \(label)  ->  \(String(format: "%.4f", actual))")
    } else {
        failures += 1
        print("  FAIL  \(label)  ->  got \(actual), expected \(expected)")
    }
}

do {
    typealias S = DayRingMath.Span
    // 09:00-11:00, 13:00-14:30, 16:00-17:00  ->  2h + 1.5h + 1h = 4h 30m
    let day = [S(start: 540, end: 660), S(start: 780, end: 870), S(start: 960, end: 1020)]

    check("total is the day's teaching time", "\(DayRingMath.total(day))", "270")

    let slices = DayRingMath.slices(day)
    check("one arc per class", "\(slices.count)", "3")
    checkF("ring starts at zero", slices.first!.from, 0)
    checkF("ring closes at one", slices.last!.to, 1)
    checkF("arcs are contiguous", slices[0].to, slices[1].from)
    checkF("arcs are contiguous 2", slices[1].to, slices[2].from)
    checkF("arc share matches duration", slices[0].to - slices[0].from, 120.0 / 270.0)

    checkF("before the first class, nothing filled", DayRingMath.progress(day, minute: 480), 0)
    checkF("first class done fills its own arc", DayRingMath.progress(day, minute: 660), 120.0 / 270.0)
    checkF("a gap between classes does not advance the fill",
           DayRingMath.progress(day, minute: 770), 120.0 / 270.0)
    checkF("mid-class fills partway into that arc",
           DayRingMath.progress(day, minute: 825), 165.0 / 270.0)
    checkF("end of day is a full ring", DayRingMath.progress(day, minute: 1439), 1)

    // Degenerate days must not divide by zero or leave stray arcs.
    check("empty day has no arcs", "\(DayRingMath.slices([]).count)", "0")
    checkF("empty day has no fill", DayRingMath.progress([], minute: 700), 0)
    check("zero-length class is dropped",
          "\(DayRingMath.slices([S(start: 600, end: 600), S(start: 700, end: 760)]).count)", "1")

    let overlap = [S(start: 540, end: 660), S(start: 600, end: 720)]
    checkF("overlapping bookings still close the ring", DayRingMath.slices(overlap).last!.to, 1)

    let unsorted = [S(start: 900, end: 960), S(start: 540, end: 600)]
    check("ordered puts the earlier class first",
          "\(DayRingMath.ordered(unsorted).first!.start)", "540")
}


print("")
if failures == 0 {
    print("All checks passed.")
    exit(0)
} else {
    print("\(failures) check(s) FAILED.")
    exit(1)
}
