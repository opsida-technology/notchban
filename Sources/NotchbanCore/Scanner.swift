import Foundation

public enum Scanner {
    static let maxBytes = 4_000_000
    static let skipped: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData", "Pods", ".venv", "_archive"]

    /// Every `KANBAN.md` up to `depth` folders under `root`, parsed, boards with work first.
    public static func boards(under root: URL, depth: Int = 3) -> [Board] {
        var found: [Board] = []
        walk(root, depth, &found)
        return oneBoardPerRepository(found).sorted { ($0.count(.progress), $0.count(.blocked)) > ($1.count(.progress), $1.count(.blocked)) }
    }

    /// A repository and its git worktrees hold one KANBAN.md each. The board is the trunk checkout's own copy, as it is
    /// on the disk (claims are committed there, pushed or not); a worktree's copy counts only when the trunk has none.
    static func oneBoardPerRepository(_ boards: [Board]) -> [Board] {
        var groups: [String: [Board]] = [:]
        for board in boards { groups[repositoryRoot(of: board.path), default: []].append(board) }
        return groups.map { root, members in
            let board = members.first(where: { URL(fileURLWithPath: $0.path).deletingLastPathComponent()
                .resolvingSymlinksInPath().path == root }) ?? members.max { modified($0.path) < modified($1.path) }!
            return Board(path: board.path, name: URL(fileURLWithPath: root).lastPathComponent, cards: board.cards)
        }
    }

    private static func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date) ?? .distantPast
    }

    /// The folder holding the real `.git` directory: a worktree's `.git` file points back at it.
    static func repositoryRoot(of file: String) -> String {
        let dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        let git = dir.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:"),
              let range = text.range(of: "/.git/worktrees/") else { return dir.resolvingSymlinksInPath().path }
        let root = String(text[text.index(text.startIndex, offsetBy: 7)..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    /// One board, or nil when it is gone, too big to be a board, or not a board.
    public static func board(at file: URL) -> Board? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int, size <= maxBytes,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return BoardParser.parse(text, path: file.path)
    }

    private static func walk(_ dir: URL, _ depth: Int, _ out: inout [Board]) {
        let manager = FileManager.default
        if let board = board(at: dir.appendingPathComponent("KANBAN.md")) { out.append(board) }
        guard depth > 0, let entries = try? manager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for entry in entries where !skipped.contains(entry.lastPathComponent) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(entry, depth - 1, &out)
            }
        }
    }
}
