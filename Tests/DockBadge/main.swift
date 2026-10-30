import Foundation
import EventKit
import AppKit

enum Failure: Error { case assertion(String) }
@MainActor
func check(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure.assertion(message) }
    print("ok: \(message)")
}

@MainActor
func eventually(_ state: AppState, count: Int) async throws {
    let deadline = Date().addingTimeInterval(5)
    while state.dockBadgeCount != count && Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(state.dockBadgeCount == count, "automatic refresh publishes \(count)")
}

@MainActor
func run() async throws {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
        print("Live lifecycle tests skipped: no existing Calendar read access.")
        return
    }
    let preferencesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Containers/com.edzhao.ClassHours/Data/Library/Preferences/com.edzhao.ClassHours.plist")
    let original = try Data(contentsOf: preferencesURL)
    let preferences = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
    let suite = "ClassHours.DockBadgeTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setPersistentDomain(preferences, forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("calendar", forKey: "lastPage")
    let store = EKEventStore()
    let disabled = store.calendars(for: .event).first {
        (preferences["feedbackVisible." + $0.calendarIdentifier] as? Bool) == false
    }
    if let disabled { defaults.set(disabled.calendarIdentifier, forKey: "selectedCalendarIdentifier") }
    let state = AppState(defaults: defaults)
    state.reloadCalendars()
    await state.refreshDockBadge().value
    let inputs = FeedbackBadge.inputs(calendarIDs: state.calendars.map(\.id), preferences: defaults.dictionaryRepresentation(),
                                      calendar: state.calculationCalendar)
    let expected = FeedbackBadge.read(inputs, now: Date())
    try check(state.page == .calendar && state.dockBadgeCount == expected, "cold start on Calendar page counts feedback before any sidebar click")
    if let disabled { try check(state.selectedCalendarID == disabled.calendarIdentifier, "selected feedback-disabled calendar does not suppress other calendars") }
    print("Read-only live total: \(expected)")

    state.selectedCalendarID = nil
    await state.refreshDockBadge().value
    try check(state.records.isEmpty && state.dockBadgeCount == expected, "empty report records do not clear the badge")
    state.selectedYear = 2023; state.selectedMonth = 1; state.query = "no matching title"
    await state.refreshDockBadge().value
    try check(state.dockBadgeCount == expected, "browsing another month or searching cannot hide pending feedback")

    if let positive = inputs.first(where: { FeedbackBadge.read([$0], now: Date()) > 0 }) {
        let contribution = FeedbackBadge.read([positive], now: Date())
        state.setFeedbackColumnVisible(false, positive.id)
        try await eventually(state, count: expected - contribution)
        state.setFeedbackColumnVisible(true, positive.id)
        try await eventually(state, count: expected)
        for _ in 0..<5 {
            state.setFeedbackColumnVisible(false, positive.id)
            state.setFeedbackColumnVisible(true, positive.id)
        }
        await state.refreshDockBadge().value
        try await eventually(state, count: expected)
        try check(state.dockBadgeCount == expected, "stale background reads cannot overwrite the latest setting")
    }

    // Edit only the isolated preference copy; no EventKit or real preference writes.
    for input in inputs { defaults.set(false, forKey: "feedbackVisible." + input.id) }
    NotificationCenter.default.post(name: .EKEventStoreChanged, object: state.store)
    try await eventually(state, count: 0)
    try check(NSApplication.shared.dockTile.badgeLabel == nil, "zero pending feedback clears the Dock label")
    for input in inputs { defaults.set(true, forKey: "feedbackVisible." + input.id) }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try await eventually(state, count: expected)
    try check(try Data(contentsOf: preferencesURL) == original, "real feedback preferences were not modified")
    print("Calendar records were read only; the isolated preference suite will be removed.")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("ERROR: \(error)"); exit(1) }
}
app.run()
