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
