import SwiftUI

struct DialOption: Identifiable, Equatable {
    let path: String?
    let title: String
    let count: Int
    var id: String { path ?? "" }
}

/// A modal dial: the names stand in a column on the left, a ruler of ticks curves down the right edge, and a pointer
/// marks the chosen one. Drag up or down and it turns, settling on the nearest name; tap a name to turn to it.
struct ProjectDial: View {
    let title: String
    let options: [DialOption]
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the dial is, in names (1.5 = halfway between the second and third); follows the finger.
    @State private var pos: Double = 0
    @State private var dragStart: Double?

    private let row: CGFloat = 50
    private let radius: CGFloat = 200
    private let edge: CGFloat = 36

    private var index: Int { options.firstIndex { $0.path == selection } ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, cy = geo.size.height / 2
            ZStack {
                ForEach(-60...60, id: \.self) { t in tick(t, w: w, cy: cy) }
                ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                    if abs(Double(i) - pos) < 3.4 { pill(i, option, w: w, cy: cy) }
                }
                pointer.position(x: w - edge - 34, y: cy)
            }
            .frame(width: w, height: geo.size.height)
            .overlay(alignment: .top) { header }
            .contentShape(Rectangle())
            .gesture(drag(max: options.count - 1))
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { pos = Double(index) }
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(options[index].title)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: settle(min(index + 1, options.count - 1))
            case .decrement: settle(max(index - 1, 0))
            @unknown default: break
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.fg3)
            Spacer()
            Button("Done") { dismiss() }.font(Theme.font(15, .semibold)).foregroundStyle(Theme.indigo.text)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var pointer: some View {
        HStack(spacing: 4) {
            Capsule().fill(Theme.review.fill).frame(width: 26, height: 2)
            Image(systemName: "arrowtriangle.left.fill").font(.system(size: 9)).foregroundStyle(Theme.fg)
        }
        .accessibilityHidden(true)
    }

    /// One mark of the ruler; every fifth is longer. The ruler is a circle seen from the left, so marks fan out.
    @ViewBuilder
    private func tick(_ t: Int, w: CGFloat, cy: CGFloat) -> some View {
        let a = (Double(t) / 5 - pos) * Double(row / radius)
        if abs(a) < 1.15 {
            Capsule().fill(Theme.fg.opacity(max(0.08, 0.75 - abs(a) * 0.65)))
                .frame(width: t % 5 == 0 ? 17 : 10, height: 2)
                .rotationEffect(.radians(a))
                .position(x: w - edge - radius * (1 - CGFloat(cos(a))) - 8, y: cy + radius * CGFloat(sin(a)))
                .accessibilityHidden(true)
        }
    }

    private func pill(_ i: Int, _ option: DialOption, w: CGFloat, cy: CGFloat) -> some View {
        let d = Double(i) - pos
        let near = abs(d) < 0.5
        return Button { settle(i) } label: {
            HStack(spacing: 10) {
                Text("\(option.count)").font(Theme.font(13, .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Circle().fill(near ? Theme.review.fill : Theme.surface))
                Text(option.title).font(Theme.font(17, .semibold)).foregroundStyle(near ? Theme.fg : Theme.fg2).lineLimit(1)
            }
            .padding(.leading, 6).padding(.trailing, 16).frame(height: 42)
            .background(Capsule().fill(Theme.fg.opacity(near ? 0.14 : 0.07)))
        }
        .buttonStyle(.plain)
        .scaleEffect(1 - min(abs(d), 3) * 0.07, anchor: .leading)
        .opacity(max(0, 1 - abs(d) * 0.3))
        .padding(.leading, 20 - CGFloat(d * d) * 5)
        .frame(width: w, alignment: .leading)
        .position(x: w / 2, y: cy + CGFloat(d) * row)
        .accessibilityHidden(true)
    }

    private func drag(max last: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { g in
                let start = dragStart ?? pos
                dragStart = start
                pos = min(max(start - Double(g.translation.height / row), 0), Double(last))
                let near = Int(pos.rounded())
                if options[near].path != selection { selection = options[near].path }
            }
            .onEnded { g in
                let end = (dragStart ?? pos) - Double((g.translation.height + g.velocity.height * 0.12) / row)
                dragStart = nil
                settle(Int(min(max(end.rounded(), 0), Double(last))))
            }
    }

    private func settle(_ i: Int) {
        selection = options[i].path
        if reduceMotion { pos = Double(i) } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pos = Double(i) } }
    }
}
