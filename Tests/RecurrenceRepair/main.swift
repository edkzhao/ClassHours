import Foundation
import EventKit

enum RepairFailure: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw RepairFailure.invalid(message) }
}
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let lower = calendar.date(from: DateComponents(year: 2023, month: 1, day: 1))!
let upper = calendar.date(from: DateComponents(year: 2030, month: 1, day: 1))!

func rules(_ event: EKEvent) -> [String] {
    (event.recurrenceRules ?? []).map {
        [String($0.frequency.rawValue), String($0.interval),
         ($0.daysOfTheWeek ?? []).map { "\($0.dayOfTheWeek.rawValue):\($0.weekNumber)" }.joined(separator: ","),
         String(describing: $0.daysOfTheMonth), String(describing: $0.monthsOfTheYear),
         String(describing: $0.weeksOfTheYear), String(describing: $0.daysOfTheYear),
         String(describing: $0.setPositions), String($0.recurrenceEnd?.occurrenceCount ?? 0),
         String(describing: $0.recurrenceEnd?.endDate?.timeIntervalSinceReferenceDate)].joined(separator: "|")
    }
}

struct Snapshot: Codable, Equatable {
    let key: String
    let calendarID: String
    let calendarName: String
    let start: Date
    let end: Date
    var title: String?
    let notes: String?
    let location: String?
    let url: URL?
    let zone: String?
    let allDay: Bool
    var detached: Bool
    let availability: Int
    let status: Int
    let recurrence: [String]
    let alarms: [String]
    var identity: String { "\(calendarID)|\(key)|\(start.timeIntervalSinceReferenceDate)" }

    init(_ event: EKEvent) {
        key = event.seriesKey; calendarID = event.calendar.calendarIdentifier
        calendarName = event.calendar.title; start = event.startDate; end = event.endDate
        title = event.title; notes = event.notes; location = event.location; url = event.url
        zone = event.timeZone?.identifier; allDay = event.isAllDay; detached = event.isDetached
        availability = event.availability.rawValue; status = event.status.rawValue
        recurrence = rules(event)
        alarms = (event.alarms ?? []).map {
            "\(String(describing: $0.absoluteDate))|\($0.relativeOffset)|\($0.proximity.rawValue)|\(String(describing: $0.structuredLocation?.title))"
        }.sorted()
    }
}

func events(_ store: EKEventStore) -> [EKEvent] {
    let calendars = store.calendars(for: .event).filter { $0.type != .subscription && $0.type != .birthday }
    var seen = Set<String>()
    return EventSearch.windows(from: lower, to: upper, calendar: calendar).flatMap { window in
        store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars))
    }.filter { !$0.isAllDay && $0.status != .canceled && seen.insert(Snapshot($0).identity).inserted }
}

func master(_ store: EKEventStore, key: String, calendarID: String) -> EKEvent? {
    store.calendarItems(withExternalIdentifier: key).compactMap { $0 as? EKEvent }
        .first { $0.calendar.calendarIdentifier == calendarID && $0.hasRecurrenceRules && !$0.isDetached }
}

struct Action: Codable {
    let kind: String
    let before: Snapshot
    let newTitle: String
}
struct Backup: Codable {
    let date: Date
    let actions: [Action]
    let live: [Snapshot]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601

func verify(_ actions: [Action], baseline: [Snapshot], store: EKEventStore) throws {
    var expected = Dictionary(uniqueKeysWithValues: baseline.map { ($0.identity, $0) })
    for action in actions where action.kind == "occurrence" {
        guard var value = expected[action.before.identity] else { throw RepairFailure.invalid("Missing occurrence in baseline") }
        value.title = action.newTitle
        if !value.recurrence.isEmpty { value.detached = true }
        expected[value.identity] = value
    }
    let found = Dictionary(uniqueKeysWithValues: events(store).map { let value = Snapshot($0); return (value.identity, value) })
    let differences = Set(expected.keys).union(found.keys).filter { expected[$0] != found[$0] }
    if !differences.isEmpty {
        for key in differences.prefix(8) {
            let before = expected[key].flatMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) } as? NSDictionary
            let after = found[key].flatMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) } as? NSDictionary
            let fields = Set((before?.allKeys as? [String]) ?? []).union((after?.allKeys as? [String]) ?? []).filter {
                !NSDictionary(dictionary: ["value": before?[$0] ?? NSNull()]).isEqual(to: ["value": after?[$0] ?? NSNull()])
            }
            print("Verification difference: \(key); fields: \(fields.sorted())")
        }
    }
    try require(differences.isEmpty, "Unexpected live occurrence changes: \(differences.count)")
}

func run() throws {
    try require(EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Full Calendar access required")
    let arguments = CommandLine.arguments
    try require(arguments.count >= 2, "Usage: recurrence-repair plan.json [--apply] [--event UID newTitle]...")
    let store = EKEventStore()
    let live = events(store)
    let baseline = live.map(Snapshot.init)
    var actions: [Action] = []
    var ambiguous = 0
    var invalidMasters = 0
    var refreshedTitles = 0
    var requestedTitles: [String: String] = [:]
    var verificationBackup: String?
    for (key, occurrences) in Dictionary(grouping: live, by: \.seriesKey) {
        let calendarIDs = Set(occurrences.map { $0.calendar.calendarIdentifier })
        guard calendarIDs.count == 1, let calendarID = calendarIDs.first,
              let target = master(store, key: key, calendarID: calendarID) else { continue }
        let titles = Set(occurrences.compactMap(\.title))
        if titles.count != 1 { ambiguous += 1; continue }
        guard let title = titles.first, !title.isEmpty, target.title != title else { continue }
        let beforeRefresh = Snapshot(target)
        if !target.refresh() { invalidMasters += 1; continue }
        if target.title == title { refreshedTitles += 1; continue }
        try require(target.calendar.allowsContentModifications, "Read-only calendar: \(target.calendar.title)")
        try require(target.seriesKey == beforeRefresh.key, "Master identity changed during refresh")
        // Legacy first-occurrence lookups are never repair write targets.
    }
    var index = 2
    while index < arguments.count {
        if arguments[index] == "--apply" { index += 1; continue }
        if arguments[index] == "--occurrences-only" { index += 1; continue }
        if arguments[index] == "--verify-baseline" {
            try require(index + 1 < arguments.count, "Missing verification backup path")
            verificationBackup = arguments[index + 1]; index += 2; continue
        }
        if arguments[index] == "--restore-live" {
            try require(index + 1 < arguments.count, "Missing backup path")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
            let originals = Dictionary(uniqueKeysWithValues: backup.live.map { ($0.identity, $0) })
            try require(Set(originals.keys) == Set(baseline.map(\.identity)), "Cannot restore titles across a changed event set")
            for current in baseline {
                let original = originals[current.identity]!
                var comparable = current; comparable.title = original.title; comparable.detached = original.detached
                try require(comparable == original, "Backup differs beyond title; manual inspection required")
                if current.title != original.title {
                    guard let title = original.title else { throw RepairFailure.invalid("Missing original title") }
                    actions.append(Action(kind: "occurrence", before: current, newTitle: title))
                }
            }
            index += 2; continue
        }
        try require(arguments[index] == "--event" && index + 2 < arguments.count, "Invalid correction arguments")
        let key = arguments[index + 1], title = arguments[index + 2]
        requestedTitles[key] = title
        let matches = live.filter { $0.seriesKey == key }
        try require(matches.count == 1, "Correction must identify exactly one occurrence")
        let target = matches[0]
        try require(!target.hasRecurrenceRules && !title.isEmpty && target.calendar.allowsContentModifications,
                    "Correction must target one writable non-recurring event")
        if target.title != title { actions.append(Action(kind: "occurrence", before: Snapshot(target), newTitle: title)) }
        index += 3
    }
    if let path = verificationBackup {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let permitted = backup.live.compactMap { before -> Action? in
            guard let title = requestedTitles[before.key] else { return nil }
            return Action(kind: "occurrence", before: before, newTitle: title)
        }
        try require(permitted.count == requestedTitles.count, "Verification corrections must be unique")
        try verify(permitted, baseline: backup.live, store: EKEventStore())
        print("Independent original-backup verification passed: \(backup.live.count) occurrences, only \(permitted.count) requested title changes; no writes.")
        return
    }
    actions.sort { $0.before.identity < $1.before.identity }
    let planURL = URL(fileURLWithPath: arguments[1])
    try encoder.encode(Backup(date: Date(), actions: actions, live: baseline)).write(to: planURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planURL.path)
    print("Plan: \(actions.count) individual occurrence titles; no recurrence master writes; \(ambiguous) ambiguous native recurrences skipped.")
    print("Legacy lookups: \(invalidMasters) invalid first-occurrence placeholders skipped; \(refreshedTitles) titles corrected by refreshing the lookup without writes.")
    guard arguments.contains("--apply") else { print("Dry run only; no Calendar writes."); return }

    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClassHours/Repairs")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let backupURL = directory.appendingPathComponent("branch-titles-\(UUID().uuidString).json")
    try encoder.encode(Backup(date: Date(), actions: actions, live: baseline)).write(to: backupURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    print("Backup: \(backupURL.path)")
    var applied: [Action] = []
    do {
        try verify([], baseline: baseline, store: EKEventStore())
        for action in actions {
            let target = events(store).first { Snapshot($0).identity == action.before.identity }
            guard let target else { throw RepairFailure.invalid("Repair target disappeared") }
            try require(target.refresh(), "Repair target is no longer valid")
            try require(Snapshot(target) == action.before, "Repair target changed since preflight")
            target.title = action.newTitle
            applied.append(action)
            try store.save(target, span: .thisEvent, commit: true)
            try verify(applied, baseline: baseline, store: EKEventStore())
            print("Verified \(applied.count)/\(actions.count): \(action.newTitle)")
        }
        // A fresh store catches accidental expansion, dropped exceptions and unrelated edits.
        try verify(applied, baseline: baseline, store: EKEventStore())
        print("Repair complete. All \(baseline.count) live occurrences preserved except the requested titles; recurrence rules, notes, times and other captured properties unchanged.")
    } catch {
        print("Repair stopped after \(applied.count) attempted writes: \(error). Rolling back applied titles only.")
        for action in applied.reversed() {
            let target = events(store).first { Snapshot($0).identity == action.before.identity }
            guard let target else { throw RepairFailure.invalid("Rollback target missing; retain backup \(backupURL.path)") }
            target.title = action.before.title
            try store.save(target, span: .thisEvent, commit: true)
        }
        try verify([], baseline: baseline, store: EKEventStore())
        throw error
    }
}

do { try run() } catch { print("ERROR: \(error)"); exit(1) }
