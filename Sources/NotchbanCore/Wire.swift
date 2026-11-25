import CryptoKit
import Foundation

/// What the Mac and a paired phone say to each other over MultipeerConnectivity (encryption required). One message per
/// send, JSON compressed with LZFSE. Only `challenge` and `answer` travel as they are; everything after the
/// handshake goes through a `Channel`. The Mac's `KANBAN.md` files stay the only truth: the phone holds a snapshot and
/// sends commands.
public enum WireMessage: Codable, Equatable, Sendable {
    /// Mac → phone: every board the Mac shows, as of `at`, and what the notch's ears show. On connect and after every
    /// change.
    case snapshot(boards: [Board], at: Date, ears: [Ear]? = nil)
    /// Mac → phone: how command `id` went; `added` is the id of a card it added, `error` a sentence for the owner.
    case result(id: UUID, added: String?, error: String?)
    /// Phone → Mac.
    case command(id: UUID, BoardCommand)
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

/// One of the notch's ears, for the phone: a provider's live agents and its two limits as the Mac last read them.
public struct Ear: Codable, Equatable, Sendable {
    public var name: String
    /// Sessions and subagents at work now.
    public var working: Int
    /// Percent used of the 5-hour and the weekly limit, and when each rolls over; nil when the Mac has no figure.
    public var fiveHour: Double?
    public var fiveHourResets: Date?
    public var week: Double?
    public var weekResets: Date?
    /// When the provider's own tool last wrote the limits.
    public var recorded: Date?

    public init(name: String, working: Int, fiveHour: Double? = nil, fiveHourResets: Date? = nil, week: Double? = nil,
                weekResets: Date? = nil, recorded: Date? = nil) {
        self.name = name; self.working = working; self.fiveHour = fiveHour; self.fiveHourResets = fiveHourResets
        self.week = week; self.weekResets = weekResets; self.recorded = recorded
    }
}

/// The phone's invitation context: its device id and `proof`, an HMAC of the device id and the time keyed with its
/// token, so the token itself never travels. Pairing sends the same, keyed with the token from the Mac's QR code.
public struct Invitation: Codable, Equatable, Sendable {
    public var device: String
    public var name: String
    public var time: Int?
    public var proof: Data?

    public init(device: String, name: String, time: Int? = nil, proof: Data? = nil) {
        self.device = device; self.name = name; self.time = time; self.proof = proof
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

    /// A fresh 32-byte pairing token.
    public static func newToken() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// What the Mac's pairing QR code holds: the Mac's id and a fresh token. The token goes from the Mac's screen to the
/// phone's camera and never over the air, so no one nearby can learn it, even while the two pair.
public struct PairingOffer: Equatable, Sendable {
    public var mac: String
    public var token: Data

    public init(mac: String, token: Data) {
        self.mac = mac; self.token = token
    }

    /// `notchban:pair?mac=<id>&token=<base64url>`
    public var link: String {
        let token = token.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "notchban:pair?mac=\(mac)&token=\(token)"
    }

    /// Reads a scanned code; nil for anything that is not a well-formed pairing link.
    public init?(link: String) {
        guard let parts = URLComponents(string: link), parts.scheme == "notchban", parts.path == "pair",
              let mac = parts.queryItems?.first(where: { $0.name == "mac" })?.value, UUID(uuidString: mac) != nil,
              var text = parts.queryItems?.first(where: { $0.name == "token" })?.value else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let token = Data(base64Encoded: text), token.count == 32 else { return nil }
        self.init(mac: mac, token: token)
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
