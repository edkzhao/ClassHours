import SwiftUI

@main
struct ClassHoursApp: App {
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

    /// Re-forms series membership by grouping events that share a calendar and
    /// a title — the same rule Tidy Up uses, without its renames or notes work.
    private func rebuildSeries() {
        let formed = series.rebuild(from: state.seriesGroupsFromTitles())
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
                        if series.isEmpty { rebuildSeries() }
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
