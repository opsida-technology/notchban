import CryptoKit
import Foundation

/// What the Mac and a paired phone say to each other over MultipeerConnectivity (encryption required). One message per
/// send, JSON compressed with LZFSE. Only `paired`, `challenge` and `answer` travel as they are; everything after the
/// handshake goes through a `Channel`. The Mac's `KANBAN.md` files stay the only truth: the phone holds a snapshot and
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
    /// Mac → phone, as soon as the session is up: a fresh nonce and the Mac's one-time key, signed with the token.
    case challenge(nonce: Data, key: Data, proof: Data)
    /// Phone → Mac: the phone's one-time key, signed with the token over both keys. Both ends then hold the same
    /// `Channel`, and nothing else is accepted or sent until it is set up.
    case answer(key: Data, proof: Data)

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

    /// Proof of the token over this session's one-time keys: for `challenge` (role "mac", `keys` = the Mac's key) and
    /// `answer` (role "phone", `keys` = the Mac's key then the phone's). Signing the keys is what ties the token to this
    /// session: someone relaying between the two can pass the proofs on, but cannot swap in keys of their own.
    public static func sessionProof(token: Data, role: String, device: String, nonce: Data, keys: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("notchban-session|\(role)|\(device)|".utf8) + nonce + keys,
                                             using: SymmetricKey(data: token)))
    }

    /// Checks a session proof in constant time.
    public static func verify(sessionProof proof: Data, token: Data, role: String, device: String, nonce: Data, keys: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("notchban-session|\(role)|\(device)|".utf8) + nonce + keys,
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

/// One end of a paired session after the handshake: a key each way, agreed from both one-time keys (X25519) and the
/// token, so only the paired Mac and phone hold them. Every message is sealed (ChaChaPoly) under the next number in its
/// direction: a relay can neither read nor change one, and a message replayed, dropped, reordered or sent back to
/// its sender does not open.
public struct Channel: Sendable {
    private let out: SymmetricKey
    private let inbound: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    /// `own` is this end's one-time key; `mac` and `phone` are the two public keys as they were sent.
    public init(role: String, own: Curve25519.KeyAgreement.PrivateKey, mac: Data, phone: Data,
                token: Data, device: String, nonce: Data) throws {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: role == "mac" ? phone : mac)
        let shared = try own.sharedSecretFromKeyAgreement(with: peer)
        let transcript = Data("\(device)|".utf8) + nonce + mac + phone
        func key(_ way: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: token,
                                           sharedInfo: Data("notchban-channel|\(way)|".utf8) + transcript, outputByteCount: 32)
        }
        out = key(role == "mac" ? "mac>phone" : "phone>mac")
        inbound = key(role == "mac" ? "phone>mac" : "mac>phone")
    }

    public mutating func seal(_ message: WireMessage) throws -> Data {
        let box = try ChaChaPoly.seal(message.encoded(), using: out, nonce: Self.nonce(sent))
        sent += 1
        return Data(box.ciphertext) + box.tag  // a fresh Data: the ciphertext is a slice of the combined box
    }

    /// The next message from the other end; throws (and counts nothing) when it is not exactly that.
    public mutating func open(_ data: Data) throws -> WireMessage {
        guard data.count > 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: data.dropLast(16), tag: data.suffix(16))
        let message = try WireMessage.decode(ChaChaPoly.open(box, using: inbound))
        received += 1
        return message
    }

    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: n.bigEndian) { Data($0) })
    }
}
