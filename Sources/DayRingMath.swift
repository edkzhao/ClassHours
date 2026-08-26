import Foundation

/// The geometry behind the today ring, kept out of the view so it can be tested.
///
/// The ring's circumference is the day's teaching time. Each class takes the
/// share of the circle that it takes of the day, in the order the classes
/// happen, and the fill boundary is how much of that teaching is already behind
/// you.
enum DayRingMath {

    /// One class, in minutes from midnight, already clipped to the day.
    struct Span: Equatable {
        let start: Int
        let end: Int
        var length: Int { max(0, end - start) }
    }

    /// A class's slice of the ring, as fractions of a full turn.
    struct Slice: Equatable {
        /// Index into the spans array this came from.
        let index: Int
        let from: Double
        let to: Double
    }

    /// Total teaching minutes in the day.
    static func total(_ spans: [Span]) -> Int {
        spans.reduce(0) { $0 + $1.length }
    }

    /// Slices in chronological order. Zero-length classes are dropped rather
    /// than drawn as invisible arcs.
    static func slices(_ spans: [Span]) -> [Slice] {
        let sum = total(spans)
        guard sum > 0 else { return [] }

        var out: [Slice] = []
        var cursor = 0
        for (index, span) in spans.enumerated() where span.length > 0 {
            out.append(Slice(index: index,
                             from: Double(cursor) / Double(sum),
                             to: Double(cursor + span.length) / Double(sum)))
            cursor += span.length
        }
        return out
    }

    /// How much of the day's teaching is done, as a fraction of the ring.
    ///
    /// Counted in taught minutes, not wall clock: the ring is made of classes,
    /// so a two-hour gap between them must not advance the fill. Mid-class, the
    /// boundary sits partway into that class's own arc.
    static func progress(_ spans: [Span], minute: Int) -> Double {
        let sum = total(spans)
        guard sum > 0 else { return 0 }
        let done = spans.reduce(0) { $0 + min(max(0, minute - $1.start), $1.length) }
        return min(1, max(0, Double(done) / Double(sum)))
    }

    /// Sorted the way the ring draws them.
    static func ordered(_ spans: [Span]) -> [Span] {
        spans.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
}
