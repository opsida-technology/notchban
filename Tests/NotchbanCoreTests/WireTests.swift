import CryptoKit
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
            .challenge(nonce: Wire.newNonce(), key: Data(repeating: 5, count: 32), proof: Data(repeating: 7, count: 32)),
            .answer(key: Data(repeating: 6, count: 32), proof: Data(repeating: 9, count: 32)),
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

    func testSessionProofIsBoundToTokenRoleDeviceNonceAndKeys() {
        let token = Wire.newToken(), nonce = Wire.newNonce(), keys = Data(repeating: 3, count: 64)
        let phone = Wire.sessionProof(token: token, role: "phone", device: "phone-1", nonce: nonce, keys: keys)
        XCTAssertTrue(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-1", nonce: nonce, keys: keys))
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "mac", device: "phone-1", nonce: nonce, keys: keys), "a phone proof is not a Mac proof")
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-1", nonce: Wire.newNonce(), keys: keys), "another session")
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: Wire.newToken(), role: "phone", device: "phone-1", nonce: nonce, keys: keys))
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-2", nonce: nonce, keys: keys))
        XCTAssertFalse(Wire.verify(sessionProof: phone, token: token, role: "phone", device: "phone-1", nonce: nonce,
                                   keys: Data(repeating: 4, count: 64)), "someone else's keys")
    }

    /// The handshake as the Mac and the phone run it; `relay` stands between them and may swap the keys.
    private func handshake(token: Data, swapMacKey: Bool = false) throws -> (mac: Channel, phone: Channel)? {
        let device = "phone-1", nonce = Wire.newNonce()
        let macOwn = Curve25519.KeyAgreement.PrivateKey(), relayOwn = Curve25519.KeyAgreement.PrivateKey()
        let macKey = macOwn.publicKey.rawRepresentation
        let macProof = Wire.sessionProof(token: token, role: "mac", device: device, nonce: nonce, keys: macKey)
        // the phone gets the Mac's key, or the relay's in its place, with the Mac's proof
        let seen = swapMacKey ? relayOwn.publicKey.rawRepresentation : macKey
        guard Wire.verify(sessionProof: macProof, token: token, role: "mac", device: device, nonce: nonce, keys: seen) else { return nil }
        let phoneOwn = Curve25519.KeyAgreement.PrivateKey(), phoneKey = phoneOwn.publicKey.rawRepresentation
        let phoneProof = Wire.sessionProof(token: token, role: "phone", device: device, nonce: nonce, keys: seen + phoneKey)
        guard Wire.verify(sessionProof: phoneProof, token: token, role: "phone", device: device, nonce: nonce, keys: macKey + phoneKey) else { return nil }
        return (try Channel(role: "mac", own: macOwn, mac: macKey, phone: phoneKey, token: token, device: device, nonce: nonce),
                try Channel(role: "phone", own: phoneOwn, mac: seen, phone: phoneKey, token: token, device: device, nonce: nonce))
    }

    func testChannelCarriesMessagesBothWays() throws {
        var (mac, phone) = try XCTUnwrap(handshake(token: Wire.newToken()))
        let command = WireMessage.command(id: UUID(), .note(board: "/b/KANBAN.md", card: "NB-1", text: "hi"))
        XCTAssertEqual(try mac.open(phone.seal(command)), command)
        let result = WireMessage.result(id: UUID(), added: nil, error: nil)
        XCTAssertEqual(try phone.open(mac.seal(result)), result)
        XCTAssertEqual(try phone.open(mac.seal(result)), result, "the second one opens under the next number")
    }

    func testARelayCannotSwapKeysReadReplayOrReflect() throws {
        XCTAssertNil(try handshake(token: Wire.newToken(), swapMacKey: true), "the Mac's proof does not cover the relay's key")

        var (mac, phone) = try XCTUnwrap(handshake(token: Wire.newToken()))
        let sealed = try phone.seal(.command(id: UUID(), .note(board: "/b/KANBAN.md", card: "NB-1", text: "once")))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("once"))
        _ = try mac.open(sealed)
        XCTAssertThrowsError(try mac.open(sealed), "replayed")
        var flipped = try phone.seal(.result(id: UUID(), added: nil, error: nil))
        flipped[0] ^= 1
        XCTAssertThrowsError(try mac.open(flipped), "changed on the way")
        var (mac2, _) = try XCTUnwrap(handshake(token: Wire.newToken()))
        let own = try mac2.seal(.result(id: UUID(), added: nil, error: nil))
        XCTAssertThrowsError(try mac2.open(own), "sent back to its sender")
        XCTAssertThrowsError(try mac.open(own), "from another session")
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
