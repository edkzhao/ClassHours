import Foundation
import EventKit

/// Every write the app makes. Kept in one place so the blast radius of "this
/// app can now change your calendar" is a single file.
enum EditScope {
    case thisOccurrence
    case thisAndFollowing
    case wholeSeries
}

/// Snapshot live content before EventKit rewrites the master or its exceptions.
struct RecurrenceTemplate: Equatable {
    let calendarID: String
    let start: Date
    let end: Date
    let title: String?
    let notes: String?
    let location: String?
    let url: URL?

    init(_ event: EKEvent) {
        calendarID = event.calendar?.calendarIdentifier ?? ""
        start = event.startDate
        end = event.endDate
        title = event.title
        notes = event.notes
        location = event.location
        url = event.url
    }

    static func latest(for start: Date, end: Date, in templates: [Self],
                       calendar: Calendar) -> Self? {
        guard let branch = BranchSignature(start: start, end: end, calendar: calendar) else { return nil }
        return templates.filter {
            $0.start < start && branch.matches(start: $0.start, end: $0.end, calendar: calendar)
        }.max { $0.start < $1.start }
    }

    @discardableResult
    func apply(to event: EKEvent) -> Bool {
        guard event.title != title || event.notes != notes || event.location != location || event.url != url
        else { return false }
        event.title = title
        event.notes = notes
        event.location = location
        event.url = url
        return true
    }
}

/// EventKit invalidates occurrence objects when a recurrence is committed.
struct CreatedOccurrenceReference {
    let calendarID: String
    let seriesKey: String
    let start: Date
    let end: Date

    init(_ event: EKEvent) {
        calendarID = event.calendar.calendarIdentifier
        seriesKey = event.seriesKey
        start = event.startDate
        end = event.endDate
    }
}

struct CalendarWriter {
    let store: EKEventStore
    let calendar: Calendar
    var didCreateOccurrence: ((EKEvent) -> Void)? = nil

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
        let seriesKeyBefore = target.seriesKey
        let queryUpper: Date
        switch end {
        case .count:
            queryUpper = calendar.startOfDay(for: Date())
        case .until(let date):
            queryUpper = calendar.date(byAdding: .day, value: 1,
                                       to: calendar.startOfDay(for: date)) ?? date
        }
        let before = Set(recurrenceOccurrences(of: target, seriesKey: seriesKeyBefore,
                                               through: queryUpper)
            .map(EventMonthCalculator.stableIdentity))
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

        // Extending an EventKit rule from an old master can lazily materialise
        // sessions between the old boundary and today. Preserve every
        // occurrence that existed before the edit, but turn only the newly
        // introduced past dates into exceptions. Future dates remain governed
        // by the new end boundary.
        let after = recurrenceOccurrences(of: target, seriesKey: target.seriesKey,
                                          through: queryUpper)
        let accidental = RecurrenceExpansionGuard.accidentalPastIDs(
            before: before,
            after: after.compactMap { occurrence in
                guard let start = occurrence.startDate else { return nil }
                return (EventMonthCalculator.stableIdentity(occurrence), start)
            },
            today: Date(), calendar: calendar)
        guard !accidental.isEmpty else { return }
        for occurrence in after where accidental.contains(EventMonthCalculator.stableIdentity(occurrence)) {
            try store.remove(occurrence, span: .thisEvent, commit: false)
        }
        try store.commit()
    }

    private func recurrenceOccurrences(of event: EKEvent, seriesKey: String,
                                       through upper: Date) -> [EKEvent] {
        guard let ekCalendar = event.calendar, let start = event.startDate else { return [] }
        let lower = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let end = max(upper, calendar.startOfDay(for: Date()))
        var seen = Set<String>()
        return EventSearch.windows(from: lower, to: end, calendar: calendar).flatMap { window in
            store.events(matching: store.predicateForEvents(
                withStart: window.start, end: window.end, calendars: [ekCalendar]))
        }
            .filter {
                $0.seriesKey == seriesKey && !$0.isAllDay && $0.status != .canceled
                    && seen.insert(EventMonthCalculator.stableIdentity($0)).inserted
            }
    }

    func delete(_ event: EKEvent, scope: EditScope) throws {
        let target = try resolve(event, scope: scope)
        try store.remove(target, span: span(for: target, scope: scope), commit: true)
    }

    func deleteCreatedOccurrence(_ reference: CreatedOccurrenceReference) throws {
        guard let targetCalendar = store.calendar(withIdentifier: reference.calendarID) else { return }
        let matches = store.events(matching: store.predicateForEvents(
            withStart: reference.start.addingTimeInterval(-1), end: reference.end.addingTimeInterval(1),
            calendars: [targetCalendar])).filter {
                $0.seriesKey == reference.seriesKey && $0.startDate == reference.start
            }
        guard matches.count <= 1 else {
            throw NSError(domain: "ClassHours", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot uniquely identify the added occurrence to undo."])
        }
        if let event = matches.first { try delete(event, scope: .thisOccurrence) }
    }

    @discardableResult
    func createOccurrence(in targetCalendar: EKCalendar, start: Date, end: Date,
                          content: RecurrenceTemplate) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar
        event.startDate = start
        event.endDate = end
        content.apply(to: event)
        try store.save(event, span: .thisEvent, commit: true)
        didCreateOccurrence?(event)
        return event
    }

    func appendOccurrences(_ planned: [PlannedRepeatOccurrence], from live: [EKEvent]) throws -> [String] {
        let templates = live.map(RecurrenceTemplate.init)
        let prepared = try planned.map { occurrence -> (PlannedRepeatOccurrence, RecurrenceTemplate, EKCalendar) in
            guard let content = RecurrenceTemplate.latest(for: occurrence.start, end: occurrence.end,
                                                          in: templates, calendar: calendar),
                  let target = store.calendar(withIdentifier: content.calendarID), target.allowsContentModifications
            else {
                throw NSError(domain: "ClassHours", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot extend a branch without a current writable occurrence."])
            }
            return (occurrence, content, target)
        }
        var created: [String] = []
        var references: [CreatedOccurrenceReference] = []
        do {
            for (occurrence, content, target) in prepared {
                let event = try createOccurrence(in: target, start: occurrence.start, end: occurrence.end, content: content)
                references.append(CreatedOccurrenceReference(event))
                created.append(event.seriesKey)
            }
            return created
        } catch {
            for reference in references.reversed() { try deleteCreatedOccurrence(reference) }
            throw error
        }
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
