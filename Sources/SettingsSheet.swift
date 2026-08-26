import SwiftUI
import AppKit

/// The subscribed-holiday key, shown in the rail above the switches.
struct HolidayLegend: View {
    @EnvironmentObject private var holidays: HolidayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(holidays.feeds.filter(\.isUsable)) { feed in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(hex: CalendarPalette.fallback(for: feed.colorIndex)))
                        .frame(width: 14, height: 7)
                    Text(feed.displayName)
                        .font(Typo.sans(12))
                        .foregroundStyle(Palette.railInk2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// App settings, grouped and reachable from a rail.
struct SettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var holidays: HolidayStore
    let onClose: () -> Void

    enum Group: String, CaseIterable, Identifiable, Hashable {
        case timeRange = "Time Range"
        case calendar = "Calendar"
        case holidays = "Holidays"
        var id: String { rawValue }
    }

    /// Where each group's top sits, so the rail can follow the scroll.
    private struct GroupTops: PreferenceKey {
        static var defaultValue: [Group: CGFloat] { [:] }
        static func reduce(value: inout [Group: CGFloat], nextValue: () -> [Group: CGFloat]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    @State private var active: Group = .timeRange
    @State private var draftFeeds: [HolidayFeed] = []
    /// Feeds whose URL box is open. A loaded feed shows its dates instead.
    @State private var editing: Set<UUID> = []


    private static let space = "settingsScroll"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(Typo.sans(15, .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Palette.rule)

            HStack(spacing: 0) {
                rail
                Divider().overlay(Palette.rule)
                content
            }

            Divider().overlay(Palette.rule)
            HStack {
                if holidays.refreshing {
                    ProgressView().controlSize(.small)
                } else if let error = holidays.lastError {
                    Text(error)
                        .font(Typo.sans(11.5))
                        .foregroundStyle(Palette.mark)
                        .lineLimit(2)
                }
                Spacer()
                AccentButton(title: "Done", action: onClose)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 720, height: 620)
        .background(Palette.canvas)
        .onAppear {
            draftFeeds = holidays.feeds
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows where window.isKeyWindow {
                    window.makeFirstResponder(nil)
                }
            }
        }
        .onDisappear(perform: save)
    }

    // MARK: Rail

    @State private var scrollTo: Group?

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Group.allCases) { group in
                Button { scrollTo = group } label: {
                    Text(group.rawValue)
                        .font(Typo.sans(13, active == group ? .semibold : .regular))
                        .foregroundStyle(active == group ? Palette.ink : Palette.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(active == group ? Palette.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(active == group ? Palette.rule : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 168)
        .background(Palette.surface2)
    }

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section(.timeRange) { timeRange }
                    section(.calendar) { calendarBlock }
                    section(.holidays) { subscriptions }
                }
                .padding(18)
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(GroupTops.self) { tops in
                // The last group whose top has passed the fold is the one you
                // are reading.
                let passed = tops.filter { $0.value <= 24 }
                active = passed.max(by: { $0.value < $1.value })?.key ?? .timeRange
            }
            .onChange(of: scrollTo) { _, group in
                guard let group else { return }
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(group, anchor: .top) }
                scrollTo = nil
            }
        }
    }

    @ViewBuilder
    private func section<C: View>(_ group: Group, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(group)
        .background(GeometryReader { geo in
            Color.clear.preference(key: GroupTops.self,
                                   value: [group: geo.frame(in: .named(Self.space)).minY])
        })
    }

    // MARK: Calendars

    private var calendarBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Calendar")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SegmentedChoice(options: [(false, "Show"), (true, "Hide")],
                                    selection: $state.hideTitlePrefix)
                    Text("Calendar Prefix")
                        .font(Typo.sans(13))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Rectangle().fill(Palette.ruleSoft).frame(height: 1)

                ForEach(Array(state.orderedCalendars.enumerated()), id: \.element.id) { index, choice in
                    calendarRow(choice, index: index, count: state.orderedCalendars.count)
                    if index < state.orderedCalendars.count - 1 {
                        Rectangle().fill(Palette.ruleSoft).frame(height: 1)
                    }
                }
            }
            .background(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func calendarRow(_ choice: CalendarChoice, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { state.isVisible(choice.id) },
                                     set: { state.setVisible($0, choice.id) }))
                .labelsHidden().toggleStyle(.checkbox)

            Circle()
                .fill(prefs.color(choice.id, fallbackIndex: choice.colorIndex))
                .frame(width: 9, height: 9)

            Text(choice.displayName)
                .font(Typo.sans(13))
                .foregroundStyle(state.isVisible(choice.id) ? Palette.ink : Palette.ink3)
                .lineLimit(1)

            Spacer(minLength: 8)

            Toggle("Feedback", isOn: Binding(
                get: { state.isFeedbackColumnVisible(choice.id) },
                set: { state.setFeedbackColumnVisible($0, choice.id) }))
                .toggleStyle(.checkbox)
                .font(Typo.sans(12))
                .foregroundStyle(Palette.ink2)

            HStack(spacing: 2) {
                NavIconButton(systemImage: "chevron.up", help: "Move up") {
                    state.moveCalendar(choice.id, by: -1)
                }
                .opacity(index == 0 ? 0.25 : 1)
                .disabled(index == 0)
                NavIconButton(systemImage: "chevron.down", help: "Move down") {
                    state.moveCalendar(choice.id, by: 1)
                }
                .opacity(index == count - 1 ? 0.25 : 1)
                .disabled(index == count - 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Display

    private var timeRange: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Time Range")
            HStack(spacing: 8) {
                hourMenu(startHour)
                SegmentedChoice(options: [(0, ":00"), (30, ":30")], selection: startHalf)

                Text("to").font(Typo.sans(12.5)).foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 2)

                hourMenu(endHour)
                SegmentedChoice(options: [(0, ":00"), (30, ":30")], selection: endHalf)

                Spacer(minLength: 8)

                Text(DurationFormatter.string((state.dayEndMinutes - state.dayStartMinutes) * 60))
                    .font(Typo.mono(13, .medium))
                    .foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// 00–24. Short enough to type into, and no text field to auto-focus.
    private func hourMenu(_ selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(0...24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 62)
    }

    // Each half of the range is edited as an hour plus a half, and written back
    // through one setter that keeps the pair valid — so no combination of menu
    // choices can produce a backwards or zero-length range.
    private var startHour: Binding<Int> {
        Binding(get: { state.dayStartMinutes / 60 },
                set: { setStart(hour: $0, minute: state.dayStartMinutes % 60) })
    }
    private var startHalf: Binding<Int> {
        Binding(get: { state.dayStartMinutes % 60 },
                set: { setStart(hour: state.dayStartMinutes / 60, minute: $0) })
    }
    private var endHour: Binding<Int> {
        Binding(get: { state.dayEndMinutes / 60 },
                set: { setEnd(hour: $0, minute: state.dayEndMinutes % 60) })
    }
    private var endHalf: Binding<Int> {
        Binding(get: { state.dayEndMinutes % 60 },
                set: { setEnd(hour: state.dayEndMinutes / 60, minute: $0) })
    }

    private func setStart(hour: Int, minute: Int) {
        // A start of 24:00 would leave no day at all, so it stops at 23:30.
        let start = min(hour * 60 + minute, DayRange.dayLength - 30)
        let end = state.dayEndMinutes <= start
            ? min(DayRange.dayLength, start + 30)
            : state.dayEndMinutes
        state.setDayRange(start: start, end: end)
    }

    private func setEnd(hour: Int, minute: Int) {
        let end = min(hour * 60 + minute, DayRange.dayLength)
        let start = end <= state.dayStartMinutes
            ? max(0, end - 30)
            : state.dayStartMinutes
        state.setDayRange(start: start, end: end)
    }

    // MARK: Holiday feeds

    private var subscriptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Holidays")
                Spacer()
                if draftFeeds.count < HolidayStore.maxFeeds {
                    Button {
                        let feed = HolidayFeed(
                            colorIndex: draftFeeds.count % CalendarPalette.options.count)
                        draftFeeds.append(feed)
                        editing.insert(feed.id)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.mark)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Add a subscription")
                }
            }

            ForEach($draftFeeds) { $feed in
                feedCard($feed)
            }
        }
    }

    private func feedCard(_ feed: Binding<HolidayFeed>) -> some View {
        let open = editing.contains(feed.wrappedValue.id) || feed.wrappedValue.url.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Only an open card carries text fields. A loaded one shows its
                // name as plain text, so the sheet has nothing to focus when it
                // opens — which is what kept selecting the first alias.
                if open {
                    TextField("Alias, e.g. US holidays", text: feed.alias)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                } else {
                    Text(feed.wrappedValue.displayName)
                        .font(Typo.sans(13, .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                }

                ForEach(Array(CalendarPalette.options.enumerated()), id: \.offset) { index, option in
                    Button { feed.wrappedValue.colorIndex = index } label: {
                        Circle()
                            .fill(Color(hex: option.hex))
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(
                                feed.wrappedValue.colorIndex == index ? Palette.ink : .clear,
                                lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                Button {
                    draftFeeds.removeAll { $0.id == feed.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.ink3).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }

            let id = feed.wrappedValue.id
            let count = holidays.holidays.filter { $0.feedID == id }.count

            if open {
                HStack(spacing: 8) {
                    TextField("https://…/holidays.ics", text: feed.url)
                        .textFieldStyle(.roundedBorder)
                        .font(Typo.mono(11.5))
                    AccentButton(title: "Load") { load(feed.wrappedValue) }
                        .opacity(feed.wrappedValue.isUsable ? 1 : 0.4)
                        .disabled(!feed.wrappedValue.isUsable)
                }
                if !feed.wrappedValue.url.isEmpty && !feed.wrappedValue.isUsable {
                    Text("That doesn't look like an http, https or webcal link.")
                        .font(Typo.sans(11.5)).foregroundStyle(Palette.mark)
                }
            } else {
                HStack(spacing: 8) {
                    Text(count > 0 ? "\(count) dates" : "No dates loaded")
                        .font(Typo.mono(11.5))
                        .foregroundStyle(count > 0 ? Palette.ink2 : Palette.mark)
                    Spacer(minLength: 8)
                    Button("Edit") { editing.insert(id) }
                        .buttonStyle(.plain)
                        .font(Typo.sans(12, .semibold))
                        .foregroundStyle(Palette.mark)
                }
            }
        }
        .padding(12)
        .background(Palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Locks a feed in and fetches it, so the dates are there before you close.
    private func load(_ feed: HolidayFeed) {
        editing.remove(feed.id)
        holidays.replaceFeeds(cleaned())
        Task { await holidays.refresh() }
    }

    private func cleaned() -> [HolidayFeed] {
        draftFeeds.map { feed in
            var f = feed
            f.url = f.url.trimmingCharacters(in: .whitespacesAndNewlines)
            f.alias = f.alias.trimmingCharacters(in: .whitespaces)
            return f
        }
    }

    /// Saving writes the feeds back and refetches, so the calendar reflects the
    /// edit without a relaunch.
    private func save() {
        holidays.replaceFeeds(cleaned())
        Task { await holidays.refresh() }
    }
}
