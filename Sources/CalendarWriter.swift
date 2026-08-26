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
            // One EventKit recurrence per weekday. ClassHours still groups
            // them as one series, but a later Branch edit can now change one
            // weekday's boundary without touching the others.
            for weekday in slot.weekdays.sorted() {
                let mine = expanded.filter {
                    $0.id == slot.id && calendar.component(.weekday, from: $0.date) == weekday
                }
                guard let first = mine.first, let last = mine.last else { continue }

                let event = newEvent(draft, in: ekCalendar, on: first.date, span: slot.span)
                if mine.count > 1, let day = EKWeekday(rawValue: weekday) {
                    let end = EKRecurrenceEnd(end: endDate(last.date, span: slot.span))
                    event.recurrenceRules = [
                        EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                         daysOfTheWeek: [EKRecurrenceDayOfWeek(day)],
                                         daysOfTheMonth: nil, monthsOfTheYear: nil,
                                         weeksOfTheYear: nil, daysOfTheYear: nil,
                                         setPositions: nil, end: end)
                    ]
                }

                try store.save(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent,
                               commit: false)
                created.append(event)
            }
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
                title: String?, start: Date?, end: Date?, notes: SeriesNotes?,
                calendar targetCalendar: EKCalendar? = nil) throws {
        let target = try resolve(event, scope: scope)
        if let title { target.title = title }
        if let notes { target.notes = notes.encoded() }
        if let targetCalendar { target.calendar = targetCalendar }
        if let start, let end {
            // Preserve the occurrence's own day when only times changed.
            target.startDate = start
            target.endDate = end
        }
        try store.save(target, span: span(for: target, scope: scope), commit: true)
    }

    /// Replaces the repeat boundary for one EventKit recurrence. The caller
    /// decides whether this recurrence represents a branch or a member of a
    /// wider ClassHours series before invoking it.
    func updateRecurrenceEnd(_ event: EKEvent, end: SeriesEnd) throws {
        let target = try resolve(event, scope: .wholeSeries)
        let wasRecurring = target.hasRecurrenceRules
        let newEnd: EKRecurrenceEnd
        switch end {
        case .count(let count):
            newEnd = EKRecurrenceEnd(occurrenceCount: max(1, count))
        case .until(let date):
            let day = calendar.startOfDay(for: date)
            let inclusive = calendar.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1) ?? date
            newEnd = EKRecurrenceEnd(end: inclusive)
        }

        if let rules = target.recurrenceRules, !rules.isEmpty {
            target.recurrenceRules = rules.map { replacingEnd(of: $0, with: newEnd) }
        } else {
            let weekday = calendar.component(.weekday, from: target.startDate)
            guard let ekWeekday = EKWeekday(rawValue: weekday) else { return }
            target.recurrenceRules = [
                EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                 daysOfTheWeek: [EKRecurrenceDayOfWeek(ekWeekday)],
                                 daysOfTheMonth: nil, monthsOfTheYear: nil,
                                 weeksOfTheYear: nil, daysOfTheYear: nil,
                                 setPositions: nil, end: newEnd)
            ]
        }
        try store.save(target, span: wasRecurring ? .futureEvents : .thisEvent, commit: true)
    }

    func delete(_ event: EKEvent, scope: EditScope) throws {
        let target = try resolve(event, scope: scope)
        try store.remove(target, span: span(for: target, scope: scope), commit: true)
    }

    @discardableResult
    func createOccurrence(copying template: EKEvent, start: Date, end: Date) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = template.calendar
        event.title = template.title
        event.notes = template.notes
        event.location = template.location
        event.url = template.url
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
        return event
    }

    /// `.futureEvents` truncates the recurrence and spawns a *new* event for the
    /// remainder — an 11-session series edited in the middle became 8 + 3. Only
    /// ever use it when holding the master of a genuine recurrence; a plain
    /// event has nothing to split and takes `.thisEvent`.
    private func span(for event: EKEvent, scope: EditScope) -> EKSpan {
        guard event.hasRecurrenceRules else { return .thisEvent }
        return scope == .thisOccurrence ? .thisEvent : .futureEvents
    }

    private func replacingEnd(of rule: EKRecurrenceRule,
                              with end: EKRecurrenceEnd) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: rule.frequency,
                         interval: rule.interval,
                         daysOfTheWeek: rule.daysOfTheWeek,
                         daysOfTheMonth: rule.daysOfTheMonth,
                         monthsOfTheYear: rule.monthsOfTheYear,
                         weeksOfTheYear: rule.weeksOfTheYear,
                         daysOfTheYear: rule.daysOfTheYear,
                         setPositions: rule.setPositions,
                         end: end)
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
