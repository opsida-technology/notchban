import NotchbanCore
import SwiftUI
import UIKit

/// Every colour and font the screens use, in one place (docs/design.html, nb.css). The notch is hardware black in
/// both modes: whatever is the owner's (the header island, his Human Entered chip, the + button, the main button,
/// the "Needs you to" box) is drawn in that black. Everything else follows the mode. Island content is rendered in
/// the dark scheme, so the same tokens give its light-on-black text.
enum Theme {
    // MARK: surfaces and text (dark / light)

    static let bg = dynamic(0x070C16, 0xECF1F5)
    static let surface = dynamic(0x101828, 0xFFFFFF)
    static let raised = dynamic(0x172036, 0xF6F8FB)
    /// A quiet tinted fill: tags, ghost buttons, segmented control.
    static let well = dynamic(UIColor(red: 153 / 255, green: 217 / 255, blue: 1, alpha: 0.07), UIColor(red: 13 / 255, green: 64 / 255, blue: 102 / 255, alpha: 0.06))
    static let line = dynamic(UIColor(red: 153 / 255, green: 217 / 255, blue: 1, alpha: 0.12), UIColor(red: 13 / 255, green: 51 / 255, blue: 77 / 255, alpha: 0.12))
    static let fg = dynamic(0xEEF3F8, 0x0B1220)
    static let fg2 = dynamic(0xA9B4C6, 0x45526A)
    static let fg3 = dynamic(0x8390A6, 0x5A667B)

    // MARK: the owner's black

    static let notch = Color.black
    static let onNotch = Color(hex: 0xF3F6FA)
    static let onNotch2 = Color(hex: 0xA9B4C6)
    static let notchLine = Color.white.opacity(0.14)
    /// Panels inside the island (status pill, ears, the "Needs you to" box).
    static let notchWell = Color.white.opacity(0.08)
    /// The stale / count badge.
    static let stale = Color(hex: 0xD42F2D)

    // MARK: tones (fill / text, dark and light)

    struct Tone {
        let fill: Color
        let text: Color
    }

    static let review = Tone(fill: dynamic(0xA38CFF, 0x8B6FFF), text: dynamic(0xB8A6FF, 0x5A3ED8))
    static let late = Tone(fill: dynamic(0xFF5452, 0xF04442), text: dynamic(0xFF7270, 0xC02826))
    static let ok = Tone(fill: dynamic(0x40E69E, 0x22C985), text: dynamic(0x5CEBAE, 0x0A7647))
    static let sky = Tone(fill: dynamic(0x4DB8FF, 0x2EA3F2), text: dynamic(0x6CC4FF, 0x0A66A8))
    static let indigo = Tone(fill: dynamic(0x6675FF, 0x5A69F5), text: dynamic(0x9AA4FF, 0x3F4FD6))
    static let ember = Tone(fill: dynamic(0xFF8045, 0xF2702F), text: dynamic(0xFF9563, 0xB0450C))
    static let teal = Tone(fill: dynamic(0x0AC7BF, 0x0AB3AC), text: dynamic(0x0AC7BF, 0x0A7F7A))
    static let backlog = Tone(fill: dynamic(0x8F99AD, 0x8A94A8), text: dynamic(0xA9B4C6, 0x45526A))

    /// The Mac app's column colours.
    static func column(_ column: Column) -> Tone {
        switch column {
        case .backlog: backlog
        case .ready: indigo
        case .progress: sky
        case .review: review
        case .verified: teal
        case .blocked: late
        case .done: ok
        }
    }

    static func verdict(_ verdict: Verdict) -> Tone {
        switch verdict {
        case .done: ok
        case .approved: indigo
        case .changes: ember
        case .hold: late
        }
    }

    /// A board's own colour, the same on every launch (from its folder name, not Swift's per-run hash).
    static func board(_ board: Board) -> Color {
        let palette = [teal, indigo, sky, review, ember, ok]
        let sum = board.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count].fill
    }

    /// Avatar colours for the agents named in a card's owner.
    static func agent(_ owner: String) -> (Color, String) {
        let o = owner.lowercased()
        if o.contains("claude") { return (Color(hex: 0xB4480D), "Cl") }
        if o.contains("codex") { return (Color(hex: 0x2B3448), "C") }
        let name = owner.split(separator: ":").last.map(String.init) ?? owner
        return (Color(hex: 0x5A667B), String(name.prefix(1)).uppercased())
    }

    // MARK: fonts (system SF; ids monospaced; scaled with the reader's text size)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: mono ? .monospaced : .default)
    }

    static var big: Font { .system(size: 96, weight: .heavy).monospacedDigit() }
    static var islandTitle: Font { font(34, .bold) }
    static var cardTitle: Font { font(25, .bold) }
    static var heroLine: Font { font(19, .semibold) }
    static var rowTitle: Font { font(16.5, .semibold) }
    static var body: Font { font(14) }
    static var needs: Font { font(13.5) }
    static var meta: Font { font(12.5) }
    static var metaBold: Font { font(12.5, .semibold) }
    static var id: Font { font(11.5, mono: true) }
    static var chip: Font { font(11.5, .semibold) }
    static var section: Font { font(13, .bold) }
    static var label: Font { font(12.5, .bold) }
    static var button: Font { font(16.5, .bold) }
    static var code: Font { font(26, .bold).monospacedDigit() }

    // MARK: helpers

    static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color { dynamic(UIColor(hex: dark), UIColor(hex: light)) }

    static func dynamic(_ dark: UIColor, _ light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(UIColor(hex: hex)) }
}

extension View {
    /// The card shadow of nb.css: soft in light mode, a faint inner line plus a deep shadow in dark mode.
    func cardShadow(radius: CGFloat = 22) -> some View { modifier(CardShadow(radius: radius)) }
}

private struct CardShadow: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if scheme == .dark {
            content
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(red: 0.6, green: 0.85, blue: 1).opacity(0.07)))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        } else {
            content
                .shadow(color: Color(hex: 0x0B1220).opacity(0.06), radius: 1, y: 1)
                .shadow(color: Color(hex: 0x0B1220).opacity(0.07), radius: 9, y: 6)
        }
    }
}
