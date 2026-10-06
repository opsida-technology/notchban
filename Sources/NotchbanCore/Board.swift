import Foundation

/// The seven columns of a `KANBAN.md` (Squawk format, `<!-- squawk-kanban:v1 -->`).
public enum Column: String, CaseIterable, Sendable {
    case backlog = "Backlog", ready = "Ready", progress = "In Progress", review = "Human Review"
    case verified = "Verified", blocked = "Blocked", done = "Done"
}

public struct ChecklistItem: Equatable, Sendable {
    public let text: String
    public let done: Bool
}

public struct Card: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let column: Column
    public var owner: String? = nil
    public var task: String? = nil
    public var leaseExpires: Date? = nil
    public var after: [String] = []
    public var before: [String] = []
    public var checklist: [ChecklistItem] = []
    /// Our extensions of the Squawk metadata line.
    public var track: Int? = nil
    public var phase: Int? = nil
    public var size: String? = nil
    public var risk: String? = nil
    public var tier: Int? = nil
    public var gate: String? = nil
    /// `Proof: …` lines and the metadata's `proofs` ids.
    public var proof: [String] = []
    /// `Blocker: …`: why a card cannot move.
    public var blocker: String? = nil
    /// Everything else under the heading, as written.
    public var notes: String = ""

    public var checked: Int { checklist.filter(\.done).count }
    public var total: Int { checklist.count }

    /// A lease that ran out while the card is still In Progress: nobody is working on it.
    public func isStale(at date: Date = Date()) -> Bool {
        column == .progress && (leaseExpires.map { $0 < date } ?? true)
    }

    /// Relative effort of `size` (S=1, M=2, L=3, XL=5; a range like "S–M" averages its ends).
    public var weight: Double {
        let points: [String: Double] = ["XS": 0.5, "S": 1, "M": 2, "L": 3, "XL": 5]
        let parts = (size ?? "").uppercased().split(whereSeparator: { "–-/ ".contains($0) }).compactMap { points[String($0)] }
        return parts.isEmpty ? 1 : parts.reduce(0, +) / Double(parts.count)
    }
}

public struct Board: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let cards: [Card]

    public init(path: String, name: String, cards: [Card]) {
        self.path = path; self.name = name; self.cards = cards
    }

    public func count(_ column: Column) -> Int { cards.filter { $0.column == column }.count }
    public func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    /// Predecessors that are not Done: what a card still waits for.
    public func open(_ ids: [String]) -> [Card] { ids.compactMap(card).filter { $0.column != .done } }
    public func stale(at date: Date = Date()) -> [Card] { cards.filter { $0.isStale(at: date) } }
}

public enum BoardParser {
    /// Reads one board. Tolerant: a card without metadata, without ids in `after`/`before`, or with a
    /// heading that has no "ID — " prefix is still listed. Returns nil when it is not a Kanban file.
    public static func parse(_ text: String, path: String) -> Board? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "# Kanban" else { return nil }
        var column: Column?
        var cards: [Card] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("## ") {
                column = Column(rawValue: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }
            guard line.hasPrefix("### "), let current = column else { i += 1; continue }
            var j = i + 1
            while j < lines.count, !lines[j].hasPrefix("## "), !lines[j].hasPrefix("### ") { j += 1 }
            cards.append(card(heading: String(line.dropFirst(4)), body: lines[(i + 1)..<j], column: current))
            i = j
        }
        return Board(path: path, name: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
                     cards: cards)
    }

    static func card(heading: String, body: ArraySlice<String>, column: Column) -> Card {
        let parts = heading.components(separatedBy: " — ")
        let id = parts.count >= 2 ? parts[0].trimmingCharacters(in: .whitespaces) : heading
        let title = parts.count >= 2 ? parts.dropFirst().joined(separator: " — ") : heading
        var card = Card(id: id, title: title, column: column)
        var notes: [String] = []
        for raw in body {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("<!-- squawk:"), l.hasSuffix("-->"), let meta = metadata(l) {
                apply(meta, to: &card)
            } else if l.hasPrefix("- [ ] ") {
                card.checklist.append(ChecklistItem(text: String(l.dropFirst(6)), done: false))
            } else if l.lowercased().hasPrefix("- [x] ") {
                card.checklist.append(ChecklistItem(text: String(l.dropFirst(6)), done: true))
            } else if l.hasPrefix("Proof:") {
                card.proof.append(String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            } else if l.hasPrefix("Blocker:") {
                card.blocker = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if !(l.isEmpty && notes.last?.isEmpty ?? true) {
                notes.append(l.isEmpty ? "" : raw)
            }
        }
        card.notes = notes.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return card
    }

    static func metadata(_ line: String) -> [String: Any]? {
        let json = line.dropFirst(12).dropLast(3).trimmingCharacters(in: .whitespaces)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    static func apply(_ meta: [String: Any], to card: inout Card) {
        func int(_ key: String) -> Int? { (meta[key] as? Int) ?? (meta[key] as? String).flatMap { Int($0) } }
        let lease = meta["lease"] as? [String: Any]
        card.owner = meta["owner"] as? String ?? lease?["holder"] as? String
        card.task = meta["task"] as? String
        card.leaseExpires = (lease?["expiresAt"] as? String).flatMap(ISO8601DateFormatter().date)
        card.after = meta["after"] as? [String] ?? []
        card.before = meta["before"] as? [String] ?? []
        card.track = int("track")
        card.phase = int("phase")
        card.tier = int("tier")
        card.size = meta["size"] as? String
        card.risk = meta["risk"] as? String
        card.gate = meta["gate"] as? String
        card.proof += meta["proofs"] as? [String] ?? []
    }
}
