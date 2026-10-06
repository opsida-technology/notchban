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

    /// A repository and its git worktrees hold one KANBAN.md each: the board of a repository is the one written last
    /// (a session working in a worktree moves its card there first), under the repository's own folder name.
    static func oneBoardPerRepository(_ boards: [Board]) -> [Board] {
        var groups: [String: [Board]] = [:]
        for board in boards { groups[repositoryRoot(of: board.path), default: []].append(board) }
        return groups.map { root, members in
            var newest = members.max { modified($0.path) < modified($1.path) }!
            // Boards that read alike (all from origin/main) are named by the repository's own copy, not a worktree's.
            if let own = members.first(where: { URL(fileURLWithPath: $0.path).deletingLastPathComponent()
                .resolvingSymlinksInPath().path == root }), members.allSatisfy({ $0.cards == own.cards }) { newest = own }
            return Board(path: newest.path, name: URL(fileURLWithPath: root).lastPathComponent, cards: newest.cards)
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

    /// One board, or nil when it is gone, too big to be a board, or not a board. The standard: a repository's board is
    /// its `KANBAN.md` on `origin/main` (what every session sees once its claim or its Done is pushed); only a folder
    /// with no such file there (no git, no remote, not committed yet) is read from the disk.
    public static func board(at file: URL) -> Board? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int, size <= maxBytes else { return nil }
        let text = recorded(in: file.deletingLastPathComponent()) ?? (try? String(contentsOf: file, encoding: .utf8))
        return text.flatMap { BoardParser.parse($0, path: file.path) }
    }

    /// `KANBAN.md` as `origin/main` (or `origin/master`) holds it.
    static func recorded(in dir: URL) -> String? {
        for ref in ["origin/main", "origin/master"] {
            if let data = git(["-C", dir.path, "cat-file", "blob", "\(ref):./KANBAN.md"]), data.count <= maxBytes,
               let text = String(data: data, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Brings every repository's `origin` refs up to date (never touches a working tree), so the recorded board is current.
    public static func fetch(_ boards: [Board]) {
        for root in Set(boards.map { repositoryRoot(of: $0.path) }) {
            // A credential helper the repository sets for itself would run as a command: such a repository is not fetched.
            if let helpers = git(["-C", root, "config", "--show-scope", "--get-regexp", #"^credential\..*helper$"#]),
               String(decoding: helpers, as: UTF8.self).split(separator: "\n").contains(where: { $0.hasPrefix("local") || $0.hasPrefix("worktree") }) { continue }
            _ = git(["-C", root, "fetch", "--quiet", "--no-tags", "origin"], timeout: 30)
        }
    }

    /// A repository's own config and hooks are not trusted: a folder that lands under the root (an archive unpacked with
    /// its `.git`) must not get to run commands. No hooks, no fsmonitor, no askpass, and only http(s) and ssh remotes.
    private static let untrusted = ["core.hooksPath=/dev/null", "core.fsmonitor=false", "core.askPass=/usr/bin/false", "protocol.allow=never",
                                    "protocol.https.allow=always", "protocol.http.allow=always", "protocol.ssh.allow=always"].flatMap { ["-c", $0] }

    /// Runs git without a terminal (no prompt can hang it) and returns stdout when it succeeded in time.
    private static func git(_ arguments: [String], timeout: TimeInterval = 10) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = untrusted + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"]) { _, new in new }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return process.terminationStatus == 0 ? data : nil
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
