import Foundation
import SwiftUI

/// Series membership, owned by ClassHours rather than by EventKit.
///
/// Apple's recurrence rules describe a *pattern*, so events at different times,
/// dates and durations can never share one. ClassHours has no such constraint:
/// a series here is simply a set of events that belong together. When writing
/// back to Apple Calendar we express whatever fits a recurrence and leave the
/// rest as individual events — they stay one series in this app either way.
@MainActor
final class SeriesStore: ObservableObject {
    /// seriesID -> member event identifiers
    @Published private(set) var groups: [String: [String]] = [:]
    private var indexByEvent: [String: String] = [:]

    private let defaults = UserDefaults.standard
    private let key = "seriesMembership.v1"

    init() { load() }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            groups = decoded
        }
        reindex()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: key) }
        reindex()
    }

    private func reindex() {
        var idx: [String: String] = [:]
        for (sid, members) in groups { for m in members { idx[m] = sid } }
        indexByEvent = idx
    }

    // MARK: Reading

    func seriesID(of eventID: String) -> String? { indexByEvent[eventID] }

    func members(of seriesID: String) -> [String] { groups[seriesID] ?? [] }

    /// Every event that shares a series with this one — itself if it's alone.
    func siblings(of eventID: String) -> [String] {
        guard let sid = indexByEvent[eventID] else { return [eventID] }
        let m = groups[sid] ?? []
        return m.isEmpty ? [eventID] : m
    }

    func isGrouped(_ eventID: String) -> Bool { indexByEvent[eventID] != nil }

    // MARK: Writing

    /// Puts these events in one series, absorbing any series they were in.
    @discardableResult
    func group(_ eventIDs: [String], into existing: String? = nil) -> String {
        let sid = existing ?? UUID().uuidString
        var combined = Set(groups[sid] ?? [])

        for id in eventIDs {
            if let old = indexByEvent[id], old != sid {
                // Absorb the whole old series rather than orphaning its members.
                combined.formUnion(groups[old] ?? [])
                groups[old] = nil
            }
            combined.insert(id)
        }
        groups[sid] = Array(combined).sorted()
        persist()
        return sid
    }

    func ungroup(_ eventID: String) {
        guard let sid = indexByEvent[eventID] else { return }
        var members = groups[sid] ?? []
        members.removeAll { $0 == eventID }
        groups[sid] = members.count > 1 ? members : nil
        persist()
    }

    /// Forget events that no longer exist, so deleted ones don't linger.
    /// True when no series have been formed yet.
    var isEmpty: Bool { groups.isEmpty }

    /// Re-forms membership from groups worked out elsewhere.
    @discardableResult
    func rebuild(from groups: [[String]]) -> Int {
        var formed = 0
        for ids in groups where ids.count > 1 {
            _ = group(ids)
            formed += 1
        }
        return formed
    }

    func prune(existing: Set<String>) {
        var changed = false
        for (sid, members) in groups {
            let kept = members.filter { existing.contains($0) }
            if kept.count != members.count {
                groups[sid] = kept.count > 1 ? kept : nil
                changed = true
            }
        }
        if changed { persist() }
    }
}
