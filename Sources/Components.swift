import SwiftUI
import AppKit

// MARK: - Counting total

/// The month total, animated. Conforming to `Animatable` lets SwiftUI
/// interpolate `seconds` frame by frame, which is what produces the count-up.
struct CountingTotal: View, Animatable {
    var seconds: Double
    var size: CGFloat

    var animatableData: Double {
        get { seconds }
        set { seconds = newValue }
    }

    var body: some View {
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        let unit = size * 0.44

        return (
            Text("\(h)").font(Typo.mono(size, .light))
            + Text("h").font(Typo.mono(unit, .medium)).foregroundColor(Palette.accent.opacity(0.6))
            + Text(String(format: "%02d", m)).font(Typo.mono(size, .light))
            + Text("m").font(Typo.mono(unit, .medium)).foregroundColor(Palette.accent.opacity(0.6))
        )
        .foregroundColor(Palette.accent)
        .monospacedDigit()
        .kerning(-1)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Readout panel

struct ReadoutPanel: View {
    let totalSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Total duration", color: .white.opacity(0.6))

            CountingTotal(seconds: Double(totalSeconds), size: 50)
                .animation(.easeOut(duration: 0.52), value: totalSeconds)
                .padding(.top, 10)

            Spacer(minLength: 12)

            Divider().overlay(Palette.railRule)

            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Decimal", color: .white.opacity(0.6))
                Spacer(minLength: 10)
                (
                    Text(DurationFormatter.decimal(totalSeconds)).font(Typo.mono(31, .light))
                    + Text("h").font(Typo.mono(15.5, .medium)).foregroundColor(Palette.accent.opacity(0.6))
                )
                .foregroundColor(Palette.accent)
                .monospacedDigit()
                .kerning(-0.8)
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 17)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            ZStack {
                Palette.readoutGradient
                RadialGradient(
                    colors: [.white.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.88, y: 0),
                    startRadius: 0, endRadius: 220
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color(hex: 0x1E2826).opacity(0.16), radius: 6, y: 2)
    }
}

// MARK: - Stat card

struct StatCard: View {
    let value: String
    let suffix: String?
    let label: String
    var alert: Bool = false
    var compact: Bool = false

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(Typo.mono(compact ? 19 : 24, .medium))
                    .foregroundStyle(alert ? Palette.mark : Palette.ink)
                    .monospacedDigit()
                    .kerning(-0.6)
                if let suffix {
                    Text(suffix)
                        .font(Typo.mono(14))
                        .foregroundStyle(Palette.ink3)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            Eyebrow(text: label)
        }
        // Fills the height it's given, so the compact card doesn't end up
        // shorter than its neighbours just because its value uses a smaller font.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? Palette.ink3 : Palette.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

// MARK: - Daily hours chart

struct DayChart: View {
    let hours: [Double]
    let todayIndex: Int?
    let onSelectDay: (Int) -> Void

    @State private var hoverIndex: Int?

    private var peak: Double { max(hours.max() ?? 0, 0.001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow(text: "Hours per day")
                Spacer()
                Text(peak > 0.01 ? String(format: "peak %.1fh", peak) : "no events")
                    .font(Typo.mono(11.5))
                    .foregroundStyle(Palette.ink3)
            }

            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(hours.indices, id: \.self) { i in
                        let value = hours[i]
                        let isToday = todayIndex == i
                        let ratio = value / peak
                        let barHeight = value > 0 ? max(geo.size.height * ratio, 4) : 0
                        // Depth tracks hours, so colour reinforces height instead
                        // of splitting the month into weekday and weekend.
                        let depth = 0.34 + 0.66 * ratio

                        ZStack(alignment: .bottom) {
                            // baseline tick, so empty days still read as days
                            Rectangle()
                                .fill(Palette.rule)
                                .frame(height: 2)

                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill((isToday ? Palette.accent : Palette.mark).opacity(depth))
                                .frame(height: barHeight)
                                .brightness(hoverIndex == i ? 0.06 : 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { hoverIndex = $0 ? i : (hoverIndex == i ? nil : hoverIndex) }
                        .onTapGesture { onSelectDay(i + 1) }
                        .help(tooltip(day: i + 1, value: value))
                    }
                }
            }
            .frame(minHeight: 48)

            HStack {
                Text("1")
                Spacer()
                Text("\(Int((Double(hours.count) / 2).rounded(.up)))")
                Spacer()
                Text("\(hours.count)")
            }
            .font(Typo.mono(10.5))
            .foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tooltip(day: Int, value: Double) -> String {
        value > 0 ? String(format: "Day %d - %.2fh", day, value) : "Day \(day) - none"
    }
}

// MARK: - Rail switch

struct RailSwitch: View {
    let title: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Palette.accent : Color.white.opacity(0.22))
                        .frame(width: 32, height: 18)
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 2)
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOn)

                Text(title)
                    .font(Typo.sans(13.5))
                    .foregroundStyle(Palette.railInk)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Feedback checkbox

struct FeedbackTick: View {
    let checked: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(checked ? Palette.mark : Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(checked ? Palette.mark : (hovering ? Palette.mark : Palette.ink3), lineWidth: 1.5)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(checked ? 1 : 0)
                        .scaleEffect(checked ? 1 : 0.4)
                )
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: checked)
    }
}

// MARK: - Overlapping-event hover card

/// Shown the instant the info icon is hovered.
///
/// `.help()` would be less code, but it routes through the system tooltip and
/// its ~2s delay is not configurable -- far too slow for something you glance at.
struct SpanInfoCard: View {
    let total: String
    let counted: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Overlapping Event")
                .font(Typo.sans(12.5, .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 1)

            line("Duration", total, tint: Palette.ink)
            line("Counted", counted, tint: Palette.mark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: Color(hex: 0x1E2826).opacity(0.18), radius: 12, y: 4)
    }

    private func line(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text("\(label):")
                .font(Typo.sans(12))
                .foregroundStyle(Palette.ink2)
            Spacer(minLength: 0)
            Text(value)
                .font(Typo.mono(12.5, .medium))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Toolbar pill

struct PillButton: View {
    let title: String?
    let systemImage: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                if let title {
                    Text(title).font(Typo.sans(13.5, .semibold))
                }
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(hovering ? Palette.surface : Palette.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovering ? Palette.ink3 : Palette.rule, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Lays children out left to right, wrapping when a row is full.
///
/// A grid would force equal-width columns, so "Adam" and "Christopher" would
/// take the same space and the row count would be fixed. This lets each chip
/// keep its own width and simply flow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Read-only text whose links are real links: the hand cursor appears over the
/// link itself, and a click opens the browser. Sizes to its content.
struct InlineLinkText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 12.5
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Palette.mark),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text {
            view.textStorage?.setAttributedString(attributed)
        }
        // Report the laid-out height so SwiftUI can give it exactly that.
        guard let manager = view.layoutManager, let container = view.textContainer else { return }
        manager.ensureLayout(for: container)
        let measured = ceil(manager.usedRect(for: container).height)
        if abs(measured - height) > 0.5 {
            DispatchQueue.main.async { height = measured }
        }
    }

    private var attributed: NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(Palette.ink2)
        ])
        for (range, url) in LinkScanner.links(in: text) {
            out.addAttribute(.link, value: url, range: NSRange(range, in: text))
        }
        return out
    }
}

/// Segmented control in the app's own palette.
///
/// Replaces `.pickerStyle(.segmented)`, which drops a system-blue capsule into
/// a page that has no blue in it anywhere.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var equalWidths = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(Typo.sans(12.5, .semibold))
                        .foregroundStyle(on ? Palette.ink : Palette.ink3)
                        // A tight row must not be allowed to break a label in
                        // half — ":00" came out as ":0" over "0".
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: equalWidths ? .infinity : nil)
                        .background(on ? Palette.surface : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: on ? Color(hex: 0x1E2826).opacity(0.10) : .clear, radius: 2, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The app's confirm button, in brass rather than system blue.
struct AccentButton: View {
    let title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typo.sans(13, .semibold))
                .foregroundStyle(Palette.readoutA)
                .padding(.horizontal, 15)
                .padding(.vertical, 6)
                .background(hovering ? Palette.accent.opacity(0.85) : Palette.accent,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The sidebar toggle. Shared so it sits in the same spot on every page.
struct SidebarToggle: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavIconButton(systemImage: "sidebar.leading", help: "Toggle sidebar") {
            withAnimation(.easeInOut(duration: 0.22)) { state.toggleSidebar() }
        }
    }
}

struct NavIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Palette.ink : Palette.ink2)
                .frame(width: 30, height: 30)
                .background(hovering ? Palette.ruleSoft : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "calendar"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(width: 42, height: 42)
                .background(Palette.ruleSoft)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.bottom, 2)

            Text(title)
                .font(Typo.sans(16, .semibold))
                .foregroundStyle(Palette.ink2)

            Text(message)
                .font(Typo.sans(13.5))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let actionTitle, let action {
                PillButton(title: actionTitle, systemImage: nil, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(56)
    }
}
