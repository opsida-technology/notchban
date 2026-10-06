import NotchbanCore
import SwiftUI

/// ⌘K: jump to any card on any board, switch boards, or run a view command, by fuzzy search.
struct PaletteView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var state: BoardState
    let board: Board
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let run: () -> Void
    }

    var body: some View {
        let items = results()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("Jump to a card, a board or a command", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { if items.indices.contains(state.paletteIndex) { run(items[state.paletteIndex]) } }
            }
            .padding(.horizontal, 16).frame(height: 52)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == state.paletteIndex).id(i)
                                .onTapGesture { run(item) }
                        }
                        if items.isEmpty {
                            Text("Nothing matches “\(query)”").foregroundStyle(.secondary).padding(24)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .onChange(of: state.paletteIndex) { proxy.scrollTo($0) }
            }
            HStack(spacing: 14) {
                Hint(keys: "↑↓", text: "move"); Hint(keys: "↩", text: "open"); Hint(keys: "esc", text: "close")
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 30)
            .background(Theme.well)
        }
        .frame(width: 600)
        .background(Glass(material: .popover, blending: .withinWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .onAppear { focused = true; state.paletteIndex = 0; state.paletteCount = items.count }
        .onChange(of: query) { _ in state.paletteIndex = 0; state.paletteCount = results().count }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).foregroundStyle(item.tint).frame(width: 18)
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func run(_ item: Item) {
        item.run()
        state.palette = false
    }

    private func results() -> [Item] {
        var scored: [(Int, Item)] = []
        func add(_ item: Item, _ text: String, bonus: Int = 0) {
            if query.isEmpty { scored.append((bonus, item)) } else if let s = Fuzzy.score(query, text) { scored.append((s + bonus, item)) }
        }
        let commands: [(String, String, () -> Void)] = [
            ("Group by status", "rectangle.split.3x1", { state.grouping = .status }),
            ("Group by track", "point.3.connected.trianglepath.dotted", { state.grouping = .track }),
            ("Group by phase", "flag", { state.grouping = .phase }),
            (state.critical ? "Hide critical path" : "Show critical path", "flame", { state.critical.toggle() }),
            (state.filter.actionable ? "Show every card" : "Only ready & unblocked", "bolt.fill", { state.filter.actionable.toggle() }),
            ("Clear filters", "line.3.horizontal.decrease.circle", { state.filter = CardFilter() }),
        ]
        for (title, icon, action) in commands { add(Item(id: "cmd:" + title, icon: icon, tint: .secondary, title: title, detail: "Command", run: action), title, bonus: 30) }
        for b in model.boards {
            add(Item(id: "board:" + b.path, icon: "square.grid.3x1.below.line.grid.1x2", tint: .accentColor, title: b.name,
                     detail: "\(b.cards.count) cards · board", run: { state.show(b.path) }), b.name, bonus: 20)
        }
        if !query.isEmpty {
            for b in model.boards {
                for card in b.cards {
                    let here = b.path == board.path
                    add(Item(id: b.path + "#" + card.id, icon: Theme.columnIcon(card.column), tint: Theme.column(card.column),
                             title: "\(card.id)  \(card.title)", detail: here ? card.column.rawValue : "\(b.name) · \(card.column.rawValue)",
                             run: { state.show(b.path); state.selection = card.id; state.detail = true }),
                        "\(card.id) \(card.title)", bonus: here ? 10 : 0)
                }
            }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(40).map(\.1)
    }
}

struct Hint: View {
    let keys: String, text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.well))
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}
