import SwiftUI

/// The four roles a series can carry.
///
/// Advisor and Manager are alternatives to one another — an event has one or
/// the other, never both. Coordinator and Instructor stand alone.
enum RoleKind: String, CaseIterable, Codable, Identifiable {
    case coordinator, instructor, advisor, manager

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .instructor:  return "Instructor"
        case .advisor:     return "Advisor"
        case .manager:     return "Manager"
        }
    }

    var exclusivePartner: RoleKind? {
        switch self {
        case .advisor: return .manager
        case .manager: return .advisor
        default:       return nil
        }
    }
}

/// Colours a calendar may be given. Deliberately a closed set — anything goes
/// and the app stops looking like itself.
enum CalendarPalette {
    static let options: [(name: String, hex: UInt32)] = [
        ("Clay",   0xC97B4A), ("Brass",  0xE8B33C),
        ("Pine",   0x4E7A6E), ("Slate",  0x6E8CA8),
        ("Plum",   0x8B7099), ("Sage",   0x8FA47E),
        ("Rose",   0xC2807F), ("Stone",  0x93A8A2),
    ]

    static func color(_ hex: UInt32) -> Color { Color(hex: hex) }

    static func fallback(for index: Int) -> UInt32 {
        options[index % options.count].hex
    }
}

/// Per-calendar settings: colour, which role sections exist, and who's in them.
///
/// Role sections are opt-in. A calendar starts with none, so a personal
/// calendar simply never shows them.
struct CalendarPrefs: Codable, Equatable {
    var colorHex: UInt32?
    var enabledRoles: [RoleKind] = []
    var roster: [RoleKind: [String]] = [:]

    func names(_ role: RoleKind) -> [String] {
        (roster[role] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func isEnabled(_ role: RoleKind) -> Bool { enabledRoles.contains(role) }
}

@MainActor
final class PrefsStore: ObservableObject {
    /// The calendar the last event was created in — the sensible default for
    /// the next one, since sessions cluster by school.
    var lastUsedCalendarID: String? {
        get { UserDefaults.standard.string(forKey: "lastUsedCalendarForNewEvents") }
        set { UserDefaults.standard.set(newValue, forKey: "lastUsedCalendarForNewEvents") }
    }

    @Published private var byCalendar: [String: CalendarPrefs] = [:]
    private let defaults = UserDefaults.standard
    private let key = "calendarPrefs.v1"

    init() { load() }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CalendarPrefs].self, from: data)
        else { return }
        byCalendar = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byCalendar) else { return }
        defaults.set(data, forKey: key)
    }

    func prefs(_ calendarID: String) -> CalendarPrefs {
        byCalendar[calendarID] ?? CalendarPrefs()
    }

    func color(_ calendarID: String, fallbackIndex: Int) -> Color {
        Color(hex: prefs(calendarID).colorHex ?? CalendarPalette.fallback(for: fallbackIndex))
    }

    func setColor(_ hex: UInt32, for calendarID: String) {
        var p = prefs(calendarID); p.colorHex = hex
        byCalendar[calendarID] = p; save()
    }

    func enableRole(_ role: RoleKind, for calendarID: String) {
        var p = prefs(calendarID)
        guard !p.enabledRoles.contains(role) else { return }
        p.enabledRoles.append(role)
        byCalendar[calendarID] = p; save()
    }

    func disableRole(_ role: RoleKind, for calendarID: String) {
        var p = prefs(calendarID)
        p.enabledRoles.removeAll { $0 == role }
        p.roster[role] = nil
        byCalendar[calendarID] = p; save()
    }

    /// Kept sorted, and duplicates ignored case-insensitively so "adam" can't
    /// join a list that already has "Adam".
    func addName(_ name: String, role: RoleKind, for calendarID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var p = prefs(calendarID)
        var list = p.roster[role] ?? []
        guard !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        list.append(trimmed)
        p.roster[role] = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        byCalendar[calendarID] = p; save()
    }

    /// True when nothing has been configured for any calendar yet.
    var isEmpty: Bool { byCalendar.isEmpty }

    /// Rebuilds a calendar's role sections and name lists from the roles
    /// actually written into its events' notes.
    ///
    /// The notes are the real record — the roster is only the convenience list
    /// behind the dropdowns — so it can always be reconstructed from them.
    @discardableResult
    func rebuildRoster(for calendarID: String, from notes: [SeriesNotes]) -> Int {
        var found: [RoleKind: Set<String>] = [:]
        for note in notes {
            for role in RoleKind.allCases {
                let name = note.name(role)
                if !name.isEmpty { found[role, default: []].insert(name) }
            }
        }
        guard !found.isEmpty else { return 0 }

        var p = prefs(calendarID)
        var added = 0
        for (role, names) in found {
            if !p.enabledRoles.contains(role) { p.enabledRoles.append(role) }
            var list = p.roster[role] ?? []
            for name in names where !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                list.append(name); added += 1
            }
            p.roster[role] = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        p.enabledRoles.sort { RoleKind.allCases.firstIndex(of: $0)! < RoleKind.allCases.firstIndex(of: $1)! }
        byCalendar[calendarID] = p
        save()
        return added
    }

    /// Replaces a name in the roster, keeping the list sorted and deduplicated.
    func rename(_ old: String, to new: String, role: RoleKind, for calendarID: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        var p = prefs(calendarID)
        var list = (p.roster[role] ?? []).filter { $0 != old }
        if !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            list.append(trimmed)
        }
        p.roster[role] = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        byCalendar[calendarID] = p; save()
    }

    func removeName(_ name: String, role: RoleKind, for calendarID: String) {
        var p = prefs(calendarID)
        p.roster[role] = (p.roster[role] ?? []).filter { $0 != name }
        byCalendar[calendarID] = p; save()
    }
}
