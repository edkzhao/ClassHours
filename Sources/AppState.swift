import Foundation
import EventKit
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // MARK: Stored state

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published var selectedCalendarID: String? { didSet { persistSelectedCalendar(); refresh() } }
    @Published private(set) var records: [EventOccurrenceRecord] = []
    @Published var errorMessage: String?

    @Published var selectedYear: Int
    @Published var selectedMonth: Int          // 1...12

    /// calendarID -> count events under 30 minutes. Off by default, and stored
    /// per calendar: a calendar of short admin blocks wants different treatment
    /// from one full of two-hour classes.
    @Published private var countShortByCalendar: [String: Bool] = [:]

    @Published var query: String = ""

    /// The user's own preference. A narrow window overrides it temporarily
    /// without overwriting it, so widening again restores what they chose.
    @Published var sidebarExpanded: Bool {
        didSet { defaults.set(sidebarExpanded, forKey: Keys.sidebarExpanded) }
    }
    /// Held here rather than in a view so every page drives the same toggle.
    @Published var narrowWindow = false

    var sidebarVisible: Bool { sidebarExpanded && !narrowWindow }

    func toggleSidebar() {
        if narrowWindow { narrowWindow = false; sidebarExpanded = true }
        else { sidebarExpanded.toggle() }
    }

    /// calendarID -> feedback column visible
    @Published private var feedbackVisible: [String: Bool] = [:]
    /// "calendarID|recordID" -> checked
    @Published private var feedbackChecks: [String: Bool] = [:]
    /// The Dock badge is global rather than month-scoped, so it reflects every
    /// feedback item that has been introduced into the user's tracked months.
    @Published private(set) var dockBadgeCount = 0

    /// Bumped to ask the table to scroll somewhere.
    @Published private(set) var scrollRequestID: Int = 0
    @Published private(set) var scrollTargetRecordID: String?
    /// Rows that should flash once the scroll lands. Empty means no flash --
    /// opening the app jumps to today every time, and a flash there would just
    /// be noise.
    @Published private(set) var blinkRecordIDs: Set<String> = []
    /// Flash strength, 0...1. Driven here rather than per row: rows in a
    /// LazyVStack are recreated as they scroll in, which would reset any local
    /// animation state part-way through.
    @Published private(set) var blinkPhase: Double = 0
    private var blinkTask: Task<Void, Never>?

    /// Ticks once a minute so the unchecked count re-evaluates as sessions
    /// finish while the window is left open.
    @Published private var clockTick = Date()
    private var clockTimer: AnyCancellable?

    // MARK: Calendar page

    enum Page { case hours, calendar }
    @Published var page: Page = .hours { didSet { defaults.set(page == .calendar ? "calendar" : "hours", forKey: Keys.lastPage) } }

    /// Calendar identifiers in the order the user arranged them in Settings.
    /// Anything not listed follows, in the store's own order.
    @Published private(set) var calendarOrder: [String] = []
    @Published var showRemaining = true { didSet { refreshRemainingCounts() } }
    @Published var seriesStarts: [String: [Date]] = [:]
    /// Supplied by SeriesStore so calendar data can resolve ClassHours series
    /// membership without AppState owning it.
    var seriesLookup: ((String) -> [String])?
    /// calendarID -> shown on the calendar page. Independent of which calendar
    /// the hours report is looking at.
    @Published private var calendarShown: [String: Bool] = [:]

    /// One EventKit query per day, remembered until something could have
    /// changed it.
    ///
    /// The calendar page reads a day's classes from inside `body`, and its body
    /// re-runs on every frame of a pan — so the week grid was firing dozens of
    /// store queries per frame, which is what made the page take a second or
    /// two to appear.
    private var dayCache: [Date: [Occurrence]] = [:]

    func occurrences(on day: Date) -> [Occurrence] {
        let key = calculationCalendar.startOfDay(for: day)
        if let hit = dayCache[key] { return hit }
        let items = computeOccurrences(on: key)
        // Panning walks forward indefinitely; keep the window bounded.
        if dayCache.count > 120 { dayCache.removeAll() }
        dayCache[key] = items
        return items
    }

    /// Class history per calendar, so typing a name does not re-query the
    /// store on every keystroke.
    private var historyCache: [String: [ClassSuggestion]] = [:]

    func suggestions(for calendarID: String) -> [ClassSuggestion] {
        if let hit = historyCache[calendarID] { return hit }
        let found = classHistory(calendarID: calendarID)
        historyCache[calendarID] = found
        return found
    }

    func invalidateDayCache() {
        dayCache.removeAll()
        historyCache.removeAll()
    }
    /// A lightweight in-session undo record for edits that sweep a logical
    /// ClassHours series.
    struct SeriesUndo {
        struct Member {
            let key: String
            let title: String
            let notes: String
        }
        let members: [Member]
    }

    private struct RecurrenceUndo {
        struct Member {
            let eventIdentifier: String
            let externalIdentifier: String
            let rules: [EKRecurrenceRule]?
            let wasRecurring: Bool
        }
        let members: [Member]
    }

    private struct EventPropertiesUndo {
        struct Member {
            let event: EKEvent
            let title: String?
            let notes: String?
            let calendar: EKCalendar?
            let start: Date?
            let end: Date?
        }
        let members: [Member]
    }

    private let undoHistory = SessionUndoStack(limit: 3)
    private var undoShortcutMonitor: Any?

    func offerUndo(_ undo: SeriesUndo) {
        guard !undo.members.isEmpty else { return }
        registerUndo { [weak self] in self?.restore(undo) }
    }

    func recurrenceUndoAction(for events: [EKEvent]) -> (() -> Void)? {
        var seen = Set<String>()
        let members = events.compactMap { event -> RecurrenceUndo.Member? in
            guard let identifier = event.eventIdentifier,
                  seen.insert(identifier).inserted
            else { return nil }
            return .init(eventIdentifier: identifier,
                         externalIdentifier: event.calendarItemExternalIdentifier ?? "",
                         rules: copiedRules(event.recurrenceRules),
                         wasRecurring: event.hasRecurrenceRules)
        }
        guard !members.isEmpty else { return nil }
        let undo = RecurrenceUndo(members: members)
        return { [weak self] in self?.restore(undo) }
    }

    func eventPropertiesUndoAction(for events: [EKEvent]) -> (() -> Void)? {
        var seen = Set<String>()
        let members = events.compactMap { event -> EventPropertiesUndo.Member? in
            let key = event.eventIdentifier ?? ObjectIdentifier(event).debugDescription
            guard seen.insert(key).inserted else { return nil }
            return .init(event: event, title: event.title, notes: event.notes,
                         calendar: event.calendar, start: event.startDate, end: event.endDate)
        }
        guard !members.isEmpty else { return nil }
        let undo = EventPropertiesUndo(members: members)
        return { [weak self] in self?.restore(undo) }
    }

    func registerUndo(_ action: @escaping () -> Void) {
        undoHistory.register(action)
    }

    func installUndoShortcut() {
        guard undoShortcutMonitor == nil else { return }
        undoShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "z",
                  !(NSApp.keyWindow?.firstResponder is NSTextView)
            else { return event }
            Task { @MainActor in self?.undoLastOperation() }
            return nil
        }
    }

    func undoLastOperation() {
        _ = undoHistory.undo()
    }

    private func restore(_ undo: SeriesUndo) {
        var restored = 0
        for member in undo.members {
            guard let ev = store.calendarItems(withExternalIdentifier: member.key).first as? EKEvent
                    ?? store.event(withIdentifier: member.key) else { continue }
            ev.title = member.title
            ev.notes = member.notes
            // Same rule as everywhere else: only a real recurrence takes
            // .futureEvents, or EventKit splits a series that was never split.
            try? store.save(ev, span: ev.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: false)
            restored += 1
        }
        if restored > 0 { try? store.commit() }
        refresh()
        refreshRemainingCounts()
    }

    private func restore(_ undo: RecurrenceUndo) {
        var restored = 0
        for member in undo.members {
            let event = store.event(withIdentifier: member.eventIdentifier)
                ?? store.calendarItems(withExternalIdentifier: member.externalIdentifier)
                    .compactMap { $0 as? EKEvent }
                    .first(where: { $0.hasRecurrenceRules })
            guard let event else { continue }
            event.recurrenceRules = copiedRules(member.rules)
            try? store.save(event,
                            span: member.wasRecurring ? .futureEvents : .thisEvent,
                            commit: false)
            restored += 1
        }
        if restored > 0 { try? store.commit() }
        refresh()
        refreshRemainingCounts()
    }

    private func restore(_ undo: EventPropertiesUndo) {
        var restored = 0
        for member in undo.members {
            member.event.title = member.title
            member.event.notes = member.notes
            member.event.calendar = member.calendar
            member.event.startDate = member.start
            member.event.endDate = member.end
            try? store.save(member.event, span: .thisEvent, commit: false)
            restored += 1
        }
        if restored > 0 { try? store.commit() }
        refresh()
        refreshRemainingCounts()
    }

    private func copiedRules(_ rules: [EKRecurrenceRule]?) -> [EKRecurrenceRule]? {
        rules?.compactMap { $0.copy() as? EKRecurrenceRule }
    }

    deinit {
        if let undoShortcutMonitor { NSEvent.removeMonitor(undoShortcutMonitor) }
    }

    /// Fired once the calendar list is populated, so work that needs the
    /// calendars can run at the right moment rather than on first render.
    var onCalendarsLoaded: (() -> Void)?

    /// Renames a person in one role, in the roster's events as well as the
    /// roster itself, so the two can never drift apart.
    @discardableResult
    func renameRoleHolder(calendarID: String, role: RoleKind,
                          from old: String, to new: String) -> Int {
        guard let ekCal = ekCalendar(calendarID),
              let from = calculationCalendar.date(byAdding: .year, value: -3, to: Date()),
              let to = calculationCalendar.date(byAdding: .year, value: 3, to: Date())
        else { return 0 }

        do {
            let writer = CalendarWriter(store: store, calendar: calculationCalendar)
            let changed = try writer.renameRoleHolder(in: ekCal, role: role,
                                                      from: old, to: new,
                                                      between: from, and: to)
            invalidateDayCache()
            refresh()
            refreshRemainingCounts()
            if !changed.isEmpty {
                offerUndo(.init(members: changed.map {
                    .init(key: $0.key, title: $0.title, notes: $0.notes)
                }))
            }
            return changed.count
        } catch {
            reportError(error.localizedDescription)
            return 0
        }
    }

    /// The app-wide settings sheet.
    @Published var settingsShown = false

    /// Drop a calendar's own name from the front of its events' titles.
    @Published var hideTitlePrefix: Bool {
        didSet { defaults.set(hideTitlePrefix, forKey: Keys.hidePrefix) }
    }

    /// The band the week opens on, in minutes from midnight. 1440 is the end of
    /// the day — the only value above 23:59 that means anything.
    @Published var dayStartMinutes: Int {
        didSet { defaults.set(dayStartMinutes, forKey: Keys.dayStart) }
    }
    @Published var dayEndMinutes: Int {
        didSet { defaults.set(dayEndMinutes, forKey: Keys.dayEnd) }
    }

    static let dayStartDefault = 8 * 60
    static let dayEndDefault = 23 * 60

    /// Accepts a range only if it reads forwards and stays inside one day.
    @discardableResult
    func setDayRange(start: Int, end: Int) -> Bool {
        guard DayRange.isValid(start: start, end: end) else { return false }
        dayStartMinutes = start
        dayEndMinutes = end
        return true
    }

    func calendarTitle(_ id: String) -> String {
        calendars.first { $0.id == id }?.title ?? ""
    }

    /// The title as it should read on screen. Anywhere the title is edited uses
    /// the real one — this is display only.
    func displayTitle(_ title: String, calendarID: String) -> String {
        guard hideTitlePrefix else { return title }
        return TitlePrefix.strip(title, prefix: calendarTitle(calendarID))
    }

    /// Which calendar's settings sheet is open.
    ///
    /// Plain state rather than a closure: the closure was installed by the
    /// calendar page's onAppear, so right-click → Settings did nothing until
    /// that page had been visited.
    @Published var calendarSettingsFor: String?

    func reportError(_ message: String) { errorMessage = message }

    func isVisible(_ calendarID: String) -> Bool {
        if let known = calendarShown[calendarID] { return known }
        return (defaults.object(forKey: Keys.calendarShownPrefix + calendarID) as? Bool) ?? true
    }
    func setVisible(_ visible: Bool, _ calendarID: String) {
        calendarShown[calendarID] = visible
        defaults.set(visible, forKey: Keys.calendarShownPrefix + calendarID)
        // Hiding the calendar you are reading would leave the report showing a
        // calendar the sidebar no longer lists.
        if !visible, calendarID == selectedCalendarID {
            selectedCalendarID = visibleCalendars.first?.id
        }
        invalidateDayCache()
        refreshRemainingCounts()
    }

    let store = EKEventStore()
    private let defaults = UserDefaults.standard
    let calculationCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private enum Keys {
        static let selectedCalendar = "selectedCalendarIdentifier"
        static let countShortPrefix = "countShort."
        static let feedbackVisiblePrefix = "feedbackVisible."
        static let feedbackChecksPrefix = "feedbackChecks."
        static let feedbackSeededPrefix = "feedbackSeeded."
        static let sidebarExpanded = "sidebarExpanded"
        static let calendarOrder = "calendarOrder.v1"
        static let lastPage = "lastPage"
        static let calendarShownPrefix = "calendarShown."
        static let hidePrefix = "hideTitlePrefix"
        static let dayStart = "dayStartMinutes"
        static let dayEnd = "dayEndMinutes"
    }

    // MARK: Init

    init() {
        let now = Date()
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        selectedYear = c.component(.year, from: now)
        selectedMonth = c.component(.month, from: now)
        sidebarExpanded = (defaults.object(forKey: Keys.sidebarExpanded) as? Bool) ?? true
        hideTitlePrefix = (defaults.object(forKey: Keys.hidePrefix) as? Bool) ?? true
        dayStartMinutes = (defaults.object(forKey: Keys.dayStart) as? Int) ?? AppState.dayStartDefault
        dayEndMinutes = (defaults.object(forKey: Keys.dayEnd) as? Int) ?? AppState.dayEndDefault
        selectedCalendarID = defaults.string(forKey: Keys.selectedCalendar)
        calendarOrder = defaults.stringArray(forKey: Keys.calendarOrder) ?? []
        // Reopen where you left off. The view within the page is always the
        // default one, though — today's month, and the calendar's own band.
        page = defaults.string(forKey: Keys.lastPage) == "calendar" ? .calendar : .hours
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)

        clockTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] tick in
                self?.clockTick = tick
                self?.refreshDockBadge()
            }
    }

    // MARK: Access

    var hasReadAccess: Bool { authorizationStatus == .fullAccess }

    var statusText: String {
        switch authorizationStatus {
        case .fullAccess:    return "Calendar access granted."
        case .denied:        return "Calendar access is denied. Enable access in System Settings."
        case .restricted:    return "Calendar access is restricted on this Mac."
        case .notDetermined: return "Calendar access has not been requested."
        case .writeOnly:     return "Write-only Calendar access cannot read existing events. Enable full Calendar access in System Settings."
        @unknown default:    return "Calendar access status is unknown."
        }
    }

    func requestReadAccessIfNeeded() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .fullAccess {
            reloadCalendars()
        } else if authorizationStatus == .notDetermined {
            requestReadAccess()
        }
    }

    func requestReadAccess() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if let error { self.errorMessage = error.localizedDescription }
                if granted { self.reloadCalendars() }
            }
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Calendars

    /// Rank sources the way Calendar.app's sidebar groups them.
    private func sourceDisplayRank(_ source: EKSource?) -> Int {
        switch source?.sourceType {
        case .some(.local):      return 0
        case .some(.calDAV):     return 1
        case .some(.mobileMe):   return 2
        case .some(.exchange):   return 3
        case .some(.subscribed): return 4
        case .some(.birthdays):  return 5
        default:                 return 6
        }
    }

    func reloadCalendars() {
        guard hasReadAccess else {
            calendars = []; records = []
            dockBadgeCount = 0
            NSApplication.shared.dockTile.badgeLabel = nil
            return
        }

        let raw = store.calendars(for: .event)
        let ordered = raw.sorted { a, b in
            let ra = sourceDisplayRank(a.source), rb = sourceDisplayRank(b.source)
            if ra != rb { return ra < rb }
            let sa = a.source?.title ?? "", sb = b.source?.title ?? ""
            if sa != sb { return sa.localizedStandardCompare(sb) == .orderedAscending }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }

        calendars = ordered.enumerated().map { index, cal in
            CalendarChoice(
                id: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source?.title ?? "Other",
                sourceRank: sourceDisplayRank(cal.source),
                colorIndex: index % Palette.calendarDots.count
            )
        }

        if selectedCalendarID == nil || !calendars.contains(where: { $0.id == selectedCalendarID }) {
            selectedCalendarID = calendars.first?.id
        } else {
            refresh()
        }
        // didSet does not fire for the initial value, so the counts behind the
        // default-on "remaining" switch have to be primed here.
        refreshRemainingCounts()
        if !calendars.isEmpty { onCalendarsLoaded?() }
        refreshDockBadge()
        // Open on today rather than at the top of the month.
        jumpToToday()
    }

    /// Every calendar in the arranged order, hidden ones included — this is
    /// what Settings lists.
    var orderedCalendars: [CalendarChoice] {
        let rank = Dictionary(uniqueKeysWithValues: calendarOrder.enumerated().map { ($1, $0) })
        return calendars.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? (calendarOrder.count + a.offset)
                let rb = rank[b.element.id] ?? (calendarOrder.count + b.offset)
                return ra < rb
            }
            .map(\.element)
    }

    /// What the sidebar and the calendar actually show.
    var visibleCalendars: [CalendarChoice] {
        orderedCalendars.filter { isVisible($0.id) }
    }

    func moveCalendar(_ id: String, by delta: Int) {
        var ids = orderedCalendars.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        let to = from + delta
        guard ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        calendarOrder = ids
        defaults.set(ids, forKey: Keys.calendarOrder)
    }

    var selectedCalendar: CalendarChoice? {
        calendars.first { $0.id == selectedCalendarID }
    }

    private func persistSelectedCalendar() {
        if let id = selectedCalendarID { defaults.set(id, forKey: Keys.selectedCalendar) }
    }

    // MARK: Month

    var monthInterval: HalfOpenMonthInterval? {
        HalfOpenMonthInterval.make(year: selectedYear, month: selectedMonth, calendar: calculationCalendar)
    }

    var monthLabel: String {
        let symbols = calculationCalendar.standaloneMonthSymbols
        let index = selectedMonth - 1
        return (index >= 0 && index < symbols.count) ? symbols[index] : ""
    }

    var daysInMonth: Int {
        guard let interval = monthInterval else { return 30 }
        return calculationCalendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 30
    }

    func moveMonth(by delta: Int) {
        guard let interval = monthInterval,
              let moved = calculationCalendar.date(byAdding: .month, value: delta, to: interval.start)
        else { return }
        selectedYear = calculationCalendar.component(.year, from: moved)
        selectedMonth = calculationCalendar.component(.month, from: moved)
        refresh()
    }

    func setMonth(year: Int, month: Int) {
        selectedYear = year
        selectedMonth = month
        refresh()
    }

    var todayStart: Date { calculationCalendar.startOfDay(for: Date()) }
    var tomorrowStart: Date { calculationCalendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart }

    var selectedMonthContainsToday: Bool {
        guard let interval = monthInterval else { return false }
        return interval.contains(todayStart)
    }

    func jumpToToday() {
        let now = Date()
        let year = calculationCalendar.component(.year, from: now)
        let month = calculationCalendar.component(.month, from: now)
        // Only refetch when the month actually changes -- switching calendars
        // already refreshed, and a second fetch here would be wasted.
        if year != selectedYear || month != selectedMonth {
            selectedYear = year
            selectedMonth = month
            refresh()
        }
        let day = calculationCalendar.component(.day, from: now)
        requestScroll(to: firstRecordID(onOrAfterDay: day), blink: [])
    }

    /// Chart bar tapped: land on the day and flash every row in it, otherwise
    /// it's hard to tell where you were sent.
    func scrollToDay(_ day: Int) {
        requestScroll(to: firstRecordID(onOrAfterDay: day), blink: Set(recordIDs(onDay: day)))
    }

    /// The oldest session still awaiting feedback -- the one most overdue.
    func jumpToOldestUnchecked() {
        let now = Date()
        guard let target = countedRecords.first(where: {
            $0.hasFinished(asOf: now) && !isChecked($0)
        }) else { return }
        requestScroll(to: target.id, blink: [target.id])
    }

    private func requestScroll(to recordID: String?, blink: Set<String>) {
        scrollTargetRecordID = recordID
        blinkRecordIDs = blink
        scrollRequestID += 1

        blinkTask?.cancel()
        blinkPhase = 0
        guard !blink.isEmpty else { return }
        // One slow pulse, not a strobe: it should read as a quiet nudge toward
        // where you landed, then get out of the way.
        blinkTask = Task { @MainActor [weak self] in
            // Let the scroll finish, or the pulse happens off-screen.
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { self.blinkPhase = 1 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeInOut(duration: 0.80)) { self.blinkPhase = 0 }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self.blinkRecordIDs = []
        }
    }

    /// Falls forward to the next day with events, so a blank day still lands
    /// somewhere sensible rather than not scrolling at all.
    private func firstRecordID(onOrAfterDay day: Int) -> String? {
        let cal = calculationCalendar
        let rows = visibleRecords
        return (rows.first { cal.component(.day, from: $0.countedStart) >= day } ?? rows.last)?.id
    }

    private func recordIDs(onDay day: Int) -> [String] {
        let cal = calculationCalendar
        return visibleRecords
            .filter { cal.component(.day, from: $0.countedStart) == day }
            .map(\.id)
    }

    // MARK: Loading

    func refresh() {
        guard hasReadAccess,
              let id = selectedCalendarID,
              let calendar = store.calendar(withIdentifier: id),
              let interval = monthInterval
        else {
            records = []
            dockBadgeCount = 0
            NSApplication.shared.dockTile.badgeLabel = nil
            invalidateDayCache()
            return
        }

        loadFeedbackPreferences(for: id)
        let fetched = EventMonthCalculator.auditedRecords(
            store: store, calendar: calendar, interval: interval
        )
        seedFeedbackIfNeeded(calendarID: id, records: fetched)
        records = fetched
        refreshDockBadge()
        invalidateDayCache()
    }

    /// The first time a calendar+month is opened, everything already in the past
    /// is marked as done -- there is no point clicking through months of history.
    /// Seeding writes explicit values, so it happens exactly once per month and
    /// every later change is the user's own record.
    ///
    /// Short events are seeded too, even though they have no checkbox while
    /// "Count <30m" is off. That way flipping the setting reveals boxes that
    /// already match the record rather than a pile of unchecked ones.
    private func seedFeedbackIfNeeded(calendarID: String, records: [EventOccurrenceRecord]) {
        let monthKey = String(format: "%04d-%02d", selectedYear, selectedMonth)
        let seededKey = Keys.feedbackSeededPrefix + calendarID + "." + monthKey
        guard !defaults.bool(forKey: seededKey) else { return }

        let today = todayStart
        var changed = false
        for record in records where record.countedStart < today {
            let key = calendarID + "|" + record.stableID
            if feedbackChecks[key] == nil {
                feedbackChecks[key] = true
                changed = true
            }
        }
        defaults.set(true, forKey: seededKey)
        if changed { saveFeedbackChecks(for: calendarID) }
    }

    // MARK: Feedback preferences

    private func loadFeedbackPreferences(for calendarID: String) {
        if feedbackVisible[calendarID] == nil {
            let key = Keys.feedbackVisiblePrefix + calendarID
            feedbackVisible[calendarID] = (defaults.object(forKey: key) as? Bool) ?? true
        }
        if countShortByCalendar[calendarID] == nil {
            let key = Keys.countShortPrefix + calendarID
            countShortByCalendar[calendarID] = (defaults.object(forKey: key) as? Bool) ?? false
        }
        let checksKey = Keys.feedbackChecksPrefix + calendarID
        if let stored = defaults.dictionary(forKey: checksKey) as? [String: Bool] {
            for (k, v) in stored { feedbackChecks[calendarID + "|" + k] = v }
        }
    }

    var countShortEvents: Bool {
        guard let id = selectedCalendarID else { return false }
        return countShortByCalendar[id] ?? false
    }

    func setCountShortEvents(_ value: Bool) {
        guard let id = selectedCalendarID else { return }
        countShortByCalendar[id] = value
        defaults.set(value, forKey: Keys.countShortPrefix + id)
        refreshDockBadge()
    }

    var isFeedbackColumnVisible: Bool {
        guard let id = selectedCalendarID else { return false }
        return isFeedbackColumnVisible(id)
    }

    func isFeedbackColumnVisible(_ id: String) -> Bool {
        if let known = feedbackVisible[id] { return known }
        return (defaults.object(forKey: Keys.feedbackVisiblePrefix + id) as? Bool) ?? true
    }

    func setFeedbackColumnVisible(_ visible: Bool, _ id: String) {
        feedbackVisible[id] = visible
        defaults.set(visible, forKey: Keys.feedbackVisiblePrefix + id)
        if id == selectedCalendarID { refreshDockBadge() }
    }

    func setFeedbackColumnVisible(_ visible: Bool) {
        guard let id = selectedCalendarID else { return }
        feedbackVisible[id] = visible
        defaults.set(visible, forKey: Keys.feedbackVisiblePrefix + id)
        refreshDockBadge()
    }

    func isChecked(_ record: EventOccurrenceRecord) -> Bool {
        guard let id = selectedCalendarID else { return false }
        // Stable key first; fall back to the old volatile one so ticks made
        // before this change aren't lost.
        if let v = feedbackChecks[id + "|" + record.stableID] { return v }
        return feedbackChecks[id + "|" + record.id] ?? false
    }

    func toggleChecked(_ record: EventOccurrenceRecord) {
        guard let id = selectedCalendarID else { return }
        let next = !isChecked(record)
        feedbackChecks[id + "|" + record.stableID] = next
        // Retire the legacy entry so the two can't disagree later.
        feedbackChecks[id + "|" + record.id] = nil
        saveFeedbackChecks(for: id)
        refreshDockBadge()
    }

    private func saveFeedbackChecks(for calendarID: String) {
        let prefix = calendarID + "|"
        var slice: [String: Bool] = [:]
        for (k, v) in feedbackChecks where k.hasPrefix(prefix) {
            slice[String(k.dropFirst(prefix.count))] = v
        }
        defaults.set(slice, forKey: Keys.feedbackChecksPrefix + calendarID)
    }

    /// Mirrors the feedback column for the currently selected report. Counting
    /// directly from `records` avoids silently including hidden calendars or
    /// historical months the user is not looking at.
    func refreshDockBadge() {
        guard hasReadAccess, selectedCalendarID != nil else {
            dockBadgeCount = 0
            NSApplication.shared.dockTile.badgeLabel = nil
            return
        }
        let count = FeedbackCounter.uncheckedCount(
            records: records,
            now: Date(),
            countShortEvents: countShortEvents,
            feedbackEnabled: isFeedbackColumnVisible,
            isChecked: isChecked)
        dockBadgeCount = count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: Derived

    /// Whether a record contributes to the totals.
    func isCounted(_ record: EventOccurrenceRecord) -> Bool {
        countShortEvents || !record.isShort
    }

    /// Whether a row should read as done and recede.
    ///
    /// With the feedback column on that is the tick. With it off there is no
    /// tick to read, so a finished session settles on time alone — otherwise
    /// every row in a feedback-less calendar stayed at full strength forever.
    func isSettled(_ record: EventOccurrenceRecord) -> Bool {
        // A row settles on time whenever there is no tick to read: either the
        // column is hidden, or the session is too short to be counted and so
        // carries no checkbox. Without the second case a short session stayed
        // at full strength forever, long after it was over.
        guard isFeedbackColumnVisible, isCounted(record) else {
            _ = clockTick          // re-evaluate as sessions finish
            return record.hasFinished(asOf: Date())
        }
        return isChecked(record)
    }

    func isFinal(_ record: EventOccurrenceRecord) -> Bool {
        isFinalOccurrence(record.startDate, seriesKey: record.seriesKey)
    }

    /// Search-filtered rows, always in chronological order. Includes uncounted
    /// short events, which stay visible with a stopwatch on their duration.
    var visibleRecords: [EventOccurrenceRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return records }
        return records.filter { record in
            if record.title.lowercased().contains(trimmed) { return true }
            // Whoever is on the class counts too: "Pita" finds every session
            // she manages, "k4" finds the ones coordinated by K4 Sheila.
            return record.notes.roleLines.contains {
                $0.person.lowercased().contains(trimmed)
                    || $0.label.lowercased().contains(trimmed)
            }
        }
    }

    var countedRecords: [EventOccurrenceRecord] { visibleRecords.filter(isCounted) }

    var totalSeconds: Int { countedRecords.reduce(0) { $0 + $1.countedSeconds } }
    var eventsCount: Int { countedRecords.count }

    /// Feedback you actually owe: unchecked, and only for sessions that have
    /// already finished. Anything still running or yet to happen is excluded.
    var uncheckedFeedbackCount: Int {
        let now = Date()
        return countedRecords.filter { $0.hasFinished(asOf: now) && !isChecked($0) }.count
    }

    var averagePerDaySeconds: Int {
        let days = max(daysInMonth, 1)
        return Int((Double(totalSeconds) / Double(days)).rounded())
    }

    /// Index 0 is day 1.
    var hoursPerDay: [Double] {
        var buckets = [Double](repeating: 0, count: daysInMonth)
        for record in countedRecords {
            let day = calculationCalendar.component(.day, from: record.countedStart)
            let index = day - 1
            if index >= 0 && index < buckets.count {
                buckets[index] += Double(record.countedSeconds) / 3600
            }
        }
        return buckets
    }

    func isToday(_ record: EventOccurrenceRecord) -> Bool {
        calculationCalendar.startOfDay(for: record.countedStart) == todayStart
    }

    func isTomorrow(_ record: EventOccurrenceRecord) -> Bool {
        calculationCalendar.startOfDay(for: record.countedStart) == tomorrowStart
    }
}
