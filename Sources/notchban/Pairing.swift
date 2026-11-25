import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import CryptoKit
import MultipeerConnectivity
import NotchbanCore
import Security
import SwiftUI

/// The Mac's side of the iPhone link: MultipeerConnectivity (Wi-Fi, peer-to-peer Wi-Fi, Bluetooth; no server), encryption
/// required. A phone pairs once by scanning a QR code shown here, which hands it a token without sending it over the air;
/// from then on the Mac accepts only invitations that prove a paired phone's token. Each phone gets the boards on connect and after every change, and its commands go through
/// `Model.apply`, so the `KANBAN.md` files stay the only truth.
@MainActor
final class Pairing: NSObject, ObservableObject {
    /// The QR code the open pairing window shows; nil when no phone may pair.
    @Published private(set) var offer: PairingOffer?
    @Published private(set) var status = ""
    /// Paired phones, device id → name. Their tokens are in the Keychain, never here.
    @Published private(set) var phones = UserDefaults.standard.dictionary(forKey: "pairedPhones") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(phones, forKey: "pairedPhones"); advertise() }
    }
    /// Device ids with a live link.
    @Published private(set) var connected: Set<String> = []

    private struct Link {
        let session: MCSession
        let device: String
        let name: String
        /// Came in with the QR code's token: the phone is kept once it proves the token in this session.
        let pairing: Data?
        /// The challenge a paired phone must answer in this session before anything else, and the Mac's one-time key for it.
        var nonce: Data?
        var ephemeral: Curve25519.KeyAgreement.PrivateKey?
        /// Set once the phone answered: every message after that is sealed in it.
        var channel: Channel?
        var ready: Bool { channel != nil }
    }

    private let model: Model
    private let me = MCPeerID(displayName: String((Host.current().localizedName ?? "Mac").prefix(40)))
    /// Lets a paired phone tell its Mac from another one nearby. Not a secret.
    private let macID: String = {
        if let id = UserDefaults.standard.string(forKey: "pairingMacID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "pairingMacID")
        return id
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var links: [MCPeerID: Link] = [:]
    /// Tokens read from the Keychain, read when a phone first knocks.
    private var tokens: [String: Data] = [:]
    /// Proofs already used, so an overheard invitation cannot be replayed.
    private var spent: [Data: Date] = [:]
    private var expiry: DispatchWorkItem?
    private var window: NSWindow?
    private var watch: AnyCancellable?

    init(model: Model) {
        self.model = model
        super.init()
    }

    func start() {
        advertise()
        // a board changed, or what the ears show did (not every read of the sessions, which changes their notes)
        let ears = model.$providers.map { $0.map(Self.ear) }.removeDuplicates().map { _ in () }
        watch = model.$boards.map { _ in () }.merge(with: ears).dropFirst(2)
            .debounce(for: .seconds(1), scheduler: RunLoop.main).sink { [weak self] in self?.broadcast() }
        #if DEBUG
        // for testing a debug build against the simulator, which has no camera: NOTCHBAN_PAIR=1 opens the window and
        // prints the QR code's link
        if ProcessInfo.processInfo.environment["NOTCHBAN_PAIR"] == "1" {
            showWindow()
            NSLog("pairing link: %@", offer?.link ?? "-")
        }
        #endif
    }

    /// Advertise only while a phone is paired or may pair.
    private func advertise() {
        let wanted = !phones.isEmpty || offer != nil
        if wanted, advertiser == nil {
            let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["mac": macID], serviceType: Wire.service)
            a.delegate = self
            a.startAdvertisingPeer()
            advertiser = a
        } else if !wanted, let a = advertiser {
            a.stopAdvertisingPeer()
            advertiser = nil
        }
    }

    // MARK: pairing window

    /// A fresh QR code, good once, for two minutes.
    func open() {
        offer = PairingOffer(mac: macID, token: Wire.newToken())
        status = "Waiting for your iPhone…"
        advertise()
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close("The code ran out. Show a new one to pair.") }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func close(_ message: String = "") {
        offer = nil
        expiry?.cancel()
        status = message
        advertise()
    }

    func forget(_ device: String) {
        PhoneKeychain.delete(device)
        tokens[device] = nil
        phones[device] = nil
        for (peer, link) in links where link.device == device {
            link.session.disconnect()
            links[peer] = nil
        }
        connected.remove(device)
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Pair iPhone"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.delegate = self
            w.contentView = NSHostingView(rootView: PairView(pairing: self))
            w.center()
            window = w
        }
        if offer == nil { open() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: invitations

    private func invited(_ peer: MCPeerID, _ invitation: Invitation?, _ answer: @escaping (Bool, MCSession?) -> Void) {
        let now = Date()
        spent = spent.filter { now.timeIntervalSince($0.value) < TimeInterval(Wire.skew * 2) }
        guard let invitation, let proof = invitation.proof, spent[proof] == nil else { return answer(false, nil) }
        if phones[invitation.device] != nil {
            guard let token = token(for: invitation.device), Wire.verify(invitation, token: token, now: now) else { return answer(false, nil) }
            spent[proof] = now
            accept(peer, invitation, pairing: nil, answer)
        } else if let offer, Wire.verify(invitation, token: offer.token, now: now) {
            // only a phone that read the QR code can sign with its token
            spent[proof] = now
            self.offer = nil  // good once
            expiry?.cancel()
            status = "Connecting to \(invitation.name)…"
            accept(peer, invitation, pairing: offer.token, answer)
        } else {
            answer(false, nil)
        }
    }

    private func accept(_ peer: MCPeerID, _ invitation: Invitation, pairing: Data?, _ answer: (Bool, MCSession?) -> Void) {
        links[peer]?.session.disconnect()
        let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        links[peer] = Link(session: session, device: invitation.device, name: String(invitation.name.prefix(60)), pairing: pairing)
        answer(true, session)
    }

    /// The token this link must prove: the QR code's while pairing, else the paired phone's.
    private func secret(_ link: Link) -> Data? { link.pairing ?? token(for: link.device) }

    private func token(for device: String) -> Data? {
        if let t = tokens[device] { return t }
        let t = PhoneKeychain.read(device)
        tokens[device] = t
        return t
    }

    // MARK: session

    private func changed(_ peer: MCPeerID, _ state: MCSessionState, in session: MCSession) {
        guard var link = links[peer], link.session === session else { return }  // not an older, replaced session
        switch state {
        case .connected:
            // The invitation proof is not tied to this session, so both ends prove the token again inside it, over
            // one-time keys that become the session's own (see `Channel`).
            guard let token = secret(link) else { return drop(peer) }
            let nonce = Wire.newNonce(), own = Curve25519.KeyAgreement.PrivateKey()
            let key = own.publicKey.rawRepresentation
            link.nonce = nonce
            link.ephemeral = own
            links[peer] = link
            sendPlain(.challenge(nonce: nonce, key: key, proof: Wire.sessionProof(token: token, role: "mac", device: link.device,
                                                                                  nonce: nonce, keys: key)),
                      to: peer, in: link.session)
            let session = link.session
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, let link = self.links[peer], link.session === session, !link.ready else { return }
                self.drop(peer)
            }
        case .notConnected:
            links[peer] = nil
            if !links.values.contains(where: { $0.device == link.device && $0.ready }) { connected.remove(link.device) }
            if link.pairing != nil && !link.ready { status = "The iPhone didn't connect. Show a new code to try again." }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    /// The link checks out: it gets snapshots and may send commands, all sealed in `channel`.
    private func open(_ peer: MCPeerID, _ channel: Channel) {
        guard var link = links[peer] else { return }
        if let token = link.pairing {
            if let failure = PhoneKeychain.save(token, for: link.device) {
                status = "Couldn't keep the pairing in the Keychain (\(failure)). Show a new code to try again."
                return drop(peer)
            }
            tokens[link.device] = token
            phones[link.device] = link.name
            status = "Paired with \(link.name)."
        }
        link.channel = channel
        link.nonce = nil
        link.ephemeral = nil
        links[peer] = link
        connected.insert(link.device)
        send(snapshot, to: peer)
    }

    private func drop(_ peer: MCPeerID) {
        links[peer]?.session.disconnect()
        links[peer] = nil
    }

    private func received(_ data: Data, from peer: MCPeerID, in session: MCSession) {
        guard var link = links[peer], link.session === session else { return }
        guard var channel = link.channel else {
            guard case let .answer(phoneKey, proof)? = try? WireMessage.decode(data), let nonce = link.nonce,
                  let own = link.ephemeral, let token = secret(link) else { return drop(peer) }
            let macKey = own.publicKey.rawRepresentation
            guard Wire.verify(sessionProof: proof, token: token, role: "phone", device: link.device, nonce: nonce, keys: macKey + phoneKey),
                  let channel = try? Channel(role: "mac", own: own, mac: macKey, phone: phoneKey, token: token,
                                             device: link.device, nonce: nonce) else { return drop(peer) }
            return open(peer, channel)
        }
        // anything that does not open as the next sealed message ends the link
        guard let message = try? channel.open(data) else { return drop(peer) }
        link.channel = channel
        links[peer] = link
        guard case let .command(id, command) = message else { return }
        var added: String?, failure: String?
        do { added = try model.apply(command) } catch { failure = Self.sentence(error) }
        send(.result(id: id, added: added, error: failure), to: peer)
    }

    private func broadcast() {
        let message = snapshot
        for peer in links.filter(\.value.ready).keys { send(message, to: peer) }
    }

    private var snapshot: WireMessage { .snapshot(boards: model.boards, at: Date(), ears: model.providers.map(Self.ear)) }

    private static func ear(_ p: Provider) -> NotchbanCore.Ear {
        NotchbanCore.Ear(name: p.name, working: p.active, fiveHour: p.fiveHour?.used, fiveHourResets: p.fiveHour?.resets,
            week: p.week?.used, weekResets: p.week?.resets, recorded: p.recorded)
    }

    /// Sealed in the peer's channel; never sent before the handshake is done.
    private func send(_ message: WireMessage, to peer: MCPeerID) {
        guard var link = links[peer], var channel = link.channel else { return }
        do {
            let data = try channel.seal(message)
            link.channel = channel
            links[peer] = link
            try link.session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            NSLog("notchban: sending to %@ failed: %@", peer.displayName, error.localizedDescription)
        }
    }

    /// The handshake's own messages, the only ones that travel unsealed.
    private func sendPlain(_ message: WireMessage, to peer: MCPeerID, in session: MCSession) {
        do {
            try session.send(message.encoded(), toPeers: [peer], with: .reliable)
        } catch {
            NSLog("notchban: sending to %@ failed: %@", peer.displayName, error.localizedDescription)
        }
    }

    /// What the owner reads on the phone when a command could not be applied.
    static func sentence(_ error: Error) -> String {
        switch error as? BoardEditor.Failure {
        case .notABoard: "This board isn't on the Mac any more."
        case .noColumn(let column): "This board has no \(column.rawValue) column."
        case .noCard(let id): "Card \(id) isn't on the board any more."
        case .notInReview: "This card has moved since your phone saw it."
        case .emptyText: "Write something first."
        case .badDay(let day): "\(day) isn't a date."
        case nil: "The Mac couldn't save the board: \(error.localizedDescription)"
        }
    }
}

extension Pairing: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let invitation = context.flatMap { try? JSONDecoder().decode(Invitation.self, from: $0) }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.invited(peer, invitation, invitationHandler) } }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.status = "Can't be found by the iPhone: \(error.localizedDescription)" } }
    }
}

extension Pairing: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.changed(peer, state, in: session) } }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(data, from: peer, in: session) } }
    }

    /// The transport's encryption has no identity of its own. What lets a phone in is the token: proved in the invitation,
    /// then again over this session's one-time keys, which seal everything after (see `Channel`).
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peer: MCPeerID,
                             certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peer: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peer: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peer: MCPeerID, at url: URL?, withError error: Error?) {}
}

extension Pairing: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if offer != nil { close() }
    }
}

/// Pairing tokens in the login Keychain, one item per phone.
enum PhoneKeychain {
    private static let service = "com.opsidatech.notchban.phone"

    private static func query(_ device: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: device]
    }

    /// nil when saved, else the OSStatus.
    static func save(_ token: Data, for device: String) -> OSStatus? {
        SecItemDelete(query(device) as CFDictionary)
        var item = query(device)
        item[kSecValueData] = token
        item[kSecAttrLabel] = "Notchban paired iPhone"
        let status = SecItemAdd(item as CFDictionary, nil)
        return status == errSecSuccess ? nil : status
    }

    static func read(_ device: String) -> Data? {
        var q = query(device)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ device: String) {
        SecItemDelete(query(device) as CFDictionary)
    }
}

/// "Pair iPhone…": the QR code, what is happening, and the phones already paired.
struct PairView: View {
    @ObservedObject var pairing: Pairing

    var body: some View {
        VStack(spacing: 14) {
            if let offer = pairing.offer {
                Text("Scan this with Notchban on your iPhone").font(.headline).multilineTextAlignment(.center)
                Image(nsImage: Self.qr(offer.link)).interpolation(.none).resizable()
                    .frame(width: 200, height: 200)
                    .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Pairing QR code")
                Text("It works once, for two minutes.").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Show a Pairing Code") { pairing.open() }.controlSize(.large).keyboardShortcut(.defaultAction)
            }
            if !pairing.status.isEmpty { Text(pairing.status).font(.callout) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Paired iPhones").font(.subheadline.weight(.semibold))
                if pairing.phones.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(pairing.phones.sorted(by: { $0.value < $1.value }), id: \.key) { device, name in
                    HStack {
                        Image(systemName: "iphone")
                        Text(name)
                        Text(pairing.connected.contains(device) ? "Connected" : "Not nearby").foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget This iPhone") { pairing.forget(device) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Black on white, one pixel per module; the view scales it up without smoothing.
    static func qr(_ text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage, let cg = CIContext().createCGImage(image, from: image.extent) else { return NSImage() }
        return NSImage(cgImage: cg, size: image.extent.size)
    }
}
