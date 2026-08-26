import SwiftUI

/// Rename the app here. This is the only place the display name is defined.
/// The top row's insets, shared so the hours page and the calendar put their
/// controls at exactly the same height. They drifted apart once already.
enum TopBarInset {
    static let horizontal: CGFloat = 20
    static let top: CGFloat = 2
    static let bottom: CGFloat = 8
}

enum Brand {
    static let name = "ClassHours"
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Brass: a deep pine-teal ground with a brass-gold accent.
///
/// The accent appears in exactly one place -- the month total -- so it always
/// means "this is the number you came for". `mark` is a separate hue that
/// carries today and interactive state, so the two never blur together.
enum Palette {
    static let canvas   = Color(hex: 0xF6F8F6)
    static let surface  = Color(hex: 0xFFFFFF)
    static let surface2 = Color(hex: 0xFAFCFA)
    static let rule     = Color(hex: 0xE2E9E5)
    static let ruleSoft = Color(hex: 0xEFF3F0)

    static let ink      = Color(hex: 0x2A403C)
    static let ink2     = Color(hex: 0x5C7570)
    static let ink3     = Color(hex: 0x93A8A2)

    static let railA    = Color(hex: 0x2F4F4A)
    static let railB    = Color(hex: 0x3A5E58)
    static let readoutA = Color(hex: 0x2C4A46)
    static let readoutB = Color(hex: 0x24403C)

    static let accent   = Color(hex: 0xE8B33C)
    static let mark     = Color(hex: 0xC97B4A)
    static let mark40   = Color(hex: 0xE9C3AC)
    static let mark20   = Color(hex: 0xF6E6DC)
    /// The end of a series. Deliberately cool, so it never competes with the
    /// warm accents that mean "today" and "still to come".
    static let finalInk  = Color(hex: 0x3F6B5C)
    static let finalWash = Color(hex: 0xE3EFE8)

    static let railInk  = Color(hex: 0xF4F8F6)
    static let railInk2 = Color.white.opacity(0.62)
    static let railRule = Color.white.opacity(0.16)

    static let railGradient = LinearGradient(
        colors: [railA, railB], startPoint: .top, endPoint: .bottom
    )
    static let readoutGradient = LinearGradient(
        colors: [readoutA, readoutB], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Calendar dot colours, tuned to sit calmly on the rail.
    static let calendarDots: [Color] = [
        Color(hex: 0xC97B4A), Color(hex: 0xE8B33C), Color(hex: 0x7FA8B2),
        Color(hex: 0xA79BC0), Color(hex: 0x93A8A2), Color(hex: 0xD98F6A),
        Color(hex: 0x8FB08A), Color(hex: 0xB59BC0),
    ]
}

enum Typo {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Small caps label used above every metric.
struct Eyebrow: View {
    let text: String
    var color: Color = Palette.ink3
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(color)
    }
}
