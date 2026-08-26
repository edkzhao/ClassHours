import SwiftUI
import EventKit

// MARK: - Sheet

struct TidyUpSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var series: SeriesStore
    @Environment(\.dismiss) private var dismiss

    @State private var plan = TidyUp.Plan()
    @State private var scanned = false
    @State private var result: String?
    @State private var included: Set<String> = []

    /// Pre-ticked. Both spellings of the third one, since it appears either way.
    private static let defaultNames: Set<String> = ["考而思", "新东方", "悉拓", "思拓"]

    private var cal: Calendar { state.calculationCalendar }

    private var choosable: [CalendarChoice] { state.writableCalendars }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tidy up series").font(Typo.sans(15.5, .semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Palette.rule)

            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result).font(Typo.sans(13.5))
                    Text("Nothing else to do.").font(Typo.sans(12)).foregroundStyle(Palette.ink3)
                }
                .padding(18)
            } else if !scanned {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Groups events that are the same class, so they share one set of notes. Titles are normalised — Jonny becomes Johnny.")
                        .font(Typo.sans(13))
                    Text("Nothing is written until you press Apply.")
                        .font(Typo.sans(12)).foregroundStyle(Palette.ink3)

                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(text: "Calendars to tidy")
                        ForEach(choosable) { c in
                            Toggle(c.title, isOn: Binding(
                                get: { included.contains(c.id) },
                                set: { on in
                                    if on { included.insert(c.id) } else { included.remove(c.id) }
                                }))
                            .font(Typo.sans(13))
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.rule, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button("Scan") { runScan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(included.isEmpty)
                }
                .padding(18)
                .onAppear {
                    if included.isEmpty {
                        included = Set(choosable.filter { Self.defaultNames.contains($0.title) }.map(\.id))
                    }
                }
            } else {
                summary
                Divider().overlay(Palette.rule)
                ScrollView { groupList.padding(18) }
                Divider().overlay(Palette.rule)
                HStack {
                    if plan.groups.contains(where: \.needsAttention) {
                        Text("Choose which notes to keep for the highlighted groups.")
                            .font(Typo.sans(12)).foregroundStyle(Palette.mark)
                    }
                    Spacer()
                    Button("Apply") { runApply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.actionable)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 600)
        .background(Palette.surface)
    }

    private var summary: some View {
        HStack(spacing: 8) {
            stat("\(plan.seriesTotal)", "Series to form")
            stat("\(plan.renameTotal)", "To rename")
            stat("\(plan.fillTotal)", "Notes to copy")
            stat("\(plan.conflicts.count)", "Conflicts")
        }
        .padding(18)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(Typo.mono(17, .medium)).monospacedDigit()
            Eyebrow(text: l)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($plan.groups) { $g in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(g.title).font(Typo.sans(13.5, .semibold)).lineLimit(1)
                        Text(g.calendarName).font(Typo.sans(11)).foregroundStyle(Palette.ink3)
                        Spacer()
                        Text("\(g.eventIDs.count) events").font(Typo.mono(11)).foregroundStyle(Palette.ink3)
                    }
                    if g.willForm {
                        Text("Grouping \(g.eventIDs.count) events into one series")
                            .font(Typo.sans(11.5)).foregroundStyle(Palette.ink2)
                    }
                    if g.renameCount > 0 {
                        Text("Renaming \(g.renameCount)").font(Typo.sans(11.5)).foregroundStyle(Palette.ink2)
                    }
                    if g.willFillNotes {
                        Text("Copying notes onto \(g.missingNotesCount) without any")
                            .font(Typo.sans(11.5)).foregroundStyle(Palette.ink2)
                    }
                    if g.isConflict {
                        Text("Two different notes — pick one to keep:")
                            .font(Typo.sans(11.5)).foregroundStyle(Palette.mark)
                        ForEach(Array(g.candidateNotes.enumerated()), id: \.offset) { i, n in
                            Button {
                                g.chosen = i
                            } label: {
                                Text(n.encoded().isEmpty ? "(empty)" : n.encoded())
                                    .font(Typo.mono(11))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(g.chosen == i ? Palette.mark20 : Palette.surface2)
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(g.chosen == i ? Palette.mark : Palette.rule, lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(11)
                .background(g.needsAttention ? Palette.mark20.opacity(0.4) : Palette.surface2)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.rule, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func runScan() {
        var names: [String: String] = [:]
        for c in state.calendars { names[c.id] = c.title }
        // Only the calendars ticked above — nothing else is even read.
        let cals = state.calendars.filter { included.contains($0.id) }
            .compactMap { state.ekCalendar($0.id) }
        let from = cal.date(byAdding: .year, value: -3, to: Date()) ?? Date()
        let to = cal.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        plan = TidyUp.scan(store: state.store, calendars: cals, calendarNames: names, from: from, to: to)
        scanned = true
    }

    private func runApply() {
        do {
            let r = try TidyUp.apply(plan, store: state.store, series: series)
            result = "Formed \(r.formed) series, renamed \(r.renamed), wrote notes to \(r.noted)."
            state.refresh()
        } catch {
            result = "Failed: \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    static let openTidyUp = Notification.Name("ClassHours.openTidyUp")
}
