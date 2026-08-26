import SwiftUI
import EventKit
import AppKit

// MARK: - Trackpad swipe

/// Horizontal two-finger swipe anywhere over the calendar shifts the days.
///
/// A local event monitor rather than a wrapped NSView: an NSView in the
/// hierarchy would have to sit above the grid to receive scroll events, and
/// would then swallow clicks on the events themselves.
@MainActor
final class SwipeRouter: ObservableObject {
    private var monitor: Any?
    var isPointerInside = false
    var onDelta: ((CGFloat) -> Void)?
    var onSettle: (() -> Void)?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, self.isPointerInside else { return event }
            // Vertical scrolling belongs to the time grid.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            self.onDelta?(event.scrollingDeltaX)
            if event.phase == .ended || event.momentumPhase == .ended { self.onSettle?() }
            return nil    // consumed
        }
    }
}

/// Horizontal panning state.
///
/// The window follows the finger pixel for pixel and then springs to the
/// nearest day boundary, rather than jumping a whole day at a time — which is
/// what made the old version feel dead.
@MainActor
final class PanState: ObservableObject {
    @Published var dragX: CGFloat = 0
    @Published var dayShift = 0
    var columnWidth: CGFloat = 120

    func drag(by delta: CGFloat) { dragX += delta }

    /// Commit whole days immediately and let the leftover pixels spring back,
    /// so the motion never visibly stutters or lands mid-day.
    func settle() {
        guard columnWidth > 0 else { dragX = 0; return }
        let days = Int((-dragX / columnWidth).rounded())
        dayShift += days
        dragX += CGFloat(days) * columnWidth
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) { dragX = 0 }
    }

    func reset() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { dayShift = 0; dragX = 0 }
    }
}

// MARK: - Page

struct CalendarPage: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @StateObject private var swipe = SwipeRouter()

    @StateObject private var pan = PanState()
    @State private var mode: Mode = .week
    @State private var anchor = Date()
    @State private var panel: PanelKind?
    @State private var monthPickerShown = false
    /// nil means "whatever year is on screen". Only a tap on the year arrows
    /// pins it, so there is no initialisation order to get wrong — seeding it
    /// from onAppear/onChange left it reading 0.
    @State private var pickerYear: Int?

    enum Mode { case week, month }
    enum PanelKind: Equatable {
        case compose
        case detail(String)          // occurrence key
    }

    private var cal: Calendar { state.calculationCalendar }

    /// Sunday-first, then shifted by however far you've dragged.
    private var windowStart: Date {
        let base = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)) ?? anchor
        return cal.date(byAdding: .day, value: pan.dayShift, to: base) ?? base
    }
    private var windowDays: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: windowStart) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Palette.rule)
            Group {
                if mode == .week {
                    WeekGrid(windowStart: windowStart, pan: pan, onPick: { open(.detail($0)) })
                } else {
                    MonthGrid(anchor: anchor, onPick: { open(.detail($0)) })
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { swipe.isPointerInside = true } else { swipe.isPointerInside = false }
            }
        }
        .background(Palette.canvas)
        // Clicking anywhere off the panel dismisses it.
        .overlay {
            if panel != nil {
                Color.black.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closePanel)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) { sidePanel }
        .onAppear {
            // Trackpad feeds the same continuous pan as dragging the day row.
            swipe.onDelta = { [weak pan] d in pan?.drag(by: d) }
            swipe.onSettle = { [weak pan] in pan?.settle() }
            swipe.install()
        }
    }

    // MARK: Top bar

    /// Same leading cluster, same spacing and padding as the hours page, so the
    /// chrome doesn't shift when you move between them.
    private var topBar: some View {
        HStack(spacing: 14) {
            SidebarToggle()

            HStack(spacing: 4) {
                NavIconButton(systemImage: "chevron.left", help: "Previous") { step(-1) }

                Button { monthPickerShown.toggle() } label: {
                    HStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(rangeTitle)
                                .font(Typo.sans(19, .semibold))
                                .foregroundStyle(Palette.ink)
                                .kerning(-0.3)
                            Text(String(cal.component(.year, from: windowStart)))
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
                .popover(isPresented: $monthPickerShown, arrowEdge: .bottom) { monthPicker }

                NavIconButton(systemImage: "chevron.right", help: "Next") { step(1) }

                PillButton(title: "Today", systemImage: nil) { goToday() }
                .padding(.leading, 8)
            }

            SegmentedChoice(options: [(Mode.week, "Week"), (Mode.month, "Month")],
                            selection: $mode)

            Spacer(minLength: 8)

            DayRing()

            PillButton(title: "New Event", systemImage: "plus") { open(.compose) }
        }
        .padding(.horizontal, TopBarInset.horizontal)
        .padding(.top, TopBarInset.top)
        .padding(.bottom, TopBarInset.bottom)
        .background(Palette.surface)
    }

    private var rangeTitle: String {
        let symbols = cal.standaloneMonthSymbols
        if mode == .month { return symbols[cal.component(.month, from: anchor) - 1] }
        let first = cal.component(.month, from: windowStart) - 1
        let last = cal.component(.month, from: windowDays.last ?? windowStart) - 1
        return first == last ? symbols[first]
             : "\(symbols[first].prefix(3))–\(symbols[last].prefix(3))"
    }

    /// Same month/year jump the hours page offers — no reason the calendar
    /// should only move a week at a time.
    private var shownYear: Int { pickerYear ?? cal.component(.year, from: windowStart) }

    private var monthPicker: some View {
        VStack(spacing: 9) {
            HStack {
                NavIconButton(systemImage: "chevron.left", help: "Previous year") { pickerYear = shownYear - 1 }
                Spacer()
                Text(String(shownYear)).font(Typo.mono(15, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                NavIconButton(systemImage: "chevron.right", help: "Next year") { pickerYear = shownYear + 1 }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(1...12, id: \.self) { month in
                    let current = month == cal.component(.month, from: windowStart)
                        && shownYear == cal.component(.year, from: windowStart)
                    Button {
                        jump(year: shownYear, month: month)
                        monthPickerShown = false
                        pickerYear = nil
                    } label: {
                        Text(cal.shortStandaloneMonthSymbols[month - 1])
                            .font(Typo.sans(13, .medium))
                            .foregroundStyle(current ? .white : Palette.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(current ? Palette.railA : .clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 268)
    }

    private func jump(year: Int, month: Int) {
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = 1
        guard let target = cal.date(from: comps) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            anchor = target
            pan.dayShift = 0
            pan.dragX = 0
        }
    }

    /// Returns to this week by *travelling* there.
    ///
    /// The window snaps home immediately, then the strip is offset back to
    /// where you were looking, so the spring that follows reads as motion in
    /// the direction you came from rather than a silent cut.
    private func goToday() {
        guard mode == .week else {
            withAnimation(.easeOut(duration: 0.22)) { anchor = Date() }
            return
        }
        let here = windowStart
        let home = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
            ?? Date()
        let days = cal.dateComponents([.day], from: home, to: here).day ?? 0

        anchor = Date()
        pan.dayShift = 0
        guard days != 0, pan.columnWidth > 0 else { pan.dragX = 0; return }

        // Clamped: a jump of months should still read as a short slide, not a
        // long scroll through empty weeks.
        let travel = CGFloat(max(-10, min(10, days)))
        pan.dragX = -travel * pan.columnWidth
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { pan.dragX = 0 }
    }

    private func step(_ n: Int) {
        withAnimation(.easeOut(duration: 0.2)) {
            if mode == .week { pan.dayShift += n * 7 }
            else { anchor = cal.date(byAdding: .month, value: n, to: anchor) ?? anchor }
        }
    }

    // MARK: Panel

    private func open(_ kind: PanelKind) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { panel = kind }
    }

    private func closePanel() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { panel = nil }
    }

    @ViewBuilder
    private var sidePanel: some View {
        if let panel {
            Group {
                switch panel {
                case .compose:
                    ComposerPanel(onClose: closePanel)
                case .detail(let key):
                    EventDetailPanel(occurrenceKey: key, onClose: closePanel)
                }
            }
            .frame(width: 512)
            .background(Palette.surface)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.rule).frame(width: 1) }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .id(panelIdentity)      // fresh scroll position on every open
        }
    }

    private var panelIdentity: String {
        if case .detail(let k) = panel { return "detail-" + k }
        return "compose"
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
    init(_ v: String) { value = v }
}

// MARK: - Today ring

/// One arc per class, in calendar order and calendar colour, filling as the day
/// is taught.
///
/// The circumference is the day's teaching time, so each arc's share of the ring
/// is its share of the day. Everything already taught is drawn solid, everything
/// still ahead is the same colour ghosted — which makes "how much is left" and
/// "what am I teaching" the same picture.
struct DayRing: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore

    private let size: CGFloat = 46
    private let stroke: CGFloat = 6

    /// One class's slice of the ring.
    private struct Arc {
        let color: Color
        /// Fractions of the whole ring, before gaps are cut.
        let from: Double
        let to: Double
    }

    private var cal: Calendar { state.calculationCalendar }

    private var items: [Occurrence] {
        let sorted = state.occurrences(on: Date()).sorted {
            $0.startMinutes == $1.startMinutes ? $0.endMinutes < $1.endMinutes
                                               : $0.startMinutes < $1.startMinutes
        }
        return sorted
    }

    private func spans(_ items: [Occurrence]) -> [DayRingMath.Span] {
        items.map { DayRingMath.Span(start: $0.startMinutes, end: $0.endMinutes) }
    }

    var body: some View {
        // Recomputed on the minute so the fill keeps up with the day.
        TimelineView(.everyMinute) { context in
            let day = items
            let spans = spans(day)
            let total = DayRingMath.total(spans)
            HStack(spacing: 11) {
                ring(arcs(day, spans: spans),
                     progress: DayRingMath.progress(spans,
                                                    minute: TimeText.minutes(of: context.date, cal)))
                VStack(alignment: .leading, spacing: 1) {
                    Eyebrow(text: "Today")
                    Text(DurationFormatter.string(total * 60))
                        .font(Typo.mono(17, .medium))
                        .foregroundStyle(total > 0 ? Palette.ink : Palette.ink3)
                        .monospacedDigit()
                }
            }
        }
    }

    private func ring(_ arcs: [Arc], progress: Double) -> some View {
        // Each arc runs a hair past its own end so neighbours meet without a
        // seam. Ghosts are drawn as one pass and the fill as a second: with the
        // two interleaved, an arc's ghost would paint over the previous arc's
        // overlapping solid tail.
        let bleed = 0.0025

        func end(_ i: Int, _ arc: Arc) -> Double {
            i == arcs.count - 1 ? arc.to : min(1, arc.to + bleed)
        }

        return ZStack {
            Circle()
                .stroke(Palette.ruleSoft, lineWidth: stroke)

            ForEach(Array(arcs.enumerated()), id: \.offset) { i, arc in
                Circle()
                    .trim(from: arc.from, to: end(i, arc))
                    .stroke(arc.color.opacity(0.22),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
            }

            ForEach(Array(arcs.enumerated()), id: \.offset) { i, arc in
                if progress > arc.from {
                    // A finished class carries the bleed so it joins the next
                    // one; the class in progress stops exactly at now.
                    let stop = progress >= arc.to ? end(i, arc) : progress
                    Circle()
                        .trim(from: arc.from, to: stop)
                        .stroke(arc.color,
                                style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
                }
            }
        }
        .rotationEffect(.degrees(-90))      // start at twelve o'clock
        // Inset by half the stroke: it is centred on the path, so without this
        // the ring draws wider than its own frame and crowds its neighbours.
        .padding(stroke / 2)
        .frame(width: size, height: size)
    }

    /// Arcs sized by each class's share of the day, in the order they happen.
    private func arcs(_ items: [Occurrence], spans: [DayRingMath.Span]) -> [Arc] {
        DayRingMath.slices(spans).map { slice in
            let item = items[slice.index]
            return Arc(color: prefs.color(item.calendarID, fallbackIndex: item.colorIndex),
                       from: slice.from,
                       to: slice.to)
        }
    }
}

// MARK: - Week grid

struct WeekGrid: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    let windowStart: Date
    @ObservedObject var pan: PanState
    let onPick: (String) -> Void
    @EnvironmentObject private var holidays: HolidayStore
    @State private var pickedHoliday: PickedHoliday?


    /// Sized to what it actually holds: holiday strip, weekday, date circle and
    /// the matching space beneath. At 62 the content overflowed and the holiday
    /// bars were pushed up under the divider.
    private let headerHeight: CGFloat = 78
    private let gutter: CGFloat = 58
    /// A week of padding either side, so there is always something to reveal
    /// as the window is dragged.
    private let pad = 7

    private var cal: Calendar { state.calculationCalendar }

    /// 21 days: the visible week with a week of slack on each side.
    private var strip: [Date] {
        (-pad..<(7 + pad)).compactMap { cal.date(byAdding: .day, value: $0, to: windowStart) }
    }

    var body: some View {
        GeometryReader { geo in
            let colW = max(40, (geo.size.width - gutter) / 7)
            let shift = -edge(pad, colW: colW) + pan.dragX
            // Sized so 08:00–23:00 fits exactly. A fixed 46pt row left the band
            // about half an hour short of 23:00 on this window.
            // Sized so the configured band fills the viewport exactly. The whole
            // day is still drawn above and below it.
            let bandHours = max(0.5, Double(state.dayEndMinutes - state.dayStartMinutes) / 60)
            let hourHeight = max(24, (geo.size.height - headerHeight - 1) / bandHours)

            VStack(spacing: 0) {
                header(colW: colW, shift: shift)
                Divider().overlay(Palette.rule)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(colW: colW, shift: shift, hourHeight: hourHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { openOnBand(proxy) }
                    // A changed range should show immediately, not next launch.
                    .onChange(of: state.dayStartMinutes) { _, _ in openOnBand(proxy) }
                    .onChange(of: state.dayEndMinutes) { _, _ in openOnBand(proxy) }
                }
            }
            .clipped()
            .onAppear { pan.columnWidth = colW }
            .onChange(of: colW) { _, w in pan.columnWidth = w }
        }
        .background(Palette.surface)
        .coordinateSpace(name: HolidayStrip.space)
        // Clicking anywhere else puts the holiday card away.
        .overlay {
            if pickedHoliday != nil {
                Color.black.opacity(0.04)
                    .contentShape(Rectangle())
                    .onTapGesture { pickedHoliday = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if let picked = pickedHoliday {
                GeometryReader { geo in
                    HolidayCard(holiday: picked.holiday,
                                feed: holidays.feed(picked.holiday.feedID),
                                onClose: { pickedHoliday = nil })
                        .offset(x: cardX(picked.anchor, in: geo.size.width),
                                y: picked.anchor.maxY + 5)
                }
                // Unfolds downward from the bar rather than appearing whole.
                .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pickedHoliday)
    }

    /// The divider on a column's leading edge.
    ///
    /// Drawn by the column rather than from a computed x. Positioning them
    /// separately meant the lines and the columns were two different
    /// calculations of the same thing, and they disagreed by a few points —
    /// which read as every date being off-centre.
    /// Centred under its bar, nudged in so it never runs off either edge.
    private func cardX(_ anchor: CGRect, in width: CGFloat) -> CGFloat {
        let card: CGFloat = 300
        return min(max(8, anchor.midX - card / 2), max(8, width - card - 8))
    }

    /// A column's leading divider.
    ///
    /// Drawn as the column's *background*, never an overlay: as an overlay it
    /// painted across every event the column contained. Behind the content, an
    /// event simply covers it.
    private var columnRule: some View {
        Rectangle()
            .fill(Palette.ruleSoft)
            .frame(width: 1)
            .allowsHitTesting(false)
    }

    /// Cumulative column edge, rounded to a whole point.
    ///
    /// The exact width is fractional — 128.2857… on this window — so the rules
    /// landed between pixels and were antialiased across two of them. Some read
    /// heavier than others, which looks like a grid that doesn't line up.
    /// Rounding the *edges* keeps every boundary crisp and still fills the
    /// width exactly; individual columns differ by at most a point.
    private func edge(_ index: Int, colW: CGFloat) -> CGFloat {
        (CGFloat(index) * colW).rounded()
    }

    private func openOnBand(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bandAnchor, anchor: .top) }
        }
    }

    /// Marks the exact start of the band, so a range like 08:30 lands on the
    /// half hour rather than the nearest whole one.
    static let bandAnchor = "band-start"

    private func columnWidth(_ index: Int, colW: CGFloat) -> CGFloat {
        edge(index + 1, colW: colW) - edge(index, colW: colW)
    }

    /// The seven-day strip, positioned explicitly.
    ///
    /// Both the header and the grid lay this out the same way, at the same x.
    /// They used to be two HStacks of `gutter + strip`, and because the strip
    /// is far wider than the space available those two stacks resolved their
    /// over-commitment differently — leaving the grid a constant 8.5pt left of
    /// the header. An overlay at an explicit offset cannot disagree.
    private func dayStrip<Cell: View>(
        colW: CGFloat, shift: CGFloat,
        @ViewBuilder cell: @escaping (Int, Date) -> Cell
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(strip.enumerated()), id: \.element) { index, day in
                cell(index, day)
                    .frame(width: columnWidth(index, colW: colW))
                    .background(alignment: .leading) { columnRule }
            }
        }
        .fixedSize()
        .offset(x: gutter + shift)
    }

    private func header(colW: CGFloat, shift: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: headerHeight)
            .overlay(alignment: .topLeading) {
                dayStrip(colW: colW, shift: shift) { _, d in dayHead(d) }
            }
            .background(Palette.surface)
            .clipped()
            .contentShape(Rectangle())
            // Follows the pointer pixel for pixel, then springs to a whole day.
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in pan.dragX = g.translation.width }
                    .onEnded { _ in pan.settle() }
            )
    }

    private func dayHead(_ d: Date) -> some View {
        let today = cal.isDateInToday(d)
        let onDay = holidays.holidays(on: d, calendar: cal)
        // The holiday strip and the space under the number are the same
        // height, so a day with no holiday still reads as balanced.
        return VStack(spacing: 2) {
            HolidayStrip(entries: onDay, onPick: { pickedHoliday = $0 })
                .frame(height: 15)
                .padding(.horizontal, 3)

            Text(cal.shortWeekdaySymbols[cal.component(.weekday, from: d) - 1].uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(today ? Palette.mark : Palette.ink3)
            Text("\(cal.component(.day, from: d))")
                .font(Typo.mono(16))
                .foregroundStyle(today ? .white : Palette.ink)
                .frame(width: 24, height: 24)
                .background(today ? Palette.mark : .clear, in: Circle())

            Color.clear.frame(height: 15)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }

    private func grid(colW: CGFloat, shift: CGFloat, hourHeight: CGFloat) -> some View {
        // The band marker has to live in the scroll view's own content — an id
        // inside an overlay is not something ScrollViewProxy will scroll to,
        // which is why a range starting at 07:30 opened at 00:00 instead.
        let startOffset = CGFloat(state.dayStartMinutes) / 60 * hourHeight
        return VStack(spacing: 0) {
            Color.clear.frame(height: startOffset)
            Color.clear.frame(width: 1, height: 1).id(Self.bandAnchor)
            Color.clear.frame(height: max(0, hourHeight * 24 - startOffset - 1))
        }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                dayStrip(colW: colW, shift: shift) { _, day in
                    DayColumn(day: day, hourHeight: hourHeight, onPick: onPick)
                }
            }
            // Drawn after the strip, so days scrolling past disappear behind it.
            .overlay(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { h in
                        ZStack(alignment: .topTrailing) {
                            Rectangle().fill(.clear).frame(height: hourHeight)
                            Text(String(format: "%02d:00", h))
                                .font(Typo.mono(10))
                                .foregroundStyle(Palette.ink3)
                                .offset(y: -6)
                                .padding(.trailing, 8)
                        }
                        .id("hour-\(h)")
                    }
                }
                .frame(width: gutter)
                .background(Palette.surface)
            }
            .clipped()
    }

}

private struct DayColumn: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    let day: Date
    let hourHeight: CGFloat
    let onPick: (String) -> Void

    private var cal: Calendar { state.calculationCalendar }

    var body: some View {
        GeometryReader { geo in
            let laid = layout(state.occurrences(on: day))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle().fill(.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) { Rectangle().fill(Palette.ruleSoft).frame(height: 1) }
                    }
                }
                ForEach(laid, id: \.item.id) { placed in
                    let top = CGFloat(placed.item.startMinutes) / 60 * hourHeight
                    let h = max(CGFloat(placed.item.endMinutes - placed.item.startMinutes) / 60 * hourHeight, 18)
                    let w = geo.size.width / CGFloat(placed.lanes)
                    EventBlock(item: placed.item, showRemaining: state.showRemaining, height: h)
                        .frame(width: max(w - 5, 20), height: h)
                        .offset(x: CGFloat(placed.lane) * w + 3, y: top)
                        .onTapGesture { onPick(placed.item.key) }
                }
                if cal.isDateInToday(day) { nowLine }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Where "now" sits, redrawn on the minute.
    @ViewBuilder
    private var nowLine: some View {
        TimelineView(.everyMinute) { context in
            let minutes = TimeText.minutes(of: context.date, cal)
            let y = CGFloat(minutes) / 60 * hourHeight
            ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.mark).frame(height: 1.5)
                    // Sits just inside the column. Centred on the edge it was
                    // cut in half by the column rule, which is drawn in an
                    // overlay above every day.
                    Circle().fill(Palette.mark).frame(width: 7, height: 7).offset(x: 2)
                }
            .offset(y: y - 0.75)
            .allowsHitTesting(false)
        }
    }

    /// Overlapping blocks sit side by side rather than on top of one another.
    ///
    /// Stacked, two events at the same time merely rendered as one darker block —
    /// which made an accidental duplicate invisible except as a colour shift.
    private func layout(_ items: [Occurrence]) -> [(item: Occurrence, lane: Int, lanes: Int)] {
        let sorted = items.sorted { $0.startMinutes < $1.startMinutes }
        var out: [(Occurrence, Int, Int)] = []
        var cluster: [(Occurrence, Int)] = []
        var laneEnd: [Int] = []
        var clusterEnd = Int.min

        // Width is decided per cluster of genuinely overlapping events. Counting
        // lanes across the whole day meant one overlap anywhere squeezed every
        // other block in that day, so back-to-back events looked interleaved.
        func flush() {
            let lanes = max(1, laneEnd.count)
            for (item, lane) in cluster { out.append((item, lane, lanes)) }
            cluster.removeAll(); laneEnd.removeAll(); clusterEnd = Int.min
        }

        for item in sorted {
            if item.startMinutes >= clusterEnd { flush() }
            if let free = laneEnd.firstIndex(where: { $0 <= item.startMinutes }) {
                laneEnd[free] = item.endMinutes
                cluster.append((item, free))
            } else {
                laneEnd.append(item.endMinutes)
                cluster.append((item, laneEnd.count - 1))
            }
            clusterEnd = max(clusterEnd, item.endMinutes)
        }
        flush()
        return out.map { (item: $0.0, lane: $0.1, lanes: $0.2) }
    }
}

private struct EventBlock: View {
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var state: AppState
    let item: Occurrence
    let showRemaining: Bool
    let height: CGFloat

    // What fits. A block's height is its duration and nothing else, so each
    // line has to earn its place rather than push the block taller.
    private var showsTime: Bool { height >= 34 }
    private var showsRemaining: Bool { showRemaining && height >= 49 }

    /// A long class name wraps rather than being cut off — but only as far as
    /// the block is actually tall, so it can never overflow into the next hour.
    private var titleLines: Int {
        let spare = height - 6 - (showsTime ? 14 : 0) - (showsRemaining ? 13 : 0)
        return max(1, min(3, Int(spare / 15)))
    }

    var body: some View {
        let color = prefs.color(item.calendarID, fallbackIndex: item.colorIndex)
        VStack(alignment: .leading, spacing: 1) {
            Text(state.displayTitle(item.title, calendarID: item.calendarID))
                .font(Typo.sans(12.5, .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(titleLines)
                .multilineTextAlignment(.leading)
            if showsTime {
                HStack(spacing: 5) {
                    Text("\(TimeText.hhmm(item.startMinutes))–\(TimeText.hhmm(item.endMinutes))")
                        .font(Typo.mono(11.5))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                    if item.isFinal {
                        Text("FINAL")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Palette.finalInk)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Palette.finalWash,
                                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
            }
            if showsRemaining, let r = item.remaining {
                Text("\(r) left")
                    .font(Typo.mono(11))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Without this the text sets the block's height: a half-hour class grew
        // to whatever its name needed, so short events drew far taller than
        // their duration and every block ended up about the same size.
        .clipped()
        .background(color.opacity(0.16))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .help(item.isFinal ? "Last in series" : "")
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A holiday plus where its bar sits, so the card can drop from it.
struct PickedHoliday: Equatable {
    let holiday: Holiday
    /// The bar's frame in the grid's own coordinate space.
    let anchor: CGRect
}

/// The holiday bars above a day's letters.
///
/// Two or three on one day split the width evenly rather than stacking, with a
/// hairline between them so they never read as one long bar.
private struct HolidayStrip: View {
    @EnvironmentObject private var holidays: HolidayStore
    let entries: [Holiday]
    let onPick: (PickedHoliday) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(entries.prefix(3)) { entry in
                let color = Color(hex: CalendarPalette.fallback(
                    for: holidays.feed(entry.feedID)?.colorIndex ?? 0))
                Text(entry.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .help(entry.title)
                    // An overlay, not a background: it has to sit above the bar
                    // to receive the click, and it reads the bar's frame in the
                    // same closure so the card can open from exactly there.
                    .overlay(GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPick(PickedHoliday(holiday: entry,
                                                     anchor: geo.frame(in: .named(Self.space))))
                            }
                    })
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Named space both the bars and the card measure against.
    static let space = "holidayAnchors"
}

/// What the feed says about a date, opened by clicking its bar.
private struct HolidayCard: View {
    let holiday: Holiday
    let feed: HolidayFeed?
    let onClose: () -> Void
    @State private var detailHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: CalendarPalette.fallback(for: feed?.colorIndex ?? 0)))
                    .frame(width: 12, height: 6)
                Text(holiday.title)
                    .font(Typo.sans(14, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.ink3).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }

            Text(readableDay)
                .font(Typo.mono(11.5))
                .foregroundStyle(Palette.ink2)

            if !holiday.detail.isEmpty {
                Divider().overlay(Palette.ruleSoft)
                InlineLinkText(text: holiday.detail, height: $detailHeight)
                    .frame(height: detailHeight)
            }

            if let feed {
                Divider().overlay(Palette.ruleSoft)
                Text(feed.displayName)
                    .font(Typo.sans(11.5, .semibold))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(Palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: Color(hex: 0x1E2826).opacity(0.18), radius: 16, y: 6)
    }

    private var readableDay: String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: holiday.day) else { return holiday.day }
        let show = DateFormatter()
        show.locale = Locale(identifier: "en_US_POSIX")
        show.dateFormat = "EEEE d MMMM yyyy"
        return show.string(from: d)
    }
}

// MARK: - Month grid

struct MonthGrid: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var holidays: HolidayStore
    let anchor: Date
    let onPick: (String) -> Void
    @State private var pickedHoliday: PickedHoliday?

    private var cal: Calendar { state.calculationCalendar }

    var body: some View {
        let cells = monthCells
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(cal.shortWeekdaySymbols[i].uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .background(Palette.surface)
            Divider().overlay(Palette.rule)

            GeometryReader { geo in
                let rows = cells.count / 7
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { c in
                                MonthCell(day: cells[r * 7 + c],
                                          inMonth: cal.isDate(cells[r * 7 + c], equalTo: anchor, toGranularity: .month),
                                          onPick: onPick,
                                          onPickHoliday: { pickedHoliday = $0 })
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(height: geo.size.height / CGFloat(rows))
                    }
                }
            }
        }
        .background(Palette.surface)
        .coordinateSpace(name: HolidayStrip.space)
        .overlay {
            if pickedHoliday != nil {
                Color.black.opacity(0.04)
                    .contentShape(Rectangle())
                    .onTapGesture { pickedHoliday = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if let picked = pickedHoliday {
                GeometryReader { geo in
                    HolidayCard(holiday: picked.holiday,
                                feed: holidays.feed(picked.holiday.feedID),
                                onClose: { pickedHoliday = nil })
                        .offset(x: min(max(8, picked.anchor.midX - 150),
                                       max(8, geo.size.width - 308)),
                                y: picked.anchor.maxY + 4)
                }
                .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pickedHoliday)
    }

    private var monthCells: [Date] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: anchor)) ?? anchor
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: first)) ?? first
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

private struct MonthCell: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var holidays: HolidayStore
    let day: Date
    let inMonth: Bool
    let onPick: (String) -> Void
    let onPickHoliday: (PickedHoliday) -> Void

    private var cal: Calendar { state.calculationCalendar }

    var body: some View {
        let items = state.occurrences(on: day)
        let today = cal.isDateInToday(day)
        let onDay = holidays.holidays(on: day, calendar: cal)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(Typo.mono(12))
                    .foregroundStyle(today ? .white : Palette.ink2)
                    .frame(width: 20, height: 20)
                    .background(today ? Palette.mark : .clear, in: Circle())

                // The empty run between the date and the day's total is exactly
                // where a holiday belongs: same row, no extra height.
                ForEach(onDay.prefix(2)) { entry in
                    let color = Color(hex: CalendarPalette.fallback(
                        for: holidays.feed(entry.feedID)?.colorIndex ?? 0))
                    Text(entry.title)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(color, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .help(entry.title)
                        .overlay(GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onPickHoliday(PickedHoliday(holiday: entry,
                                                                anchor: geo.frame(in: .named(HolidayStrip.space))))
                                }
                        })
                }

                Spacer(minLength: 2)
                if !items.isEmpty {
                    Text(DurationFormatter.string(items.reduce(0) { $0 + $1.durationMinutes } * 60))
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.ink3)
                }
            }
            ForEach(items.prefix(4)) { item in
                let color = prefs.color(item.calendarID, fallbackIndex: item.colorIndex)
                HStack(spacing: 4) {
                    Text(TimeText.hhmm(item.startMinutes)).font(Typo.mono(10.5)).foregroundStyle(Palette.ink3)
                    Text(state.displayTitle(item.title, calendarID: item.calendarID))
                        .font(Typo.sans(12)).lineLimit(1)
                }
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.15))
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2.5) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { onPick(item.key) }
            }
            if items.count > 4 {
                Text("+\(items.count - 4) more").font(Typo.sans(10)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Palette.surface : Palette.surface2)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ruleSoft).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Palette.ruleSoft).frame(width: 1) }
    }
}
