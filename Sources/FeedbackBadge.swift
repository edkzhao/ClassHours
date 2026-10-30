import Foundation
import EventKit

struct FeedbackBadgeCalendar: Sendable {
    let id: String
    let months: [HalfOpenMonthInterval]
    let countShortEvents: Bool
    let checks: [String: Bool]
}

enum FeedbackBadge {
    /// Read persisted settings for every calendar, including reports not opened this session.
    static func inputs(calendarIDs: [String], preferences: [String: Any],
                       calendar: Calendar) -> [FeedbackBadgeCalendar] {
        calendarIDs.compactMap { id in
            guard (preferences["feedbackVisible." + id] as? Bool) ?? true else { return nil }
            let prefix = "feedbackSeeded." + id + "."
            let months = preferences.compactMap { key, value -> HalfOpenMonthInterval? in
                guard key.hasPrefix(prefix), (value as? Bool) == true else { return nil }
                let parts = key.dropFirst(prefix.count).split(separator: "-")
                guard parts.count == 2, let year = Int(parts[0]), (1...9999).contains(year),
                      let month = Int(parts[1]), (1...12).contains(month) else { return nil }
                return HalfOpenMonthInterval.make(year: year, month: month, calendar: calendar)
            }.sorted { $0.start < $1.start }
            return FeedbackBadgeCalendar(id: id, months: months,
                countShortEvents: (preferences["countShort." + id] as? Bool) ?? false,
                checks: (preferences["feedbackChecks." + id] as? [String: Bool]) ?? [:])
        }
    }

    static func count(_ inputs: [FeedbackBadgeCalendar], now: Date,
                      records: (String, HalfOpenMonthInterval) -> [EventOccurrenceRecord]) -> Int {
        inputs.reduce(into: 0) { total, input in
            var seen = Set<String>()
            for month in input.months where month.start < now {
                guard !Task.isCancelled else { return }
                let unique = records(input.id, month).filter {
                    seen.insert($0.stableID.isEmpty ? $0.id : $0.stableID).inserted
                }
                total += FeedbackCounter.uncheckedCount(records: unique, now: now,
                    countShortEvents: input.countShortEvents, feedbackEnabled: true,
                    isChecked: { input.checks[$0.stableID] ?? input.checks[$0.id] ?? false })
            }
        }
    }

    static func read(_ inputs: [FeedbackBadgeCalendar], now: Date) -> Int {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return 0 }
        let store = EKEventStore()
        return count(inputs, now: now) { id, interval in
            guard let target = store.calendar(withIdentifier: id) else { return [] }
            return EventMonthCalculator.auditedRecords(store: store, calendar: target, interval: interval)
        }
    }
}
