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
    /// What the Mac's notch ears showed; nil from a Mac that sends none.
    var ears: [Ear]?
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
    /// The Mac never gave an answer (not nearby, link dropped, silence): the command may be sent again.
    var retry = false
    /// A verdict kept on the phone until the Mac is back.
    var queued = false
}

/// A verdict waiting on the phone for the Mac. Replaying one is safe: the Mac refuses a card no longer in review.
struct Queued: Codable, Identifiable, Equatable {
    var id = UUID()
    var board: String
    var card: String
    var verdict: Verdict
    var note: String
}

/// The phone's side of the link: finds the paired Mac nearby (MultipeerConnectivity, encryption required), keeps the
/// last snapshot on disk, and sends the owner's commands. Review verdicts wait on the phone when the Mac is away
/// and go when it is back; every other command needs the Mac nearby.
@MainActor
final class Link: NSObject, ObservableObject {
    enum State { case searching, connecting, connected }

    @Published private(set) var state = State.searching
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var paired: PairedMac?
    /// Macs that can be paired with, while this phone is not paired.
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var pairingError: String?
    /// Verdicts given while the Mac was away, oldest first.
    @Published private(set) var queued: [Queued] = []
    /// What happened to queued verdicts the Mac refused, to show once.
    @Published var notice: String?

    var isConnected: Bool { state == .connected }

    private let me = MCPeerID(displayName: String(UIDevice.current.name.prefix(40)))
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    /// Every Mac found, with its discovery id.
    private var macs: [MCPeerID: String] = [:]
    /// The device id and scanned QR code of a pairing in flight; kept only once the Mac proves the token in a session.
    private var pairing: (device: String, offer: PairingOffer)?
    private var waiting: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    /// Set once this session's Mac proved the token over its one-time key: snapshots and results come only sealed in it.
    private var channel: Channel?

    private static let cache = URL.applicationSupportDirectory.appending(path: "snapshot.json")
    private static let queueFile = URL.applicationSupportDirectory.appending(path: "queue.json")
    private var flushing = false

    override init() {
        super.init()
        paired = MacKeychain.read()
        snapshot = (try? Data(contentsOf: Self.cache)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        queued = (try? Data(contentsOf: Self.queueFile)).flatMap { try? JSONDecoder().decode([Queued].self, from: $0) } ?? []
        browse()
        #if DEBUG
        // for testing against a debug Mac build in the simulator, which has no camera
        if paired == nil, let text = ProcessInfo.processInfo.environment["NOTCHBAN_PAIR_LINK"], let offer = PairingOffer(link: text) {
            pair(offer)
        }
        #endif
    }

    func board(_ path: String) -> Board? { snapshot?.boards.first { $0.path == path } }

    /// Starts looking again (the app came back to the front, or a link dropped).
    func browse() {
        // restarting the browser while inviting would drop the invitation without a word
        guard state == .searching else { return }
        browser?.stopBrowsingForPeers()
        macs = [:]
        nearby = []
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Wire.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    // MARK: pairing

    /// Pairs with the Mac whose QR code was scanned, as soon as it is found nearby.
    func pair(_ offer: PairingOffer) {
        pairing = (UUID().uuidString, offer)
        pairingError = nil
        reconnect()
    }

    /// Drops the pairing and the boards it brought. The Mac keeps its side until "Forget This iPhone" there.
    func forget() {
        MacKeychain.delete()
        paired = nil
        pairing = nil
        snapshot = nil
        try? FileManager.default.removeItem(at: Self.cache)
        queued = []
        saveQueue()
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
        // MultipeerConnectivity does not always report a declined or lost invitation: give up on it ourselves
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.session === s, self.state == .connecting else { return }
            s.disconnect()
            self.changed(s, peer, .notConnected)
        }
    }

    /// The Mac being paired with, or the paired one, if it is in reach.
    private func reconnect() {
        guard let secret, state == .searching,
              let peer = macs.first(where: { $0.value == secret.mac })?.key else { return }
        invite(peer, Invitation.paired(device: secret.device, name: me.displayName, token: secret.token))
    }

    /// What this phone proves, and to which Mac: the scanned code's token while pairing, else the paired one's.
    private var secret: (device: String, token: Data, mac: String)? {
        if let pairing { return (pairing.device, pairing.offer.token, pairing.offer.mac) }
        return paired.map { ($0.device, $0.token, $0.mac) }
    }

    // MARK: commands

    /// Sends a command and waits for the Mac's answer (at most 15 s).
    func run(_ command: BoardCommand) async -> Outcome {
        let id = UUID()
        guard let session, isConnected, var channel, let message = try? channel.seal(.command(id: id, command)) else {
            return Outcome(error: "Your Mac isn't nearby. Try again when it is.", retry: true)
        }
        self.channel = channel
        do {
            try session.send(message, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            return Outcome(error: "Couldn't reach your Mac: \(error.localizedDescription)", retry: true)
        }
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.waiting.removeValue(forKey: id)?.resume(returning: Outcome(error: "Your Mac didn't answer. Check the board before trying again.", retry: true))
            }
        }
    }

    /// A verdict: sent now when the Mac is near, else kept on the phone and sent when it is back.
    func review(board: String, card: String, verdict: Verdict, note: String) async -> Outcome {
        if isConnected {
            let outcome = await run(.review(board: board, card: card, verdict: verdict, note: note))
            if !outcome.retry { return outcome }
        }
        queued.append(Queued(board: board, card: card, verdict: verdict, note: note))
        saveQueue()
        return Outcome(queued: true)
    }

    func isQueued(_ board: String, _ card: String) -> Bool { queued.contains { $0.board == board && $0.card == card } }

    /// Sends the waiting verdicts in order; stops at the first the Mac cannot be asked, reports the ones it refuses.
    private func flush() {
        guard !flushing, !queued.isEmpty else { return }
        flushing = true
        Task {
            var refused: [String] = []
            while let next = queued.first, isConnected {
                let outcome = await run(.review(board: next.board, card: next.card, verdict: next.verdict, note: next.note))
                if outcome.retry { break }
                queued.removeAll { $0.id == next.id }
                saveQueue()
                if outcome.error != nil { refused.append(next.card) }
            }
            flushing = false
            if !refused.isEmpty {
                notice = "\(refused.joined(separator: ", ")) \(refused.count == 1 ? "was" : "were") already decided on your Mac."
            }
        }
    }

    private func saveQueue() {
        guard !queued.isEmpty else {
            try? FileManager.default.removeItem(at: Self.queueFile)
            return
        }
        try? FileManager.default.createDirectory(at: Self.queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(queued) {
            try? data.write(to: Self.queueFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: events

    private func found(_ peer: MCPeerID, mac: String?, by b: MCNearbyServiceBrowser) {
        // a peer found by a browser since replaced cannot be invited through the new one
        guard let mac, b === browser else { return }
        macs[peer] = mac
        if paired == nil, !nearby.contains(peer) { nearby.append(peer) }
        reconnect()
    }

    private func lost(_ peer: MCPeerID, by b: MCNearbyServiceBrowser) {
        guard b === browser else { return }
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
            for (_, c) in waiting { c.resume(returning: Outcome(error: "The link to your Mac dropped. Check the board before trying again.", retry: true)) }
            waiting = [:]
            if pairing != nil {
                pairing = nil
                pairingError = "Your Mac didn't accept that code. Show a new one on the Mac and scan it again."
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
            case let .snapshot(boards, at, ears):
                if let pairing {  // the Mac proved the scanned token in this session: keep the pairing
                    let record = PairedMac(device: pairing.device, token: pairing.offer.token, mac: pairing.offer.mac, name: peer.displayName)
                    if let failure = MacKeychain.save(record) {
                        pairingError = "Couldn't keep the pairing in the Keychain (\(failure))."
                        return s.disconnect()
                    }
                    paired = record
                    self.pairing = nil
                    nearby = []
                }
                state = .connected
                let fresh = Snapshot(boards: boards, at: at, ears: ears)
                snapshot = fresh
                if let data = try? JSONEncoder().encode(fresh) {
                    try? FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                flush()
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
            guard let current = secret, Wire.verify(sessionProof: proof, token: current.token, role: "mac",
                                                    device: current.device, nonce: nonce, keys: macKey)
            else { return s.disconnect() }
            let own = Curve25519.KeyAgreement.PrivateKey(), phoneKey = own.publicKey.rawRepresentation
            guard let channel = try? Channel(role: "phone", own: own, mac: macKey, phone: phoneKey, token: current.token,
                                             device: current.device, nonce: nonce),
                  let answer = try? WireMessage.answer(key: phoneKey, proof: Wire.sessionProof(
                      token: current.token, role: "phone", device: current.device, nonce: nonce, keys: macKey + phoneKey)).encoded()
            else { return s.disconnect() }
            self.channel = channel
            try? s.send(answer, toPeers: [peer], with: .reliable)
        default:
            break  // nothing else is taken before the channel is set up
        }
    }
}

extension Link: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let mac = info?["mac"]
        DispatchQueue.main.async { MainActor.assumeIsolated { self.found(peer, mac: mac, by: browser) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lost(peer, by: browser) } }
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
