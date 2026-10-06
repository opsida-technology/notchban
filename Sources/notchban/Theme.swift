import AppKit
import NotchbanCore
import SwiftUI

/// Colours, small shared pieces and text helpers of the board window and the notch.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// The board's ground: deep ink with a teal cast in the dark, a pale mist of the same hue in the light.
    static let canvas = dynamic(light: NSColor(red: 0.925, green: 0.945, blue: 0.96, alpha: 1), dark: NSColor(red: 0.027, green: 0.047, blue: 0.086, alpha: 1))
    /// The band under the notch (the toolbar), always dark: the notch's black flows into it.
    static let ink = Color(red: 0.027, green: 0.047, blue: 0.086)
    static let card = dynamic(light: .white, dark: NSColor(red: 0.065, green: 0.095, blue: 0.16, alpha: 1))
    static let cardStroke = dynamic(light: NSColor(red: 0.05, green: 0.2, blue: 0.3, alpha: 0.1), dark: NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.1))
    static let well = dynamic(light: NSColor(red: 0.05, green: 0.25, blue: 0.4, alpha: 0.05), dark: NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.045))
    // The logo's colours (indigo, sky, teal, mint) for flow; gold and ember only for what to watch, red only for alarm.
    static let upstream = Color(red: 0.3, green: 0.72, blue: 1.0)  // sky
    static let downstream = indigo
    static let critical = Color(red: 1.0, green: 0.5, blue: 0.27)  // ember
    static let good = Color(red: 0.25, green: 0.9, blue: 0.62)  // mint
    static let indigo = Color(red: 0.4, green: 0.46, blue: 1.0)
    static let teal = Color(red: 0.04, green: 0.78, blue: 0.75)
    static let alarm = Color(red: 1.0, green: 0.33, blue: 0.32)

    static func column(_ c: Column) -> Color {
        switch c {
        case .backlog: Color(red: 0.56, green: 0.6, blue: 0.68)
        case .ready: indigo
        case .progress: upstream
        case .review: Color(red: 0.64, green: 0.55, blue: 1)  // lavender
        case .verified: teal
        case .blocked: alarm
        case .done: good
        }
    }

    static func columnIcon(_ c: Column) -> String {
        switch c {
        case .backlog: "tray"
        case .ready: "circle.dashed"
        case .progress: "circle.lefthalf.filled"
        case .review: "eye"
        case .verified: "checkmark.seal"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle.fill"
        }
    }

    static let tracks: [Color] = [
        upstream, teal, good, indigo,
        Color(red: 0.64, green: 0.55, blue: 1), Color(red: 0.5, green: 0.8, blue: 1),
    ]
    static func track(_ n: Int?) -> Color? { n.map { tracks[(max($0, 1) - 1) % tracks.count] } }

    /// A stable colour per owner (String.hashValue changes between launches).
    static func avatar(_ name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(150 + hash % 140) / 360, saturation: 0.5, brightness: 0.82)  // mint through violet, never pink
    }
}

enum Format {
    /// "agent:task-forgejo-move-2026-10-06" → "forgejo-move".
    static func owner(_ raw: String) -> String {
        var s = raw
        for prefix in ["agent:", "human:", "task-"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let r = s.range(of: #"-\d{4}-\d{2}-\d{2}.*$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.isEmpty ? raw : s
    }

    static func initials(_ raw: String) -> String {
        let words = owner(raw).split(whereSeparator: { "-_ .".contains($0) })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    static func lease(_ expires: Date?, now: Date) -> String {
        guard let expires else { return "no lease" }
        let minutes = Int(expires.timeIntervalSince(now) / 60)
        func span(_ m: Int) -> String { m >= 2880 ? "\(m / 1440)d" : m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
        return minutes >= 0 ? "\(span(minutes)) left" : "expired \(span(-minutes)) ago"
    }

    /// Joins the hard-wrapped lines of each paragraph, keeping list items and indented code on their own lines.
    static func unwrap(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph in
            var out = "", previous = ""
            for line in paragraph.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                let own = t.hasPrefix("- ") || t.hasPrefix("* ") || line.hasPrefix("    ") || (t.first?.isNumber == true && t.contains(". "))
                let wrapped = previous.count >= 60  // a short line ended on purpose
                out += out.isEmpty ? line : (own || !wrapped ? "\n" + line : " " + t)
                previous = line
            }
            return out
        }.joined(separator: "\n\n")
    }

    /// Inline markdown of a board's text. Board files are untrusted: links are dropped, so no text in a card can
    /// open a URL (or another app's scheme) when it is clicked.
    static func markdown(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in out.runs where run.link != nil { out[run.range].link = nil }
        return out
    }
}

/// An AppKit material behind SwiftUI content: the board window's glass.
struct Glass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

struct Avatar: View {
    let owner: String
    var size: CGFloat = 18
    var body: some View {
        let colour = Theme.avatar(Format.owner(owner))
        Text(Format.initials(owner))
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [colour, colour.opacity(0.7)], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel("Owner \(Format.owner(owner))")
    }
}

struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

struct Ring: View {
    let done: Int, total: Int
    var size: CGFloat = 14
    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        let tint: Color = fraction >= 1 ? Theme.column(.done) : .accentColor
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle().trim(from: 0, to: fraction).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

extension Card {
    func riskChip() -> Chip? {
        switch risk {
        case "sec": Chip(text: "sec", icon: "lock.shield", tint: Theme.alarm)
        case "data": Chip(text: "data", icon: "cylinder.split.1x2", tint: Theme.downstream)
        default: nil
        }
    }
}
