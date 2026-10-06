import Foundation

/// The dependency graph of one board. An edge `a → b` means "b waits for a"; it comes from either
/// `b.after` containing `a` or `a.before` containing `b`, so a board may write it on one side only.
public struct BoardGraph: Sendable {
    public let board: Board
    public let predecessors: [String: [String]]
    public let successors: [String: [String]]

    public init(_ board: Board) {
        self.board = board
        let known = Set(board.cards.map(\.id))
        var pre: [String: Set<String>] = [:], suc: [String: Set<String>] = [:]
        func link(_ a: String, _ b: String) {
            guard a != b, known.contains(a), known.contains(b) else { return }
            suc[a, default: []].insert(b); pre[b, default: []].insert(a)
        }
        for card in board.cards {
            card.after.forEach { link($0, card.id) }
            card.before.forEach { link(card.id, $0) }
        }
        let order = Dictionary(uniqueKeysWithValues: board.cards.enumerated().map { ($1.id, $0) })
        func sorted(_ s: Set<String>) -> [String] { s.sorted { order[$0, default: 0] < order[$1, default: 0] } }
        predecessors = pre.mapValues(sorted)
        successors = suc.mapValues(sorted)
    }

    /// Every card `id` transitively waits for.
    public func upstream(of id: String) -> Set<String> { closure(id, predecessors) }
    /// Every card that transitively waits for `id`.
    public func downstream(of id: String) -> Set<String> { closure(id, successors) }

    /// Predecessors not Done yet.
    public func waitsFor(_ id: String) -> [String] {
        (predecessors[id] ?? []).filter { board.card($0)?.column != .done }
    }

    /// `gate: tier0` holds a card until every Tier 0 card is Done.
    public func gateOpen(_ card: Card) -> Bool {
        guard card.gate == "tier0" else { return true }
        return !board.cards.contains { $0.tier == 0 && $0.column != .done }
    }

    /// Ready, nothing open before it, and its gate is open: a card someone can take now.
    public func isActionable(_ card: Card) -> Bool {
        card.column == .ready && waitsFor(card.id).isEmpty && gateOpen(card)
    }

    /// The heaviest chain of cards not Done yet, weighted by size: the work that sets the finish date.
    /// Edges into Done cards are ignored; a cycle is cut where it closes.
    static let maxCriticalCards = 2000

    public func criticalPath() -> [String] {
        let open = Set(board.cards.filter { $0.column != .done }.map(\.id))
        // a hostile file could chain thousands of cards and the walk is recursive: real boards are far smaller
        guard open.count <= BoardGraph.maxCriticalCards else { return [] }
        var best: [String: (Double, [String])] = [:]
        var visiting: Set<String> = []
        func longest(from id: String) -> (Double, [String]) {
            if let hit = best[id] { return hit }
            visiting.insert(id)
            var tail: (Double, [String]) = (0, [])
            for next in successors[id] ?? [] where open.contains(next) && !visiting.contains(next) {
                let candidate = longest(from: next)
                if candidate.0 > tail.0 { tail = candidate }
            }
            visiting.remove(id)
            let result = ((board.card(id)?.weight ?? 1) + tail.0, [id] + tail.1)
            best[id] = result
            return result
        }
        var winner: (Double, [String]) = (0, [])
        for card in board.cards where open.contains(card.id) {
            let candidate = longest(from: card.id)
            if candidate.1.count > 1, candidate.0 > winner.0 { winner = candidate }
        }
        return winner.1
    }

    private func closure(_ id: String, _ edges: [String: [String]]) -> Set<String> {
        var seen: Set<String> = [], stack = edges[id] ?? []
        while let next = stack.popLast() {
            if next != id, seen.insert(next).inserted { stack += edges[next] ?? [] }
        }
        return seen
    }
}
