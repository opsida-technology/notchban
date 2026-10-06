import AppKit
import NotchbanCore
import SwiftUI

enum Grouping: String, CaseIterable, Identifiable {
    case status = "Status", track = "Track", phase = "Phase"
    var id: String { rawValue }
}

/// One swimlane: a group of cards laid out across the seven columns.
struct Lane: Identifiable {
    let id: String
    let title: String?
    let tint: Color?
    let cells: [Column: [Card]]
    var count: Int { cells.values.reduce(0) { $0 + $1.count } }
    var done: Int { cells[.done]?.count ?? 0 }
}

/// What the board window shows and where the keyboard is. Never touches the file.
@MainActor
final class BoardState: ObservableObject {
    /// The board last shown, kept across launches: the notch opens on it.
    @Published var path: String? = UserDefaults.standard.string(forKey: "lastBoard") {
        didSet { UserDefaults.standard.set(path, forKey: "lastBoard") }
    }
    @Published var selection: String?
    @Published var detail = false
    @Published var filter = CardFilter()
    @Published var grouping = Grouping.status
    @Published var critical = false
    /// The board's second screen: the working agents instead of the columns.
    @Published var agents = false
    /// Show only the selected card and everything it waits for or unlocks.
    @Published var chain = false
    @Published var palette = false
    @Published var collapsed: Set<Column> = []
    @Published var focusSearch = false
    @Published var paletteIndex = 0
    var paletteCount = 0

    func lanes(_ board: Board, _ graph: BoardGraph) -> [Lane] {
        var visible = board.cards.filter { filter.matches($0, in: graph) }
        if critical {
            let path = Set(graph.criticalPath())
            visible = visible.filter { path.contains($0.id) }
        } else if chain, let sel = selection {
            let keep = graph.upstream(of: sel).union(graph.downstream(of: sel)).union([sel])
            visible = visible.filter { keep.contains($0.id) }
        }
        func lane(_ id: String, _ title: String?, _ tint: Color?, _ cards: [Card]) -> Lane {
            Lane(id: id, title: title, tint: tint, cells: Dictionary(grouping: cards, by: \.column))
        }
        switch grouping {
        case .status:
            return [lane("all", nil, nil, visible)]
        case .track, .phase:
            let key: (Card) -> Int? = grouping == .track ? { $0.track } : { $0.phase }
            let groups = Dictionary(grouping: visible, by: key)
            return groups.keys.sorted { ($0 ?? .max) < ($1 ?? .max) }.map { k in
                let name = k.map { "\(grouping.rawValue) \($0)" } ?? "No \(grouping.rawValue.lowercased())"
                return lane("\(grouping.rawValue)-\(k ?? -1)", name, Theme.track(k), groups[k] ?? [])
            }
        }
    }

    /// Columns in reading order with their visible cards, lanes stacked: what j/k/h/l walk.
    func columns(_ board: Board, _ graph: BoardGraph) -> [(Column, [Card])] {
        let lanes = lanes(board, graph)
        return Column.allCases.filter { !collapsed.contains($0) }.map { c in (c, lanes.flatMap { $0.cells[c] ?? [] }) }
    }

    func move(_ dx: Int, _ dy: Int, _ board: Board, _ graph: BoardGraph) {
        let cols = columns(board, graph).filter { !$0.1.isEmpty }
        guard !cols.isEmpty else { return }
        guard let sel = selection, let ci = cols.firstIndex(where: { $0.1.contains { $0.id == sel } }),
              let ri = cols[ci].1.firstIndex(where: { $0.id == sel }) else {
            selection = cols[0].1[0].id; return
        }
        if dy != 0 {
            let cards = cols[ci].1
            selection = cards[min(max(ri + dy, 0), cards.count - 1)].id
        } else {
            let target = cols[min(max(ci + dx, 0), cols.count - 1)].1
            selection = target[min(ri, target.count - 1)].id
        }
    }

    func toggleCollapse(_ c: Column) {
        if collapsed.contains(c) { collapsed.remove(c) } else { collapsed.insert(c) }
    }

    /// The window's keys. Returns true when it used the event.
    func handle(_ event: NSEvent, board: Board?, boards: [Board], textFocused: Bool) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode
        if cmd, key == "k" { palette.toggle(); return true }
        if cmd, key == "q" { NSApp.terminate(nil); return true }  // no Dock icon and no menu bar: the board is the only way out
        if code == 53 { return escape(textFocused) }
        if palette {
            guard code == 125 || code == 126, paletteCount > 0 else { return false }
            paletteIndex = min(max(paletteIndex + (code == 125 ? 1 : -1), 0), paletteCount - 1)
            return true
        }
        if cmd { return false }
        if textFocused {
            if code == 36 || code == 125 { focusSearch = false; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            return false
        }
        guard let board else { return false }
        let graph = BoardGraph(board)
        switch (key, code) {
        case ("j", _), (_, 125): move(0, 1, board, graph)
        case ("k", _), (_, 126): move(0, -1, board, graph)
        case ("h", _), (_, 123): move(-1, 0, board, graph)
        case ("l", _), (_, 124): move(1, 0, board, graph)
        case ("/", _): focusSearch = true
        case (" ", _), (_, 36): if selection != nil { detail.toggle() } else { move(0, 0, board, graph) }
        case ("g", _):
            let all = Grouping.allCases
            grouping = all[(all.firstIndex(of: grouping)! + 1) % all.count]
        case ("c", _): critical.toggle()
        case ("a", _): agents.toggle()
        case ("f", _): if selection != nil { chain.toggle() }
        case ("r", _): filter.actionable.toggle()
        case ("[", _), ("]", _):
            guard let i = boards.firstIndex(where: { $0.path == board.path }), boards.count > 1 else { return true }
            show(boards[(i + (key == "]" ? 1 : boards.count - 1)) % boards.count].path)
        default: return false
        }
        return true
    }

    /// Opens a card of any board in the board view, its detail beside it.
    func open(_ card: String, on board: String) {
        agents = false
        show(board)
        selection = card
        detail = true
    }

    func show(_ board: String) {
        guard board != path else { return }
        path = board
        selection = nil
        detail = false
        chain = false
        filter = CardFilter()
    }

    private func escape(_ textFocused: Bool) -> Bool {
        if palette { palette = false }
        else if agents && !textFocused { agents = false }
        else if textFocused || !filter.text.isEmpty { filter.text = ""; focusSearch = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        else if chain { chain = false }
        else if detail { detail = false }
        else if critical { critical = false }
        else if selection != nil { selection = nil }
        else if !filter.isEmpty { filter = CardFilter() }
        else { return false }
        return true
    }
}
