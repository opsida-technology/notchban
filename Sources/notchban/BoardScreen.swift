import AppKit
import NotchbanCore
import SwiftUI

/// The full board window: toolbar, seven columns (optionally in lanes), dependency curves,
/// the detail sheet and the command palette.
struct BoardScreen: View {
    @EnvironmentObject var model: Model
    @ObservedObject var state: BoardState
    /// Room kept free at the top for the notch.
    var inset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let columnWidth: CGFloat = 268, collapsedWidth: CGFloat = 40, gap: CGFloat = 20

    var body: some View {
        let board = model.board(state.path) ?? model.boards.first
        ZStack(alignment: .top) {
            Theme.canvas.ignoresSafeArea()
            LinearGradient(colors: [Theme.upstream.opacity(0.06), .clear, Theme.good.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            if let board {
                let graph = BoardGraph(board)
                VStack(spacing: 0) {
                    Toolbar(state: state, board: board, graph: graph)
                    if state.agents { AgentFlow(state: state).transition(.opacity) } else { content(board, graph) }
                }
                .padding(.top, inset)
                .ignoresSafeArea(edges: .top)
                HStack {
                    Spacer()
                    if state.detail, let id = state.selection, let card = board.card(id) {
                        DetailPanel(state: state, board: board, graph: graph, card: card)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.top, 84 + inset)
                if state.palette {
                    Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { state.palette = false }
                    PaletteView(state: state, board: board)
                        .padding(.top, 90 + inset)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            } else {
                ContentUnavailable()
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.84), value: state.detail)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: state.palette)
        .animation(.easeInOut(duration: 0.18), value: state.agents)
        .onAppear { if model.board(state.path) == nil { state.path = board?.path } }
    }

    private func content(_ board: Board, _ graph: BoardGraph) -> some View {
        let lanes = state.lanes(board, graph)
        let focus = Focus(graph: graph, selection: state.selection, critical: state.critical)
        let visible = lanes.reduce(into: [Column: Int]()) { acc, lane in
            for (c, cards) in lane.cells { acc[c, default: 0] += cards.count }
        }
        let shut = Set(Column.allCases.filter { state.collapsed.contains($0) || visible[$0, default: 0] == 0 })
        return GeometryReader { geo in
        // The open columns share the width, so all seven fit; below 190 points a column the board scrolls instead.
        let fit = (geo.size.width - 36 - Self.gap * 6 - CGFloat(shut.count) * Self.collapsedWidth) / CGFloat(max(7 - shut.count, 1))
        let column = min(max(fit, 190), Self.columnWidth)
        let width: (Column) -> CGFloat = { shut.contains($0) ? Self.collapsedWidth : column }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Self.gap) {
                        ForEach(Column.allCases, id: \.self) { c in
                            ColumnHeader(column: c, count: visible[c, default: 0], total: board.count(c),
                                         collapsed: width(c) == Self.collapsedWidth) { state.toggleCollapse(c) }
                                .frame(width: width(c))
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 22) {
                            if state.critical { CriticalBanner(graph: graph) }
                            ForEach(lanes) { lane in
                                LaneView(lane: lane, width: width, state: state, graph: graph, focus: focus, now: model.now)
                            }
                            if lanes.allSatisfy({ $0.count == 0 }) { NoMatches(state: state) }
                        }
                        .padding(.horizontal, 18).padding(.bottom, 40)
                        .backgroundPreferenceValue(CardAnchors.self) { anchors in
                            EdgeLayer(edges: focus.edges, anchors: anchors)
                                .id(focus.edges)
                        }
                    }
                }
            }
            .onChange(of: state.selection) { id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)) { proxy.scrollTo(id) }
            }
            .onChange(of: state.chain) { _ in
                guard let id = state.selection else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: state.grouping)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: state.filter)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: state.chain)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: state.critical)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: state.collapsed)
    }
}

struct ColumnHeader: View {
    let column: Column, count: Int, total: Int, collapsed: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            if collapsed {
                HStack(spacing: 3) {
                    Image(systemName: Theme.columnIcon(column)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.column(column))
                    Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(width: BoardScreen.collapsedWidth, height: 28)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 7) {
                    Image(systemName: Theme.columnIcon(column)).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.column(column))
                    Text(column.rawValue).font(.system(size: 12.5, weight: .semibold))
                    Text(count == total ? "\(total)" : "\(count) of \(total)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.well))
                    Spacer()
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand \(column.rawValue)" : "Collapse \(column.rawValue)")
        .accessibilityLabel("\(column.rawValue), \(count) cards")
    }
}

struct LaneView: View {
    let lane: Lane
    let width: (Column) -> CGFloat
    @ObservedObject var state: BoardState
    let graph: BoardGraph
    let focus: Focus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = lane.title {
                HStack(spacing: 8) {
                    Circle().fill(lane.tint ?? .secondary).frame(width: 8, height: 8)
                    Text(title).font(.system(size: 13, weight: .bold))
                    Text("\(lane.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    ProgressView(value: Double(lane.done), total: Double(max(lane.count, 1)))
                        .progressViewStyle(.linear).tint(lane.tint ?? .accentColor).frame(width: 80)
                    Text("\(lane.done) done").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 2)
            }
            HStack(alignment: .top, spacing: BoardScreen.gap) {
                ForEach(Column.allCases, id: \.self) { c in
                    let w = width(c)
                    VStack(spacing: 8) {
                        if w > BoardScreen.collapsedWidth {
                            ForEach(lane.cells[c] ?? []) { card in
                                CardView(card: card, graph: graph, now: now, role: focus.role(card.id))
                                    .id(card.id)
                                    .anchorPreference(key: CardAnchors.self, value: .bounds) { [card.id: $0] }
                                    .onTapGesture { select(card.id) }
                                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                            }
                        } else {
                            Text(c.rawValue.uppercased())
                                .font(.system(size: 9.5, weight: .bold)).kerning(1.4).foregroundStyle(.tertiary)
                                .fixedSize().rotationEffect(.degrees(90))
                                .frame(width: w, height: 120)
                        }
                    }
                    .frame(width: w, alignment: .top)
                    .frame(minHeight: 60, alignment: .top)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well).padding(-6))
                }
            }
        }
    }

    private func select(_ id: String) {
        if state.selection == id { state.detail.toggle() } else { state.selection = id; state.detail = true }
    }
}

struct NoMatches: View {
    @ObservedObject var state: BoardState
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No card matches").font(.headline)
            Button("Clear filters") { state.filter = CardFilter() }.buttonStyle(.link)
        }
        .frame(maxWidth: 600).padding(60)
    }
}

struct ContentUnavailable: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No KANBAN.md under \((model.root.path as NSString).abbreviatingWithTildeInPath)").font(.headline)
            Text("A board appears here the moment one is written.").foregroundStyle(.secondary)
            Button("Choose Another Folder…") { model.chooseRoot() }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CriticalBanner: View {
    let graph: BoardGraph
    var body: some View {
        let path = graph.criticalPath()
        let points = path.compactMap(graph.board.card).reduce(0) { $0 + $1.weight }
        HStack(spacing: 10) {
            Image(systemName: "flame.fill").font(.system(size: 15)).foregroundStyle(Theme.critical.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.isEmpty ? "No open dependency chain" : "Critical path · \(path.count) cards · \(points.formatted()) size points")
                    .font(.system(size: 13, weight: .bold))
                Text("The heaviest chain of open work, weighted by size (S 1 · M 2 · L 3 · XL 5). It sets the finish date.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.critical.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.critical.opacity(0.25), lineWidth: 0.5))
        .padding(.top, 4)
    }
}
