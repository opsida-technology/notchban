import CryptoKit
import Foundation

/// What the Mac and a paired phone say to each other over MultipeerConnectivity (encryption required). One message per
/// send, JSON compressed with LZFSE. The Mac's `KANBAN.md` files stay the only truth: the phone holds a snapshot and
/// sends commands.
public enum WireMessage: Codable, Equatable, Sendable {
    /// Mac → phone: every board the Mac shows, as of `at`. On connect and after every change.
    case snapshot(boards: [Board], at: Date)
    /// Mac → phone: how command `id` went; `added` is the id of a card it added, `error` a sentence for the owner.
    case result(id: UUID, added: String?, error: String?)
    /// Phone → Mac.
    case command(id: UUID, BoardCommand)
    /// Mac → phone, once, right after the pairing code matched: the secret the phone proves from then on.
    case paired(token: Data)
    /// Mac → paired phone, once the encrypted session is up: prove the token inside this session. `proof` shows the
    /// phone that this Mac holds the token too.
    case challenge(nonce: Data, proof: Data)
    /// Phone → Mac: the answer to `challenge`. Nothing else is accepted or sent until it checks out.
    case answer(proof: Data)

    public func encoded() throws -> Data {
        try (JSONEncoder().encode(self) as NSData).compressed(using: .lzfse) as Data
    }

    public static func decode(_ data: Data) throws -> WireMessage {
        try JSONDecoder().decode(WireMessage.self, from: (data as NSData).decompressed(using: .lzfse) as Data)
    }
}

/// The phone's invitation context. Pairing sends the 6-digit `code`; a paired phone sends `proof`, an HMAC of its
/// device id and the time keyed with its token, so the token itself never travels again.
public struct Invitation: Codable, Equatable, Sendable {
    public var device: String
    public var name: String
    public var code: String?
    public var time: Int?
    public var proof: Data?

    public init(device: String, name: String, code: String? = nil, time: Int? = nil, proof: Data? = nil) {
        self.device = device; self.name = name; self.code = code; self.time = time; self.proof = proof
    }

    /// A paired phone's invitation, signed now.
    public static func paired(device: String, name: String, token: Data, at date: Date = Date()) -> Invitation {
        let time = Int(date.timeIntervalSince1970)
        return Invitation(device: device, name: name, time: time, proof: Wire.proof(token: token, device: device, time: time))
    }
}

public enum Wire {
    /// The Bonjour service type (`_notchban._tcp`, `_notchban._udp`).
    public static let service = "notchban"
    /// How far a paired invitation's clock may be from the Mac's.
    public static let skew = 120

    public static func proof(token: Data, device: String, time: Int) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("notchban-invite|\(device)|\(time)".utf8), using: SymmetricKey(data: token)))
    }

    /// True when `invitation` carries a fresh proof made with `token` (constant-time comparison).
    public static func verify(_ invitation: Invitation, token: Data, now: Date = Date()) -> Bool {
        guard let time = invitation.time, let proof = invitation.proof,
              abs(Int(now.timeIntervalSince1970) - time) <= skew else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("notchban-invite|\(invitation.device)|\(time)".utf8),
                                                       using: SymmetricKey(data: token))
    }

    /// Proof of the token inside a live session, for `challenge` (role "mac") and `answer` (role "phone").
    public static func sessionProof(token: Data, role: String, device: String, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("notchban-session|\(role)|\(device)|".utf8) + nonce, using: SymmetricKey(data: token)))
    }

    /// Checks a session proof in constant time.
    public static func verify(sessionProof proof: Data, token: Data, role: String, device: String, nonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("notchban-session|\(role)|\(device)|".utf8) + nonce,
                                               using: SymmetricKey(data: token))
    }

    /// A fresh random challenge.
    public static func newNonce() -> Data { newToken() }

    /// Compares two secrets without leaking where they differ.
    public static func same(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A fresh 32-byte pairing token.
    public static func newToken() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// A 6-digit pairing code from the system's secure generator.
    public static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}
