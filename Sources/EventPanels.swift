import SwiftUI
import EventKit
import AppKit

// MARK: - Shared bits

/// A metric tile whose contents are centred, used for the series figures.
private struct SeriesStat: View {
    let value: String
    let label: String
    var alert = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Typo.mono(16, .medium))
                .foregroundStyle(alert ? Palette.mark : Palette.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Eyebrow(text: label)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The weekday shown beside the date, as a solid chip in the calendar's own
/// colour — it ties the row to its calendar and fills the space a bare label
/// left empty.
private struct WeekdayChip: View {
    let date: Date
    let color: Color
    let calendar: Calendar

    var body: some View {
        Text(calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1].uppercased())
            .font(Typo.mono(12, .semibold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .frame(width: 46)
            .frame(maxHeight: .infinity)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Roles block. Only the sections turned on for this calendar appear, and a
/// role left unset writes no line into the notes.
private struct RoleMenus: View {
    @EnvironmentObject private var prefs: PrefsStore
    let calendarID: String
    @Binding var notes: SeriesNotes

    /// Which half of the Advisor/Manager pair is selected.
    ///
    /// Held explicitly rather than derived from the notes: picking Manager
    /// clears the advisor name, and with no manager name set yet a derived
    /// value computed straight back to Advisor — so the menu kept showing
    /// advisors.
    @State private var pairRole: RoleKind = .advisor
    @State private var syncedPair = false

    var body: some View {
        let p = prefs.prefs(calendarID)
        ForEach(p.enabledRoles) { role in
            if role == .manager && p.isEnabled(.advisor) {
                EmptyView()          // drawn by the advisor row as a pair
            } else if role == .advisor && p.isEnabled(.manager) {
                pairPicker(p)
            } else {
                single(role, names: p.names(role))
            }
        }
    }

    private func single(_ role: RoleKind, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: role.title)
            Picker("", selection: binding(role)) {
                Text("—").tag("")
                ForEach(options(names, current: notes.name(role)), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 12)
    }

    /// Advisor and Manager share one control: choosing in one clears the other.
    private func pairPicker(_ p: CalendarPrefs) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: "Advisor / Manager")
            HStack(spacing: 6) {
                SegmentedChoice(options: [(RoleKind.advisor, "Advisor"), (RoleKind.manager, "Manager")],
                                selection: $pairRole)

                Picker("", selection: binding(pairRole)) {
                    Text("—").tag("")
                    ForEach(options(p.names(pairRole), current: notes.name(pairRole)), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .id(pairRole)          // rebuild so the menu lists the new role
            }
        }
        .padding(.bottom, 12)
        .onAppear {
            guard !syncedPair else { return }
            syncedPair = true
            pairRole = notes.name(.manager).isEmpty ? .advisor : .manager
        }
        // Filling the notes from history sets a name directly, and the
        // one-shot onAppear sync had already run by then — so a student with a
        // manager still showed the Advisor side.
        .onChange(of: notes.name(.manager)) { _, name in
            if !name.isEmpty { pairRole = .manager }
        }
        .onChange(of: notes.name(.advisor)) { _, name in
            if !name.isEmpty { pairRole = .advisor }
        }
        .onChange(of: pairRole) { old, new in
            guard old != new else { return }
            // Carry the name across only if the other roster also has it.
            let carried = notes.name(old)
            notes.set(old, "")
            if !carried.isEmpty, p.names(new).contains(carried) { notes.set(new, carried) }
        }
    }

    private func binding(_ role: RoleKind) -> Binding<String> {
        Binding(get: { notes.name(role) }, set: { notes.set(role, $0) })
    }

    /// The roster, plus whoever is currently set if they are not on it.
    ///
    /// A name adopted from history need not be in the saved roster, and a
    /// selection with no matching tag renders as blank — which read as "no one
    /// assigned" for someone who was in fact assigned.
    private func options(_ names: [String], current: String) -> [String] {
        current.isEmpty || names.contains(current) ? names : [current] + names
    }
}

/// The notes block: role lines above a short rule, free text below, editable in
/// place. This is literally the event's Notes field in Apple Calendar.
private struct NotesBlock: View {
    @Binding var notes: SeriesNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RoleKind.allCases) { role in
                let name = notes.name(role)
                if !name.isEmpty {
                    HStack(spacing: 6) {
                        Text("\(role.title):")
                        Text(name)
                    }
                    .font(Typo.mono(12, .semibold))
                    .foregroundStyle(Palette.ink)
                    .padding(.bottom, 2)
                }
            }
            if notes.hasAnyRole {
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: 1)
                    .padding(.trailing, 40)
                    .padding(.vertical, 7)
            }
            NotesEditor(text: $notes.text)
                .frame(height: 194)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The notes field: always editable, with live links.
///
/// One view rather than a read-only view that swaps for an editor when clicked.
/// Swapping meant the click landed on one view and a different one appeared and
/// took focus, so the caret went to the end of the text instead of where you
/// clicked — and before that, deciding the swap from focus state deadlocked
/// outright. A single editable text view has neither problem: the caret lands
/// where you click, and a click on a link opens it.
private struct NotesEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = LinkAwareTextView()
        view.delegate = context.coordinator
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Palette.mark),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        view.typingAttributes = Coordinator.plainAttributes
        view.string = text
        context.coordinator.markLinks(view)

        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? LinkAwareTextView else { return }
        context.coordinator.parent = self
        // Only adopt outside changes; never rewrite what is being typed.
        if view.string != text, view.window?.firstResponder != view {
            view.string = text
            context.coordinator.markLinks(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesEditor
        init(_ parent: NotesEditor) { self.parent = parent }

        static let plainAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(Palette.ink)
        ]

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? LinkAwareTextView else { return }
            parent.text = view.string
            markLinks(view)
        }

        /// Re-marks the URLs after every edit, keeping the caret where it was.
        func markLinks(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let selection = view.selectedRange()
            let all = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(Self.plainAttributes, range: all)
            for (range, url) in LinkScanner.links(in: view.string) {
                storage.addAttribute(.link, value: url, range: NSRange(range, in: view.string))
            }
            storage.endEditing()

            view.typingAttributes = Self.plainAttributes
            view.setSelectedRange(selection)
        }
    }
}

/// Editable, but a click that lands on a link follows it instead of placing a
/// caret — the plain-click behaviour you want from notes you mostly read.
private final class LinkAwareTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if let url = link(at: convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func link(at point: CGPoint) -> URL? {
        guard let manager = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        // The glyph actually under the pointer, not the nearest insertion point:
        // otherwise a click just past the end of a link would follow it.
        let glyph = manager.glyphIndex(for: inContainer, in: container,
                                       fractionOfDistanceThroughGlyph: nil)
        let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                          in: container)
        guard bounds.offsetBy(dx: origin.x, dy: origin.y).contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }
}

private struct PanelChrome<Content: View, Footer: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Typo.sans(15, .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink3).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().overlay(Palette.rule)

            ScrollView { content.padding(16) }

            Divider().overlay(Palette.rule)
            HStack(spacing: 8) { footer }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

// MARK: - Detail

struct EventDetailPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var series: SeriesStore
    let occurrenceKey: String
    let onClose: () -> Void

    @State private var title = ""
    @State private var date = Date()
    @State private var span = TimeSpan()
    @State private var timeFocus = 0
    @State private var notes = SeriesNotes()
    @State private var loaded = false
    @State private var scopePrompt: ScopePrompt?
    /// What was on screen when the panel opened, so an untouched Save can just
    /// close instead of asking which occurrences to apply nothing to.
    @State private var original: (title: String, date: Date, span: TimeSpan, notes: SeriesNotes)?
    @State private var calendarID = ""
    @State private var seriesCount = 0
    @State private var position = 0
    @State private var remaining = 0
    @State private var seriesMinutes = 0
    @State private var openDate = false

    private struct ScopePrompt: Identifiable { let id = UUID(); let deleting: Bool }
    private var cal: Calendar { state.calculationCalendar }

    var body: some View {
        PanelChrome(title: "Event", onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                field("Event") {
                    TextField("", text: $title).textFieldStyle(.roundedBorder)
                }

                field("Date & Time") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            WeekdayChip(date: date,
                                        color: prefs.color(calendarID, fallbackIndex: 0),
                                        calendar: cal)
                            DateField(date: date, open: openDate) { openDate.toggle() }
                            SpanRow(span: $span, focusRequest: timeFocus)
                            Spacer(minLength: 0)
                        }
                        if openDate {
                            DatePicker("", selection: $date, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(Palette.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(Palette.rule, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .onChange(of: date) { _, _ in
                                    openDate = false
                                    timeFocus += 1      // land in the time boxes
                                }
                        }
                    }
                }

                HStack(spacing: 8) {
                    SeriesStat(value: "\(position) / \(seriesCount)", label: "In series")
                    SeriesStat(value: "\(remaining)", label: "Remaining", alert: true)
                    SeriesStat(value: DurationFormatter.string(seriesMinutes * 60), label: "Series total")
                }

                Divider().overlay(Palette.rule).padding(.vertical, 2)

                field("Notes") { NotesBlock(notes: $notes) }

                RoleMenus(calendarID: calendarID, notes: $notes)
            }
        } footer: {
            if let prompt = scopePrompt {
                // Inline rather than a sheet: this panel already lives inside an
                // overlay of a view that presents sheets, and the nested
                // presentation silently never appeared.
                ScopeChooser(deleting: prompt.deleting, seriesCount: seriesCount) { scope in
                    apply(scope: scope, deleting: prompt.deleting)
                    scopePrompt = nil
                    onClose()
                } onCancel: { scopePrompt = nil }
            } else {
                Button("Delete…") { scopePrompt = ScopePrompt(deleting: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.mark)
                Spacer()
                AccentButton(title: isDirty ? "Save…" : "Done") {
                    if isDirty { scopePrompt = ScopePrompt(deleting: false) } else { onClose() }
                }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Eyebrow(text: label); content() }
    }

    private var isDirty: Bool {
        guard let o = original else { return false }
        return o.0 != title
            || !cal.isDate(o.date, inSameDayAs: date)
            || o.span != span
            || o.notes != notes
    }

    private func load() {
        guard !loaded, let ev = state.event(forKey: occurrenceKey) else { return }
        loaded = true
        title = ev.title ?? ""
        date = ev.startDate
        let length = Int(ev.endDate.timeIntervalSince(ev.startDate) / 60)
        span = TimeSpan.matching(minutes: length)
        span.start = TimeText.minutes(of: ev.startDate, cal)
        if span.duration == nil { span.end = TimeText.minutes(of: ev.endDate, cal) }
        notes = SeriesNotes.decode(ev.notes)
        calendarID = ev.calendar?.calendarIdentifier ?? ""
        original = (title, date, span, notes)

        // Series figures come from ClassHours membership, so events at
        // different times and durations still count as one series.
        do {
            let all = state.seriesOccurrences(of: ev.seriesKey)
            seriesCount = all.count
            position = (all.firstIndex { $0.start == ev.startDate } ?? 0) + 1
            remaining = all.filter { $0.start > ev.startDate }.count
            seriesMinutes = all.reduce(0) { $0 + $1.minutes }
        }
    }

    private func apply(scope: EditScope, deleting: Bool) {
        guard let ev = state.event(forKey: occurrenceKey) else { return }
        let writer = CalendarWriter(store: state.store, calendar: cal)
        // Remember the series before writing: EventKit can mint a new identifier
        // when it rewrites an event, which silently dropped it out of its series.
        let seriesBefore = series.seriesID(of: ev.seriesKey)
        do {
            if deleting {
                series.ungroup(ev.seriesKey)
                try writer.delete(ev, scope: scope)
            } else {
                let day = cal.startOfDay(for: date)
                // Added as minutes, so a class running past midnight lands on
                // the following day rather than failing to resolve.
                let s = span.start.map { cal.date(byAdding: .minute, value: $0, to: day) ?? ev.startDate }
                    ?? ev.startDate
                let e = span.resolvedEnd.map { cal.date(byAdding: .minute, value: $0, to: day) ?? ev.endDate }
                    ?? ev.endDate
                // Only rewrite dates if you actually changed them, so a notes-only
                // edit can't drag the rest of the series onto this date.
                let movedInTime = original.map { !cal.isDate($0.date, inSameDayAs: date) || $0.span != span } ?? true
                try writer.update(ev, scope: scope, title: title,
                                  start: movedInTime ? s : nil, end: movedInTime ? e : nil, notes: notes)
                if scope == .wholeSeries {
                    // Notes are a property of the series, so they reach every
                    // member — including ones Apple Calendar keeps separate.
                    let mine = ev.seriesKey
                    var before: [AppState.SeriesUndo.Member] = []
                    for sibling in series.siblings(of: mine) where sibling != mine {
                        guard let other = state.store.calendarItems(withExternalIdentifier: sibling).first as? EKEvent
                                ?? state.store.event(withIdentifier: sibling) else { continue }
                        // Captured before the write, so it can be put back.
                        before.append(.init(key: sibling,
                                            title: other.title ?? "",
                                            notes: other.notes ?? ""))
                        other.title = title
                        other.notes = notes.encoded()
                        // Same rule: only a real recurrence takes .futureEvents.
                        try state.store.save(other,
                                             span: other.hasRecurrenceRules ? .futureEvents : .thisEvent,
                                             commit: false)
                    }
                    try state.store.commit()
                    state.offerUndo(.init(
                        message: "Updated \(before.count + 1) events in the series",
                        members: before))
                }
            }
            // Safety net: re-register in case the key moved anyway.
            if let sid = seriesBefore { series.group([ev.seriesKey], into: sid) }
            state.refresh()
            state.refreshRemainingCounts()
        } catch {
            state.reportError(error.localizedDescription)
        }
    }
}

// MARK: - Scope sheet

struct ScopeChooser: View {
    let deleting: Bool
    let seriesCount: Int
    let onChoose: (EditScope) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(deleting ? "Delete…" : "Apply to…")
                    .font(Typo.sans(13, .semibold))
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain)
                    .font(Typo.sans(12)).foregroundStyle(Palette.ink3)
            }
            choice(.thisOccurrence, "This occurrence only",
                   seriesCount > 1 ? "The other \(seriesCount - 1) are untouched." : "")
            if seriesCount > 1 {
                choice(.thisAndFollowing, "This and all following", "Earlier ones keep what they had.")
                choice(.wholeSeries, "The whole series", "All \(seriesCount) occurrences.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func choice(_ scope: EditScope, _ title: String, _ detail: String) -> some View {
        Button { onChoose(scope) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.sans(13.5, .semibold))
                    .foregroundStyle(deleting ? Palette.mark : Palette.ink)
                if !detail.isEmpty {
                    Text(detail).font(Typo.sans(11.5)).foregroundStyle(Palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.surface2)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Composer

struct ComposerPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @EnvironmentObject private var series: SeriesStore
    let onClose: () -> Void

    enum EndKind: Hashable { case after, on }

    @State private var draft = SeriesDraft()
    // Ends on today by default: a series being entered is nearly always a
    // block of classes already taught up to now, not an open-ended count.
    @State private var endKind: EndKind = .on
    @State private var count = 8
    @State private var until = Date()
    /// Suppressed straight after a pick, so the list does not reopen over the
    /// name it just filled in.
    @State private var suggestionsDismissed = false
    /// The class this draft was filled from, so a later edit can be recognised
    /// as touching a series that already exists.
    @State private var adopted: ClassSuggestion?
    @State private var conflict = false
    @State private var openDate: DateTarget?
    /// Bumped per session to jump into its time boxes once its date is set.
    @State private var timeFocus: [UUID: Int] = [:]

    enum DateTarget: Equatable {
        case starting, ending
        case session(UUID)
    }

    private var cal: Calendar { state.calculationCalendar }

    var body: some View {
        PanelChrome(title: "New event", onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(text: "Calendar")
                        Picker("", selection: $draft.calendarID) {
                            ForEach(state.writableCalendars) { Text($0.title).tag($0.id) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(text: "Event")
                        TextField("", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: draft.title) { _, _ in suggestionsDismissed = false }
                    }
                }

                // In the flow rather than floating over it: as an overlay it
                // covered the When row underneath.
                if !suggestions.isEmpty { suggestionList }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 14) {
                        Eyebrow(text: "When")
                        SegmentedChoice(options: [(WhenMode.repeats, "Repeats"),
                                                  (WhenMode.sessions, "Sessions")],
                                        selection: $draft.mode)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 2)

                    if draft.mode == .repeats {
                        ForEach($draft.slots) { $slot in
                            SlotRow(slot: $slot, canRemove: draft.slots.count > 1) {
                                draft.slots.removeAll { $0.id == slot.id }
                            }
                        }
                        Button("+ Add another day & time") {
                            draft.slots.append(SeriesSlot())
                        }
                            .buttonStyle(.plain)
                            .font(Typo.sans(12.5, .semibold))
                            .foregroundStyle(Palette.mark)
                            .padding(.top, 2)
                    } else {
                        ForEach($draft.sessions) { $session in
                            SessionRow(session: $session,
                                       canRemove: draft.sessions.count > 1,
                                       open: openDate == .session(session.id),
                                       focusRequest: timeFocus[session.id] ?? 0,
                                       onToggleDate: {
                                           openDate = openDate == .session(session.id)
                                               ? nil : .session(session.id)
                                       },
                                       onRemove: { draft.sessions.removeAll { $0.id == session.id } })
                        }
                        Button("+ Add a date") {
                            var next = SeriesSession()
                            // Carry the last row's time forward: consecutive
                            // one-off sessions are usually the same slot.
                            if let last = draft.sessions.last {
                                next.span = last.span
                                next.date = last.date
                            }
                            draft.sessions.append(next)
                        }
                            .buttonStyle(.plain)
                            .font(Typo.sans(12.5, .semibold))
                            .foregroundStyle(Palette.mark)
                            .padding(.top, 2)
                    }
                }

                if draft.mode == .repeats {
                // The end rule sits literally between the two dates it joins.
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(text: "Starting")
                        DateField(date: draft.start, open: openDate == .starting) {
                            openDate = openDate == .starting ? nil : .starting
                        }
                    }

                    Picker("", selection: $endKind) {
                        Text("After").tag(EndKind.after)
                        Text("On").tag(EndKind.on)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 82)

                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(text: endKind == .after ? "Times" : "Ends")
                        if endKind == .after {
                            TextField("", value: $count, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 62)
                        } else {
                            DateField(date: until, open: openDate == .ending) {
                                openDate = openDate == .ending ? nil : .ending
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                }

                if let openDate { calendarSheet(for: openDate) }


                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: "Will create")
                    preview
                }

                Divider().overlay(Palette.rule).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: "Notes")
                    NotesBlock(notes: $draft.notes)
                }
                RoleMenus(calendarID: draft.calendarID, notes: $draft.notes)
            }
        } footer: {
            if conflict {
                SeriesConflictChooser(
                    title: adopted?.title ?? "",
                    onNew: { conflict = false; create(updateSeries: false) },
                    onUpdate: { conflict = false; create(updateSeries: true) },
                    onCancel: { conflict = false })
            } else {
            Button("Cancel", action: onClose).buttonStyle(.plain)
            Spacer()
            AccentButton(title: "Create") {
                if divergesFromAdopted { conflict = true } else { create(updateSeries: false) }
            }
                .opacity(canCreate ? 1 : 0.4)
                .disabled(!canCreate)
            }
        }
        // An end date earlier than the start silently produces nothing, so it
        // follows the start forward rather than being left behind.
        .onChange(of: draft.start) { _, start in
            if until < start { until = start }
        }
        .onAppear {
            guard draft.calendarID.isEmpty else { return }
            let writable = state.writableCalendars
            draft.calendarID = writable.first { $0.id == prefs.lastUsedCalendarID }?.id
                ?? writable.first?.id ?? ""
        }
    }

    /// The month grid, opened under the whole row rather than in a popover.
    ///
    /// A SwiftUI `.popover` here brought up an `NSPopover` from inside the
    /// panel's layout pass, which crashed in AppKit's window ordering. Nothing
    /// about picking a date needs a window of its own.
    private func calendarSheet(for target: DateTarget) -> some View {
        DatePicker("", selection: dateBinding(target), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Palette.surface2)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .onChange(of: dateBinding(target).wrappedValue) { _, _ in
                openDate = nil
                // The time is the obvious next thing to type, so land there
                // with whatever is already in the boxes selected.
                if case .session(let id) = target { timeFocus[id, default: 0] += 1 }
            }
    }

    private func dateBinding(_ target: DateTarget) -> Binding<Date> {
        switch target {
        case .starting: return $draft.start
        case .ending:   return $until
        case .session(let id):
            return Binding(
                get: { draft.sessions.first { $0.id == id }?.date ?? draft.start },
                set: { new in
                    guard let i = draft.sessions.firstIndex(where: { $0.id == id }) else { return }
                    draft.sessions[i].date = new
                })
        }
    }

    /// Past classes on the chosen calendar matching what has been typed.
    private var suggestions: [ClassSuggestion] {
        let query = draft.title.trimmingCharacters(in: .whitespaces)
        guard !suggestionsDismissed, query.count >= 1, !draft.calendarID.isEmpty else { return [] }
        return state.suggestions(for: draft.calendarID)
            .compactMap { s -> (ClassSuggestion, Int)? in
                guard s.title != draft.title,
                      let rank = TitleSearch.score(query, title: s.title) else { return nil }
                return (s, rank)
            }
            .sorted { a, b in
                a.1 == b.1 ? a.0.lastSeen > b.0.lastSeen : a.1 < b.1
            }
            .prefix(3)
            .map(\.0)
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { hit in
                Button { adopt(hit) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title)
                                .font(Typo.sans(12.5, .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            HStack(spacing: 7) {
                                Text("\(weekdayName(hit.weekday)) \(TimeText.hhmm(hit.startMinutes))–\(TimeText.hhmm(hit.endMinutes))")
                                    .font(Typo.mono(10.5))
                                ForEach(hit.notes.roleLines) { role in
                                    Text(role.person).font(Typo.sans(10.5).italic())
                                }
                            }
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text("×\(hit.count)")
                            .font(Typo.mono(10.5))
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
            }
        }
        .background(Palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .shadow(color: Color(hex: 0x1E2826).opacity(0.16), radius: 10, y: 4)
    }

    private func weekdayName(_ wd: Int) -> String {
        let symbols = cal.shortWeekdaySymbols
        return (wd >= 1 && wd <= symbols.count) ? symbols[wd - 1] : ""
    }

    /// Re-book a class already in the calendar: the whole form is filled from
    /// the last time it ran, and whatever gets created joins that same series.
    private func adopt(_ hit: ClassSuggestion) {
        draft.title = hit.title
        draft.notes = hit.notes
        draft.joinSeriesKey = hit.seriesKey
        adopted = hit

        var slot = SeriesSlot()
        slot.weekdays = [hit.weekday]
        var span = TimeSpan.matching(minutes: max(0, hit.endMinutes - hit.startMinutes))
        span.start = hit.startMinutes
        if span.duration == nil { span.end = hit.endMinutes }
        slot.span = span
        draft.slots = [slot]
        draft.mode = .repeats

        // Land the window on the next matching weekday. Leaving it on today
        // produced a range that the class's own weekday never falls in, so the
        // whole form filled in and then said "0 occurrences".
        let today = cal.startOfDay(for: Date())
        let next = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
            .first { cal.component(.weekday, from: $0) == hit.weekday } ?? today
        draft.start = next
        until = next
        endKind = .on

        suggestionsDismissed = true
    }

    /// Nothing to create means nothing to press: no calendar, no title, or a
    /// When section that produces no occurrences.
    private var canCreate: Bool {
        !draft.calendarID.isEmpty
            && !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !resolved.occurrences(calendar: cal).isEmpty
    }

    private var resolved: SeriesDraft {
        var d = draft
        d.end = endKind == .after ? .count(max(1, count)) : .until(until)
        return d
    }

    private var preview: some View {
        let occ = resolved.occurrences(calendar: cal)
        let total = occ.reduce(0) { $0 + $1.span.minutes }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(occ.count) occurrence\(occ.count == 1 ? "" : "s")")
                    .font(Typo.mono(16, .medium))
                Spacer()
                Text(DurationFormatter.string(total * 60))
                    .font(Typo.mono(12)).foregroundStyle(Palette.ink2)
            }
            if let first = occ.first, let last = occ.last {
                Text("\(dateLabel(first.date)) → \(dateLabel(last.date))")
                    .font(Typo.mono(11)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func dateLabel(_ d: Date) -> String {
        let wd = cal.shortWeekdaySymbols[cal.component(.weekday, from: d) - 1]
        let mo = cal.shortMonthSymbols[cal.component(.month, from: d) - 1]
        return String(format: "%@ %02d %@", wd, cal.component(.day, from: d), mo)
    }

    /// True once an adopted class has been edited into something that no longer
    /// matches the series it came from.
    private var divergesFromAdopted: Bool {
        guard let adopted else { return false }
        return adopted.title != draft.title || adopted.notes != draft.notes
    }

    private func create(updateSeries: Bool) {
        guard let ekCal = state.ekCalendar(draft.calendarID) else { return }
        let writer = CalendarWriter(store: state.store, calendar: cal)
        do {
            var plan = resolved
            // Standing alone means letting go of the series it came from.
            if divergesFromAdopted && !updateSeries { plan.joinSeriesKey = nil }

            let made = try writer.createSeries(plan, in: ekCal)
            var ids = made.map(\.seriesKey)
            // An extra occurrence of a class picked from history belongs with
            // the rest of that class, however far its date or time has drifted.
            if let join = plan.joinSeriesKey { ids.append(join) }
            if ids.count > 1 { series.group(ids) }

            if updateSeries, let join = draft.joinSeriesKey {
                try sweepSeries(join, writer: writer)
            }
            prefs.lastUsedCalendarID = draft.calendarID
            state.refresh()
            state.refreshRemainingCounts()
            onClose()
        } catch {
            state.reportError(error.localizedDescription)
        }
    }

    /// Carries the edited name and notes to every existing member, keeping a
    /// copy of what each one said so the whole sweep can be put back.
    private func sweepSeries(_ seriesKey: String, writer: CalendarWriter) throws {
        var before: [AppState.SeriesUndo.Member] = []
        for sibling in series.siblings(of: seriesKey) {
            guard let other = state.store.calendarItems(withExternalIdentifier: sibling).first as? EKEvent
                    ?? state.store.event(withIdentifier: sibling) else { continue }
            before.append(.init(key: sibling,
                                title: other.title ?? "",
                                notes: other.notes ?? ""))
            other.title = draft.title
            other.notes = draft.notes.encoded()
            try state.store.save(other,
                                 span: other.hasRecurrenceRules ? .futureEvents : .thisEvent,
                                 commit: false)
        }
        guard !before.isEmpty else { return }
        try state.store.commit()
        state.offerUndo(.init(message: "Updated \(before.count) events in the series",
                              members: before))
    }
}

/// Asked when a class adopted from history has been edited: does the edit
/// belong to this booking alone, or to the whole class?
private struct SeriesConflictChooser: View {
    let title: String
    let onNew: () -> Void
    let onUpdate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("This differs from “\(title)”")
                .font(Typo.sans(12.5, .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel).buttonStyle(.plain)
                Spacer(minLength: 8)
                Button("New series", action: onNew)
                    .buttonStyle(.plain)
                    .font(Typo.sans(12.5, .semibold))
                    .foregroundStyle(Palette.ink2)
                AccentButton(title: "Update series", action: onUpdate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SlotRow: View {
    @Binding var slot: SeriesSlot
    let canRemove: Bool
    let onRemove: () -> Void

    private let order = [1, 2, 3, 4, 5, 6, 7]      // Sun-first
    private let letters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(order, id: \.self) { wd in
                    let on = slot.weekdays.contains(wd)
                    Button(letters[wd - 1]) {
                        // Clearing the last day is allowed; Create is what
                        // guards against an empty draft.
                        if on { slot.weekdays.remove(wd) } else { slot.weekdays.insert(wd) }
                    }
                    .buttonStyle(.plain)
                    .font(Typo.sans(11, .semibold))
                    .foregroundStyle(on ? .white : Palette.ink3)
                    .frame(width: 18, height: 24)
                    .background(on ? Palette.railA : Palette.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? .clear : Palette.rule, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Rectangle()
                .fill(Palette.ink3.opacity(0.45))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 6)

            SpanRow(span: $slot.span)

            Spacer(minLength: 0)
            Button { onRemove() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink3).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(canRemove ? 1 : 0.25)
            .disabled(!canRemove)
        }
        // If this row ever outgrows the panel again it clips here rather than
        // widening the scroll content — an overflowing stack centres itself,
        // which slid the whole form sideways and cut the close button off.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// One individually chosen date in Sessions mode.
///
/// Deliberately built from the same pieces as a Repeats row — same date field,
/// same divider, same span row — so switching modes changes what you are saying
/// rather than how the panel looks.
private struct SessionRow: View {
    @Binding var session: SeriesSession
    let canRemove: Bool
    let open: Bool
    let focusRequest: Int
    let onToggleDate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            DateField(date: session.date, open: open, toggle: onToggleDate)

            Rectangle()
                .fill(Palette.ink3.opacity(0.45))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 6)

            SpanRow(span: $session.span, focusRequest: focusRequest)

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink3).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(canRemove ? 1 : 0.25)
            .disabled(!canRemove)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.bottom, 3)
    }
}

/// `[HH] : [MM] for [1h 30m ▾] → 12:40`, the way a class is actually described.
///
/// Choosing a length rather than typing an end is also what makes a class past
/// midnight expressible: 23:00 for 2h can only mean 01:00 the next day.
struct SpanRow: View {
    @Binding var span: TimeSpan
    /// Bumped by the caller to jump into the start box, e.g. after a date is
    /// picked and the time is the obvious next thing to type.
    var focusRequest: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            TimePair(minutes: $span.start, focusRequest: focusRequest)

            Text("for").font(Typo.sans(12)).foregroundStyle(Palette.ink3).fixedSize()

            Picker("", selection: durationBinding) {
                ForEach(TimeSpan.presets, id: \.self) { Text(TimeSpan.label($0)).tag($0) }
                Divider()
                Text("Custom…").tag(-1)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 96)

            if span.duration == nil {
                TimePair(minutes: $span.end)
            }

            if span.duration != nil, let end = span.resolvedEnd {
                Text("to").font(Typo.sans(12)).foregroundStyle(Palette.ink3).fixedSize()
                PlainTime(minutes: end % (24 * 60))
            }
            if span.crossesMidnight { NextDayTag() }
        }
    }

    private var durationBinding: Binding<Int> {
        Binding(get: { span.duration ?? -1 },
                set: { span.duration = $0 == -1 ? nil : $0 })
    }
}

/// The computed end, set exactly like a typed time so the row reads as one
/// thing — same face, same size, same column widths, just no box around it.
private struct PlainTime: View {
    let minutes: Int

    var body: some View {
        HStack(spacing: 3) {
            digits(minutes / 60)
            Text(":").font(Typo.mono(12)).foregroundStyle(Palette.ink3).fixedSize()
            digits(minutes % 60)
        }
        .fixedSize()
    }

    private func digits(_ v: Int) -> some View {
        Text(String(format: "%02d", v))
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(Palette.ink)
            .frame(width: 20)
            .padding(.horizontal, 2)
            .padding(.vertical, 5)
    }
}

/// Marks a time that lands on the following day.
private struct NextDayTag: View {
    var body: some View {
        Text("+1d")
            .font(Typo.mono(9.5, .semibold))
            .foregroundStyle(Palette.mark)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Palette.mark20, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// `[HH] : [MM]`, two digits per box.
///
/// Built on real `NSTextField`s rather than SwiftUI's `TextField`. A SwiftUI
/// text field on macOS keeps its own editing buffer, and a binding that
/// rewrites what was typed — which digit filtering has to do — does not
/// reliably sync back into that buffer: boxes went dead once full, and the
/// later ones stopped taking clicks at all. Owning the field means the value,
/// the selection and the focus order are all set directly.
struct TimePair: View {
    @Binding var minutes: Int?
    /// Bumped by the caller to jump in and select what is there.
    var focusRequest: Int = 0
    /// 24 is allowed where the value means "the end of the day".
    var maxHour: Int = 23

    enum Box: Hashable, CaseIterable { case hour, minute }

    @StateObject private var focusBus = TimePairFocus()
    @State private var text: [Box: String] = [:]

    var body: some View {
        HStack(spacing: 3) {
            cell(.hour, limit: maxHour)
            Text(":").font(Typo.mono(12)).foregroundStyle(Palette.ink3).fixedSize()
            cell(.minute, limit: 59)
        }
        .onAppear(perform: seed)
        // A suggestion picked from history fills the model directly.
        .onChange(of: minutes) { _, _ in seed() }
        .onChange(of: focusRequest) { _, _ in
            guard focusRequest > 0 else { return }
            focusBus.focus(.hour)
        }
    }

    private func cell(_ which: Box, limit: Int) -> some View {
        let on = focusBus.focused == which
        return DigitField(
            text: Binding(get: { text[which] ?? "" },
                          set: { text[which] = $0; publish() }),
            limit: limit,
            box: which,
            bus: focusBus,
            onFilled: { advance(from: which) })
            .frame(width: 20, height: 16)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .background(on ? Palette.mark20 : Palette.surface2)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(on ? Palette.mark40 : Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// A full hour box hands over to the minutes; a full minutes box gives
    /// focus up, so nothing is left blinking once the time is complete.
    private func advance(from which: Box) {
        switch which {
        case .hour:   focusBus.focus(.minute)
        case .minute: focusBus.blur()
        }
    }

    private func publish() {
        let hh = text[.hour] ?? "", mm = text[.minute] ?? ""
        guard hh.count == 2, mm.count == 2, let h = Int(hh), let m = Int(mm) else {
            minutes = nil
            return
        }
        minutes = h * 60 + m
    }

    /// Mirrors the model into the boxes without disturbing a partly-typed one.
    private func seed() {
        let hh = text[.hour] ?? "", mm = text[.minute] ?? ""
        let shown: Int? = (hh.count == 2 && mm.count == 2) ? (Int(hh)! * 60 + Int(mm)!) : nil
        guard shown != minutes else { return }
        if let minutes {
            // Not wrapped at 24: 24:00 is a legitimate end of day.
            text[.hour] = String(format: "%02d", min(minutes / 60, maxHour))
            text[.minute] = String(format: "%02d", minutes % 60)
        } else {
            text[.hour] = ""; text[.minute] = ""
        }
    }
}

/// Shared handle on a pair's fields, so one can pass focus to the other.
@MainActor
final class TimePairFocus: ObservableObject {
    @Published var focused: TimePair.Box?
    /// Not published: registered during view creation, and publishing there
    /// would be a change made in the middle of a SwiftUI update.
    fileprivate var fields: [TimePair.Box: NSTextField] = [:]

    func focus(_ box: TimePair.Box) {
        guard let field = fields[box], let window = field.window else { return }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func blur() {
        fields.values.first?.window?.makeFirstResponder(nil)
        focused = nil
    }
}

/// One two-digit box.
private struct DigitField: NSViewRepresentable {
    @Binding var text: String
    let limit: Int
    let box: TimePair.Box
    let bus: TimePairFocus
    let onFilled: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllOnFocusField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        field.stringValue = text
        bus.fields[box] = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never overwrite what is being typed; only adopt outside changes.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DigitField
        init(_ parent: DigitField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.bus.focused = parent.box
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if parent.bus.focused == parent.box { parent.bus.focused = nil }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let all = field.stringValue.filter(\.isNumber)
            // The most recent two digits, not the first two — keeping the first
            // two meant a box that was already full could never be changed.
            var digits = String(all.count > 2 ? all.suffix(2) : all.prefix(2))

            // A first digit too large to begin a valid number is the whole
            // number: 9 in an hour box means 09, so it fills and moves on.
            if digits.count == 1, let d = Int(digits), d * 10 > parent.limit {
                digits = "0" + digits
            }
            if digits.count == 2, let v = Int(digits), v > parent.limit {
                digits = String(parent.limit)
            }

            if field.stringValue != digits { field.stringValue = digits }
            parent.text = digits
            if digits.count == 2 { parent.onFilled() }
        }
    }
}

/// Clicking in selects what is there, so a filled box is retyped rather than
/// edited a character at a time.
private final class SelectAllOnFocusField: NSTextField {
    /// Programmatic focus — the auto-advance from the previous box.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return ok
    }

    /// Clicking in. `super` runs the mouse-tracking loop and only then sets the
    /// insertion point, which is what was cancelling the selection a frame
    /// after it appeared — so select once that has finished.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        currentEditor()?.selectAll(nil)
    }
}

/// A date as a plain field with a chevron. Opening the month grid is the
/// caller's job, so only one is ever open and it can be laid out full width.
private struct DateField: View {
    let date: Date
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                Text(label)
                    .font(Typo.sans(13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hovering || open ? Palette.ink : Palette.ink2)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(width: 96)
            .background(open ? Palette.mark20 : (hovering ? Palette.ruleSoft : Palette.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(open ? Palette.mark40 : Palette.rule, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: open)
    }

    /// "Aug 12" — no weekday, matching the Repeats side, and the year is still
    /// carried on the Date itself so a series across New Year is unaffected.
    private var label: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

/// A list row that lights up under the pointer.
private struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.mark20
                        : (hovering ? Palette.ruleSoft : Color.clear))
            .onHover { hovering = $0 }
    }
}

// MARK: - Settings

struct CalendarSettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: PrefsStore
    @Environment(\.dismiss) private var dismiss
    let calendarID: String

    @State private var pendingRemoval: (RoleKind, String)?
    @State private var newName: [RoleKind: String] = [:]

    private var calName: String {
        state.calendars.first { $0.id == calendarID }?.title ?? "Calendar"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(calName) settings").font(Typo.sans(15.5, .semibold))
                Spacer()
                AccentButton(title: "Done") { dismiss() }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Palette.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Color")
                        HStack(spacing: 7) {
                            ForEach(CalendarPalette.options, id: \.name) { opt in
                                let selected = prefs.prefs(calendarID).colorHex == opt.hex
                                Button { prefs.setColor(opt.hex, for: calendarID) } label: {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(hex: opt.hex))
                                        .frame(width: 26, height: 26)
                                        .overlay(RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(Palette.ink, lineWidth: selected ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                                .help(opt.name)
                            }
                        }
                    }

                    let p = prefs.prefs(calendarID)
                    ForEach(p.enabledRoles) { role in
                        rosterBox(role, names: p.names(role))
                    }

                    let missing = RoleKind.allCases.filter { !p.isEnabled($0) }
                    if !missing.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(text: "Add a section")
                            // Wraps rather than squeezing — "Coordinator" is
                            // long enough to break onto two lines otherwise.
                            FlowLayout(spacing: 7) {
                                ForEach(missing) { role in
                                    Button {
                                        prefs.enableRole(role, for: calendarID)
                                    } label: {
                                        Label(role.title, systemImage: "plus")
                                            .font(Typo.sans(12.5, .semibold))
                                            .foregroundStyle(Palette.ink2)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .padding(.horizontal, 11).padding(.vertical, 7)
                                            .background(Palette.surface2)
                                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.rule, lineWidth: 1))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        // Resizable, so the name chips reflow to however wide you make it
        // instead of being pinned to a fixed number per row.
        .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity,
               minHeight: 400, idealHeight: 560, maxHeight: .infinity)
        .background(Palette.surface)
        .alert("Remove \(pendingRemoval?.1 ?? "")?",
               isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let (role, name) = pendingRemoval {
                    prefs.removeName(name, role: role, for: calendarID)
                }
                pendingRemoval = nil
            }
        }
    }

    private func rosterBox(_ role: RoleKind, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow(text: role.title)
                Spacer()
                Button("Remove section") { prefs.disableRole(role, for: calendarID) }
                    .buttonStyle(.plain)
                    .font(Typo.sans(11))
                    .foregroundStyle(Palette.ink3)
            }
            FlowChips(names: names,
                      onRemove: { name in pendingRemoval = (role, name) },
                      onRename: { old, new in
                          // Roster first, then every event that names them, so
                          // the two can't disagree.
                          prefs.rename(old, to: new, role: role, for: calendarID)
                          state.renameRoleHolder(calendarID: calendarID, role: role,
                                                 from: old, to: new)
                      })
            HStack(spacing: 6) {
                TextField("Name…", text: Binding(
                    get: { newName[role] ?? "" },
                    set: { newName[role] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit(role) }
                Button("Add") { commit(role) }
            }
        }
    }

    private func commit(_ role: RoleKind) {
        prefs.addName(newName[role] ?? "", role: role, for: calendarID)
        newName[role] = ""
    }
}

/// Name chips with a hover-revealed remove control.
private struct FlowChips: View {
    let names: [String]
    let onRemove: (String) -> Void
    let onRename: (String, String) -> Void

    @State private var hovered: String?
    @State private var renaming: String?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if names.isEmpty {
            Text("None yet.").font(Typo.sans(12)).foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    if renaming == name { editor(name) } else { chip(name) }
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }

    private func chip(_ name: String) -> some View {
        HStack(spacing: 5) {
            Text(name).font(Typo.sans(12.5)).lineLimit(1)

            // Renaming in place, rather than remove-then-add: the roster and
            // the events that name this person are updated together.
            Button {
                draft = name
                renaming = name
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Palette.railA, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovered == name ? 1 : 0)
            .help("Rename")

            Button { onRemove(name) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Color(hex: 0xB4483C), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovered == name ? 1 : 0)
        }
        .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 5)
        .background(Palette.surface)
        .overlay(Capsule().strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(Capsule())
        .onHover { hovered = $0 ? name : (hovered == name ? nil : hovered) }
    }

    private func editor(_ name: String) -> some View {
        HStack(spacing: 5) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Typo.sans(12.5))
                .frame(width: 110)
                .focused($focused)
                .onSubmit { commit(name) }
                .onExitCommand { renaming = nil }
            Button { commit(name) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Palette.railA, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 5)
        .background(Palette.surface)
        .overlay(Capsule().strokeBorder(Palette.mark40, lineWidth: 1))
        .clipShape(Capsule())
        .onAppear { focused = true }
    }

    private func commit(_ old: String) {
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !next.isEmpty, next != old else { return }
        onRename(old, next)
    }
}
