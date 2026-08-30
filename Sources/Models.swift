import Foundation

/// A month as a half-open interval `[start, end)`.
///
/// Half-open matters: an event beginning exactly at midnight on the 1st belongs
/// to the new month only, so it can never be counted twice across a boundary.
struct HalfOpenMonthInterval {
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// True when the event overlaps this month at all.
    func overlaps(start eventStart: Date, end eventEnd: Date) -> Bool {
        eventEnd > start && eventStart < end
    }

    static func make(year: Int, month: Int, calendar: Calendar) -> HalfOpenMonthInterval? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let start = calendar.date(from: comps),
              let end = calendar.date(byAdding: .month, value: 1, to: start)
        else { return nil }
        return HalfOpenMonthInterval(start: start, end: end)
    }
}

/// One calendar the user can pick, carrying enough to group and order the list
/// the way Calendar.app's sidebar does.
struct CalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
    let sourceRank: Int
    let colorIndex: Int

    var displayName: String { title }
}

/// One occurrence of an event, already clipped to the selected month.
///
/// `countedStart`/`countedEnd` are the clipped bounds; `startDate`/`endDate`
/// remain the event's real bounds. The distinction is the whole point: an
/// event straddling a month boundary contributes only its in-month portion.
struct EventOccurrenceRecord: Identifiable, Hashable {
    let id: String
    /// Key used for the feedback checkbox — see EventMonthCalculator.stableIdentity.
    var stableID: String = ""
    /// EventKit identifier, so a row can open the same detail panel the
    /// calendar page uses.
    var eventID: String = ""
    /// Parsed once here rather than per redraw.
    var notes = SeriesNotes()
    /// The series this occurrence belongs to, for "remaining" and the final marker.
    var seriesKey: String = ""
    let title: String
    let startDate: Date
    let endDate: Date
    let countedStart: Date
    let countedEnd: Date
    let countedSeconds: Int
    /// The event's real length, ignoring any clipping.
    let fullSeconds: Int
    /// True when the month boundary trimmed either end.
    let isClipped: Bool

    /// Short is judged on the event's REAL length, never on the clipped
    /// fragment. A two-hour session is not a short session just because only
    /// ten minutes of it landed inside this month.
    var isShort: Bool { fullSeconds < 30 * 60 }

    /// The key `AppState.event(forKey:)` expects, so an hours-table row can
    /// open the same detail panel the calendar page uses.
    var panelKey: String { "\(eventID)|\(startDate.timeIntervalSinceReferenceDate)" }

    /// True once the session is entirely over.
    ///
    /// Measured against the event's real end, and strictly in the past -- a
    /// class currently in progress straddles `now` and is not finished, so it
    /// is not yet feedback you owe.
    func hasFinished(asOf now: Date) -> Bool { endDate <= now }
}

/// The Dock badge deliberately uses the same records and rules as the visible
/// feedback column. That keeps its number understandable: it is never a wider
/// scan of hidden calendars or old months.
enum FeedbackCounter {
    static func uncheckedCount(records: [EventOccurrenceRecord], now: Date,
                               countShortEvents: Bool,
                               feedbackEnabled: Bool,
                               isChecked: (EventOccurrenceRecord) -> Bool) -> Int {
        guard feedbackEnabled else { return 0 }
        return records.reduce(into: 0) { count, record in
            guard record.hasFinished(asOf: now),
                  (countShortEvents || !record.isShort),
                  !isChecked(record)
            else { return }
            count += 1
        }
    }
}

enum SeriesKey {
    /// Reduces an EventKit identifier to the thing that identifies the *series*.
    ///
    /// Editing one occurrence of a recurring event detaches it, and EventKit
    /// gives the detached instance an identifier of the form
    /// `<UID>/RID=<timestamp>`. Left as-is that reads as a brand-new event, so
    /// the occurrence dropped out of its series and lost its feedback tick every
    /// time it was edited. Stripping the suffix maps it back to where it came
    /// from.
    static func normalize(_ raw: String) -> String {
        guard let marker = raw.range(of: "/RID=") else { return raw }
        return String(raw[..<marker.lowerBound])
    }
}

/// One time line inside a ClassHours series. A branch is deliberately derived
/// from the event itself rather than stored in Notes: a one-off event joins the
/// matching branch as soon as its weekday and time range line up.
struct BranchSignature: Hashable {
    let weekday: Int
    let startMinutes: Int
    let durationMinutes: Int

    init?(start: Date, end: Date, calendar: Calendar) {
        let duration = Int(end.timeIntervalSince(start) / 60)
        guard duration > 0 else { return nil }
        weekday = calendar.component(.weekday, from: start)
        startMinutes = TimeText.minutes(of: start, calendar)
        durationMinutes = duration
    }

    func matches(start: Date, end: Date, calendar: Calendar) -> Bool {
        calendar.component(.weekday, from: start) == weekday
            && TimeText.minutes(of: start, calendar) == startMinutes
            && Int(end.timeIntervalSince(start) / 60) == durationMinutes
    }

    func label(calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let day = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
        let end = (startMinutes + durationMinutes) % (24 * 60)
        return "\(day) \(TimeText.hhmm(startMinutes))–\(TimeText.hhmm(end))"
    }
}

/// A future event that overlaps an event being drafted. Conflicts are advisory:
/// they help spot a collision without turning scheduling into a hard blocker.
struct EventConflict: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarTitle: String
}

/// One weekly line used when previewing or redistributing a repeat boundary.
/// Several patterns may share an id when one EventKit recurrence contains
/// more than one weekday.
struct WeeklyRepeatPattern: Hashable {
    let id: String
    let firstStart: Date
    let weekdays: Set<Int>
    let startMinutes: Int
    let durationMinutes: Int
}

struct PlannedRepeatOccurrence: Hashable {
    let patternID: String
    let start: Date
    let end: Date
}

enum RepeatPlanner {
    /// Expands the same weekly model used by New Event. A count is global
    /// across all supplied patterns, while an end date is inclusive.
    static func occurrences(patterns: [WeeklyRepeatPattern], end: SeriesEnd,
                            calendar: Calendar, limit: Int = 400) -> [PlannedRepeatOccurrence] {
        guard !patterns.isEmpty else { return [] }
        let wanted: Int
        let lastDay: Date?
        switch end {
        case .count(let count):
            wanted = min(limit, max(1, count))
            lastDay = nil
        case .until(let date):
            wanted = limit
            lastDay = calendar.startOfDay(for: date)
        }

        let ordered = patterns.sorted {
            if $0.startMinutes != $1.startMinutes { return $0.startMinutes < $1.startMinutes }
            return $0.id < $1.id
        }
        var cursor = ordered.map { calendar.startOfDay(for: $0.firstStart) }.min()!
        var output: [PlannedRepeatOccurrence] = []
        var guardDays = 0
        while output.count < wanted && guardDays < 2_800 {
            guardDays += 1
            if let lastDay, cursor > lastDay { break }
            let weekday = calendar.component(.weekday, from: cursor)
            for pattern in ordered where pattern.weekdays.contains(weekday)
                && cursor >= calendar.startOfDay(for: pattern.firstStart) {
                if output.count >= wanted { break }
                guard let start = calendar.date(byAdding: .minute, value: pattern.startMinutes, to: cursor),
                      let finish = calendar.date(byAdding: .minute,
                                                 value: pattern.startMinutes + pattern.durationMinutes,
                                                 to: cursor)
                else { continue }
                output.append(.init(patternID: pattern.id, start: start, end: finish))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return output.sorted { $0.start < $1.start }
    }

    static func countsByPattern(patterns: [WeeklyRepeatPattern], total: Int,
                                calendar: Calendar) -> [String: Int] {
        Dictionary(grouping: occurrences(patterns: patterns, end: .count(total), calendar: calendar),
                   by: \.patternID)
            .mapValues(\.count)
    }
}

/// A recurrence is allowed to add future sessions when its boundary is moved,
/// but must never retroactively fill dates that were absent before the change.
/// EventKit expands recurrence rules lazily, so this small pure helper compares
/// the pre-save and post-save views and identifies only those accidental past
/// additions that need to become exceptions.
enum RecurrenceExpansionGuard {
    static func accidentalPastIDs(before: Set<String>,
                                   after: [(id: String, start: Date)],
                                   today: Date,
                                   calendar: Calendar) -> Set<String> {
        let floor = calendar.startOfDay(for: today)
        return Set(after.compactMap { occurrence in
            occurrence.start < floor && !before.contains(occurrence.id) ? occurrence.id : nil
        })
    }
}

struct RepeatOccurrenceModification: Hashable {
    let before: PlannedRepeatOccurrence
    let after: PlannedRepeatOccurrence
}

enum RepeatScheduleContractor {
    static func clip(_ baseline: [PlannedRepeatOccurrence],
                     to end: SeriesEnd,
                     calendar: Calendar) -> [PlannedRepeatOccurrence] {
        switch end {
        case .until(let cutoff):
            let finalDay = calendar.startOfDay(for: cutoff)
            return baseline.filter { calendar.startOfDay(for: $0.start) <= finalDay }
                .sorted { $0.start < $1.start }
        case .count(let count):
            return Array(baseline.sorted { $0.start < $1.start }.prefix(max(1, count)))
        }
    }
}

/// The canonical description of a repeat edit. Both the preview and the
/// EventKit reconciliation consume this diff, so an occurrence that already
/// belongs to the old schedule can never be mistaken for a newly-added one.
struct RepeatEditPlan: Hashable {
    let unchanged: [PlannedRepeatOccurrence]
    let removed: [PlannedRepeatOccurrence]
    let added: [PlannedRepeatOccurrence]
    let modified: [RepeatOccurrenceModification]

    static func make(baseline: [PlannedRepeatOccurrence],
                     desired: [PlannedRepeatOccurrence],
                     scheduleChanged: Bool) -> RepeatEditPlan {
        let old = baseline.sorted { $0.start < $1.start }
        let revised = desired.sorted { $0.start < $1.start }
        var unchanged: [PlannedRepeatOccurrence] = []
        var removed: [PlannedRepeatOccurrence] = []
        var added: [PlannedRepeatOccurrence] = []
        var modified: [RepeatOccurrenceModification] = []

        // EventKit identifiers are storage details, not schedule identity.
        // Detached occurrences and ClassHours-grouped recurrence masters can
        // legitimately use different identifiers for the same live session.
        // Match the complete target schedule as a minute-precision multiset.
        var oldByMinute = Dictionary(grouping: old.indices,
                                     by: { minuteKey(old[$0].start) })
        var matchedOld = Set<Int>()
        var matchedNew = Set<Int>()
        for newIndex in revised.indices {
            let key = minuteKey(revised[newIndex].start)
            guard var candidates = oldByMinute[key],
                  let oldIndex = candidates.first(where: { !matchedOld.contains($0) })
            else { continue }
            candidates.removeAll { $0 == oldIndex }
            oldByMinute[key] = candidates
            matchedOld.insert(oldIndex)
            matchedNew.insert(newIndex)
            if scheduleChanged && minuteKey(old[oldIndex].end) != minuteKey(revised[newIndex].end) {
                modified.append(.init(before: old[oldIndex], after: revised[newIndex]))
            } else {
                unchanged.append(old[oldIndex])
            }
        }

        var unmatchedOld = old.indices.filter { !matchedOld.contains($0) }.map { old[$0] }
        var unmatchedNew = revised.indices.filter { !matchedNew.contains($0) }.map { revised[$0] }
        if scheduleChanged {
            let pairCount = min(unmatchedOld.count, unmatchedNew.count)
            for index in 0..<pairCount {
                modified.append(.init(before: unmatchedOld[index], after: unmatchedNew[index]))
            }
            unmatchedOld.removeFirst(pairCount)
            unmatchedNew.removeFirst(pairCount)
        }
        removed.append(contentsOf: unmatchedOld)
        added.append(contentsOf: unmatchedNew)

        return RepeatEditPlan(
            unchanged: unchanged.sorted { $0.start < $1.start },
            removed: removed.sorted { $0.start < $1.start },
            added: added.sorted { $0.start < $1.start },
            modified: modified.sorted { $0.after.start < $1.after.start })
    }

    func futureConflictCandidates(asOf now: Date) -> [PlannedRepeatOccurrence] {
        (added + modified.map(\.after))
            .filter { $0.end > now }
            .sorted { $0.start < $1.start }
    }

    private static func minuteKey(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate / 60).rounded())
    }
}

/// Small, in-memory-only undo history. Actions are intentionally closures so
/// nothing is serialized: quitting the app drops the history by design.
final class SessionUndoStack {
    private let limit: Int
    private var actions: [() -> Void] = []

    init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    var count: Int { actions.count }

    func register(_ action: @escaping () -> Void) {
        actions.append(action)
        if actions.count > limit { actions.removeFirst(actions.count - limit) }
    }

    @discardableResult
    func undo() -> Bool {
        guard let action = actions.popLast() else { return false }
        action()
        return true
    }
}

enum DurationFormatter {
    /// "1h 30m" / "45m"
    static func string(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// "49.25" -- always two places so digits stay column-aligned month to month.
    static func decimal(_ seconds: Int) -> String {
        String(format: "%.2f", Double(seconds) / 3600)
    }
}

/// A class taught before, offered back while typing a new event's name.
struct ClassSuggestion: Identifiable, Hashable {
    var id: String { title }
    let seriesKey: String
    let title: String
    let weekday: Int
    let startMinutes: Int
    let endMinutes: Int
    let notes: SeriesNotes
    let lastSeen: Date
    let count: Int
}

/// The band the calendar opens on.
enum DayRange {
    static let dayLength = 24 * 60

    /// 24:00 is accepted, but only as an end — it is the close of the day, and
    /// as a start it would mean a band of no length.
    static func isValid(start: Int, end: Int) -> Bool {
        start >= 0 && start < dayLength && end > start && end <= dayLength
    }

    static func clamped(start: Int, end: Int) -> (start: Int, end: Int)? {
        isValid(start: start, end: end) ? (start, end) : nil
    }
}
