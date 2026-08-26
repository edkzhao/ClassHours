import Foundation
import EventKit

/// Turns raw EventKit events into the month's audited, clipped, deduplicated
/// list of occurrences.
enum EventMonthCalculator {

    /// Recurring events hand back one `EKEvent` per occurrence, and the same
    /// occurrence can surface more than once across overlapping queries. This
    /// key is stable per occurrence so duplicates collapse.
    static func occurrenceIdentity(_ event: EKEvent) -> String {
        var parts: [String] = []
        parts.append("event=\(event.eventIdentifier ?? "")")
        parts.append("external=\(event.calendarItemExternalIdentifier ?? "")")
        parts.append("calendar=\(event.calendar?.calendarIdentifier ?? "")")
        if let occurrence = event.occurrenceDate {
            parts.append("occurrence=\(dateIdentity(occurrence))")
        }
        if let start = event.startDate {
            parts.append("start=\(dateIdentity(start))")
        }
        return parts.joined(separator: "|")
    }

    /// Identity that survives an edit.
    ///
    /// Deliberately excludes `eventIdentifier`: EventKit reissues it whenever it
    /// rewrites an event, which silently orphaned the feedback checkbox and made
    /// a session you'd already ticked reappear as unchecked.
    static func stableIdentity(_ event: EKEvent) -> String {
        var parts: [String] = []
        parts.append("uid=\(SeriesKey.normalize(event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? ""))")
        parts.append("calendar=\(event.calendar?.calendarIdentifier ?? "")")
        if let start = event.startDate { parts.append("start=\(dateIdentity(start))") }
        return parts.joined(separator: "|")
    }

    static func dateIdentity(_ date: Date) -> String {
        String(format: "%.0f", date.timeIntervalSinceReferenceDate)
    }

    /// Fetch, filter, deduplicate and clip every event overlapping `interval`.
    ///
    /// Excluded: all-day events and cancelled events -- matching the original.
    /// Clipping to the month is applied here and is entirely independent of the
    /// "Count <30m" setting, which is a display/aggregation concern applied later.
    static func auditedRecords(
        store: EKEventStore,
        calendar: EKCalendar,
        interval: HalfOpenMonthInterval
    ) -> [EventOccurrenceRecord] {

        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: [calendar]
        )
        let events = store.events(matching: predicate)

        var seen = Set<String>()
        var records: [EventOccurrenceRecord] = []
        records.reserveCapacity(events.count)

        for event in events {
            if event.isAllDay { continue }
            if event.status == .canceled { continue }
            guard let start = event.startDate, let end = event.endDate else { continue }
            guard end > start else { continue }
            guard interval.overlaps(start: start, end: end) else { continue }

            let identity = occurrenceIdentity(event)
            if seen.contains(identity) { continue }
            seen.insert(identity)

            let countedStart = max(start, interval.start)
            let countedEnd = min(end, interval.end)
            guard countedEnd > countedStart else { continue }

            let title = (event.title?.isEmpty == false) ? event.title! : "(Untitled)"

            records.append(
                EventOccurrenceRecord(
                    id: identity,
                    stableID: stableIdentity(event),
                    eventID: event.eventIdentifier ?? "",
                    notes: SeriesNotes.decode(event.notes),
                    seriesKey: event.seriesKey,
                    title: title,
                    startDate: start,
                    endDate: end,
                    countedStart: countedStart,
                    countedEnd: countedEnd,
                    countedSeconds: Int(countedEnd.timeIntervalSince(countedStart).rounded()),
                    fullSeconds: Int(end.timeIntervalSince(start).rounded()),
                    isClipped: countedStart > start || countedEnd < end
                )
            )
        }

        records.sort { isOrderedBefore($0, $1) }
        return records
    }

    static func isOrderedBefore(_ a: EventOccurrenceRecord, _ b: EventOccurrenceRecord) -> Bool {
        if a.countedStart != b.countedStart { return a.countedStart < b.countedStart }
        if a.countedEnd != b.countedEnd { return a.countedEnd < b.countedEnd }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
