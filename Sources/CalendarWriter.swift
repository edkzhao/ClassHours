import Foundation
import EventKit

/// Every write the app makes. Kept in one place so the blast radius of "this
/// app can now change your calendar" is a single file.
enum EditScope {
    case thisOccurrence
    case thisAndFollowing
    case wholeSeries
}

struct CalendarWriter {
    let store: EKEventStore
    let calendar: Calendar

    // MARK: Create

    /// One recurring event per distinct time slot, all carrying the same notes.
    ///
    /// EventKit can't express "Mon 10–12 *and* Thu 14–15:30" in a single
    /// recurrence rule, so a multi-slot draft becomes several series. Grouping
    /// them would mean writing a tracking id into the Notes field, which is the
    /// one field that has to stay readable.
    @discardableResult
    func createSeries(_ draft: SeriesDraft, in ekCalendar: EKCalendar) throws -> [EKEvent] {
        let expanded = draft.occurrences(calendar: calendar)
        var created: [EKEvent] = []

        // Sessions follow no pattern, so each one is its own event. They are
        // held together as a series on the ClassHours side instead.
        if draft.mode == .sessions {
            for occ in expanded {
                let event = newEvent(draft, in: ekCalendar, on: occ.date, span: occ.span)
                try store.save(event, span: .thisEvent, commit: false)
                created.append(event)
            }
            try store.commit()
            return created
        }

        for slot in draft.slots where slot.isComplete {
            let mine = expanded.filter { $0.id == slot.id }
            guard let first = mine.first, let last = mine.last else { continue }

            let event = newEvent(draft, in: ekCalendar, on: first.date, span: slot.span)

            if mine.count > 1 {
                let days = slot.weekdays.sorted().compactMap { wd -> EKRecurrenceDayOfWeek? in
                    guard let d = EKWeekday(rawValue: wd) else { return nil }
                    return EKRecurrenceDayOfWeek(d)
                }
                // End on this slot's own last date, so the occurrence count is
                // exact even when slots fall on different weekdays.
                let end = EKRecurrenceEnd(end: endDate(last.date, span: slot.span))
                let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                            daysOfTheWeek: days, daysOfTheMonth: nil,
                                            monthsOfTheYear: nil, weeksOfTheYear: nil,
                                            daysOfTheYear: nil, setPositions: nil, end: end)
                event.recurrenceRules = [rule]
            }

            try store.save(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent,
                           commit: false)
            created.append(event)
        }
        try store.commit()
        return created
    }

    private func newEvent(_ draft: SeriesDraft, in ekCalendar: EKCalendar,
                          on day: Date, span: TimeSpan) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = ekCalendar
        event.title = draft.title.isEmpty ? "Untitled" : draft.title
        event.notes = draft.notes.encoded()
        event.startDate = date(day, atMinutes: span.start ?? 0)
        event.endDate = endDate(day, span: span)
        return event
    }

    /// Past midnight the end lands on the following day, which falls out of
    /// adding the resolved minute offset rather than setting a clock time.
    private func endDate(_ day: Date, span: TimeSpan) -> Date {
        date(day, atMinutes: span.resolvedEnd ?? span.start ?? 0)
    }


    // MARK: Edit

    func update(_ event: EKEvent, scope: EditScope,
                title: String?, start: Date?, end: Date?, notes: SeriesNotes?) throws {
        let target = try resolve(event, scope: scope)
        if let title { target.title = title }
        if let notes { target.notes = notes.encoded() }
        if let start, let end {
            // Preserve the occurrence's own day when only times changed.
            target.startDate = start
            target.endDate = end
        }
        try store.save(target, span: span(for: target, scope: scope), commit: true)
    }

    func delete(_ event: EKEvent, scope: EditScope) throws {
        let target = try resolve(event, scope: scope)
        try store.remove(target, span: span(for: target, scope: scope), commit: true)
    }

    /// `.futureEvents` truncates the recurrence and spawns a *new* event for the
    /// remainder — an 11-session series edited in the middle became 8 + 3. Only
    /// ever use it when holding the master of a genuine recurrence; a plain
    /// event has nothing to split and takes `.thisEvent`.
    private func span(for event: EKEvent, scope: EditScope) -> EKSpan {
        guard event.hasRecurrenceRules else { return .thisEvent }
        return scope == .thisOccurrence ? .thisEvent : .futureEvents
    }

    /// "Whole series" means the first occurrence — EventKit has no all-events
    /// span. Resolved through the normalised UID so an already-detached
    /// occurrence still finds the master rather than splitting itself again.
    private func resolve(_ event: EKEvent, scope: EditScope) throws -> EKEvent {
        guard scope == .wholeSeries else { return event }
        let uid = SeriesKey.normalize(
            event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "")
        guard !uid.isEmpty else { return event }

        let candidates = store.calendarItems(withExternalIdentifier: uid).compactMap { $0 as? EKEvent }
        if let master = candidates.first(where: { $0.hasRecurrenceRules }) { return master }
        if let earliest = candidates.min(by: { $0.startDate < $1.startDate }) { return earliest }
        return event
    }

    /// Added as minutes rather than set as a clock time, so an offset past
    /// 24h rolls into the next day instead of failing to resolve.
    /// Rewrites one role's holder everywhere it appears on a calendar.
    ///
    /// Works on masters, never occurrences: saving an occurrence of a
    /// recurrence with `.futureEvents` splits the series, which is the bug that
    /// repeatedly cost events their membership.
    func renameRoleHolder(in ekCalendar: EKCalendar, role: RoleKind,
                          from old: String, to new: String,
                          between start: Date, and end: Date) throws
    -> [(key: String, title: String, notes: String)] {

        let found = store.events(matching: store.predicateForEvents(
            withStart: start, end: end, calendars: [ekCalendar]))

        var seen = Set<String>()
        var changed: [(key: String, title: String, notes: String)] = []

        for occurrence in found {
            let key = occurrence.seriesKey
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let candidates = store.calendarItems(withExternalIdentifier: key)
                .compactMap { $0 as? EKEvent }
            let target = candidates.first(where: { $0.hasRecurrenceRules })
                ?? candidates.min(by: { $0.startDate < $1.startDate })
                ?? occurrence

            var notes = SeriesNotes.decode(target.notes)
            guard notes.name(role) == old else { continue }

            changed.append((key, target.title ?? "", target.notes ?? ""))
            // Set the entry directly rather than through `set`, which would
            // also clear the exclusive partner — a rename is not a role change.
            notes.people[role] = new
            target.notes = notes.encoded()
            try store.save(target,
                           span: target.hasRecurrenceRules ? .futureEvents : .thisEvent,
                           commit: false)
        }

        if !changed.isEmpty { try store.commit() }
        return changed
    }

    private func date(_ day: Date, atMinutes m: Int) -> Date {
        calendar.date(byAdding: .minute, value: m, to: calendar.startOfDay(for: day)) ?? day
    }

    // MARK: Test calendar

    /// Creates a scratch calendar so writes can be exercised without touching
    /// real teaching records.
    @discardableResult
    static func makeTestCalendar(store: EKEventStore, named name: String) throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == name }) {
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = name
        cal.source = store.sources.first { $0.sourceType == .local }
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first
        try store.saveCalendar(cal, commit: true)
        return cal
    }
}
