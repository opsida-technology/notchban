import XCTest
@testable import NotchbanCore

final class GraphTests: XCTestCase {
    /// A → B → D, A → C, with edges written on either side; E is Done; F is gated on Tier 0.
    let text = """
    # Kanban
    <!-- squawk-kanban:v1 -->

    ## Backlog

    ### B — Middle
    <!-- squawk:{"size":"L","after":["A"]} -->

    ### D — Last
    <!-- squawk:{"size":"M"} -->

    ### F — Gated
    <!-- squawk:{"gate":"tier0"} -->

    ## Ready

    ### C — Side
    <!-- squawk:{"size":"S","after":["A","E","GHOST"]} -->

    ### G — Free
    <!-- squawk:{"track":2,"risk":"sec","owner":"agent:x"} -->

    ## In Progress

    ### A — First
    <!-- squawk:{"size":"S","tier":0,"before":["B","D"]} -->

    ## Done

    ### E — Old
    <!-- squawk:{} -->
    """

    func graph() throws -> BoardGraph { BoardGraph(try XCTUnwrap(BoardParser.parse(text, path: "/x/KANBAN.md"))) }

    func testEdgesFromBothSidesAndUnknownIdsDropped() throws {
        let g = try graph()
        XCTAssertEqual(g.predecessors["B"], ["A"])
        XCTAssertEqual(Set(g.successors["A"] ?? []), ["B", "C", "D"])
        XCTAssertEqual(Set(g.predecessors["C"] ?? []), ["A", "E"])
        XCTAssertEqual(g.waitsFor("C"), ["A"], "Done predecessors no longer hold a card")
    }

    func testTransitiveClosures() throws {
        let g = try graph()
        XCTAssertEqual(g.upstream(of: "C"), ["A", "E"])
        XCTAssertEqual(g.downstream(of: "A"), ["B", "C", "D"])
        XCTAssertEqual(g.downstream(of: "D"), [])
    }

    func testActionableNeedsReadyNoOpenPredecessorAndOpenGate() throws {
        let g = try graph()
        let b = try XCTUnwrap(g.board.card("G")), c = try XCTUnwrap(g.board.card("C"))
        XCTAssertTrue(g.isActionable(b))
        XCTAssertFalse(g.isActionable(c), "C still waits for A")
        XCTAssertFalse(g.gateOpen(try XCTUnwrap(g.board.card("F"))), "A is Tier 0 and not Done")
    }

    func testCriticalPathFollowsTheHeaviestOpenChain() throws {
        XCTAssertEqual(try graph().criticalPath(), ["A", "B"])
    }

    func testCriticalPathSurvivesACycle() throws {
        let cyclic = """
        # Kanban
        ## Backlog
        ### X — x
        <!-- squawk:{"before":["Y"]} -->
        ### Y — y
        <!-- squawk:{"before":["X"]} -->
        """
        let g = BoardGraph(try XCTUnwrap(BoardParser.parse(cyclic, path: "/x/KANBAN.md")))
        XCTAssertEqual(g.criticalPath().count, 2)
        XCTAssertEqual(g.upstream(of: "X"), ["Y"])
    }

    func testFilter() throws {
        let g = try graph()
        func ids(_ f: CardFilter) -> [String] { g.board.cards.filter { f.matches($0, in: g) }.map(\.id) }
        var f = CardFilter()
        XCTAssertEqual(ids(f).count, 7)
        f.actionable = true
        XCTAssertEqual(ids(f), ["G"])
        f = CardFilter(); f.text = "midd"
        XCTAssertEqual(ids(f), ["B"])
        f = CardFilter(); f.track = 2; f.risk = "sec"; f.owner = "agent:x"
        XCTAssertEqual(ids(f), ["G"])
    }

    func testFuzzyPrefersWordStartsAndRejectsNonSubsequences() {
        XCTAssertNil(Fuzzy.score("zz", "HD-01 Forgejo"))
        let tight = Fuzzy.score("hd01", "HD-01 — Forgejo")!, loose = Fuzzy.score("hd01", "the hidden d0 1")!
        XCTAssertGreaterThan(tight, loose)
        XCTAssertGreaterThan(Fuzzy.score("mob", "SQ-B7 Mobile çok daha iyi")!, Fuzzy.score("mob", "GV-04 A model-based check")!)
    }

    func testWeight() {
        XCTAssertEqual(Card(id: "a", title: "", column: .ready, size: "S–M").weight, 1.5)
        XCTAssertEqual(Card(id: "a", title: "", column: .ready, size: "XL").weight, 5)
        XCTAssertEqual(Card(id: "a", title: "", column: .ready).weight, 1)
    }
}

final class HostileInputTests: XCTestCase {
    func testAHugeChainDoesNotRecurseWithoutLimit() throws {
        var text = "# Kanban\n<!-- squawk-kanban:v1 -->\n\n## Backlog\n\n"
        for n in 0..<3000 { text += "### A-\(n) — c\n<!-- squawk:{\"before\":[\"A-\(n + 1)\"]} -->\n\n" }
        let board = try XCTUnwrap(BoardParser.parse(text, path: "/x/KANBAN.md"))
        XCTAssertEqual(BoardGraph(board).criticalPath(), [])
    }
}
