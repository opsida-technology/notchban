import NotchbanCore
import SwiftUI

/// Each card reports its frame, so the board can draw dependency curves between them.
struct CardAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct Edge: Hashable {
    enum Kind { case upstream, downstream, critical }
    let from: String, to: String, kind: Kind
    var colour: Color {
        switch kind {
        case .upstream: Theme.upstream
        case .downstream: Theme.downstream
        case .critical: Theme.critical
        }
    }
}

/// What the focus lights up: card roles and the edges to draw.
struct Focus {
    var roles: [String: Role] = [:]
    var edges: [Edge] = []

    init(graph: BoardGraph, selection: String?, critical: Bool) {
        if critical {
            let path = graph.criticalPath()
            for (i, id) in path.enumerated() { roles[id] = .critical(i + 1) }
            edges = zip(path, path.dropFirst()).map { Edge(from: $0, to: $1, kind: .critical) }
            if !path.isEmpty { roles = roles.merging(dimRest(graph, Set(path))) { a, _ in a } }
            if let selection, !path.contains(selection) { roles[selection] = .selected }
            return
        }
        guard let selection else { return }
        roles[selection] = .selected
        let up = graph.upstream(of: selection), down = graph.downstream(of: selection)
        guard !up.isEmpty || !down.isEmpty else { return }
        up.forEach { roles[$0] = .upstream }
        down.forEach { roles[$0] = .downstream }
        roles = roles.merging(dimRest(graph, up.union(down).union([selection]))) { a, _ in a }
        for (a, targets) in graph.successors {
            for b in targets {
                if up.contains(a), up.contains(b) || b == selection { edges.append(Edge(from: a, to: b, kind: .upstream)) }
                if down.contains(b), down.contains(a) || a == selection { edges.append(Edge(from: a, to: b, kind: .downstream)) }
            }
        }
    }

    private func dimRest(_ graph: BoardGraph, _ keep: Set<String>) -> [String: Role] {
        Dictionary(uniqueKeysWithValues: graph.board.cards.filter { !keep.contains($0.id) }.map { ($0.id, Role.dimmed) })
    }

    func role(_ id: String) -> Role { roles[id] ?? .plain }
}

/// Curves from each predecessor to the card that waits for it, dashed, the dot at the waiting end. Drawn still: an animated
/// dash redraws the whole board-sized layer every frame.
struct EdgeLayer: View {
    let edges: [Edge]
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(edges, id: \.self) { edge in
                    if let a = anchors[edge.from], let b = anchors[edge.to] {
                        let curve = Curve(from: proxy[a], to: proxy[b])
                        curve.stroke(edge.colour.opacity(0.22), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        curve.stroke(edge.colour, style: StrokeStyle(lineWidth: 1.8, lineCap: .round,
                                                                    dash: [7, 5]))
                        Circle().fill(edge.colour).frame(width: 7, height: 7).position(curve.end)
                        Circle().strokeBorder(edge.colour, lineWidth: 1.5).background(Circle().fill(Theme.card))
                            .frame(width: 8, height: 8).position(curve.start)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A cubic from one card's side to the other's: left-to-right, right-to-left, or a loop on the right
/// when both sit in the same column.
struct Curve: Shape {
    let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint

    init(from a: CGRect, to b: CGRect) {
        if b.minX > a.maxX + 4 {
            start = CGPoint(x: a.maxX, y: a.midY); end = CGPoint(x: b.minX, y: b.midY)
        } else if b.maxX < a.minX - 4 {
            start = CGPoint(x: a.minX, y: a.midY); end = CGPoint(x: b.maxX, y: b.midY)
        } else {
            start = CGPoint(x: a.maxX, y: a.midY); end = CGPoint(x: b.maxX, y: b.midY)
            let bulge = min(28, 12 + abs(end.y - start.y) * 0.04)  // stays in the gutter
            c1 = CGPoint(x: start.x + bulge, y: start.y); c2 = CGPoint(x: end.x + bulge, y: end.y)
            return
        }
        let dx = max(abs(end.x - start.x) * 0.5, 30) * (end.x > start.x ? 1 : -1)
        c1 = CGPoint(x: start.x + dx, y: start.y); c2 = CGPoint(x: end.x - dx, y: end.y)
    }

    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: start); p.addCurve(to: end, control1: c1, control2: c2) }
    }
}
