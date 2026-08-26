import Foundation
import EventKit

/// The structured half of an event's Notes field, plus whatever free text
/// follows it.
///
/// Stored in the event's real Notes so it round-trips through Apple Calendar
/// and stays readable there:
///
///     Coordinator: Adam
///     Advisor: Sofia
///     ---
///     Prefers worked examples before theory.
///
/// A role that isn't set writes no line at all.
struct SeriesNotes: Equatable, Hashable {
    var people: [RoleKind: String] = [:]
    var text: String = ""

    static let divider = "---"

    var hasAnyRole: Bool { people.values.contains { !$0.isEmpty } }

    /// Label and person kept apart so a row can fade the two independently:
    /// the label is always secondary, the name only fades once the session's
    /// feedback is done. Fixed order, so roles line up down the table.
    var roleLines: [RoleLine] {
        RoleKind.allCases.compactMap { role in
            let n = name(role)
            return n.isEmpty ? nil : RoleLine(id: role.title, label: role.title, person: n)
        }
    }

    func name(_ role: RoleKind) -> String { people[role] ?? "" }

    mutating func set(_ role: RoleKind, _ name: String) {
        if name.isEmpty {
            people[role] = nil
        } else {
            people[role] = name
            // Advisor and Manager displace each other.
            if let partner = role.exclusivePartner { people[partner] = nil }
        }
    }

    /// Rebuilt into the Notes field.
    func encoded() -> String {
        var lines: [String] = []
        for role in RoleKind.allCases {
            let n = name(role)
            if !n.isEmpty { lines.append("\(role.title): \(n)") }
        }
        if lines.isEmpty { return text }
        return lines.joined(separator: "\n") + "\n\(Self.divider)\n" + text
    }

    /// Parsed back out, tolerantly: anything we don't recognise is free text,
    /// so editing the notes in Apple Calendar can never destroy them.
    static func decode(_ raw: String?) -> SeriesNotes {
        guard let raw, !raw.isEmpty else { return SeriesNotes() }
        var out = SeriesNotes()

        let lines = raw.components(separatedBy: .newlines)
        var idx = 0
        var found = false
        while idx < lines.count {
            let line = lines[idx].trimmingCharacters(in: .whitespaces)
            if line == divider { idx += 1; found = true; break }
            guard let colon = line.firstIndex(of: ":") else { break }
            let label = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard let role = RoleKind.allCases.first(where: { $0.title.caseInsensitiveCompare(label) == .orderedSame })
            else { break }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { out.people[role] = value }
            found = true
            idx += 1
        }
        out.text = found
            ? lines.dropFirst(idx).joined(separator: "\n")
            : raw
        return out
    }
}

struct RoleLine: Identifiable, Hashable {
    let id: String
    let label: String
    let person: String
}

/// A start time plus either a preset length or a typed end.
///
/// Duration is the primary way in: a class is "an hour from eleven", not two
/// timestamps. It also makes a class running past midnight expressible at all —
/// 23:00 for 2h can only mean 01:00 the next day.
struct TimeSpan: Equatable, Hashable {
    /// Minutes from midnight. nil until typed.
    var start: Int?
    /// A typed end, used only when `duration` is nil.
    var end: Int?
    /// A preset length. nil means Custom — the end time is typed instead.
    var duration: Int? = 120

    static let presets = [15, 30, 60, 90, 120]

    /// Minutes from the start day's midnight. May exceed 24h, which is exactly
    /// how a class past midnight is carried.
    var resolvedEnd: Int? {
        guard let start else { return nil }
        if let duration { return start + duration }
        guard let end else { return nil }
        // An end earlier than the start is the next day — the only sensible
        // reading, and the only way to type one of these by hand.
        return end > start ? end : end + 24 * 60
    }

    var minutes: Int {
        guard let start, let resolvedEnd else { return 0 }
        return max(0, resolvedEnd - start)
    }

    var crossesMidnight: Bool { (resolvedEnd ?? 0) >= 24 * 60 }
    var isComplete: Bool { start != nil && minutes > 0 }

    /// What the end reads as on a clock, ignoring which day it lands on.
    var endLabel: String? {
        guard let resolvedEnd else { return nil }
        return TimeText.hhmm(resolvedEnd % (24 * 60))
    }

    /// "1h 30m", or nil when the end is typed rather than chosen.
    static func label(_ minutes: Int) -> String {
        String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Picks the preset matching a real event's length, or Custom if none does.
    static func matching(minutes: Int) -> TimeSpan {
        var span = TimeSpan()
        span.duration = presets.contains(minutes) ? minutes : nil
        return span
    }
}

/// How the When section is being filled in.
enum WhenMode: Hashable, CaseIterable {
    /// A weekly pattern — the usual block of classes.
    case repeats
    /// Individually chosen dates that follow no pattern.
    case sessions
}

/// One weekday+time rule inside a new-event draft. A draft may carry several,
/// which is what makes bulk entry quick.
struct SeriesSlot: Identifiable, Equatable {
    let id = UUID()
    /// 1 = Sunday, matching Calendar. Empty until you choose — a prefilled
    /// weekday is too easy to leave in by accident.
    var weekdays: Set<Int> = []
    var span = TimeSpan()

    /// Only a slot with a day and a real length can produce occurrences.
    var isComplete: Bool { !weekdays.isEmpty && span.isComplete }
}

/// One individually chosen date, for a series that follows no pattern.
struct SeriesSession: Identifiable, Equatable {
    let id = UUID()
    var date: Date = Calendar.current.startOfDay(for: Date())
    var span = TimeSpan()

    var isComplete: Bool { span.isComplete }
}

enum SeriesEnd: Equatable {
    case count(Int)
    case until(Date)
}

/// One occurrence the draft will produce, in either mode.
struct PlannedOccurrence: Identifiable {
    /// Occurrences sharing an id belong to one recurrence rule.
    let id: UUID
    let date: Date
    let span: TimeSpan
}

/// A draft of what "New Event" will create.
struct SeriesDraft {
    var calendarID: String = ""
    var title: String = ""
    var mode: WhenMode = .repeats
    var slots: [SeriesSlot] = [SeriesSlot()]
    var sessions: [SeriesSession] = [SeriesSession()]
    /// Set when the draft was started from a class already in the calendar, so
    /// what gets created joins that series instead of standing alone.
    var joinSeriesKey: String?
    var start: Date = Calendar.current.startOfDay(for: Date())
    /// Ends today by default: most series being entered are a block of
    /// classes already scheduled up to now, not an open-ended count.
    var end: SeriesEnd = .until(Calendar.current.startOfDay(for: Date()))
    var notes = SeriesNotes()

    /// Expanded locally so the panel can show exactly what will be written
    /// before anything is written.
    func occurrences(calendar: Calendar, limit: Int = 400) -> [PlannedOccurrence] {
        if mode == .sessions {
            return sessions.filter(\.isComplete)
                .sorted { a, b in
                    a.date == b.date ? (a.span.start ?? 0) < (b.span.start ?? 0) : a.date < b.date
                }
                .map { PlannedOccurrence(id: $0.id,
                                         date: calendar.startOfDay(for: $0.date),
                                         span: $0.span) }
        }

        var out: [PlannedOccurrence] = []
        let wanted: Int
        var hardEnd: Date?
        switch end {
        case .count(let n): wanted = max(1, n); hardEnd = nil
        case .until(let d): wanted = limit; hardEnd = calendar.startOfDay(for: d)
        }

        let usable = slots.filter(\.isComplete)
        guard !usable.isEmpty else { return [] }

        var cursor = calendar.startOfDay(for: start)
        var guardCount = 0
        while out.count < wanted && guardCount < 800 {
            guardCount += 1
            if let hardEnd, cursor > hardEnd { break }
            let weekday = calendar.component(.weekday, from: cursor)
            for slot in usable where slot.weekdays.contains(weekday) {
                if out.count >= wanted { break }
                out.append(PlannedOccurrence(id: slot.id, date: cursor, span: slot.span))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        out.sort { a, b in
            a.date == b.date ? (a.span.start ?? 0) < (b.span.start ?? 0) : a.date < b.date
        }
        return out
    }

    var totalMinutes: Int {
        occurrences(calendar: .current).reduce(0) { $0 + $1.span.minutes }
    }
}

enum TimeText {
    static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
    static func minutes(of date: Date, _ cal: Calendar) -> Int {
        cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }
}
