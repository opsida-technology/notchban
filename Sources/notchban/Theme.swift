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
    static let card = dynamic(light: .white, dark: NSColor(red: 0.065, green: 0.095, blue: 0.16, alpha: 1))
    static let cardStroke = dynamic(light: NSColor(red: 0.05, green: 0.2, blue: 0.3, alpha: 0.1), dark: NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.1))
    static let well = dynamic(light: NSColor(red: 0.05, green: 0.25, blue: 0.4, alpha: 0.05), dark: NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.045))
    /// Under the notch: black in the dark (the notch flows into the toolbar), white paper in the light.
    static let band = dynamic(light: .white, dark: .black)
    // The logo's colours (indigo, sky, teal, mint) for flow; ember only for what to watch, red only for alarm.
    // Each has a deeper light-mode shade so it reads as text on white (4.5:1).
    static let upstream = rgb(light: (0.05, 0.45, 0.78), dark: (0.3, 0.72, 1.0))  // sky
    static let downstream = indigo
    static let critical = rgb(light: (0.69, 0.27, 0.05), dark: (1.0, 0.5, 0.27))  // ember
    static let good = rgb(light: (0.04, 0.46, 0.28), dark: (0.25, 0.9, 0.62))  // mint
    static let indigo = rgb(light: (0.25, 0.31, 0.84), dark: (0.4, 0.46, 1.0))
    static let teal = rgb(light: (0.03, 0.5, 0.48), dark: (0.04, 0.78, 0.75))
    static let alarm = rgb(light: (0.75, 0.16, 0.15), dark: (1.0, 0.33, 0.32))
    static let lavender = rgb(light: (0.35, 0.24, 0.85), dark: (0.64, 0.55, 1.0))
    static let slate = rgb(light: (0.35, 0.4, 0.48), dark: (0.56, 0.6, 0.68))

    private static func rgb(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        dynamic(light: NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1), dark: NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1))
    }

    static func column(_ c: Column) -> Color {
        switch c {
        case .backlog: slate
        case .ready: indigo
        case .progress: upstream
        case .review: lavender
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
        lavender, rgb(light: (0.1, 0.42, 0.62), dark: (0.5, 0.8, 1)),
    ]
    /// Track 1 takes the first colour, 2 the second; a named track ("fark") a stable one.
    static func track(_ key: String?) -> Color? {
        key.map { key in tracks[(Int(key).map { max($0, 1) - 1 } ?? Int(stableHash(key))) % tracks.count] }
    }

    static func stableHash(_ s: String) -> UInt32 { s.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } }

    /// A stable colour per owner (String.hashValue changes between launches).
    static func avatar(_ name: String) -> Color {
        let hash = stableHash(name)
        return Color(hue: Double(150 + hash % 140) / 360, saturation: 0.5, brightness: 0.82)  // mint through violet, never pink
    }
}

enum Format {
    /// "Track 2" for a numbered track, the name itself for a named one.
    static func track(_ key: String) -> String { Int(key) == nil ? key : "Track \(key)" }

    /// YYYY-MM-DD in this Mac's time zone, the form `due` is written in.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The owner's review day in words: "review today", "review by Fri", "2 days late".
    static func due(_ day: String, now: Date) -> (text: String, late: Bool) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { return ("review by \(day)", false) }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day ?? 0
        switch days {
        case ..<0: return ("\(-days) day\(days == -1 ? "" : "s") late", true)
        case 0: return ("review today", false)
        case 1: return ("review tomorrow", false)
        case 2...6: return ("review by " + date.formatted(.dateTime.weekday(.abbreviated)), false)
        default: return ("review by " + date.formatted(.dateTime.day().month(.abbreviated)), false)
        }
    }

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

/// The owner's own card (`"source": "human"`), drawn in the notch's black in both modes: black is the owner's.
struct HumanChip: View {
    var body: some View {
        Label("Human Entered", systemImage: "person.fill")
            .labelStyle(TightLabel())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black).overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)))
            .help("Human Entered: you typed this card in")
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
