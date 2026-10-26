import Foundation
import EventKit

struct EventSearchItem: Identifiable, Sendable {
    let id: String
    let eventID: String
    let calendarID: String
    let calendarTitle: String
    let title: String
    let notes: String
    let location: String
    let start: Date
    let end: Date
    let allDay: Bool

    var displayTitle: String { TitlePrefix.strip(title, prefix: calendarTitle) }
    var fields: [String] { [title, notes, location, calendarTitle] }
    var occurrenceKey: String { "\(eventID)|\(start.timeIntervalSinceReferenceDate)" }
}

struct CalendarSearchDestination: Equatable {
    let id = UUID()
    let item: EventSearchItem
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct EventSearchHit: Identifiable, Sendable {
    let item: EventSearchItem
    let score: Int
    let context: String?
    var id: String { item.id }
}

enum EventSearch {
    static func rank(_ query: String, items: [EventSearchItem]) -> [EventSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        // Recurrences share text; score that text once, not once per occurrence.
        var scores: [[String]: Int] = [:]
        var hits: [EventSearchHit] = []
        for item in items {
            if Task.isCancelled { return [] }
            guard seen.insert(item.id).inserted else { continue }
            let fields = item.fields
            let score: Int
            if let cached = scores[fields] {
                score = cached
            } else {
                let whole = fields.compactMap { TitleSearch.score(query, title: $0) }.min()
                let tokenScores = tokens.compactMap { token in
                    fields.compactMap { TitleSearch.score(token, title: $0) }.min()
                }
                score = whole ?? (tokenScores.count == tokens.count ? 10 + tokenScores.reduce(0, +) : -1)
                scores[fields] = score
            }
            guard score >= 0 else { continue }
            let context = (item.notes.components(separatedBy: .newlines) + [item.location])
                .first { line in tokens.contains { TitleSearch.matches($0, title: line) } }
            hits.append(EventSearchHit(item: item, score: score, context: context))
        }
        return hits.sorted { a, b in
            if a.item.start != b.item.start { return a.item.start < b.item.start }
            let names = a.item.displayTitle.localizedStandardCompare(b.item.displayTitle)
            if names != .orderedSame { return names == .orderedAscending }
            let calendars = a.item.calendarTitle.localizedStandardCompare(b.item.calendarTitle)
            if calendars != .orderedSame { return calendars == .orderedAscending }
            return a.id < b.id
        }
    }

    static func todayIndex(in hits: [EventSearchHit], now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        return hits.firstIndex { $0.item.start >= today } ?? hits.count
    }

    static func windows(from: Date, to: Date, calendar: Calendar) -> [DateInterval] {
        var start = from
        var result: [DateInterval] = []
        // EventKit silently truncates queries longer than four years.
        while start < to, let next = calendar.date(byAdding: .year, value: 3, to: start), next > start {
            let end = min(next, to)
            result.append(DateInterval(start: start, end: end))
            start = end
        }
        return result
    }
}

enum EventSearchCatalog {
    static func read() -> [EventSearchItem] {
        let store = EKEventStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var items: [EventSearchItem] = []
        var seen = Set<String>()
        for window in EventSearch.windows(from: .distantPast, to: .distantFuture, calendar: calendar) {
            if Task.isCancelled { return [] }
            autoreleasepool {
                let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
                store.enumerateEvents(matching: predicate) { event, _ in
                    guard event.status != .canceled,
                          let start = event.startDate, let end = event.endDate,
                          let source = event.calendar else { return }
                    let id = EventMonthCalculator.occurrenceIdentity(event)
                    guard seen.insert(id).inserted else { return }
                    items.append(EventSearchItem(
                        id: id, eventID: event.eventIdentifier ?? "", calendarID: source.calendarIdentifier,
                        calendarTitle: source.title, title: event.title ?? "(Untitled)",
                        notes: event.notes ?? "", location: event.location ?? "",
                        start: start, end: end, allDay: event.isAllDay))
                }
            }
        }
        return items
    }
}
