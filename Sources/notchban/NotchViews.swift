import NotchbanCore
import SwiftUI

/// Two arcs: the outer one the 5-hour limit, the inner one the weekly limit.
struct Rings: View {
    let provider: Provider
    let now: Date

    var body: some View {
        ZStack {
            arc(provider.fiveHour, radius: 9)
            arc(provider.week, radius: 5)
        }
        .frame(width: 22, height: 22)
    }

    private func arc(_ window: Window?, radius: CGFloat) -> some View {
        let used = (window?.current(at: now) ?? 0) / 100
        let known = window.map { $0.resets > now } ?? false  // a rolled window is unknown, as its figure says ("—"): no arc
        return ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 2.6)
            Circle().trim(from: 0, to: known ? max(used, 0.015) : 0)
                .stroke(Limit.color(used), style: StrokeStyle(lineWidth: 2.6, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

enum Limit {
    static func color(_ used: Double) -> Color { used < 0.6 ? Theme.good : used < 0.85 ? Color(red: 0.98, green: 0.75, blue: 0.33) : Theme.alarm }

    static func resets(_ window: Window?, now: Date) -> String {
        guard let window, window.resets > now else { return "—" }
        let m = Int(window.resets.timeIntervalSince(now) / 60)
        return m >= 2880 ? "\(m / 1440)d \(m % 1440 / 60)h" : m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func percent(_ window: Window?, now: Date) -> String {
        window.flatMap { $0.resets > now ? "\(Int($0.used.rounded()))%" : nil } ?? "—"  // a rolled window is unknown, not 0
    }
}

/// One side of the notch: the rings, with how many agents work as a badge on them, the 5-hour figure and when it resets.
struct Ear: View {
    let provider: Provider
    let now: Date
    var body: some View {
        HStack(spacing: 5) {
            Rings(provider: provider, now: now)
                .overlay(alignment: .bottomTrailing) {
                    if provider.active > 0 {
                        Text("\(provider.active)").font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                            .frame(minWidth: 11, minHeight: 11).background(Circle().fill(Theme.good)).offset(x: 4, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(provider.name) \(Limit.percent(provider.fiveHour, now: now))").font(.system(size: 10.5, weight: .semibold))
                Text("↻ \(Limit.resets(provider.fiveHour, now: now))").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
            .fixedSize()
        }
        .opacity(provider.fiveHour.map { $0.resets > now } != true || provider.recorded.map { now.timeIntervalSince($0) > 1800 } == true ? 0.55 : 1)  // unknown, or written long ago
        .help(provider.recorded.map { "\(provider.name) limits recorded \($0.formatted(date: .omitted, time: .shortened)): 5 hours \(Limit.percent(provider.fiveHour, now: now)), week \(Limit.percent(provider.week, now: now)) (resets in \(Limit.resets(provider.week, now: now)))" } ?? "\(provider.name): limits not connected")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.name): \(Limit.percent(provider.fiveHour, now: now)) of the 5-hour limit used, \(provider.active) agents working")
    }
}

/// The notch and the board as one outline: the pill's sides run down and flare out, through concave fillets, into the
/// board's top edge; every corner is round. `progress` 0 is the closed pill, 1 the open board, and it is the only thing
/// animated: the board inside is laid out once at full size and only clipped by this shape.
struct NotchOutline: Shape {
    let pill: CGFloat, notch: CGFloat
    var progress: CGFloat
    var closed = true  // false: no edge along the screen's top, for the border
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(progress, 0), cx = rect.midX, a = pill / 2
        let full = rect.width / 2 - NotchView.margin
        let A = max(a, a + (full - a) * p), bottom = notch + (rect.height - notch - NotchView.margin) * p
        let bend = min(1, (A - a) / 36)  // the flare's fillet and corner grow in as the board widens
        let fillet = 14 * bend, corner = 22 * bend
        let round = min(26, bottom / 2)
        let top = max(min(notch, bottom - round - corner), 0)  // a short board flares higher up, inside the pill
        var path = Path()
        path.move(to: CGPoint(x: cx - a, y: 0))
        if closed { path.addLine(to: CGPoint(x: cx + a, y: 0)) } else { path.move(to: CGPoint(x: cx + a, y: 0)) }
        for (corner, next, r) in [((cx + a, top), (cx + A, top), min(fillet, top)), ((cx + A, top), (cx + A, bottom), corner),
                                  ((cx + A, bottom), (cx - A, bottom), round), ((cx - A, bottom), (cx - A, top), round),
                                  ((cx - A, top), (cx - a, top), corner), ((cx - a, top), (cx - a, 0), min(fillet, top))] {
            path.addArc(tangent1End: CGPoint(x: corner.0, y: corner.1), tangent2End: CGPoint(x: next.0, y: next.1), radius: r)
        }
        path.addLine(to: CGPoint(x: cx - a, y: 0))
        if closed { path.closeSubpath() }
        return path
    }
}

/// The pill over the notch; the pointer on it shows who works where, a click (or ⌥⌘B) opens the whole board.
struct NotchView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var state: BoardState
    let notch: CGSize
    let width: CGFloat
    let open: () -> Void
    static let margin: CGFloat = 36  // room around the board for its glow
    private let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        let progress: CGFloat = model.reveal ? 1 : 0
        if model.expanded {
            let outline = NotchOutline(pill: width, notch: notch.height, progress: progress)
            let rim = NotchOutline(pill: width, notch: notch.height, progress: progress, closed: false)
            let settled = NotchOutline(pill: width, notch: notch.height, progress: 1, closed: false)
            let light = LinearGradient(colors: [Theme.upstream, Theme.good], startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                BoardScreen(state: state, inset: 0)
                .frame(width: geo.size.width - Self.margin * 2, height: geo.size.height - notch.height - Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, Self.margin)
                .overlay(alignment: .top) { ears.frame(height: notch.height).frame(width: width) }
                .background(.black)
                .clipShape(outline)
                // A soft halo of the settled outline, faded in once the board has landed: opacity only, never a radius per frame.
                .background(settled.stroke(light, lineWidth: 5).blur(radius: 9).opacity(model.reveal ? 0.55 : 0)
                    .animation(model.reveal ? .easeOut(duration: 0.6).delay(0.3) : .easeIn(duration: 0.1), value: model.reveal))
                .overlay(rim.stroke(light, lineWidth: 1.2).opacity(model.reveal ? 0.9 : 0))
                .overlay {  // once per opening, a light runs from the notch down both sides and meets itself at the bottom
                    if !still {
                        let t = progress
                        ZStack {
                            settled.trim(from: 0.6 * t - 0.1, to: 0.5 * t).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            settled.trim(from: 1 - 0.5 * t, to: 1.1 - 0.6 * t).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                        .animation(model.reveal ? .easeInOut(duration: 1.1).delay(0.25) : nil, value: model.reveal)
                    }
                }
            }
        } else {
            ears.frame(height: notch.height).frame(width: width).background(NotchOutline(pill: width, notch: notch.height, progress: 0).fill(.black))
                .contentShape(Rectangle()).onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton).accessibilityLabel("Open the board")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var ears: some View {
        HStack {
            if let left = model.providers.first { Ear(provider: left, now: model.now) }
            Spacer(minLength: notch.width)
            if model.providers.count > 1 { Ear(provider: model.providers[1], now: model.now) }
        }
        .padding(.horizontal, 12).foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
}
