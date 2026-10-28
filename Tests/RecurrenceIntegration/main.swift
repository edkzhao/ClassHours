import Foundation
import EventKit

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "RecurrenceIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    print("ok: \(message)")
}
func run() throws {
    try require(EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Calendar access available")
    let store = EKEventStore()
    let test = EKCalendar(for: .event, eventStore: store)
    test.title = "ClassHours verification " + UUID().uuidString
    test.source = store.sources.first { $0.sourceType == .local }
        ?? store.defaultCalendarForNewEvents?.source
    try store.saveCalendar(test, commit: true)
    let testID = test.calendarIdentifier
    print("Temporary calendar: \(testID)")
    defer {
        do {
            try store.removeCalendar(test, commit: true)
            print("Temporary test calendar removed; all fixture events removed with it.")
        } catch {
            print("CLEANUP FAILED for temporary calendar \(testID): \(error)")
        }
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let first = cal.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 10))!
    func at(_ weeks: Int) -> Date { cal.date(byAdding: .weekOfYear, value: weeks, to: first)! }
    func occurrences() -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: first.addingTimeInterval(-86400), end: at(8), calendars: [test]))
            .sorted { $0.startDate < $1.startDate }
    }
    func readMaster(_ key: String) -> EKEvent {
        store.calendarItems(withExternalIdentifier: key).compactMap { $0 as? EKEvent }.first { $0.hasRecurrenceRules && !$0.isDetached }!
    }
    let event = EKEvent(eventStore: store)
    event.calendar = test; event.title = "Old title"; event.notes = "Old master notes"
    event.startDate = first; event.endDate = first.addingTimeInterval(7200)
    event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 4))]
    try store.save(event, span: .thisEvent, commit: true)
    let key = event.seriesKey
    for (index, occurrence) in occurrences().enumerated() {
        occurrence.title = "Current title"
        occurrence.notes = "Preserve note \(index)"
        try store.save(occurrence, span: .thisEvent, commit: true)
    }
    for occurrence in occurrences() where occurrence.startDate == at(0) || occurrence.startDate == at(2) {
        try store.remove(occurrence, span: .thisEvent, commit: true)
    }
    let baseline = occurrences().map(RecurrenceTemplate.init)
    try require(baseline.count == 2, "first and middle deletions are in place")
    let schedule = RepeatPlanner.occurrences(patterns: [
        WeeklyRepeatPattern(id: key, firstStart: first, weekdays: [2], startMinutes: 600, durationMinutes: 120)
    ], end: .count(4), calendar: cal)
    func liveSchedule() -> [PlannedRepeatOccurrence] {
        occurrences().map { PlannedRepeatOccurrence(patternID: $0.seriesKey, start: $0.startDate, end: $0.endDate) }
    }
    var additions: [CreatedOccurrenceReference] = []
    let writer = CalendarWriter(store: store, calendar: cal, didCreateOccurrence: { additions.append(CreatedOccurrenceReference($0)) })
    let planned = RepeatPlanner.extensionOccurrences(live: liveSchedule(), baseline: schedule,
                                                     end: .count(5), now: Date(), calendar: cal)
    _ = try writer.appendOccurrences(planned, from: occurrences())
    try require(occurrences().count == 5, "count extension counts actual sessions and preserves deleted exceptions")
    let added = occurrences().first { $0.startDate == at(4) }!
    try require(added.title == "Current title" && added.notes == "Preserve note 3", "extension persists live title and notes")
    try require(baseline.allSatisfy { before in occurrences().contains { RecurrenceTemplate($0) == before } }, "existing per-occurrence content is untouched")
    try require(readMaster(key).recurrenceRules!.first!.recurrenceEnd!.occurrenceCount == 4, "legacy recurrence master is not rewritten")
    for occurrence in additions { try writer.deleteCreatedOccurrence(occurrence) }
    try require(occurrences().map(RecurrenceTemplate.init) == baseline, "undo restores the original live schedule")
    let again = RepeatPlanner.extensionOccurrences(live: liveSchedule(), baseline: schedule,
                                                   end: .count(5), now: Date(), calendar: cal)
    _ = try writer.appendOccurrences(again, from: occurrences())
    try require(occurrences().count == 5 && occurrences().contains { $0.startDate == at(4) && $0.title == "Current title" },
                "re-extending after undo still creates the added weeks")

    let shifted = EKEvent(eventStore: store)
    shifted.calendar = test; shifted.title = "Shifted branch title"; shifted.notes = "Shifted branch notes"
    shifted.startDate = cal.date(byAdding: .minute, value: -30, to: at(4))!
    shifted.endDate = shifted.startDate.addingTimeInterval(3600)
    let start = cal.date(byAdding: .weekOfYear, value: 1, to: shifted.startDate)!
    let end = start.addingTimeInterval(3600)
    let content = RecurrenceTemplate.latest(for: start, end: end, in: [RecurrenceTemplate(shifted)], calendar: cal)!
    let copied = try writer.createOccurrence(in: test, start: start, end: end, content: content)
    try require(copied.title == shifted.title && copied.notes == shifted.notes && copied.startDate == start && copied.endDate == end,
                "shifted branch one-off persists live content rather than master content")
}
do { try run() } catch { print("ERROR: \(error)"); exit(1) }
