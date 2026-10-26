import SwiftUI

struct GlobalSearchPanel: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var catalog: [EventSearchItem] = []
    @State private var hits: [EventSearchHit] = []
    @State private var loading = true
    @State private var matching = false
    @State private var catalogVersion = 0
    @State private var resultsVersion = 0

    private struct Request: Equatable {
        let query: String
        let catalogVersion: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search").font(Typo.sans(15, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button { state.globalSearchShown = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().overlay(Palette.rule)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.ink2)
                    TextField("Events, notes or roles", text: $query)
                        .textFieldStyle(.plain)
                        .font(Typo.sans(13))
                        .focused($focused)
                        .accessibilityLabel("Search all calendars")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.ink2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Palette.mark : Palette.rule))

                HStack {
                    Text("All calendars").font(Typo.sans(11.5, .medium))
                    Spacer()
                    if loading || matching {
                        ProgressView().controlSize(.small)
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(hits.count) results").font(Typo.mono(11.5))
                    }
                }
                .foregroundStyle(Palette.ink2)
                if let first = catalog.map(\.start).min(), let last = catalog.map(\.start).max() {
                    Text("\(dateText(first)) – \(dateText(last))")
                        .font(Typo.mono(10.5)).foregroundStyle(Palette.ink2)
                }
            }
            .padding(16)
            Divider().overlay(Palette.rule)

            if loading {
                message("Reading calendars…")
            } else if !state.hasReadAccess {
                message("Allow Calendar access to search events.")
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message("Search your calendar events.")
            } else if hits.isEmpty && !matching {
                message("No matching events.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        let todayIndex = EventSearch.todayIndex(in: hits, now: Date(), calendar: state.calculationCalendar)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                if index == todayIndex { todayDivider }
                                result(hit)
                                Divider().overlay(Palette.ruleSoft).padding(.horizontal, 16)
                            }
                            if todayIndex == hits.count { todayDivider }
                        }
                    }
                    .onChange(of: resultsVersion) { _, _ in scrollToToday(proxy) }
                    .onAppear { scrollToToday(proxy) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
        .onAppear { focused = true }
        .onExitCommand { state.globalSearchShown = false }
        .task(id: state.searchRevision) {
            loading = true
            let items = await state.searchCatalog()
            guard !Task.isCancelled else { return }
            catalog = items
            catalogVersion += 1
            loading = false
        }
        .task(id: Request(query: query, catalogVersion: catalogVersion)) {
            hits = []
            matching = true
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let text = query
            let items = catalog
            let work = Task.detached(priority: .userInitiated) { EventSearch.rank(text, items: items) }
            let found = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            hits = found
            resultsVersion += 1
            matching = false
        }
    }

    private var todayDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Palette.rule).frame(height: 1)
            Text("Today").font(Typo.sans(12, .semibold)).foregroundStyle(Palette.ink)
            Text(dateText(Date())).font(Typo.mono(10.5)).foregroundStyle(Palette.ink2)
                .fixedSize()
            Rectangle().fill(Palette.rule).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.surface2)
        .id("search-today")
        .accessibilityElement(children: .combine)
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("search-today", anchor: .center) }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Typo.sans(13)).foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    private func result(_ hit: EventSearchHit) -> some View {
        let item = hit.item
        return Button { state.revealSearchResult(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.displayTitle)
                        .font(Typo.sans(13, .semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(item.calendarTitle)
                        .font(Typo.sans(10.5, .medium))
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Palette.ruleSoft, in: RoundedRectangle(cornerRadius: 5))
                }
                Text("\(dateText(item.start))  ·  \(timeText(item))")
                    .font(Typo.mono(11)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let context = hit.context {
                    Text(context)
                        .font(Typo.sans(11.5)).foregroundStyle(Palette.ink2)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(item.notes)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = state.calculationCalendar
        formatter.timeZone = state.calculationCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE dd MMM yyyy"
        return formatter.string(from: date)
    }

    private func timeText(_ item: EventSearchItem) -> String {
        guard !item.allDay else { return "All day" }
        let calendar = state.calculationCalendar
        let start = TimeText.hhmm(TimeText.minutes(of: item.start, calendar))
        let end = TimeText.hhmm(TimeText.minutes(of: item.end, calendar))
        return calendar.isDate(item.start, inSameDayAs: item.end)
            ? "\(start)–\(end)" : "\(start)–\(dateText(item.end)) \(end)"
    }
}
