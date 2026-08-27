import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var series: SeriesStore
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var holidays: HolidayStore
    @FocusState private var searchFocused: Bool
    @State private var monthPickerShown = false
    @State private var pickerYear: Int = 0
    @State private var selectedRowID: String?
    @State private var detailKey: String?
    @State private var revealed = false
    @State private var refreshSpin = 0.0
    @State private var tidyUpShown = false

    /// Below this the sidebar folds away on its own, so the window can be
    /// dragged genuinely small without the table being squeezed to nothing.
    private static let sidebarCollapseWidth: CGFloat = 900

    /// The narrow-window override wins, but only while it applies.
    private var sidebarVisible: Bool { state.sidebarVisible }

    var body: some View {
        // A real GeometryReader, not a preference set inside .background():
        // background content's preferences don't reliably reach the parent, so
        // the width was never observed and auto-collapse never fired.
        GeometryReader { geo in
            shell
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: geo.size.width, initial: true) { _, width in
                    let shouldCollapse = width > 0 && width < Self.sidebarCollapseWidth
                    guard shouldCollapse != state.narrowWindow else { return }
                    withAnimation(.easeInOut(duration: 0.22)) { state.narrowWindow = shouldCollapse }
                }
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    private func closeDetail() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { detailKey = nil }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let detailKey {
            EventDetailPanel(occurrenceKey: detailKey, onClose: closeDetail)
                .frame(width: 512)
                .background(Palette.surface)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.rule).frame(width: 1) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .id(detailKey)
        }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarRail(selectedRowID: $selectedRowID)
                    .frame(width: 224)
                    .zIndex(2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if state.page == .calendar {
                CalendarPage()
            } else {
                VStack(spacing: 0) {
                    topBar
                    if state.hasReadAccess {
                        summaryBand
                        tableArea
                    } else {
                        accessGate
                    }
                    statusBar
                }
                .background(Palette.canvas)
                // Same panel the calendar page opens, so an event is edited the
                // same way whichever list you found it in.
                .overlay {
                    if detailKey != nil {
                        Color.black.opacity(0.06)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: closeDetail)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .trailing) { detailPanel }
            }
        }
        .background(Palette.surface)
        .overlay {
            if state.settingsShown {
                ZStack {
                    // So Settings stays visually in front, gently soften the
                    // calendar behind it while keeping the outside click area.
                    Color.black.opacity(0.10)
                        .contentShape(Rectangle())
                        .onTapGesture { state.settingsShown = false }
                    SettingsSheet(onClose: { state.settingsShown = false })
                        .environmentObject(state)
                        .environmentObject(prefs)
                        .environmentObject(holidays)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.rule, lineWidth: 1)
                        }
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        // Presented at the root so it is reachable from either page.
        .sheet(item: Binding(get: { state.calendarSettingsFor.map(IdentifiedString.init) },
                             set: { state.calendarSettingsFor = $0?.value })) { wrapped in
            CalendarSettingsSheet(calendarID: wrapped.value)
                .environmentObject(prefs)
                .environmentObject(state)
        }
        .onAppear {
            pickerYear = state.selectedYear
            state.requestReadAccessIfNeeded()
            ClickAwayFocusReleaser.install()
            state.installUndoShortcut()
            // macOS makes the first text field in a window the initial
            // responder, which left the search box permanently outlined with a
            // blinking caret. Start with nothing focused.
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows where window.isVisible {
                    window.makeFirstResponder(nil)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTidyUp)) { _ in
            tidyUpShown = true
        }
        .sheet(isPresented: $tidyUpShown) {
            TidyUpSheet().environmentObject(state).environmentObject(series)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            SidebarToggle()

            HStack(spacing: 4) {
                NavIconButton(systemImage: "chevron.left", help: "Previous month") {
                    moveMonth(-1)
                }

                Button {
                    pickerYear = state.selectedYear
                    monthPickerShown.toggle()
                } label: {
                    // Outer stack is centre-aligned so the chevron sits on the
                    // vertical middle of the text rather than its baseline.
                    HStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(state.monthLabel)
                                .font(Typo.sans(19, .semibold))
                                .foregroundStyle(Palette.ink)
                                .kerning(-0.3)
                            // Same size as the month, a shade lighter -- present,
                            // not shouting.
                            Text(String(state.selectedYear))
                                .font(Typo.mono(19, .light))
                                .foregroundStyle(Palette.ink2)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $monthPickerShown, arrowEdge: .bottom) {
                    monthPicker
                }

                NavIconButton(systemImage: "chevron.right", help: "Next month") {
                    moveMonth(1)
                }

                PillButton(title: "Today", systemImage: nil) { state.jumpToToday() }
                    .padding(.leading, 8)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink3)
                    TextField("Filter events\u{2026}", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(Typo.sans(13.5))
                        .foregroundStyle(Palette.ink)
                        .focused($searchFocused)
                        .frame(width: 180)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(searchFocused ? Palette.surface : Palette.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(searchFocused ? Palette.mark : Palette.rule, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(.easeOut(duration: 0.18), value: searchFocused)

                PillButton(title: nil, systemImage: "arrow.clockwise") {
                    withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                    state.refresh()
                    triggerReveal()
                }
                .rotationEffect(.degrees(refreshSpin))
            }
        }
        // Flush with the summary band below it. The window's title-bar safe
        // area already drops this row clear of the traffic lights, so no extra
        // indent is needed when the sidebar is hidden.
        .padding(.horizontal, TopBarInset.horizontal)
        .padding(.top, TopBarInset.top)
        .padding(.bottom, TopBarInset.bottom)
        // No rule beneath: this shares its background with the summary band, so
        // the two read as one header block.
        .background(Palette.surface)
    }

    private var monthPicker: some View {
        VStack(spacing: 9) {
            HStack {
                NavIconButton(systemImage: "chevron.left", help: "Previous year") { pickerYear -= 1 }
                Spacer()
                Text(String(pickerYear))
                    .font(Typo.mono(15, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                NavIconButton(systemImage: "chevron.right", help: "Next year") { pickerYear += 1 }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(1...12, id: \.self) { month in
                    let isCurrent = month == state.selectedMonth && pickerYear == state.selectedYear
                    Button {
                        state.setMonth(year: pickerYear, month: month)
                        selectedRowID = nil
                        monthPickerShown = false
                        triggerReveal()
                    } label: {
                        Text(shortMonth(month))
                            .font(Typo.sans(13, .medium))
                            .foregroundStyle(isCurrent ? .white : Palette.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(isCurrent ? Palette.railA : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(Palette.surface)
    }

    private func shortMonth(_ month: Int) -> String {
        let symbols = state.calculationCalendar.shortStandaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : ""
    }

    // MARK: Summary

    private var summaryBand: some View {
        HStack(alignment: .top, spacing: 16) {
            ReadoutPanel(totalSeconds: state.totalSeconds)
                .frame(width: 272)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    StatCard(value: "\(state.eventsCount)", suffix: nil, label: "Events")
                    StatCard(
                        value: state.isFeedbackColumnVisible ? "\(state.uncheckedFeedbackCount)" : "\u{2014}",
                        suffix: nil,
                        label: "Unchecked feedback",
                        alert: state.isFeedbackColumnVisible && state.uncheckedFeedbackCount > 0
                    )
                    .onTapGesture { state.jumpToOldestUnchecked() }
                    StatCard(
                        value: DurationFormatter.string(state.averagePerDaySeconds),
                        suffix: "/ \(DurationFormatter.decimal(state.averagePerDaySeconds)) h",
                        label: "Average per day",
                        compact: true
                    )
                }
                // One definite height for the row, so all three cards match.
                .frame(height: 62)

                DayChart(
                    hours: state.hoursPerDay,
                    todayIndex: todayIndex,
                    onSelectDay: { day in state.scrollToDay(day) }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // 62 card row + 10 gap + the chart's 96 minimum + 24 padding.
        .frame(height: 192)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
    }

    private var todayIndex: Int? {
        guard state.selectedMonthContainsToday else { return nil }
        return state.calculationCalendar.component(.day, from: Date()) - 1
    }

    // MARK: Table

    private var tableArea: some View {
        VStack(spacing: 0) {
            EventTableHeader()
            Divider().overlay(Palette.rule)

            if state.visibleRecords.isEmpty {
                emptyTable
            } else {
                EventTableBody(selectedRowID: $selectedRowID, revealed: revealed) { record in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        detailKey = record.panelKey
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: tableIdentity) { triggerReveal() }
    }

    private var tableIdentity: String {
        "\(state.selectedCalendarID ?? "")|\(state.selectedYear)-\(state.selectedMonth)|\(state.query)"
    }

    private func triggerReveal() {
        revealed = false
        DispatchQueue.main.async { revealed = true }
    }

    private var emptyTable: some View {
        Group {
            if state.calendars.isEmpty {
                EmptyStateView(
                    title: "No calendars",
                    message: "No event calendars are available."
                )
            } else if !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyStateView(
                    title: "No matching events",
                    message: "Nothing in \(state.monthLabel) \(state.selectedYear) matches \u{201C}\(state.query)\u{201D}.",
                    systemImage: "magnifyingglass"
                )
            } else {
                EmptyStateView(
                    title: "No Counted Events",
                    message: "This calendar has no non-all-day, non-cancelled events overlapping \(state.monthLabel) \(state.selectedYear)."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    // MARK: Access gate

    private var accessGate: some View {
        EmptyStateView(
            title: "Calendar access needed",
            message: state.authorizationStatus == .notDetermined
                ? "Grant Calendar access to read events."
                : state.statusText,
            systemImage: "lock",
            actionTitle: state.authorizationStatus == .notDetermined ? "Grant Access" : "Open Settings",
            action: {
                if state.authorizationStatus == .notDetermined {
                    state.requestReadAccess()
                } else {
                    state.openCalendarPrivacySettings()
                }
            }
        )
        .frame(maxHeight: .infinity)
        .background(Palette.canvas)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            keyHint("\u{2318}\u{2190}", "\u{2318}\u{2192}", "month")
            keyHint("\u{2191}", "\u{2193}", "row")
            keyHint("space", nil, "check")
            keyHint("\u{2318}T", nil, "today")
            keyHint("\u{2318}F", nil, "search")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
    }

    private func keyHint(_ a: String, _ b: String?, _ label: String) -> some View {
        HStack(spacing: 3) {
            keyCap(a)
            if let b { keyCap(b) }
            Text(label)
                .font(Typo.mono(11))
                .foregroundStyle(Palette.ink3)
        }
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(Typo.mono(10.5))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.surface2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func moveMonth(_ delta: Int) {
        state.moveMonth(by: delta)
        selectedRowID = nil
        triggerReveal()
    }
}

// MARK: - Sidebar

struct SidebarRail: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var holidays: HolidayStore
    @Binding var selectedRowID: String?

    @State private var settingsHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // On the Hours page the mark opens the Calendar. On the Calendar it
            // is inert -- you leave by picking a calendar below.
            Button {
                if state.page == .hours { state.page = .calendar }
            } label: {
                HStack(spacing: 10) {
                    Text("\u{03A3}")
                        .font(Typo.mono(14, .bold))
                        .foregroundStyle(Palette.readoutA)
                        .frame(width: 30, height: 30)
                        .background(Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(Brand.name)
                        .font(Typo.sans(15.5, .semibold))
                        .foregroundStyle(Palette.railInk)
                        .kerning(-0.2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Inert on the calendar, but not dimmed -- .disabled() would fade
            // the mark, and it's the app's identity, not a control.
            .allowsHitTesting(state.page == .hours)
            .help(state.page == .hours ? "Open the calendar" : "")
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The rail ignores the title-bar safe area (below), so this band is
            // measured from the window's top edge. Reserve the strip the
            // traffic lights sit in, then centre the mark in what's left --
            // putting it midway between the buttons and the divider.
            .frame(height: 76)
            .padding(.top, 20)

            Rectangle().fill(Palette.railRule).frame(height: 1)

            // One flat list in the order set in Settings — the source a
            // calendar happens to sync through isn't something you choose by.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.visibleCalendars) { choice in
                        CalendarRow(
                            choice: choice,
                            // The highlight marks which report you're
                            // reading, so it clears on the calendar.
                            isSelected: choice.id == state.selectedCalendarID
                                        && state.page == .hours
                        ) {
                            // A calendar always means its hours report.
                            state.page = .hours
                            state.selectedCalendarID = choice.id
                            selectedRowID = nil
                            state.jumpToToday()
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)

            if !holidays.feeds.filter(\.isUsable).isEmpty {
                Rectangle().fill(Palette.railRule).frame(height: 1)
                HolidayLegend()
            }

            Rectangle().fill(Palette.railRule).frame(height: 1)

            HStack(spacing: 8) {
                if state.page == .calendar {
                    RailSwitch(
                        title: "Remaining",
                        help: "Show how many occurrences are left",
                        isOn: Binding(get: { state.showRemaining },
                                      set: { state.showRemaining = $0 })
                    )
                } else {
                    RailSwitch(
                        title: "Count <30m",
                        help: "Per calendar",
                        isOn: Binding(
                            get: { state.countShortEvents },
                            set: { state.setCountShortEvents($0) }
                        )
                    )
                }

                Spacer(minLength: 0)

                Button { state.settingsShown = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(settingsHovering ? Palette.railInk : Palette.railInk2)
                        .frame(width: 26, height: 26)
                        .background(settingsHovering ? Color.white.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { settingsHovering = $0 }
                .help("Settings")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                Palette.railGradient
                RadialGradient(
                    colors: [.white.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.15, y: 0),
                    startRadius: 0, endRadius: 260
                )
            }
        )
        // Lay out from the window's top edge rather than below the title bar,
        // so the header band's top is a known point to centre against.
        .ignoresSafeArea(edges: .top)
    }
}

struct CalendarRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    let choice: CalendarChoice
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(prefs.color(choice.id, fallbackIndex: choice.colorIndex))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 2.5))

                Text(choice.displayName)
                    .font(Typo.sans(14, isSelected ? .semibold : .regular))
                    .foregroundStyle(Palette.railInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isSelected ? Color.white.opacity(0.15) : (hovering ? Color.white.opacity(0.09) : .clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Palette.accent)
                        .frame(width: 3)
                        .padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contextMenu {
            // Reachable from either page: the roles and colours it edits show
            // up in the hours report too, not just on the calendar.
            Button("Settings…") { state.calendarSettingsFor = choice.id }
        }
    }
}

// MARK: - Table columns

enum Col {
    static let date: CGFloat = 112
    /// Wide enough for the "START TIME" label; values are trailing-aligned so
    /// the three numeric columns read as one right-aligned block.
    static let time: CGFloat = 90
    /// Wide enough for the duration plus the stopwatch / info affordances.
    static let duration: CGFloat = 116
    /// Breathing room between the numbers and the checkbox column.
    static let gap: CGFloat = 34
    static let feedback: CGFloat = 84
    static let inset: CGFloat = 16
}

struct EventTableHeader: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            label("Date", width: Col.date, align: .leading)
            label("Event", width: nil, align: .leading)
            label("Start Time", width: Col.time, align: .trailing)
            label("End Time", width: Col.time, align: .trailing)
            label("Duration", width: Col.duration, align: .trailing)
            if state.isFeedbackColumnVisible {
                Color.clear.frame(width: Col.gap, height: 1)
                label("Feedback", width: Col.feedback, align: .center)
            }
        }
        .padding(.horizontal, Col.inset)
        .padding(.vertical, 9)
        .background(Palette.surface)
    }

    private func label(_ title: String, width: CGFloat?, align: Alignment) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Palette.ink3)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }
}

struct EventTableBody: View {
    @EnvironmentObject private var state: AppState
    @Binding var selectedRowID: String?
    let revealed: Bool
    let onOpen: (EventOccurrenceRecord) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let rows = state.visibleRecords
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                        let previous = index > 0 ? rows[index - 1] : nil
                        EventRow(
                            record: record,
                            isFirstOfDay: isFirstOfDay(record, previous: previous),
                            isSelected: selectedRowID == record.id,
                            index: index,
                            revealed: revealed
                        ) {
                            selectedRowID = nil
                            onOpen(record)
                        }
                        .id(record.id)
                    }
                }
            }
            .background(Palette.canvas)
            // task(id:) also runs on first appearance, so a jump requested
            // before this view existed -- app launch, or switching calendars --
            // still lands instead of being dropped.
            .task(id: state.scrollRequestID) {
                guard state.scrollRequestID > 0,
                      let target = state.scrollTargetRecordID else { return }
                // Let the lazy stack lay out before asking it to scroll.
                try? await Task.sleep(nanoseconds: 150_000_000)
                // A quarter down the viewport: a glimpse of yesterday above,
                // and most of the day ahead below.
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.25))
                }
            }
        }
    }

    /// Grouped by the event's real start day, matching what the Date column
    /// shows. A session carried over from the previous month therefore forms its
    /// own group at the top rather than being folded into the 1st.
    private func isFirstOfDay(_ record: EventOccurrenceRecord, previous: EventOccurrenceRecord?) -> Bool {
        guard let previous else { return true }
        let cal = state.calculationCalendar
        return cal.startOfDay(for: record.startDate) != cal.startOfDay(for: previous.startDate)
    }
}

struct EventRow: View {
    @EnvironmentObject private var state: AppState
    let record: EventOccurrenceRecord
    let isFirstOfDay: Bool
    let isSelected: Bool
    let index: Int
    let revealed: Bool
    let onTap: () -> Void

    @State private var hovering = false
    @State private var infoHovering = false

    private var counted: Bool { state.isCounted(record) }
    private var checked: Bool { state.isChecked(record) }
    /// Drives the fade. Where there is no tick to read — column hidden, or a
    /// session too short to count — a finished session settles on time instead.
    private var settled: Bool { state.isSettled(record) }
    private var isToday: Bool { state.isToday(record) }
    private var isTomorrow: Bool { state.isTomorrow(record) }

    var body: some View {
        HStack(spacing: 0) {
            // Date blanks on repeat, so the table reads grouped by day.
            Text(isFirstOfDay ? dateText : "")
                .font(Typo.mono(13))
                .foregroundStyle(Palette.ink2)
                .frame(width: Col.date, alignment: .leading)

            HStack(spacing: 0) {
                Text(state.displayTitle(record.title, calendarID: state.selectedCalendarID ?? ""))
                    .font(Typo.sans(14))
                    .foregroundStyle(settled ? Palette.ink3 : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)

                // Who's attached to the class. Set well back from the title and
                // faded, so the column still scans as a list of class names.
                let roles = record.notes.roleLines
                if !roles.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(roles.enumerated()), id: \.element.id) { i, role in
                            if i > 0 {
                                Rectangle()
                                    .fill(Palette.ink3.opacity(0.6))
                                    .frame(width: 1, height: 11)
                                    .padding(.horizontal, 11)
                            }
                            HStack(spacing: 4) {
                                Text("\(role.label):")
                                    .foregroundStyle(Palette.ink3)
                                // The name carries the row's own state: it
                                // stays legible while feedback is outstanding
                                // and fades once the row is ticked off.
                                Text(role.person)
                                    .foregroundStyle(settled ? Palette.ink3 : Palette.ink2)
                            }
                            .lineLimit(1)
                        }
                    }
                    .font(Typo.sans(12).italic())
                    .padding(.leading, 20)
                    .layoutPriority(1)
                }

                // The last of a series, after the roles. Cool green so it
                // reads as "closed" rather than as another warm alert.
                if state.isFinal(record) {
                    Text("FINAL")
                        .font(Typo.sans(10, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(settled ? Palette.ink3 : Palette.finalInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(settled ? Palette.ruleSoft : Palette.finalWash,
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(.leading, 14)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(record.title)

            // The event's real bounds, even when only part of it falls in this
            // month. The duration is what's actually counted here.
            Text(timeText(record.startDate))
                .font(Typo.mono(13.5))
                .foregroundStyle(Palette.ink2)
                .frame(width: Col.time, alignment: .trailing)

            Text(timeText(record.endDate))
                .font(Typo.mono(13.5))
                .foregroundStyle(Palette.ink2)
                .frame(width: Col.time, alignment: .trailing)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if !counted {
                    Text("\u{23F1}\u{FE0F}").font(.system(size: 11))
                }
                if record.isClipped {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.mark)
                        .onHover { infoHovering = $0 }
                }
                Text(DurationFormatter.string(record.countedSeconds))
                    .font(Typo.mono(13.5, .medium))
                    .foregroundStyle(settled ? Palette.ink3 : Palette.ink)
            }
            .frame(width: Col.duration, alignment: .trailing)

            if state.isFeedbackColumnVisible {
                Color.clear.frame(width: Col.gap, height: 1)
                Group {
                    if counted {
                        FeedbackTick(checked: checked) { state.toggleChecked(record) }
                    } else {
                        Color.clear.frame(width: 18, height: 18)
                    }
                }
                .frame(width: Col.feedback, alignment: .center)
            }
        }
        .padding(.horizontal, Col.inset)
        .frame(height: 38)
        .background {
            ZStack {
                rowBackground
                // The pulse borrows today's wash exactly -- same tint, same
                // fade across the row -- so it reads as the app's own language
                // rather than a new alert colour. Sits behind the text, so
                // nothing is tinted over.
                todayWash.opacity(isBlinkTarget ? state.blinkPhase : 0)
            }
        }
        .overlay(alignment: .leading) {
            if isToday {
                Rectangle().fill(Palette.accent).frame(width: 3)
            } else if isTomorrow {
                Rectangle().fill(Palette.mark40).frame(width: 3)
            }
        }
        .overlay(alignment: .top) {
            if isFirstOfDay && index > 0 {
                Rectangle().fill(Palette.rule).frame(height: 1)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.ruleSoft).frame(height: 1)
        }
        // Declared last so it draws above the row's separator hairlines --
        // nested inside the row content, those rules were drawn over the card
        // and cut a line through it.
        //
        // A spanning event is always the month's first or last row, so a fixed
        // direction would clip against the header or footer. Open away from
        // whichever edge this row sits on.
        .overlay(alignment: cardOpensDown ? .topTrailing : .bottomTrailing) {
            if infoHovering {
                SpanInfoCard(
                    total: DurationFormatter.string(record.fullSeconds),
                    counted: DurationFormatter.string(record.countedSeconds)
                )
                .frame(width: 186)
                .offset(x: -cardTrailingInset, y: cardOpensDown ? 5 : -5)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: infoHovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 5)
        .animation(
            .easeOut(duration: 0.3).delay(min(Double(index) * 0.014, 0.32)),
            value: revealed
        )
        // Later siblings draw over earlier ones, so lift the hovered row or the
        // card would slide under the row beneath it.
        .zIndex(infoHovering ? 10 : 0)
    }

    private var isBlinkTarget: Bool { state.blinkRecordIDs.contains(record.id) }

    /// The soft warm wash used to mark today, and reused for the navigation pulse.
    private var todayWash: LinearGradient {
        LinearGradient(
            colors: [Palette.mark20, Palette.mark20.opacity(0)],
            startPoint: .leading, endPoint: UnitPoint(x: 0.46, y: 0.5)
        )
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Palette.mark20
        } else if isToday {
            todayWash
        } else if hovering {
            Palette.ruleSoft
        } else {
            Color.clear
        }
    }

    /// An event clipped at its start began in the previous month, so this is the
    /// first row and the card must open downward. Clipped at the end means the
    /// last row, and it opens upward.
    private var cardOpensDown: Bool { record.countedStart > record.startDate }

    /// Distance from the row's trailing edge to the duration column, so the card
    /// lands just left of the numbers.
    private var cardTrailingInset: CGFloat {
        Col.inset + Col.duration
            + (state.isFeedbackColumnVisible ? Col.feedback + Col.gap : 0)
    }

    /// The event's real start day, so a session carried in from the previous
    /// month reads as "Fri 31 Jul" rather than colliding with the 1st.
    private var dateText: String {
        let cal = state.calculationCalendar
        let weekday = cal.shortWeekdaySymbols[cal.component(.weekday, from: record.startDate) - 1]
        let day = cal.component(.day, from: record.startDate)
        let month = cal.shortMonthSymbols[cal.component(.month, from: record.startDate) - 1]
        return String(format: "%@ %02d %@", weekday, day, month)
    }

    private func timeText(_ date: Date) -> String {
        let cal = state.calculationCalendar
        return String(
            format: "%02d:%02d",
            cal.component(.hour, from: date),
            cal.component(.minute, from: date)
        )
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("ClassHours.focusSearch")
}

/// Ends text editing when you click somewhere else.
///
/// AppKit keeps the field editor as first responder until something explicitly
/// takes it away, and clicking an ordinary SwiftUI view doesn't. Without this
/// the search box stayed outlined with a blinking caret long after you'd moved
/// on. One local event monitor covers every click in the app, rather than
/// wiring "clear focus" into each row, button and chart bar.
enum ClickAwayFocusReleaser {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView
            else { return event }

            // Inset outward so the field's own padding and search icon still
            // count as clicking inside it.
            let editable = editor.convert(editor.bounds, to: nil).insetBy(dx: -20, dy: -12)
            if !editable.contains(event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}
