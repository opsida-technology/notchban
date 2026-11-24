import Foundation

/// The owner's verdict on a Human Review card.
public enum Verdict: String, Codable, CaseIterable, Sendable {
    /// Checked and finished: to Done.
    case done
    /// The gated step may go ahead (merge, deploy, send): back to Ready for an agent.
    case approved
    /// Not right yet; the note says what to fix: back to Ready.
    case changes
    /// Parked; the note is the blocker: to Blocked.
    case hold

    public var needsNote: Bool { self == .changes || self == .hold }
}

/// What the owner does to a board from the phone (or the Mac). `board` is the board's path on the Mac, which applies
/// the command to that trunk `KANBAN.md`; the file stays the only truth.
public enum BoardCommand: Codable, Equatable, Sendable {
    /// A card the owner typed in: `"source": "human"`, on top of its column.
    case add(board: String, title: String, notes: String, column: Column)
    case review(board: String, card: String, verdict: Verdict, note: String)
    case note(board: String, card: String, text: String)
    /// The owner's review day for a card; nil clears it.
    case due(board: String, card: String, day: String?)
    /// The name the board shows instead of its folder's. Kept by the Mac, not written into the file.
    case rename(board: String, name: String)

    public var board: String {
        switch self {
        case .add(let b, _, _, _), .review(let b, _, _, _), .note(let b, _, _), .due(let b, _, _), .rename(let b, _): b
        }
    }
}

/// Edits a board's text in place, touching only the lines a command is about.
public enum BoardEditor {
    public enum Failure: Error, Equatable {
        case notABoard, noColumn(Column), noCard(String), notInReview(String), emptyText, badDay(String)
    }

    /// The new text, and the id of the card it added (for `.add`). `person` signs review and note lines; `today` is
    /// YYYY-MM-DD in the owner's time zone. A command about a card that moved meanwhile fails rather than guess.
    public static func apply(_ command: BoardCommand, to text: String, by person: String, today: String) throws -> (text: String, added: String?) {
        guard text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) == "# Kanban" else { throw Failure.notABoard }
        var lines = text.components(separatedBy: "\n")
        switch command {
        case .rename:
            return (text, nil)

        case let .add(board, title, notes, column):
            let title = oneLine(title)
            guard !title.isEmpty else { throw Failure.emptyText }
            let id = nextID(lines, folder: URL(fileURLWithPath: board).deletingLastPathComponent().lastPathComponent)
            var block = ["### \(id) — \(title)", meta(nil, [("source", "human"), ("created", today)])]
            let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { block += [""] + body.components(separatedBy: "\n") }
            try insert(block, at: column, in: &lines)
            return (lines.joined(separator: "\n"), id)

        case let .review(_, id, verdict, note):
            let note = oneLine(note)
            if verdict.needsNote && note.isEmpty { throw Failure.emptyText }
            guard let at = column(of: id, in: text) else { throw Failure.noCard(id) }
            guard at == .review else { throw Failure.notInReview(id) }
            var block = try take(id, from: &lines)
            setMeta(&block, [("due", nil), ("owner", nil), ("task", nil), ("lease", nil)])
            append(&block, "Review (\(person), \(today)): \(verdict.rawValue)" + (note.isEmpty ? "" : " — \(note)"))
            if verdict == .hold { append(&block, "Blocker: \(note)") }
            let to: Column = switch verdict { case .done: .done; case .approved, .changes: .ready; case .hold: .blocked }
            try insert(block, at: to, in: &lines)
            return (lines.joined(separator: "\n"), nil)

        case let .note(_, id, text):
            let text = oneLine(text)
            guard !text.isEmpty else { throw Failure.emptyText }
            try edit(id, in: &lines) { append(&$0, "Note (\(person), \(today)): \(text)") }
            return (lines.joined(separator: "\n"), nil)

        case let .due(_, id, day):
            if let day, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil { throw Failure.badDay(day) }
            try edit(id, in: &lines) { setMeta(&$0, [("due", day)]) }
            return (lines.joined(separator: "\n"), nil)
        }
    }

    // MARK: blocks

    /// The lines of card `id`, from its heading up to the next card or column heading.
    private static func range(of id: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0 == "### \(id)" || $0.hasPrefix("### \(id) — ") }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("### ") || $0.hasPrefix("## ") } ?? lines.count
        return start..<end
    }

    private static func column(of id: String, in text: String) -> Column? {
        BoardParser.parse(text, path: "")?.card(id)?.column
    }

    private static func edit(_ id: String, in lines: inout [String], _ change: (inout [String]) -> Void) throws {
        guard let r = range(of: id, in: lines) else { throw Failure.noCard(id) }
        var block = Array(lines[r])
        change(&block)
        lines.replaceSubrange(r, with: block)
    }

    private static func take(_ id: String, from lines: inout [String]) throws -> [String] {
        guard let r = range(of: id, in: lines) else { throw Failure.noCard(id) }
        let block = Array(lines[r])
        lines.removeSubrange(r)
        return block
    }

    /// Puts a card on top of a column, one blank line on each side.
    private static func insert(_ block: [String], at column: Column, in lines: inout [String]) throws {
        guard let header = lines.firstIndex(of: "## \(column.rawValue)") else { throw Failure.noColumn(column) }
        var block = block
        while block.last?.isEmpty == true { block.removeLast() }
        var at = header + 1
        while at < lines.count, lines[at].isEmpty { at += 1 }
        lines.replaceSubrange(header + 1..<at, with: [""] + block + [""])
    }

    /// Adds a line at the end of a card, after its last written line.
    private static func append(_ block: inout [String], _ line: String) {
        var end = block.count
        while end > 1, block[end - 1].isEmpty { end -= 1 }
        let last = block[end - 1]
        // a list or a metadata line is not run on into: a note starts its own paragraph
        let gap = end == 1 || last.hasPrefix("<!--") || last.hasPrefix("- [")
        block.insert(contentsOf: (gap ? [""] : []) + [line], at: end)
    }

    // MARK: metadata

    private static func setMeta(_ block: inout [String], _ changes: [(String, Any?)]) {
        if let i = block.firstIndex(where: { $0.hasPrefix("<!-- squawk:") }) {
            block[i] = meta(block[i], changes)
        } else if changes.contains(where: { $0.1 != nil }) {
            block.insert(meta(nil, changes), at: 1)
        }
    }

    /// The metadata line with `changes` made (nil removes a key), keeping the line's key order and its spacing.
    static func meta(_ old: String?, _ changes: [(String, Any?)]) -> String {
        var values = old.flatMap(BoardParser.metadata) ?? [:]
        let json = old ?? ""
        var order = values.keys.sorted {
            (json.range(of: "\"\($0)\"")?.lowerBound ?? json.endIndex) < (json.range(of: "\"\($1)\"")?.lowerBound ?? json.endIndex)
        }
        for (key, value) in changes {
            if let value {
                if values[key] == nil { order.append(key) }
                values[key] = value
            } else {
                values[key] = nil
                order.removeAll { $0 == key }
            }
        }
        let spaced = json.contains("\": ")
        let body = order.map { key in
            let data = try? JSONSerialization.data(withJSONObject: values[key]!, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys])
            return "\"\(key)\"\(spaced ? ": " : ":")" + (data.map { String(decoding: $0, as: UTF8.self) } ?? "null")
        }.joined(separator: spaced ? ", " : ",")
        return "<!-- squawk:{\(body)} -->"
    }

    // MARK: ids

    /// The board's own id scheme, one higher: after AB-49 comes AB-50, after KB-02 KB-03. A board with no ids yet
    /// takes the folder's first two letters (notchban → NO-1).
    static func nextID(_ lines: [String], folder: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"^### ([A-Za-z][A-Za-z0-9]*[-_])(\d+)(?: — |$)"#)
        var found: [String: (max: Int, width: Int, count: Int)] = [:]
        for line in lines {
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let p = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line), let value = Int(line[n]) else { continue }
            let prefix = String(line[p]), old = found[prefix] ?? (0, 0, 0)
            found[prefix] = (max(old.max, value), max(old.width, line[n].count), old.count + 1)
        }
        guard let (prefix, best) = found.max(by: { $0.value.count < $1.value.count }).map({ ($0.key, $0.value) }) else {
            return String(folder.filter(\.isLetter).prefix(2)).uppercased().padding(toLength: 2, withPad: "X", startingAt: 0) + "-1"
        }
        let number = String(best.max + 1)
        return prefix + String(repeating: "0", count: max(0, best.width - number.count)) + number
    }

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
