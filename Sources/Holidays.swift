import Foundation

/// One subscribed holiday feed.
///
/// Fetched and parsed by ClassHours rather than handed to EventKit: these are
/// reference dates to show behind the week, not events you teach, and keeping
/// them out of the event store means they can never be counted, edited, or
/// swept up by Tidy Up.
struct HolidayFeed: Identifiable, Equatable, Codable {
    var id = UUID()
    var url: String = ""
    var alias: String = ""
    var colorIndex: Int = 0

    var isUsable: Bool {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return false }
        return parsed.scheme == "https" || parsed.scheme == "http" || parsed.scheme == "webcal"
    }

    /// `webcal://` is the same document over https — Calendar.app's scheme, and
    /// what most of these links are published as.
    var fetchURL: URL? {
        var text = url.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("webcal://") {
            text = "https://" + text.dropFirst("webcal://".count)
        }
        return URL(string: text)
    }

    var displayName: String {
        alias.isEmpty ? (fetchURL?.host ?? "Holidays") : alias
    }
}

/// One dated entry out of a feed.
struct Holiday: Identifiable, Equatable, Codable {
    var id: String { "\(feedID.uuidString)|\(day)|\(title)" }
    let feedID: UUID
    /// Local calendar day, as `yyyy-MM-dd`, since these are all-day entries and
    /// a timestamp would drift across zones.
    let day: String
    let title: String
    let detail: String
}

/// Minimal iCalendar reader — enough for a holiday feed and nothing more.
enum ICSParser {

    /// Unfolds continuation lines, then reads each VEVENT's summary, start and
    /// description.
    static func parse(_ text: String, feedID: UUID) -> [Holiday] {
        var out: [Holiday] = []
        var inEvent = false
        var summary = "", day = "", detail = ""

        for line in unfold(text) {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") {
                inEvent = true; summary = ""; day = ""; detail = ""
                continue
            }
            if upper.hasPrefix("END:VEVENT") {
                if inEvent, !summary.isEmpty, !day.isEmpty {
                    out.append(Holiday(feedID: feedID, day: day, title: summary, detail: detail))
                }
                inEvent = false
                continue
            }
            guard inEvent else { continue }

            // Property names may carry parameters: DTSTART;VALUE=DATE:20260704
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
                .split(separator: ";").first.map(String.init)?.uppercased() ?? ""
            let value = unescape(String(line[line.index(after: colon)...]))

            switch name {
            case "SUMMARY":     summary = value
            case "DESCRIPTION": detail = value
            case "DTSTART":     day = dayStamp(value)
            default:            break
            }
        }
        return out
    }

    /// A line beginning with a space or tab continues the one before it.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t" {
                if !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() }
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `20260704` or `20260704T000000Z` both reduce to `2026-07-04`.
    static func dayStamp(_ value: String) -> String {
        let digits = value.prefix { $0.isNumber }
        guard digits.count >= 8 else { return "" }
        let d = Array(digits)
        return "\(String(d[0..<4]))-\(String(d[4..<6]))-\(String(d[6..<8]))"
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class HolidayStore: ObservableObject {
    /// Three is plenty for the countries a term actually spans, and it keeps the
    /// day header readable — the bars share one row.
    static let maxFeeds = 3

    @Published private(set) var feeds: [HolidayFeed] = []
    @Published private(set) var holidays: [Holiday] = []
    @Published private(set) var refreshing = false
    @Published var lastError: String?

    private let defaults = UserDefaults.standard
    private let feedsKey = "holidayFeeds.v1"
    private let cacheKey = "holidayCache.v1"

    /// Day string -> entries, rebuilt whenever the holidays change.
    private var byDay: [String: [Holiday]] = [:]

    init() {
        if let data = defaults.data(forKey: feedsKey),
           let decoded = try? JSONDecoder().decode([HolidayFeed].self, from: data) {
            feeds = decoded
        }
        if let data = defaults.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([Holiday].self, from: data) {
            holidays = decoded
            reindex()
        }
    }

    // MARK: Feeds

    func addFeed() {
        guard feeds.count < Self.maxFeeds else { return }
        feeds.append(HolidayFeed(colorIndex: feeds.count % CalendarPalette.options.count))
        persistFeeds()
    }

    func update(_ feed: HolidayFeed) {
        guard let i = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[i] = feed
        persistFeeds()
    }

    func remove(_ id: UUID) {
        feeds.removeAll { $0.id == id }
        holidays.removeAll { $0.feedID == id }
        persistFeeds(); persistCache(); reindex()
    }

    func feed(_ id: UUID) -> HolidayFeed? { feeds.first { $0.id == id } }

    /// Replaces the whole set, dropping cached dates for feeds that are gone.
    func replaceFeeds(_ next: [HolidayFeed]) {
        feeds = Array(next.prefix(Self.maxFeeds))
        let live = Set(feeds.map(\.id))
        holidays.removeAll { !live.contains($0.feedID) }
        persistFeeds(); persistCache(); reindex()
    }

    // MARK: Lookup

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func holidays(on date: Date, calendar: Calendar) -> [Holiday] {
        var f = Self.dayFormatter
        f.timeZone = calendar.timeZone
        return byDay[f.string(from: date)] ?? []
    }

    private func reindex() {
        byDay = Dictionary(grouping: holidays, by: \.day)
    }

    // MARK: Refresh

    /// Fetches every usable feed and replaces the cache wholesale.
    ///
    /// A feed that fails leaves its previously cached entries in place, so a
    /// flaky network never blanks the calendar.
    func refresh() async {
        let usable = feeds.filter(\.isUsable)
        guard !usable.isEmpty else {
            holidays = []; persistCache(); reindex(); return
        }

        refreshing = true
        defer { refreshing = false }

        var collected: [Holiday] = []
        var failures: [String] = []

        for feed in usable {
            guard let url = feed.fetchURL else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: "Holidays", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "\(feed.displayName): server returned \(http.statusCode)"])
                }
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    throw NSError(domain: "Holidays", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "\(feed.displayName): not readable as text"])
                }
                let parsed = ICSParser.parse(text, feedID: feed.id)
                if parsed.isEmpty {
                    failures.append("\(feed.displayName): no dates found")
                }
                collected += parsed
            } catch {
                failures.append("\(feed.displayName): \(error.localizedDescription)")
                // Keep whatever this feed had before rather than dropping it.
                collected += holidays.filter { $0.feedID == feed.id }
            }
        }

        holidays = collected
        persistCache()
        reindex()
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func persistFeeds() {
        defaults.set(try? JSONEncoder().encode(feeds), forKey: feedsKey)
    }

    private func persistCache() {
        defaults.set(try? JSONEncoder().encode(holidays), forKey: cacheKey)
    }
}
