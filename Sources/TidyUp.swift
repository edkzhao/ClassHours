import SwiftUI
import EventKit

/// Groups scattered events that are really the same class, so they share one
/// set of notes.
///
/// It cannot make them a *recurrence* — EventKit rules describe a pattern, and
/// these events don't follow one. What it does is normalise the titles and
/// reconcile the notes, which is what "being in a series" actually buys you.
///
/// Read-only until `apply` is called. Nothing is written while you're reading
/// the plan.
enum TidyUp {

    /// Known typos to fold together. Compared case-insensitively on whole words.
    static let aliases: [String: String] = ["jonny": "Johnny"]

    static func normalize(_ raw: String) -> String {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Replace alias words wherever they appear, preserving the rest.
        var out = collapsed
        for (wrong, right) in aliases {
            let pattern = "(?<![\\p{L}])\(NSRegularExpression.escapedPattern(for: wrong))(?![\\p{L}])"
            out = out.replacingOccurrences(of: pattern, with: right,
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    struct Group: Identifiable {
        let id = UUID()
        let calendarID: String
        let calendarName: String
        let title: String
        var eventIDs: [String]
        var renameCount: Int
        /// Distinct non-empty notes found across the group.
        var candidateNotes: [SeriesNotes]
        var missingNotesCount: Int
        /// Which candidate wins when there's more than one. nil until chosen.
        var chosen: Int?

        var isConflict: Bool { candidateNotes.count > 1 }
        var willFillNotes: Bool { candidateNotes.count == 1 && missingNotesCount > 0 }
        var needsAttention: Bool { isConflict && chosen == nil }
        /// Two or more events sharing a title are a series, whatever their times.
        var willForm: Bool { eventIDs.count > 1 }
    }

    struct Plan {
        var groups: [Group] = []

        var seriesTotal: Int { groups.filter(\.willForm).count }
        var renameTotal: Int { groups.reduce(0) { $0 + $1.renameCount } }
        var fillTotal: Int { groups.filter(\.willFillNotes).reduce(0) { $0 + $1.missingNotesCount } }
        var conflicts: [Group] { groups.filter(\.isConflict) }
        var actionable: Bool { seriesTotal > 0 || renameTotal > 0 || fillTotal > 0 }
    }

    /// Scan without touching anything.
    static func scan(store: EKEventStore, calendars: [EKCalendar], calendarNames: [String: String],
                     from: Date, to: Date) -> Plan {
        let writable = calendars.filter { $0.allowsContentModifications }
        guard !writable.isEmpty else { return Plan() }

        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: writable))

        // One entry per event identifier: a recurring event is a single thing
        // however many occurrences it draws.
        var seen = Set<String>()
        var buckets: [String: [EKEvent]] = [:]
        for ev in events {
            let member = ev.seriesKey
            guard !member.isEmpty, !seen.contains(member) else { continue }
            seen.insert(member)
            let calID = ev.calendar?.calendarIdentifier ?? ""
            let bucket = calID + "\u{1}" + normalize(ev.title ?? "")
            buckets[bucket, default: []].append(ev)
        }

        var plan = Plan()
        for (key, group) in buckets {
            let parts = key.components(separatedBy: "\u{1}")
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            // A group of one is already consistent with itself.
            let renames = group.filter { ($0.title ?? "") != parts[1] }.count

            var distinct: [SeriesNotes] = []
            var missing = 0
            for ev in group {
                let n = SeriesNotes.decode(ev.notes)
                let empty = n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !n.hasAnyRole
                if empty { missing += 1 }
                else if !distinct.contains(n) { distinct.append(n) }
            }
            // Forming the series is itself the point, so any group of two or
            // more counts — even with tidy titles and no notes anywhere.
            guard group.count > 1 || renames > 0 else { continue }

            plan.groups.append(Group(
                calendarID: parts[0],
                calendarName: calendarNames[parts[0]] ?? "Calendar",
                title: parts[1],
                eventIDs: group.map(\.seriesKey),
                renameCount: renames,
                candidateNotes: distinct,
                missingNotesCount: missing,
                chosen: distinct.count == 1 ? 0 : nil))
        }
        plan.groups.sort {
            $0.calendarName == $1.calendarName ? $0.title < $1.title : $0.calendarName < $1.calendarName
        }

        return plan
    }

    /// Writes the plan. Groups still awaiting a decision are skipped.
    ///
    /// Series membership is recorded in ClassHours; only titles and notes are
    /// written back to Apple Calendar.
    @MainActor
    @discardableResult
    static func apply(_ plan: Plan, store: EKEventStore,
                      series: SeriesStore) throws -> (formed: Int, renamed: Int, noted: Int) {
        var formed = 0, renamed = 0, noted = 0

        for group in plan.groups {
            guard !group.needsAttention else { continue }

            if group.willForm {
                series.group(group.eventIDs)
                formed += 1
            }
            let winner = group.chosen.flatMap { group.candidateNotes.indices.contains($0) ? group.candidateNotes[$0] : nil }

            for id in group.eventIDs {
                guard let ev = store.calendarItems(withExternalIdentifier: id).first as? EKEvent
                        ?? store.event(withIdentifier: id) else { continue }
                var dirty = false

                if (ev.title ?? "") != group.title { ev.title = group.title; renamed += 1; dirty = true }

                if let winner {
                    let current = SeriesNotes.decode(ev.notes)
                    let isEmpty = current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !current.hasAnyRole
                    // Fill blanks always; overwrite only when you picked a winner
                    // for a genuine conflict.
                    if isEmpty || (group.isConflict && current != winner) {
                        ev.notes = winner.encoded(); noted += 1; dirty = true
                    }
                }
                // A plain event has no recurrence to split, so .thisEvent.
                if dirty {
                    try store.save(ev, span: ev.hasRecurrenceRules ? .futureEvents : .thisEvent,
                                   commit: false)
                }
            }
        }

        try store.commit()
        return (formed, renamed, noted)
    }
}
