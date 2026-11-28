import CryptoKit
import Foundation
import MultipeerConnectivity
import Network
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
    /// The Mac's Tailscale address (or name), for reaching it away from home; sent by the Mac or typed by the owner.
    var remote: String?
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
    /// The card's `reviews` when the owner decided; the Mac refuses the verdict if the card has had another since.
    var seen: Int?
}

/// The phone's side of the link: finds the paired Mac nearby (MultipeerConnectivity, encryption required) or, when
/// it is not, over Tailscale (TCP to the Mac's Tailscale address, the same proofs and seal). Keeps the last snapshot
/// on disk and sends the owner's commands. Review verdicts wait on the phone when the Mac is out of reach and go when
/// it is back; every other command needs the Mac.
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
    /// The TCP link over Tailscale, while one is up or being made; nil while the link is nearby or there is none.
    private var far: NWConnection?
    private var frames = Frames(limit: 16 << 20)
    /// Nearby comes first: Tailscale is tried once the browser has had a moment, and not more than every 20 s.
    private var browsed = Date()
    private var dialed = Date.distantPast
    private var retry: Timer?

    private static let cache = URL.applicationSupportDirectory.appending(path: "snapshot.json")
    private static let queueFile = URL.applicationSupportDirectory.appending(path: "queue.json")
    private var flushing = false

    override init() {
        super.init()
        paired = MacKeychain.read()
        snapshot = (try? Data(contentsOf: Self.cache)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        queued = (try? Data(contentsOf: Self.queueFile)).flatMap { try? JSONDecoder().decode([Queued].self, from: $0) } ?? []
        browse()
        retry = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect() }
        }
        #if DEBUG
        // for testing against a debug Mac build in the simulator, which has no camera
        if paired == nil, let text = ProcessInfo.processInfo.environment["NOTCHBAN_PAIR_LINK"], let offer = PairingOffer(link: text) {
            pair(offer)
        }
        if paired != nil, let host = ProcessInfo.processInfo.environment["NOTCHBAN_FAR"] { setRemote(host) }
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
        browsed = Date()
        dialed = .distantPast  // back at the front: try Tailscale soon, if the Mac is not nearby
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.reconnect() }
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
        far?.cancel()
        far = nil
        state = .searching
        browse()
    }

    /// The Mac's Tailscale address, typed by the owner; empty clears it.
    func setRemote(_ text: String) {
        guard var record = paired else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        record.remote = value.isEmpty ? nil : value
        keep(record)
        dialed = .distantPast
        reconnect()
    }

    private func keep(_ record: PairedMac) {
        guard record.remote != paired?.remote || paired == nil else { return }
        if MacKeychain.save(record) == nil { paired = record }
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

    /// The Mac being paired with, or the paired one: nearby if it is, else over Tailscale.
    private func reconnect() {
        guard let secret, state == .searching else { return }
        guard let peer = macs.first(where: { $0.value == secret.mac })?.key else { return dial() }
        invite(peer, Invitation.paired(device: secret.device, name: me.displayName, token: secret.token))
    }

    /// Away from home: a TCP connection to the Mac's Tailscale address. Its first message is the same signed
    /// invitation as nearby; the Mac then sends its challenge. Pairing itself needs the QR code, so never this way.
    private func dial() {
        guard state == .searching, pairing == nil, let paired, let host = paired.remote,
              Date().timeIntervalSince(browsed) > 3, Date().timeIntervalSince(dialed) > 19,
              let port = NWEndpoint.Port(rawValue: Wire.port),
              let context = try? JSONEncoder().encode(Invitation.paired(device: paired.device, name: me.displayName, token: paired.token))
        else { return }
        dialed = Date()
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        far = c
        frames = Frames(limit: 16 << 20)
        channel = nil
        state = .connecting
        c.stateUpdateHandler = { [weak self] new in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.far === c else { return }
                    switch new {
                    case .ready: c.send(content: Frames.wrap(context), completion: .contentProcessed { _ in })
                    case .waiting, .failed: c.cancel()  // no route (Tailscale off) or refused: try again later
                    case .cancelled: self.dropped(c)
                    default: break
                    }
                }
            }
        }
        c.start(queue: .main)
        read(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.far === c, self.state == .connecting else { return }
            c.cancel()
        }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.far === c else { return }
                    if let data, !data.isEmpty {
                        guard let messages = try? self.frames.feed(data) else { return c.cancel() }
                        for message in messages where self.far === c { self.handle(message, from: self.paired?.name ?? "Mac") }
                    }
                    if done || error != nil { c.cancel() } else if self.far === c { self.read(c) }
                }
            }
        }
    }

    private func dropped(_ c: NWConnection) {
        guard far === c else { return }
        far = nil
        lost()
    }

    /// Sends on whichever link is up.
    private func transmit(_ data: Data) throws {
        if let session, !session.connectedPeers.isEmpty {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } else if let far {
            far.send(content: Frames.wrap(data), completion: .contentProcessed { _ in })
        } else {
            throw URLError(.networkConnectionLost)
        }
    }

    private func hangUp() {
        session?.disconnect()
        far?.cancel()
    }

    /// What this phone proves, and to which Mac: the scanned code's token while pairing, else the paired one's.
    private var secret: (device: String, token: Data, mac: String)? {
        if let pairing { return (pairing.device, pairing.offer.token, pairing.offer.mac) }
        return paired.map { ($0.device, $0.token, $0.mac) }
    }

    /// Pull to refresh: the Mac sends its boards whenever a session comes up, so drop this one and let it return.
    /// Waits (at most 10 s) for the boards to arrive, so the spinner means something.
    func refresh() async {
        let before = snapshot?.at
        dialed = .distantPast
        if let s = session, let peer = s.connectedPeers.first {
            s.disconnect(); changed(s, peer, .notConnected)
        } else if let c = far {
            c.cancel(); dropped(c)
        } else {
            reconnect()
        }
        for _ in 0..<40 {
            if isConnected, snapshot?.at != before { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: commands

    /// Sends a command and waits for the Mac's answer (at most 15 s).
    func run(_ command: BoardCommand) async -> Outcome {
        let id = UUID()
        guard isConnected, var channel, let message = try? channel.seal(.command(id: id, command)) else {
            return Outcome(error: "Your Mac isn't in reach. Try again when it is.", retry: true)
        }
        self.channel = channel
        do {
            try transmit(message)
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
        let seen = self.board(board)?.card(card)?.reviews
        if isConnected {
            let outcome = await run(.review(board: board, card: card, verdict: verdict, note: note, seen: seen))
            if !outcome.retry { return outcome }
        }
        queued.append(Queued(board: board, card: card, verdict: verdict, note: note, seen: seen))
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
                let outcome = await run(.review(board: next.board, card: next.card, verdict: next.verdict, note: next.note, seen: next.seen))
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
        #if DEBUG
        // NOTCHBAN_FAR=<host>: a paired simulator ignores the Mac nearby, to test the Tailscale path on the same machine
        if paired != nil, ProcessInfo.processInfo.environment["NOTCHBAN_FAR"] != nil { return }
        #endif
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
            lost()
        @unknown default:
            break
        }
    }

    /// The link went, whichever it was: the commands waiting on it get their answer, and the Mac is looked for again.
    private func lost() {
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
    }

    private func received(_ data: Data, from peer: MCPeerID, in s: MCSession) {
        guard s === session else { return }
        handle(data, from: peer.displayName)
    }

    private func handle(_ data: Data, from name: String) {
        if var channel {
            // anything that does not open as the Mac's next sealed message ends the link
            guard let message = try? channel.open(data) else { return hangUp() }
            self.channel = channel
            switch message {
            case let .snapshot(boards, at, ears, remote):
                if let pairing {  // the Mac proved the scanned token in this session: keep the pairing
                    let record = PairedMac(device: pairing.device, token: pairing.offer.token, mac: pairing.offer.mac, name: name, remote: remote)
                    if let failure = MacKeychain.save(record) {
                        pairingError = "Couldn't keep the pairing in the Keychain (\(failure))."
                        return hangUp()
                    }
                    paired = record
                    self.pairing = nil
                    nearby = []
                } else if let remote, var record = paired, record.remote != remote {
                    record.remote = remote  // the Mac's own word beats a typed one: it knows its address
                    keep(record)
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
            else { return hangUp() }
            let own = Curve25519.KeyAgreement.PrivateKey(), phoneKey = own.publicKey.rawRepresentation
            guard let channel = try? Channel(role: "phone", own: own, mac: macKey, phone: phoneKey, token: current.token,
                                             device: current.device, nonce: nonce),
                  let answer = try? WireMessage.answer(key: phoneKey, proof: Wire.sessionProof(
                      token: current.token, role: "phone", device: current.device, nonce: nonce, keys: macKey + phoneKey)).encoded()
            else { return hangUp() }
            self.channel = channel
            try? transmit(answer)
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
