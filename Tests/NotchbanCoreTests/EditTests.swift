import XCTest
@testable import NotchbanCore

final class EditTests: XCTestCase {
    let board = """
    # Kanban
    <!-- squawk-kanban:v1 -->

    ## Backlog

    ### AB-08 — Old
    <!-- squawk:{"grup": "sonra", "size": "S"} -->

    ## Ready

    ## In Progress

    ## Human Review

    ### AB-09 — Sign the installer
    <!-- squawk:{"owner": "agent:x", "due": "2026-11-20", "before": ["AB-10"], "lease": {"holder": "agent:x"}} -->

    - [x] signed

    Proof: spctl ok

    ## Verified

    ## Blocked

    ## Done

    """

    func run(_ c: BoardCommand) throws -> (Board, String) {
        let (text, _) = try BoardEditor.apply(c, to: board, by: "Ada", today: "2026-11-24")
        return (try XCTUnwrap(BoardParser.parse(text, path: "/r/KANBAN.md")), text)
    }

    func testAddIsHumanEnteredWithTheBoardsNextID() throws {
        let (text, id) = try BoardEditor.apply(.add(board: "/r/KANBAN.md", title: " Fix\nthe login ", notes: "Seen on iPad.", column: .backlog),
                                               to: board, by: "Ada", today: "2026-11-24")
        XCTAssertEqual(id, "AB-10")
        let b = try XCTUnwrap(BoardParser.parse(text, path: "/r/KANBAN.md"))
        let card = try XCTUnwrap(b.card("AB-10"))
        XCTAssertEqual(card.title, "Fix the login")
        XCTAssertTrue(card.isHumanEntered)
        XCTAssertEqual(card.column, .backlog)
        XCTAssertEqual(card.notes, "Seen on iPad.")
        XCTAssertEqual(b.cards.filter { $0.column == .backlog }.map(\.id), ["AB-10", "AB-08"], "on top of its column")
        XCTAssertTrue(text.contains("## Backlog\n\n### AB-10 — Fix the login\n<!-- squawk:{\"source\":\"human\",\"created\":\"2026-11-24\"} -->\n\nSeen on iPad.\n\n### AB-08"))
    }

    func testReviewVerdictsMoveTheCardAndSignIt() throws {
        let (changes, text) = try run(.review(board: "/r/KANBAN.md", card: "AB-09", verdict: .changes, note: "use the new icon"))
        let card = try XCTUnwrap(changes.card("AB-09"))
        XCTAssertEqual(card.column, .ready)
        XCTAssertNil(card.due)
        XCTAssertNil(card.owner)
        XCTAssertEqual(card.before, ["AB-10"], "other metadata stays")
        XCTAssertTrue(card.notes.hasSuffix("Review (Ada, 2026-11-24): changes — use the new icon"))
        XCTAssertTrue(text.contains(#"<!-- squawk:{"before": ["AB-10"]} -->"#), "the line keeps its spacing")

        let (hold, _) = try run(.review(board: "/r/KANBAN.md", card: "AB-09", verdict: .hold, note: "wait for the cert"))
        XCTAssertEqual(hold.card("AB-09")?.column, .blocked)
        XCTAssertEqual(hold.card("AB-09")?.blocker, "wait for the cert")

        let (done, _) = try run(.review(board: "/r/KANBAN.md", card: "AB-09", verdict: .done, note: ""))
        XCTAssertEqual(done.card("AB-09")?.column, .done)
        XCTAssertEqual(done.card("AB-09")?.checklist.count, 1)
        XCTAssertEqual(done.card("AB-09")?.proof, ["spctl ok"])
    }

    func testReviewRefusesWhatItCannotDoSafely() {
        XCTAssertThrowsError(try run(.review(board: "", card: "AB-08", verdict: .done, note: ""))) {
            XCTAssertEqual($0 as? BoardEditor.Failure, .notInReview("AB-08"), "the card moved since the phone saw it")
        }
        XCTAssertThrowsError(try run(.review(board: "", card: "AB-09", verdict: .changes, note: " "))) {
            XCTAssertEqual($0 as? BoardEditor.Failure, .emptyText, "sending back needs what to fix")
        }
        XCTAssertThrowsError(try run(.note(board: "", card: "AB-99", text: "x")))
        XCTAssertThrowsError(try run(.due(board: "", card: "AB-09", day: "Friday")))
    }

    func testNoteAndDue() throws {
        let (b, _) = try run(.note(board: "", card: "AB-08", text: "ask the designer"))
        XCTAssertEqual(b.card("AB-08")?.notes, "Note (Ada, 2026-11-24): ask the designer")
        XCTAssertEqual(b.card("AB-08")?.column, .backlog)
        let (d, _) = try run(.due(board: "", card: "AB-09", day: "2026-11-28"))
        XCTAssertEqual(d.card("AB-09")?.due, "2026-11-28")
        XCTAssertTrue(try XCTUnwrap(BoardParser.parse(board, path: "")?.card("AB-09")).isOverdue(today: "2026-11-24"))
    }

    func testNextIDOnAnEmptyBoardUsesTheFolder() {
        XCTAssertEqual(BoardEditor.nextID(["# Kanban", "## Backlog"], folder: "notchban"), "NO-1")
        XCTAssertEqual(BoardEditor.nextID(["### KB-02 — a", "### KB-09 — b"], folder: "x"), "KB-10")
    }

    func testBoardsTravelAsJSON() throws {
        let b = try XCTUnwrap(BoardParser.parse(board, path: "/r/KANBAN.md"))
        XCTAssertEqual(try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(b)), b)
        let c = BoardCommand.review(board: "/r/KANBAN.md", card: "AB-09", verdict: .approved, note: "")
        XCTAssertEqual(try JSONDecoder().decode(BoardCommand.self, from: JSONEncoder().encode(c)), c)
    }
}
