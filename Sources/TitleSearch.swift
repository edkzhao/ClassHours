import Foundation
import SwiftUI

/// Matching a part-typed class name against what has been taught before.
///
/// Class names here are routinely mixed script — "考而思：Zhu-Statistics" — and
/// the keyboard is in English. So a title is matched not only on itself but on
/// its Mandarin romanisation and that romanisation's initials: typing `kao`,
/// `kes` or `zhu` all reach that class, and typing 考 still works too.
enum TitleSearch {

    /// Ranked hit quality, lowest first. `nil` means no match at all.
    ///
    /// Kept ordinal rather than a bool so a literal hit always outranks a
    /// romanised one — otherwise typing "shi" surfaces every 思 in the list
    /// ahead of the class actually called "Shi".
    static func score(_ query: String, title: String) -> Int? {
        let q = fold(query)
        guard !q.isEmpty else { return nil }

        let plain = fold(title)
        if plain.hasPrefix(q) { return 0 }
        if plain.contains(q) { return 1 }

        let roman = romanised(title)
        if roman.hasPrefix(q) { return 2 }
        if roman.contains(q) { return 3 }
        // Romanisation comes back one syllable at a time — "kao er si" — but
        // nobody types the spaces, so run the query against the joined-up form
        // as well.
        if compacted(roman).contains(compacted(q)) { return 4 }
        if syllableInitials(roman).contains(q) { return 5 }
        return nil
    }

    static func matches(_ query: String, title: String) -> Bool {
        score(query, title: title) != nil
    }

    /// Case, accent and width folded, so "ZHU", "zhu" and "ｚｈｕ" are one query.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Han characters become their pinyin; everything else is left alone, so a
    /// mixed title romanises to something still containing its English half.
    static func romanised(_ s: String) -> String {
        let buffer = NSMutableString(string: s)
        CFStringTransform(buffer as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(buffer as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
        return fold(buffer as String)
    }

    /// Letters and digits only, so syllable spacing and punctuation stop
    /// mattering.
    static func compacted(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber })
    }

    /// First letter of each romanised syllable — "kao er si" becomes "kes".
    static func syllableInitials(_ romanised: String) -> String {
        String(romanised.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap(\.first))
    }
}

/// Drops a calendar's own name off the front of its events' titles.
///
/// Titles are routinely filed as "考而思：高培-科学推理" — the agency, then the
/// class. Inside that agency's own calendar the agency is a given, and repeating
/// it on every block costs the space the class name needs.
enum TitlePrefix {
    /// What may sit between the prefix and the class name.
    static let separators: Set<Character> = ["：", ":", "-", "–", "—", "|", "·"]

    static func strip(_ title: String, prefix: String) -> String {
        let mark = prefix.trimmingCharacters(in: .whitespaces)
        guard !mark.isEmpty, title.hasPrefix(mark) else { return title }

        var rest = Substring(title).dropFirst(mark.count)
        while rest.first == " " { rest = rest.dropFirst() }
        // Only a real separator counts, or "Maths" would lose its "Math".
        guard let next = rest.first, separators.contains(next) else { return title }
        rest = rest.dropFirst()
        while rest.first == " " { rest = rest.dropFirst() }

        let stripped = String(rest)
        // Never leave a row with no name at all.
        return stripped.isEmpty ? title : stripped
    }
}

/// Turns bare URLs in free text into followable links.
enum LinkScanner {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func links(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let detector, !text.isEmpty else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: full).compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: text) else { return nil }
            return (range, url)
        }
    }

    /// The same text with its links marked up, so a click opens the browser.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for (range, url) in links(in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }
}
