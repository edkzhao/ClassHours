import Foundation
import EventKit
import SwiftUI

/// One event occurrence as the calendar page draws it.
struct Occurrence: Identifiable, Equatable {
    let key: String
    let eventID: String
    let seriesKey: String
    let calendarID: String
    let colorIndex: Int
    let title: String
    let start: Date
    let end: Date
    /// Clipped to whichever day the block is drawn on.
    var startMinutes: Int
    var endMinutes: Int
    let durationMinutes: Int
    let isRecurring: Bool
    var remaining: Int?
    /// Last occurrence of a series — nothing follows it.
    var isFinal = false

    var id: String { key }
}

extension AppState {

    // MARK: Lookup

    func ekCalendar(_ id: String) -> EKCalendar? { store.calendar(withIdentifier: id) }

    var writableCalendars: [CalendarChoice] {
        calendars.filter { ekCalendar($0.id)?.allowsContentModifications ?? false }
    }

    /// Events on one day, across every calendar currently ticked in the sidebar.
    ///
    /// Each block is clipped to the day it's drawn on. A session running
    /// 22:10 → 00:10 shows as 22:10–24:00 on its own day and 00:00–00:10 on the
    /// next; without the clip the tail was painted at 22:10 on the following
    /// day too, stacking translucent blocks into a much darker band.
    /// Uncached. Call `occurrences(on:)` instead — see the cache in AppState.
    func computeOccurrences(on day: Date) -> [Occurrence] {
        let start = calculationCalendar.startOfDay(for: day)
        guard let end = calculationCalendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return occurrences(from: start, to: end).map { occ in
            var o = occ
            o.startMinutes = occ.start <= start ? 0 : TimeText.minutes(of: occ.start, calculationCalendar)
            o.endMinutes = occ.end >= end ? 24 * 60 : TimeText.minutes(of: occ.end, calculationCalendar)
            if o.endMinutes <= o.startMinutes { o.endMinutes = min(24 * 60, o.startMinutes + 15) }
            return o
        }
    }

    func occurrences(from: Date, to: Date) -> [Occurrence] {
        let cals = calendars
            .filter { isVisible($0.id) }
            .compactMap { ekCalendar($0.id) }
        guard !cals.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        let events = store.events(matching: predicate)
        let cal = calculationCalendar

        return events.compactMap { ev -> Occurrence? in
            guard let s = ev.startDate, let e = ev.endDate, !ev.isAllDay, ev.status != .canceled
            else { return nil }
            let calID = ev.calendar?.calendarIdentifier ?? ""
            let idx = calendars.firstIndex { $0.id == calID } ?? 0
            let sm = TimeText.minutes(of: s, cal)
            let em = cal.isDate(e, inSameDayAs: s) ? TimeText.minutes(of: e, cal) : 24 * 60
            let key = "\(ev.eventIdentifier ?? UUID().uuidString)|\(s.timeIntervalSinceReferenceDate)"
            return Occurrence(
                key: key,
                eventID: ev.eventIdentifier ?? "",
                seriesKey: ev.seriesKey,
                calendarID: calID,
                colorIndex: idx,
                title: (ev.title?.isEmpty == false) ? ev.title! : "(Untitled)",
                start: s, end: e,
                startMinutes: sm, endMinutes: max(em, sm + 5),
                durationMinutes: max(5, Int(e.timeIntervalSince(s) / 60)),
                isRecurring: ev.hasRecurrenceRules,
                remaining: remaining(after: s, seriesKey: ev.seriesKey),
                isFinal: isFinalOccurrence(s, seriesKey: ev.seriesKey)
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// Uses each block's clipped span, not the event's full length — otherwise a
    /// 22:10 → 00:10 session counted its whole two hours against both days.
    func minutesScheduled(on day: Date) -> Int {
        occurrences(on: day).reduce(0) { $0 + max(0, $1.endMinutes - $1.startMinutes) }
    }

    /// Events grouped the way Tidy Up groups them: same calendar, same
    /// normalised title. Returns the series keys per group.
    ///
    /// Membership lives only in ClassHours, so it can always be rebuilt from
    /// the calendar — which is what makes losing it recoverable.
    func seriesGroupsFromTitles() -> [[String]] {
        let cals = calendars.compactMap { ekCalendar($0.id) }
        guard !cals.isEmpty,
              let from = calculationCalendar.date(byAdding: .year, value: -3, to: Date()),
              let to = calculationCalendar.date(byAdding: .year, value: 2, to: Date())
        else { return [] }

        var buckets: [String: Set<String>] = [:]
        for ev in store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: cals)) {
            guard let title = ev.title, !title.isEmpty, !ev.isAllDay else { continue }
            let key = (ev.calendar?.calendarIdentifier ?? "") + "\u{1}" + TidyUp.normalize(title)
            buckets[key, default: []].insert(ev.seriesKey)
        }
        return buckets.values.filter { $0.count > 1 }.map { Array($0).sorted() }
    }

    /// Every distinct set of roles written into a calendar's events.
    func roleNotes(calendarID: String) -> [SeriesNotes] {
        guard let ekCal = ekCalendar(calendarID),
              let from = calculationCalendar.date(byAdding: .year, value: -2, to: Date()),
              let to = calculationCalendar.date(byAdding: .year, value: 1, to: Date())
        else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [ekCal]))
            .compactMap { $0.notes }
            .map(SeriesNotes.decode)
            .filter(\.hasAnyRole)
    }

    // MARK: History

    /// Classes already taught on a calendar, one entry per distinct name.
    ///
    /// Everything needed to re-book the class is carried along, so picking one
    /// fills the whole form rather than just the title.
    func classHistory(calendarID: String) -> [ClassSuggestion] {
        guard let ekCal = ekCalendar(calendarID) else { return [] }
        let now = Date()
        guard let from = calculationCalendar.date(byAdding: .month, value: -18, to: now),
              let to = calculationCalendar.date(byAdding: .month, value: 3, to: now)
        else { return [] }

        let events = store.events(matching: store.predicateForEvents(
            withStart: from, end: to, calendars: [ekCal]))

        var best: [String: ClassSuggestion] = [:]
        for ev in events {
            guard let s = ev.startDate, let e = ev.endDate, !ev.isAllDay, ev.status != .canceled,
                  let title = ev.title, !title.isEmpty else { continue }

            let key = title
            let existing = best[key]
            // The most recent booking wins: times and roles drift over a term,
            // and the latest is what you are most likely repeating.
            if let existing, existing.lastSeen >= s {
                best[key] = ClassSuggestion(seriesKey: existing.seriesKey, title: existing.title,
                                            weekday: existing.weekday,
                                            startMinutes: existing.startMinutes,
                                            endMinutes: existing.endMinutes,
                                            notes: existing.notes, lastSeen: existing.lastSeen,
                                            count: existing.count + 1)
            } else {
                best[key] = ClassSuggestion(
                    seriesKey: ev.seriesKey,
                    title: title,
                    weekday: calculationCalendar.component(.weekday, from: s),
                    startMinutes: TimeText.minutes(of: s, calculationCalendar),
                    endMinutes: TimeText.minutes(of: e, calculationCalendar),
                    notes: SeriesNotes.decode(ev.notes),
                    lastSeen: s,
                    count: (existing?.count ?? 0) + 1)
            }
        }
        return best.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: Branches

    /// Occurrences in the same ClassHours series that follow the selected
    /// weekday + time line. EventKit keeps detached occurrences under the
    /// original external identifier, so matching the live dates makes one-off
    /// exceptions join a branch without extra metadata in Calendar notes.
    func branchOccurrences(of event: EKEvent, scope: EditScope,
                           including joinedSignature: BranchSignature? = nil) -> [EKEvent] {
        guard scope != .thisOccurrence,
              let start = event.startDate,
              let end = event.endDate,
              let signature = BranchSignature(start: start, end: end, calendar: calculationCalendar)
        else { return [event] }

        let now = Date()
        guard let lower = calculationCalendar.date(byAdding: .year, value: -3, to: now),
              let upper = calculationCalendar.date(byAdding: .year, value: 5, to: now)
        else { return [event] }

        let from = scope == .thisAndFollowing ? max(start, lower) : lower
        let calendars = self.calendars.compactMap { ekCalendar($0.id) }
        guard !calendars.isEmpty else { return [event] }

        let seriesKeys = Set(seriesLookup?(event.seriesKey) ?? [event.seriesKey])
        let predicate = store.predicateForEvents(withStart: from, end: upper, calendars: calendars)
        var seen = Set<String>()
        let matched = store.events(matching: predicate).filter { candidate in
            guard let candidateStart = candidate.startDate, let candidateEnd = candidate.endDate,
                  !candidate.isAllDay, candidate.status != .canceled,
                  seriesKeys.contains(candidate.seriesKey),
                  (signature.matches(start: candidateStart, end: candidateEnd, calendar: calculationCalendar)
                   || joinedSignature?.matches(start: candidateStart, end: candidateEnd, calendar: calculationCalendar) == true)
            else { return false }
            let identity = EventMonthCalculator.occurrenceIdentity(candidate)
            return seen.insert(identity).inserted
        }
        return matched.isEmpty ? [event] : matched.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    func branchOccurrenceCount(of event: EKEvent) -> Int {
        branchOccurrences(of: event, scope: .wholeSeries).count
    }

    /// Live occurrences across every member of the ClassHours series. This is
    /// the series counterpart to `branchOccurrences` and lets the target
    /// switch drive all ordinary edits without another branch/series prompt.
    func seriesEventOccurrences(of event: EKEvent, scope: EditScope) -> [EKEvent] {
        guard scope != .thisOccurrence else { return [event] }
        let now = Date()
        guard let lower = calculationCalendar.date(byAdding: .year, value: -3, to: now),
              let upper = calculationCalendar.date(byAdding: .year, value: 5, to: now)
        else { return [event] }
        let from = scope == .thisAndFollowing ? max(event.startDate, lower) : lower
        let calendars = self.calendars.compactMap { ekCalendar($0.id) }
        guard !calendars.isEmpty else { return [event] }
        let seriesKeys = Set(seriesLookup?(event.seriesKey) ?? [event.seriesKey])
        let predicate = store.predicateForEvents(withStart: from, end: upper, calendars: calendars)
        var seen = Set<String>()
        let matched = store.events(matching: predicate).filter { candidate in
            guard !candidate.isAllDay, candidate.status != .canceled,
                  seriesKeys.contains(candidate.seriesKey) else { return false }
            return seen.insert(EventMonthCalculator.occurrenceIdentity(candidate)).inserted
        }
        return matched.isEmpty ? [event] : matched.sorted { $0.startDate < $1.startDate }
    }

    // MARK: Conflict preview

    func futureConflicts(for draft: SeriesDraft) -> [EventConflict] {
        let planned = draft.occurrences(calendar: calculationCalendar).compactMap { occurrence -> (Date, Date)? in
            guard let startMinutes = occurrence.span.start,
                  let endMinutes = occurrence.span.resolvedEnd
            else { return nil }
            let day = calculationCalendar.startOfDay(for: occurrence.date)
            guard let start = calculationCalendar.date(byAdding: .minute, value: startMinutes, to: day),
                  let end = calculationCalendar.date(byAdding: .minute, value: endMinutes, to: day),
                  end > start,
                  start > Date()
            else { return nil }
            return (start, end)
        }
        return futureConflicts(for: planned, excluding: [])
    }

    func futureConflicts(for planned: [(Date, Date)], excluding excludedIDs: Set<String>) -> [EventConflict] {
        guard let first = planned.map({ $0.0 }).min(), let last = planned.map({ $0.1 }).max() else { return [] }

        let calendars = self.calendars.compactMap { ekCalendar($0.id) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: first, end: last, calendars: calendars)
        var seen = Set<String>()
        return store.events(matching: predicate).compactMap { event in
            guard let start = event.startDate, let end = event.endDate,
                  !event.isAllDay, event.status != .canceled,
                  end > Date(), planned.contains(where: { start < $0.1 && end > $0.0 })
            else { return nil }
            let id = EventMonthCalculator.occurrenceIdentity(event)
            guard !excludedIDs.contains(id) else { return nil }
            guard seen.insert(id).inserted else { return nil }
            let calendarID = event.calendar?.calendarIdentifier ?? ""
            return EventConflict(id: id,
                                 title: event.title?.isEmpty == false ? event.title! : "(Untitled)",
                                 start: start,
                                 end: end,
                                 calendarTitle: self.calendars.first(where: { $0.id == calendarID })?.title ?? "Calendar")
        }
        .sorted { $0.start < $1.start }
    }

    /// Fetch the EKEvent behind an occurrence, matched on its exact start so we
    /// edit the right instance of a recurring series.
    func event(forKey key: String) -> EKEvent? {
        let parts = key.split(separator: "|")
        guard parts.count == 2, let stamp = Double(parts[1]) else { return nil }
        let start = Date(timeIntervalSinceReferenceDate: stamp)
        let cals = calendars.compactMap { ekCalendar($0.id) }
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-60),
            end: start.addingTimeInterval(60),
            calendars: cals)
        return store.events(matching: predicate).first { $0.eventIdentifier == String(parts[0]) }
    }

    // MARK: Remaining counts

    /// Start dates of every occurrence in each series, so "remaining" can be
    /// measured from the occurrence you're looking at rather than from today —
    /// otherwise every day of a series showed the same number.
    func refreshRemainingCounts() {
        defer { invalidateDayCache() }
        // Computed regardless of the switch: the switch hides the count, but
        // the final-occurrence marker still needs to know where a series ends.
        let cals = calendars.filter { isVisible($0.id) }.compactMap { ekCalendar($0.id) }
        guard !cals.isEmpty,
              let from = calculationCalendar.date(byAdding: .year, value: -2, to: Date()),
              let to = calculationCalendar.date(byAdding: .year, value: 3, to: Date())
        else { seriesStarts = [:]; return }

        var map: [String: [Date]] = [:]
        for ev in store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: cals)) {
            guard let s = ev.startDate else { continue }
            map[ev.seriesKey, default: []].append(s)
        }
        for key in map.keys { map[key]?.sort() }
        seriesStarts = map
    }

    /// Every start in this occurrence's series, its own included.
    func seriesStarts(for seriesKey: String) -> [Date] {
        let keys = seriesLookup?(seriesKey) ?? [seriesKey]
        return keys.flatMap { seriesStarts[$0] ?? [] }
    }

    /// How many occurrences of this series come after this one.
    ///
    /// nil for a standalone event — "0 left" on a one-off booking says nothing
    /// and only added noise.
    func remaining(after occurrence: Date, seriesKey: String) -> Int? {
        guard showRemaining else { return nil }
        let starts = seriesStarts(for: seriesKey)
        guard starts.count > 1 else { return nil }
        return starts.filter { $0 > occurrence }.count
    }

    /// True when this is the last occurrence of a real series.
    func isFinalOccurrence(_ occurrence: Date, seriesKey: String) -> Bool {
        let starts = seriesStarts(for: seriesKey)
        guard starts.count > 1 else { return false }
        return !starts.contains { $0 > occurrence }
    }

    /// Every occurrence in the ClassHours series this event belongs to —
    /// across all its member events, whatever their times or durations.
    func seriesOccurrences(of seriesKey: String) -> [(start: Date, minutes: Int)] {
        let ids = seriesLookup?(seriesKey) ?? [seriesKey]
        let cals = calendars.compactMap { ekCalendar($0.id) }
        guard !cals.isEmpty,
              let from = calculationCalendar.date(byAdding: .year, value: -3, to: Date()),
              let to = calculationCalendar.date(byAdding: .year, value: 3, to: Date())
        else { return [] }

        let wanted = Set(ids)
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: cals))
            .filter { wanted.contains($0.seriesKey) }
            .map { (start: $0.startDate!, minutes: Int($0.endDate.timeIntervalSince($0.startDate) / 60)) }
            .sorted { $0.start < $1.start }
    }
}
