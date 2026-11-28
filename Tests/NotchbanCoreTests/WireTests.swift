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
            .snapshot(boards: [], at: Date(timeIntervalSince1970: 1_790_000_200), ears: [
                Ear(name: "Codex", working: 0),
                Ear(name: "Claude", working: 3, fiveHour: 38.5, fiveHourResets: Date(timeIntervalSince1970: 1_790_009_000),
                    week: 71, weekResets: Date(timeIntervalSince1970: 1_790_300_000), recorded: Date(timeIntervalSince1970: 1_790_000_100)),
            ]),
            .result(id: UUID(), added: "AB-10", error: nil),
            .result(id: UUID(), added: nil, error: "This card has moved since your phone saw it."),
            .command(id: UUID(), .add(board: "/r/KANBAN.md", title: "Call the bank", notes: "before Friday", column: .ready)),
            .command(id: UUID(), .review(board: "/r/KANBAN.md", card: "AB-09", verdict: .changes, note: "wrong cert")),
            .command(id: UUID(), .note(board: "/r/KANBAN.md", card: "AB-09", text: "seen")),
            .command(id: UUID(), .due(board: "/r/KANBAN.md", card: "AB-09", day: nil)),
            .command(id: UUID(), .rename(board: "/r/KANBAN.md", name: "Books")),
            .challenge(nonce: Wire.newNonce(), key: Data(repeating: 5, count: 32), proof: Data(repeating: 7, count: 32)),
            .answer(key: Data(repeating: 6, count: 32), proof: Data(repeating: 9, count: 32)),
        ]
        for message in messages {
            XCTAssertEqual(try WireMessage.decode(message.encoded()), message)
        }
        guard case let .snapshot(boards, _, ears, _) = try WireMessage.decode(messages[0].encoded()) else { return XCTFail() }
        XCTAssertNil(ears)
        XCTAssertEqual(boards[0].displayName, "Shop")
        XCTAssertTrue(boards[0].cards[0].isHumanEntered)
    }

    func testASnapshotWithoutEarsStillReads() throws {
        // what a Mac from before the ears sends
        let json = #"{"snapshot":{"boards":[],"at":0}}"#
        let data = try (Data(json.utf8) as NSData).compressed(using: .lzfse) as Data
        guard case let .snapshot(boards, _, ears, _) = try WireMessage.decode(data) else { return XCTFail() }
        XCTAssertEqual(boards, [])
        XCTAssertNil(ears)
    }

    func testPairedInvitationProvesTheTokenAndGoesStale() throws {
        let token = Wire.newToken(), now = Date()
        let invitation = Invitation.paired(device: "phone-1", name: "iPhone", token: token, at: now)
        let sent = try JSONDecoder().decode(Invitation.self, from: JSONEncoder().encode(invitation))
        XCTAssertTrue(Wire.verify(sent, token: token, now: now.addingTimeInterval(30)))
        XCTAssertFalse(Wire.verify(sent, token: Wire.newToken(), now: now), "another phone's token")
        XCTAssertFalse(Wire.verify(sent, token: token, now: now.addingTimeInterval(600)), "replayed later")
        var forged = sent
        forged.device = "phone-2"
        XCTAssertFalse(Wire.verify(forged, token: token, now: now), "proof is bound to the device id")
        XCTAssertFalse(Wire.verify(Invitation(device: "phone-1", name: "iPhone"), token: token), "no proof")
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

    func testTokensAndThePairingCode() {
        XCTAssertEqual(Wire.newToken().count, 32)
        XCTAssertNotEqual(Wire.newToken(), Wire.newToken())
        let mac = UUID().uuidString
        for _ in 0..<50 {  // every base64 padding and the url-safe letters
            let offer = PairingOffer(mac: mac, token: Wire.newToken())
            let token = offer.link.components(separatedBy: "token=")[1]
            XCTAssertFalse(token.contains("+") || token.contains("/") || token.contains("="), token)
            XCTAssertEqual(PairingOffer(link: offer.link), offer)
        }
        let good = PairingOffer(mac: mac, token: Wire.newToken()).link
        XCTAssertNil(PairingOffer(link: good.replacingOccurrences(of: "notchban:", with: "https:")), "another scheme")
        XCTAssertNil(PairingOffer(link: good.replacingOccurrences(of: mac, with: "not-a-mac")))
        XCTAssertNil(PairingOffer(link: "notchban:pair?mac=\(mac)&token=AAAA"), "a short token")
        XCTAssertNil(PairingOffer(link: "notchban:pair?mac=\(mac)"))
        XCTAssertNil(PairingOffer(link: "123456"))
    }

    func testFramesSurviveAnySplitAndRefuseOversizedMessages() throws {
        let a = Data("first".utf8), b = Data(repeating: 7, count: 300)
        let stream = Frames.wrap(a) + Frames.wrap(b) + Frames.wrap(Data())
        var frames = Frames(limit: 1_000), out: [Data] = []
        for chunk in stride(from: 0, to: stream.count, by: 3) { out += try frames.feed(stream.subdata(in: chunk..<min(chunk + 3, stream.count))) }
        XCTAssertEqual(out, [a, b, Data()])
        var small = Frames(limit: 100)
        XCTAssertThrowsError(try small.feed(Frames.wrap(b).prefix(4)))
    }

    func testASnapshotCarriesTheMacsTailscaleAddressAndOldOnesStillOpen() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        guard case let .snapshot(_, _, _, remote) = try WireMessage.decode(WireMessage.snapshot(boards: [], at: now, remote: "100.1.2.3").encoded())
        else { return XCTFail() }
        XCTAssertEqual(remote, "100.1.2.3")
        guard case let .snapshot(_, _, _, none) = try WireMessage.decode(WireMessage.snapshot(boards: [], at: now).encoded()) else { return XCTFail() }
        XCTAssertNil(none)
    }
}
