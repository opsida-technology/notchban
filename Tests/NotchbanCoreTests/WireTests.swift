import XCTest
@testable import NotchbanCore

final class WireTests: XCTestCase {
    func testEveryMessageRoundTrips() throws {
        var card = Card(id: "AB-09", title: "Sign the installer", column: .review)
        card.source = "human"
        card.due = "2026-11-20"
        card.leaseExpires = Date(timeIntervalSince1970: 1_790_000_000.5)
        card.checklist = [ChecklistItem(text: "signed", done: true)]
        card.proof = ["spctl ok"]
        var board = Board(path: "/r/KANBAN.md", name: "r", cards: [card])
        board.title = "Shop"
        let messages: [WireMessage] = [
            .snapshot(boards: [board], at: Date(timeIntervalSince1970: 1_790_000_123.25)),
            .result(id: UUID(), added: "AB-10", error: nil),
            .result(id: UUID(), added: nil, error: "This card has moved since your phone saw it."),
            .command(id: UUID(), .add(board: "/r/KANBAN.md", title: "Call the bank", notes: "before Friday", column: .ready)),
            .command(id: UUID(), .review(board: "/r/KANBAN.md", card: "AB-09", verdict: .changes, note: "wrong cert")),
            .command(id: UUID(), .note(board: "/r/KANBAN.md", card: "AB-09", text: "seen")),
            .command(id: UUID(), .due(board: "/r/KANBAN.md", card: "AB-09", day: nil)),
            .command(id: UUID(), .rename(board: "/r/KANBAN.md", name: "Books")),
            .paired(token: Wire.newToken()),
            .challenge(nonce: Wire.newNonce(), proof: Data(repeating: 7, count: 32)),
            .answer(proof: Data(repeating: 9, count: 32)),
        ]
        for message in messages {
            XCTAssertEqual(try WireMessage.decode(message.encoded()), message)
        }
        guard case let .snapshot(boards, _) = try WireMessage.decode(messages[0].encoded()) else { return XCTFail() }
        XCTAssertEqual(boards[0].displayName, "Shop")
        XCTAssertTrue(boards[0].cards[0].isHumanEntered)
    }

    func testPairedInvitationProvesTheTokenAndGoesStale() throws {
        let token = Wire.newToken(), now = Date()
        let invitation = Invitation.paired(device: "phone-1", name: "iPhone", token: token, at: now)
        let sent = try JSONDecoder().decode(Invitation.self, from: JSONEncoder().encode(invitation))
        XCTAssertNil(sent.code)
        XCTAssertTrue(Wire.verify(sent, token: token, now: now.addingTimeInterval(30)))
        XCTAssertFalse(Wire.verify(sent, token: Wire.newToken(), now: now), "another phone's token")
        XCTAssertFalse(Wire.verify(sent, token: token, now: now.addingTimeInterval(600)), "replayed later")
        var forged = sent
        forged.device = "phone-2"
        XCTAssertFalse(Wire.verify(forged, token: token, now: now), "proof is bound to the device id")
        XCTAssertFalse(Wire.verify(Invitation(device: "phone-1", name: "iPhone", code: "123456"), token: token))
    }

    func testSessionProofIsBoundToTokenRoleDeviceAndNonce() {
        let token = Wire.newToken(), nonce = Wire.newNonce()
        let phone = Wire.sessionProof(token: token, role: "phone", device: "phone-1", nonce: nonce)
        XCTAssertTrue(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-1", nonce: nonce))
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "mac", device: "phone-1", nonce: nonce), "a phone proof is not a Mac proof")
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-1", nonce: Wire.newNonce()), "another session")
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: Wire.newToken(), role: "phone", device: "phone-1", nonce: nonce))
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-2", nonce: nonce))
    }

    func testCodesAndTokens() {
        XCTAssertEqual(Wire.newToken().count, 32)
        XCTAssertNotEqual(Wire.newToken(), Wire.newToken())
        let code = Wire.newCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertTrue(Wire.same("042137", "042137"))
        XCTAssertFalse(Wire.same("042137", "042138"))
        XCTAssertFalse(Wire.same("042137", "42137"))
    }
}
