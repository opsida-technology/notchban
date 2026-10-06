import Foundation

/// What the board window shows. Empty fields match everything.
public struct CardFilter: Equatable, Sendable {
    public var text = ""
    public var owner: String?
    public var track: Int?
    public var risk: String?
    /// Only cards someone can take now (`BoardGraph.isActionable`).
    public var actionable = false

    public init() {}

    public var isEmpty: Bool { self == CardFilter() }

    public func matches(_ card: Card, in graph: BoardGraph) -> Bool {
        if let owner, card.owner != owner { return false }
        if let track, card.track != track { return false }
        if let risk, card.risk != risk { return false }
        if actionable, !graph.isActionable(card) { return false }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [card.id, card.title, card.owner ?? "", card.blocker ?? ""].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

public enum Fuzzy {
    /// A subsequence match score, higher is better; nil when `query` is not a subsequence of `text`.
    /// Consecutive letters and letters at word starts score more, so "hd1" finds "HD-01" first.
    public static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace }), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, run = 0, last = -1
        for (ti, ch) in t.enumerated() where qi < q.count {
            guard ch == q[qi] else { run = 0; continue }
            run += 1
            let wordStart = ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber)
            score += 1 + run * 2 + (wordStart ? 6 : 0) - (last < 0 ? 0 : min(ti - last - 1, 5))
            last = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - t.count / 20 + (String(t).contains(String(q)) ? 15 : 0)
    }
}
