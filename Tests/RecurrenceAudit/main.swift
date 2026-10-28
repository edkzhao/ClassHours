import Foundation
import EventKit

// Read-only: compare live occurrences with their stored recurrence masters.
guard CommandLine.arguments.count > 1 else { fatalError("Usage: recurrence-audit output.json [student]") }
guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
    fatalError("Calendar permission is required; this audit never requests or writes access.")
}
let store = EKEventStore()
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let from = cal.date(from: DateComponents(year: 2023, month: 1, day: 1))!
let through = cal.date(from: DateComponents(year: 2030, month: 1, day: 1))!
let calendars = store.calendars(for: .event).filter { $0.type != .subscription && $0.type != .birthday }
let prefsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.edzhao.ClassHours/Data/Library/Preferences/com.edzhao.ClassHours.plist")
let prefs = try PropertyListSerialization.propertyList(from: Data(contentsOf: prefsURL), format: nil) as! [String: Any]
let groups = try JSONDecoder().decode([String: [String]].self, from: prefs["seriesMembership.v1"] as? Data ?? Data("{}".utf8))
var groupByKey: [String: String] = [:]
for (id, keys) in groups { for key in keys { groupByKey[key] = id } }
var seen = Set<String>()
var events: [EKEvent] = []
for window in EventSearch.windows(from: from, to: through, calendar: cal) {
    events += store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)).filter {
        !$0.isAllDay && $0.status != .canceled && seen.insert(EventMonthCalculator.occurrenceIdentity($0)).inserted
    }
}
let formatter = DateFormatter()
formatter.timeZone = cal.timeZone
formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
func describe(_ event: EKEvent) -> [String: Any] {
    ["date": formatter.string(from: event.startDate), "end": formatter.string(from: event.endDate), "title": event.title ?? "", "calendar": event.calendar.title,
     "key": event.seriesKey, "detached": event.isDetached]
}
var mismatches: [[String: Any]] = []
var inheritanceChecks = 0
var invalidLookups = 0
for (key, live) in Dictionary(grouping: events, by: \.seriesKey) {
    let candidates = store.calendarItems(withExternalIdentifier: key).compactMap { $0 as? EKEvent }
    guard let master = candidates.first(where: \.hasRecurrenceRules) else { continue }
    let titleGroups = Dictionary(grouping: live, by: { $0.title ?? "" })
    guard titleGroups.count > 1 || titleGroups.keys.first != (master.title ?? "") else { continue }
    let templates = live.map(RecurrenceTemplate.init)
    let branches = Dictionary(grouping: live, by: { BranchSignature(start: $0.startDate, end: $0.endDate, calendar: cal) })
    for (branch, occurrences) in branches where branch != nil {
        let last = occurrences.max { $0.startDate < $1.startDate }!
        let next = cal.date(byAdding: .weekOfYear, value: 1, to: last.startDate)!
        let end = next.addingTimeInterval(last.endDate.timeIntervalSince(last.startDate))
        let inherited = RecurrenceTemplate.latest(for: next, end: end, in: templates, calendar: cal)
        assert(inherited == RecurrenceTemplate(last), "Extension did not inherit the latest live branch snapshot")
        inheritanceChecks += 1
    }
    let tail = live.sorted { $0.startDate < $1.startDate }
    let masterDescription = describe(master)
    let valid = master.refresh()
    if !valid { invalidLookups += 1 }
    mismatches.append(["master": masterDescription, "validLookup": valid, "logicalSeries": groupByKey[key] ?? key,
        "variants": titleGroups.map { title, values in
            ["title": title, "count": values.count,
             "dates": values.sorted { $0.startDate < $1.startDate }.map { formatter.string(from: $0.startDate) }]
        }, "lastOccurrences": tail.suffix(5).map(describe)])
}
var protectedCourses = 0
var plannedChecks = 0
if CommandLine.arguments.count > 3 {
    let original = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
    let rows = original["masterMismatches"] as! [[String: Any]]
    let keys = Set(rows.compactMap { ($0["master"] as? [String: Any])?["key"] as? String })
    for (_, members) in Dictionary(grouping: events, by: { groupByKey[$0.seriesKey] ?? $0.seriesKey }) {
        guard members.contains(where: { keys.contains($0.seriesKey) }) else { continue }
        let live = members.map { PlannedRepeatOccurrence(patternID: $0.seriesKey, start: $0.startDate, end: $0.endDate) }
        let cutoff = cal.date(byAdding: .day, value: 7, to: max(Date(), live.map(\.start).max()!))!
        let plan = RepeatPlanner.extensionOccurrences(live: live, baseline: live, end: .until(cutoff), now: Date(), calendar: cal)
        let templates = members.map(RecurrenceTemplate.init)
        assert(Set(plan.map { "\($0.start)|\($0.end)" }).count == plan.count, "Duplicate logical branch extensions")
        for occurrence in plan {
            guard let content = RecurrenceTemplate.latest(for: occurrence.start, end: occurrence.end, in: templates, calendar: cal) else {
                fatalError("No live content source for an affected course")
            }
            assert(!content.calendarID.isEmpty)
            plannedChecks += 1
        }
        protectedCourses += 1
    }
}
var mixedGroups: [[String: Any]] = []
for (id, live) in Dictionary(grouping: events, by: { groupByKey[$0.seriesKey] ?? $0.seriesKey }) {
    let titles = Set(live.map { $0.title ?? "" })
    guard titles.count > 1 else { continue }
    mixedGroups.append(["series": id, "variants": Dictionary(grouping: live, by: { $0.title ?? "" }).map { title, values in
        ["title": title, "count": values.count, "keys": Array(Set(values.map(\.seriesKey))),
         "first": formatter.string(from: values.map(\.startDate).min()!),
         "last": formatter.string(from: values.map(\.startDate).max()!)]
    }])
}
let output: [String: Any] = ["range": "2023-01-01..<2030-01-01 Asia/Shanghai", "calendarCount": calendars.count, "contentInheritanceChecks": inheritanceChecks,
    "invalidLookupCount": invalidLookups, "protectedOriginalCourses": protectedCourses, "logicalExtensionChecks": plannedChecks,
    "eventCount": events.count, "masterMismatches": mismatches, "mixedLogicalSeries": mixedGroups,
    "reportedStudent": events.filter { CommandLine.arguments.count > 2 && ($0.title ?? "").contains(CommandLine.arguments[2]) }.sorted { $0.startDate < $1.startDate }.map(describe)]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try data.write(to: outputURL, options: .atomic)
print("Read-only audit: \(calendars.count) calendars, \(events.count) occurrences, \(mismatches.count) master mismatches, \(mixedGroups.count) mixed logical series; \(inheritanceChecks) live-branch inheritance checks passed. No calendar writes.")
print("Affected courses covered by the new extension path: \(protectedCourses), \(plannedChecks) new-date/content-source checks; invalid old lookups isolated: \(invalidLookups).")
