import XCTest
@testable import NotchbanCore

final class BoardTests: XCTestCase {
    let text = """
    # Kanban
    <!-- squawk-kanban:v1 -->

    ## Backlog

    ### KB-02 — Second
    <!-- squawk:{"after":["KB-01"],"before":[]} -->

    - [ ] a

    ## Ready

    ## In Progress

    ### KB-01 — First
    <!-- squawk:{"owner":"agent:t","lease":{"expiresAt":"2020-01-01T00:00:00Z"},"before":["KB-02"]} -->

    - [x] a
    - [ ] b

    ## Human Review

    ## Verified

    ## Blocked

    ## Done
    """

    func testCardsColumnsChecklistsAndEdges() throws {
        let board = try XCTUnwrap(BoardParser.parse(text, path: "/x/app/KANBAN.md"))
        XCTAssertEqual(board.name, "app")
        XCTAssertEqual(board.cards.map(\.id), ["KB-02", "KB-01"])
        let first = try XCTUnwrap(board.card("KB-01"))
        XCTAssertEqual(first.column, .progress)
        XCTAssertEqual([first.checked, first.total], [1, 2])
        XCTAssertTrue(first.isStale())
        XCTAssertEqual(board.open(try XCTUnwrap(board.card("KB-02")).after).map(\.id), ["KB-01"])
    }

    func testExtensionsProofBlockerAndNotes() throws {
        let rich = """
        # Kanban
        ## Blocked

        ### HD-01 — Move Forgejo — then deploy
        <!-- squawk:{"track":1,"phase":"2","size":"S–M","risk":"sec","tier":0,"gate":"tier0","proofs":["test:local-1"],"lease":{"holder":"agent:h","expiresAt":"2999-01-01T00:00:00Z"}} -->

        Hat 1 · Faz 1
        Blocker: Ada's yes.

        - [X] copied
        - [ ] deployed

        Proof: `./tools/test.sh` — 1600/1600

        Notes go here.
        """
        let card = try XCTUnwrap(BoardParser.parse(rich, path: "/x/KANBAN.md")?.cards.first)
        XCTAssertEqual(card.title, "Move Forgejo — then deploy")
        XCTAssertEqual(card.column, .blocked)
        XCTAssertEqual(card.track, "1")
        XCTAssertEqual([card.phase, card.tier], [2, 0])
        XCTAssertEqual([card.size, card.risk, card.gate, card.owner], ["S–M", "sec", "tier0", "agent:h"])
        XCTAssertEqual(card.blocker, "Ada's yes.")
        XCTAssertEqual(card.proof, ["test:local-1", "`./tools/test.sh` — 1600/1600"])
        XCTAssertEqual(card.checklist, [ChecklistItem(text: "copied", done: true), ChecklistItem(text: "deployed", done: false)])
        XCTAssertEqual(card.notes, "Hat 1 · Faz 1\n\nNotes go here.", "runs of blank lines collapse")
        XCTAssertFalse(card.isStale(), "only In Progress cards go stale")
    }

    func testNotAKanbanFileIsSkipped() {
        XCTAssertNil(BoardParser.parse("# Notes\n", path: "/x/KANBAN.md"))
    }
}

final class WorktreeTests: XCTestCase {
    func testAWorktreeAndItsRepositoryAreOneBoardNamedAfterTheRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let main = root.appendingPathComponent("app"), tree = root.appendingPathComponent("app-wt1")
        for dir in [main, tree] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/hd03\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        func board(_ id: String) -> String { "# Kanban\n<!-- squawk-kanban:v1 -->\n\n## In Progress\n\n### \(id) — x\n" }
        try board("A-1").write(to: main.appendingPathComponent("KANBAN.md"), atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.1)
        try board("A-2").write(to: tree.appendingPathComponent("KANBAN.md"), atomically: true, encoding: .utf8)
        let boards = Scanner.boards(under: root)
        XCTAssertEqual(boards.map(\.name), ["app"])
        XCTAssertEqual(boards.first?.cards.map(\.id), ["A-1"], "the trunk's copy is the board, however new a worktree's")
    }

    /// Boards name tracks ("fark") as often as they number them.
    func testTrackIsNumberOrName() throws {
        let text = "# Kanban\n\n## Ready\n\n### A-1 — x\n<!-- squawk:{\"track\":\"fark\"} -->\n\n### A-2 — y\n<!-- squawk:{\"track\":3} -->\n"
        XCTAssertEqual(BoardParser.parse(text, path: "/x/KANBAN.md")?.cards.map(\.track), ["fark", "3"])
    }

    /// The skill the app installs must write boards the app reads: its empty board, with its example card in Ready.
    func testTheSkillsTemplateIsABoard() throws {
        let skill = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .appendingPathComponent("../../../docs/kanban-skill.md").standardized, encoding: .utf8)
        let blocks = skill.components(separatedBy: "```markdown\n").dropFirst().map { $0.components(separatedBy: "\n```")[0] }
        XCTAssertGreaterThanOrEqual(blocks.count, 2)
        let text = blocks[0].replacingOccurrences(of: "## Ready\n", with: "## Ready\n\n" + blocks[1] + "\n")
        let board = try XCTUnwrap(BoardParser.parse(text, path: "/x/KANBAN.md"))
        XCTAssertEqual(board.cards.map(\.id), ["KB-12"])
        XCTAssertEqual(board.cards.first?.column, .ready)
        XCTAssertEqual(board.cards.first?.after, ["KB-09"])
        XCTAssertEqual(board.cards.first?.checklist.count, 2)
    }
}
