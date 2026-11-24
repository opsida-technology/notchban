import CryptoKit
import Foundation
import MultipeerConnectivity
import NotchbanCore
import Security
import UIKit

/// The boards as the Mac last sent them.
struct Snapshot: Codable {
    var boards: [Board]
    var at: Date
}

/// The Mac this phone is paired with, kept in the Keychain.
struct PairedMac: Codable {
    var device: String
    var token: Data
    var mac: String
    var name: String
}

/// How a command went: the id of an added card, or a sentence to show.
struct Outcome {
    var added: String?
    var error: String?
}

/// The phone's side of the link: finds the paired Mac nearby (MultipeerConnectivity, encryption required), keeps the
/// last snapshot on disk, and sends the owner's commands. No offline queue: writes need the Mac nearby.
@MainActor
final class Link: NSObject, ObservableObject {
    enum State { case searching, connecting, connected }

    @Published private(set) var state = State.searching
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var paired: PairedMac?
    /// Macs that can be paired with, while this phone is not paired.
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var pairingError: String?

    var isConnected: Bool { state == .connected }

    private let me = MCPeerID(displayName: String(UIDevice.current.name.prefix(40)))
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    /// Every Mac found, with its discovery id.
    private var macs: [MCPeerID: String] = [:]
    /// The device id and Mac of a pairing in flight.
    private var pairing: (device: String, peer: MCPeerID)?
    private var waiting: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    /// Set once this session's Mac proved the token over its one-time key: snapshots and results come only sealed in it.
    private var channel: Channel?

    private static let cache = URL.applicationSupportDirectory.appending(path: "snapshot.json")

    override init() {
        super.init()
        paired = MacKeychain.read()
        snapshot = (try? Data(contentsOf: Self.cache)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        browse()
    }

    func board(_ path: String) -> Board? { snapshot?.boards.first { $0.path == path } }

    /// Starts looking again (the app came back to the front, or a link dropped).
    func browse() {
        guard state != .connected else { return }
        browser?.stopBrowsingForPeers()
        macs = [:]
        nearby = []
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Wire.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    // MARK: pairing

    func pair(with peer: MCPeerID, code: String) {
        let device = UUID().uuidString
        pairing = (device, peer)
        pairingError = nil
        invite(peer, Invitation(device: device, name: me.displayName, code: code))
    }

    /// Drops the pairing and the boards it brought. The Mac keeps its side until "Forget This iPhone" there.
    func forget() {
        MacKeychain.delete()
        paired = nil
        snapshot = nil
        try? FileManager.default.removeItem(at: Self.cache)
        session?.disconnect()
        session = nil
        state = .searching
        browse()
    }

    private func invite(_ peer: MCPeerID, _ invitation: Invitation) {
        guard let browser, let context = try? JSONEncoder().encode(invitation) else { return }
        session?.disconnect()
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
        channel = nil
        state = .connecting
        browser.invitePeer(peer, to: s, withContext: context, timeout: 20)
    }

    /// The paired Mac, if it is in reach.
    private func reconnect() {
        guard let paired, state == .searching,
              let peer = macs.first(where: { $0.value == paired.mac })?.key else { return }
        invite(peer, Invitation.paired(device: paired.device, name: me.displayName, token: paired.token))
    }

    // MARK: commands

    /// Sends a command and waits for the Mac's answer (at most 15 s).
    func run(_ command: BoardCommand) async -> Outcome {
        let id = UUID()
        guard let session, isConnected, var channel, let message = try? channel.seal(.command(id: id, command)) else {
            return Outcome(error: "Your Mac isn't nearby. Try again when it is.")
        }
        self.channel = channel
        do {
            try session.send(message, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            return Outcome(error: "Couldn't reach your Mac: \(error.localizedDescription)")
        }
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.waiting.removeValue(forKey: id)?.resume(returning: Outcome(error: "Your Mac didn't answer. Check the board before trying again."))
            }
        }
    }

    // MARK: events

    private func found(_ peer: MCPeerID, mac: String?) {
        guard let mac else { return }
        macs[peer] = mac
        if paired == nil {
            if !nearby.contains(peer) { nearby.append(peer) }
        } else {
            reconnect()
        }
    }

    private func lost(_ peer: MCPeerID) {
        macs[peer] = nil
        nearby.removeAll { $0 == peer }
    }

    private func changed(_ s: MCSession, _ peer: MCPeerID, _ new: MCSessionState) {
        guard s === session else { return }
        switch new {
        case .connected, .connecting:
            // "connected" only once the Mac has proved itself and sent the boards
            state = .connecting
        case .notConnected:
            session = nil
            channel = nil
            state = .searching
            for (_, c) in waiting { c.resume(returning: Outcome(error: "The link to your Mac dropped. Check the board before trying again.")) }
            waiting = [:]
            if pairing != nil, paired == nil {
                pairing = nil
                pairingError = "Your Mac didn't accept that code. Check it, or show a new one on the Mac."
            }
            // the Mac may have only blinked: try again shortly, while it is still found
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reconnect() }
        @unknown default:
            break
        }
    }

    private func received(_ data: Data, from peer: MCPeerID, in s: MCSession) {
        guard s === session else { return }
        if var channel {
            // anything that does not open as the Mac's next sealed message ends the link
            guard let message = try? channel.open(data) else { return s.disconnect() }
            self.channel = channel
            switch message {
            case let .snapshot(boards, at):
                state = .connected
                let fresh = Snapshot(boards: boards, at: at)
                snapshot = fresh
                if let data = try? JSONEncoder().encode(fresh) {
                    try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            case let .result(id, added, error):
                waiting.removeValue(forKey: id)?.resume(returning: Outcome(added: added, error: error))
            default:
                break
            }
            return
        }
        guard let message = try? WireMessage.decode(data) else { return }
        switch message {
        case let .challenge(nonce, macKey, proof):
            // The Mac proves the token over its one-time key; the phone answers over both keys, and the two agree a
            // channel no one relaying between them can read or change.
            guard let paired, pairing == nil,
                  Wire.verify(sessionProof: proof, token: paired.token, role: "mac", device: paired.device, nonce: nonce, keys: macKey)
            else { return s.disconnect() }
            let own = Curve25519.KeyAgreement.PrivateKey(), phoneKey = own.publicKey.rawRepresentation
            guard let channel = try? Channel(role: "phone", own: own, mac: macKey, phone: phoneKey, token: paired.token,
                                             device: paired.device, nonce: nonce),
                  let answer = try? WireMessage.answer(key: phoneKey, proof: Wire.sessionProof(
                      token: paired.token, role: "phone", device: paired.device, nonce: nonce, keys: macKey + phoneKey)).encoded()
            else { return s.disconnect() }
            self.channel = channel
            try? s.send(answer, toPeers: [peer], with: .reliable)
        case let .paired(token):
            guard let pairing, pairing.peer == peer, let mac = macs[peer] else { return }
            let record = PairedMac(device: pairing.device, token: token, mac: mac, name: peer.displayName)
            if let failure = MacKeychain.save(record) {
                pairingError = "Couldn't keep the pairing in the Keychain (\(failure))."
                session?.disconnect()
                return
            }
            paired = record
            self.pairing = nil
            nearby = []
            // the Mac's challenge follows at once, under the new token
        default:
            break  // nothing else is taken before the channel is set up
        }
    }
}

extension Link: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let mac = info?["mac"]
        DispatchQueue.main.async { MainActor.assumeIsolated { self.found(peer, mac: mac) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lost(peer) } }
    }
}

extension Link: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.changed(session, peer, state) } }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(data, from: peer, in: session) } }
    }

    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peer: MCPeerID,
                             certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peer: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peer: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peer: MCPeerID, at url: URL?, withError error: Error?) {}
}

/// The pairing in this phone's Keychain, readable after the first unlock, never synced.
enum MacKeychain {
    private static let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                                 kSecAttrService: "com.opsidatech.notchban.mac", kSecAttrAccount: "pairing"]

    static func save(_ record: PairedMac) -> OSStatus? {
        guard let data = try? JSONEncoder().encode(record) else { return errSecParam }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        return status == errSecSuccess ? nil : status
    }

    static func read() -> PairedMac? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
