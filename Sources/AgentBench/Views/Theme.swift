import SwiftUI

// Design tokens ported 1:1 from the AgentBench prototype CSS (monochrome, editorial).
enum Theme {
    // surfaces
    static let bg      = Color(hex: 0xF5F5F6)
    static let panel   = Color(hex: 0xFFFFFF)
    static let panel2  = Color(hex: 0xFAFAFA)
    static let rail    = Color(hex: 0xFBFBFC)

    // ink
    static let ink   = Color(hex: 0x16161A)
    static let ink2  = Color(hex: 0x65656C)
    static let ink3  = Color(hex: 0x9A9AA2)

    // hairlines
    static let line  = Color(hex: 0x14141A, alpha: 0.09)
    static let line2 = Color(hex: 0x14141A, alpha: 0.055)
    static let line3 = Color(hex: 0x14141A, alpha: 0.16)

    // accent (overridable)
    static let accentDefault = Color(hex: 0x111111)

    // semantic
    static let good = Color(hex: 0x15803D)
    static let bad  = Color(hex: 0xB42318)

    // diff
    static let addBG = Color(hex: 0x15803D, alpha: 0.10)
    static let addFG = Color(hex: 0x15803D)
    static let delBG = Color(hex: 0xB42318, alpha: 0.08)
    static let delFG = Color(hex: 0xB42318)

    // radii
    static let r:   CGFloat = 14
    static let rSm: CGFloat = 9
    static let rXs: CGFloat = 6

    // layout
    static let sideW: CGFloat = 276
    static let sideCollapsed: CGFloat = 62

    // fonts (system; the prototype used Inter / JetBrains Mono — SF carries the monochrome look)
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let accentChoices: [UInt32] = [0x111111, 0x2563EB, 0x16A34A, 0xDB2777]
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0x111111
        self.init(hex: v)
    }
}

// Soft card shadow approximating the prototype's --shadow.
struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color(hex: 0x14141A, alpha: 0.04), radius: 1, x: 0, y: 1)
            .shadow(color: Color(hex: 0x14141A, alpha: 0.05), radius: 9, x: 0, y: 6)
    }
}
extension View {
    func cardShadow() -> some View { modifier(CardShadow()) }
}
