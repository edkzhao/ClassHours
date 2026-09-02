import SwiftUI
import AppKit

/// Keeps the single main window alive when its close button is pressed. This
/// follows the usual menu-bar/Dock pattern: close hides it; clicking the Dock
/// icon brings the same window forward; Command-Q still quits the app.
final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.adoptMainWindow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        adoptMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        adoptMainWindow()
        guard let mainWindow else { return true }
        sender.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func adoptMainWindow() {
        guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) else { return }
        mainWindow = window
        if window.delegate !== self { window.delegate = self }
    }
}

@main
struct ClassHoursApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle
    @StateObject private var state = AppState()
    @StateObject private var prefs = PrefsStore()
    @StateObject private var series = SeriesStore()
    @StateObject private var holidays = HolidayStore()

    /// Repopulates every calendar's role sections and name lists from the
    /// roles already recorded in its events.
    private func rebuildRosters() {
        for choice in state.calendars {
            prefs.rebuildRoster(for: choice.id, from: state.roleNotes(calendarID: choice.id))
        }
    }

    /// Repairs any local membership links that are missing from otherwise
    /// identical event titles. Existing links and EventKit notes are untouched.
    private func rebuildSeries() {
        let formed = series.repair(from: state.seriesGroupsFromTitles())
        if formed > 0 { state.refreshRemainingCounts() }
    }

    var body: some Scene {
        Window(Brand.name, id: "main") {
            ContentView()
                .environmentObject(state)
                .environmentObject(prefs)
                .environmentObject(series)
                .environmentObject(holidays)
                .onAppear {
                    state.seriesLookup = { [weak series] in series?.siblings(of: $0) ?? [$0] }
                    // Feeds are cached, so this only tops them up.
                    Task { await holidays.refresh() }
                    // A blank slate — first run, or settings lost — can be
                    // filled straight from what the events already say. Waits
                    // for the calendars, which arrive after authorisation.
                    state.onCalendarsLoaded = {
                        if prefs.isEmpty { rebuildRosters() }
                        rebuildSeries()
                    }
                }
                // The design is a single committed light interface.
                .preferredColorScheme(.light)
                .frame(minWidth: 680, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .sidebar) {
                Button(state.sidebarExpanded ? "Hide Sidebar" : "Show Sidebar") {
                    state.sidebarExpanded.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            CommandGroup(after: .appSettings) {
                Button("Settings\u{2026}") { state.settingsShown = true }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Calendar") {
                Button("Hours Report") { state.page = .hours }
                Button("Calendar") { state.page = .calendar }
                Divider()
                Toggle("Show Remaining Occurrences", isOn: Binding(
                    get: { state.showRemaining },
                    set: { state.showRemaining = $0 }))
                Divider()
                // Scratch calendar for exercising writes without touching real
                // teaching records.
                Button("Tidy Up Series\u{2026}") {
                    NotificationCenter.default.post(name: .openTidyUp, object: nil)
                }
                Divider()
                Button("Rebuild Rosters from Events") { rebuildRosters() }
                Button("Rebuild Series from Titles") { rebuildSeries() }
                Divider()
                Button("Create Test Calendar") {
                    do {
                        _ = try CalendarWriter.makeTestCalendar(store: state.store, named: "ClassHours Test")
                        state.reloadCalendars()
                    } catch {
                        state.reportError(error.localizedDescription)
                    }
                }
            }

            CommandMenu("Month") {
                Button("Previous Month") { state.moveMonth(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Month") { state.moveMonth(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Today") { state.jumpToToday() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Refresh") { state.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Find\u{2026}") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Toggle("Count Events Under 30 Minutes", isOn: Binding(
                    get: { state.countShortEvents },
                    set: { state.setCountShortEvents($0) }
                ))
            }
        }
    }
}
