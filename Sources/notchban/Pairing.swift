import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import CryptoKit
import MultipeerConnectivity
import Network
import NotchbanCore
import Security
import SwiftUI

/// The Mac's side of the iPhone link: MultipeerConnectivity (Wi-Fi, peer-to-peer Wi-Fi, Bluetooth; no server), encryption
/// required. A phone pairs once by scanning a QR code shown here, which hands it a token without sending it over the air;
/// from then on the Mac accepts only invitations that prove a paired phone's token. Each phone gets the boards on connect and after every change, and its commands go through
/// `Model.apply`, so the `KANBAN.md` files stay the only truth. Away from home a paired phone can come in over Tailscale
/// instead, when the owner turned that on: a TCP port on the Mac's Tailscale address only, the same proofs and seal.
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
    /// Paired phones may also come in over Tailscale (off until the owner turns it on).
    @Published private(set) var remote = UserDefaults.standard.bool(forKey: "tailscale")

    /// How a phone's messages travel: MultipeerConnectivity nearby, or a TCP connection over Tailscale.
    private enum Pipe {
        case near(MCSession, MCPeerID)
        case far(NWConnection)

        func send(_ data: Data) throws {
            switch self {
            case let .near(session, peer): try session.send(data, toPeers: [peer], with: .reliable)
            case let .far(connection): connection.send(content: Frames.wrap(data), completion: .contentProcessed { _ in })
            }
        }

        func close() {
            switch self {
            case let .near(session, _): session.disconnect()
            case let .far(connection): connection.cancel()
            }
        }
    }

    private struct Link {
        let pipe: Pipe
        var session: MCSession? { if case let .near(session, _) = pipe { session } else { nil } }
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
    /// Keyed by the MCPeerID nearby, by the connection's ObjectIdentifier over Tailscale.
    private var links: [AnyHashable: Link] = [:]
    private var listener: NWListener?
    /// The Tailscale address the listener is bound to, once it is up; sent to phones in each snapshot.
    private var address: String?
    private var frames: [ObjectIdentifier: Frames] = [:]
    private var recheck: Timer?
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
        listen()
        // Tailscale may come up, go down or change address while the app runs
        recheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.remote, Self.tailscaleAddress() != self.address else { return }
                self.listen()
            }
        }
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
        offer = PairingOffer(mac: macID, token: Wire.newToken(), remote: address)
        status = "Waiting for your iPhone…"
        advertise()
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close("The code ran out. Show a new one to pair.") }
        expiry = work
        var seconds = 120.0
        #if DEBUG
        // NOTCHBAN_PAIR_SECONDS: a longer code, for pairing a phone by hand from a debug build
        if let text = ProcessInfo.processInfo.environment["NOTCHBAN_PAIR_SECONDS"], let n = Double(text) { seconds = n }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
        for (key, link) in links where link.device == device {
            link.pipe.close()
            links[key] = nil
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
        guard let invitation, let pairing = admit(invitation) else { return answer(false, nil) }
        links[peer]?.pipe.close()
        let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        links[peer] = Link(pipe: .near(session, peer), device: invitation.device, name: String(invitation.name.prefix(60)),
                           pairing: pairing.isEmpty ? nil : pairing)
        answer(true, session)
    }

    /// Checks a fresh proof, spent once: a paired phone's token (the answer is empty), or the open pairing code's (the
    /// answer is that token, now used up). Nil turns the phone away.
    private func admit(_ invitation: Invitation) -> Data? {
        let now = Date()
        spent = spent.filter { now.timeIntervalSince($0.value) < TimeInterval(Wire.skew * 2) }
        guard let proof = invitation.proof, spent[proof] == nil else { return nil }
        if phones[invitation.device] != nil {
            guard let token = token(for: invitation.device), Wire.verify(invitation, token: token, now: now) else { return nil }
            spent[proof] = now
            return Data()
        } else if let offer, Wire.verify(invitation, token: offer.token, now: now) {
            // only a phone that read the code (scanned, or its link pasted) can sign with its token
            spent[proof] = now
            self.offer = nil  // good once
            expiry?.cancel()
            status = "Connecting to \(invitation.name)…"
            return offer.token
        }
        return nil
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
        guard let link = links[peer], link.session === session else { return }  // not an older, replaced session
        switch state {
        case .connected: challenge(peer)
        case .notConnected: closed(peer)
        case .connecting: break
        @unknown default: break
        }
    }

    /// The invitation proof is not tied to this session, so both ends prove the token again inside it, over one-time
    /// keys that become the session's own (see `Channel`). A link that has not answered in 10 s is dropped.
    private func challenge(_ key: AnyHashable) {
        guard var link = links[key] else { return }
        guard let token = secret(link) else { return drop(key) }
        let nonce = Wire.newNonce(), own = Curve25519.KeyAgreement.PrivateKey()
        let mine = own.publicKey.rawRepresentation
        link.nonce = nonce
        link.ephemeral = own
        links[key] = link
        do {
            try link.pipe.send(WireMessage.challenge(nonce: nonce, key: mine, proof: Wire.sessionProof(
                token: token, role: "mac", device: link.device, nonce: nonce, keys: mine)).encoded())
        } catch {
            return drop(key)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let now = self.links[key], now.nonce == nonce, !now.ready else { return }
            self.drop(key)
        }
    }

    /// The link is gone, whichever way it went.
    private func closed(_ key: AnyHashable) {
        guard let link = links.removeValue(forKey: key) else { return }
        if !links.values.contains(where: { $0.device == link.device && $0.ready }) { connected.remove(link.device) }
        if link.pairing != nil && !link.ready { status = "The iPhone didn't connect. Show a new code to try again." }
    }

    /// The link checks out: it gets snapshots and may send commands, all sealed in `channel`.
    private func open(_ key: AnyHashable, _ channel: Channel) {
        guard var link = links[key] else { return }
        if link.pairing != nil {
            let token = channel.paired  // not the code's token: that one may have travelled as a pasted link
            if let failure = PhoneKeychain.save(token, for: link.device) {
                status = "Couldn't keep the pairing in the Keychain (\(failure)). Show a new code to try again."
                return drop(key)
            }
            tokens[link.device] = token
            phones[link.device] = link.name
            status = "Paired with \(link.name)."
        }
        link.channel = channel
        link.nonce = nil
        link.ephemeral = nil
        links[key] = link
        connected.insert(link.device)
        send(snapshot, to: key)
    }

    private func drop(_ key: AnyHashable) {
        links[key]?.pipe.close()
        closed(key)
    }

    private func received(_ data: Data, from peer: MCPeerID, in session: MCSession) {
        guard links[peer]?.session === session else { return }
        handle(data, from: peer)
    }

    private func handle(_ data: Data, from key: AnyHashable) {
        guard var link = links[key] else { return }
        guard var channel = link.channel else {
            guard case let .answer(phoneKey, proof)? = try? WireMessage.decode(data), let nonce = link.nonce,
                  let own = link.ephemeral, let token = secret(link) else { return drop(key) }
            let macKey = own.publicKey.rawRepresentation
            guard Wire.verify(sessionProof: proof, token: token, role: "phone", device: link.device, nonce: nonce, keys: macKey + phoneKey),
                  let channel = try? Channel(role: "mac", own: own, mac: macKey, phone: phoneKey, token: token,
                                             device: link.device, nonce: nonce) else { return drop(key) }
            return open(key, channel)
        }
        // anything that does not open as the next sealed message ends the link
        guard let message = try? channel.open(data) else { return drop(key) }
        link.channel = channel
        links[key] = link
        guard case let .command(id, command) = message else { return }
        var added: String?, failure: String?
        do { added = try model.apply(command) } catch { failure = Self.sentence(error) }
        send(.result(id: id, added: added, error: failure), to: key)
    }

    private func broadcast() {
        let message = snapshot
        for key in links.filter(\.value.ready).keys { send(message, to: key) }
    }

    private var snapshot: WireMessage {
        .snapshot(boards: model.boards, at: Date(), ears: model.providers.map(Self.ear), remote: address)
    }

    private static func ear(_ p: Provider) -> NotchbanCore.Ear {
        NotchbanCore.Ear(name: p.name, working: p.active, fiveHour: p.fiveHour?.used, fiveHourResets: p.fiveHour?.resets,
            week: p.week?.used, weekResets: p.week?.resets, recorded: p.recorded)
    }

    /// Sealed in the link's channel; never sent before the handshake is done.
    private func send(_ message: WireMessage, to key: AnyHashable) {
        guard var link = links[key], var channel = link.channel else { return }
        do {
            let data = try channel.seal(message)
            link.channel = channel
            links[key] = link
            try link.pipe.send(data)
        } catch {
            NSLog("notchban: sending to %@ failed: %@", link.name, error.localizedDescription)
        }
    }

    // MARK: over Tailscale

    func setRemote(_ on: Bool) {
        remote = on
        UserDefaults.standard.set(on, forKey: "tailscale")
        listen()
    }

    /// Listens on the Mac's Tailscale address only, never on the local network or the internet; Tailscale's own
    /// encryption and access rules come first, then the same proofs and seal as nearby.
    private func listen() {
        listener?.cancel()
        listener = nil
        if address != nil { address = nil; broadcast() }
        for (key, link) in links { if case .far = link.pipe { drop(key) } }
        guard remote, let ip = Self.tailscaleAddress(), let port = NWEndpoint.Port(rawValue: Wire.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: port)
        parameters.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: parameters) else { return }
        l.stateUpdateHandler = { [weak self, weak l] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let l, self.listener === l else { return }
                    switch state {
                    case .ready: self.address = ip; self.broadcast()
                    case .failed: self.listener = nil; self.address = nil  // the minute's recheck tries again
                    default: break
                    }
                }
            }
        }
        l.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.arrived(connection) } }
        }
        l.start(queue: .main)
        listener = l
    }

    /// A knock on the Tailscale port. Its first message must be an invitation, small and within 10 s: a paired phone's,
    /// or one signed with the open pairing code (the owner pasted its link on a phone away from home).
    private func arrived(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        frames[id] = Frames(limit: 4_096)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.frames[id] = nil
                        self?.closed(id)
                    }
                }
            default: break
            }
        }
        connection.start(queue: .main)
        read(connection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.links[id] == nil, self.frames[id] != nil else { return }
            connection.cancel()
        }
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let id = ObjectIdentifier(connection)
                    if let data, !data.isEmpty {
                        guard let messages = try? self.frames[id]?.feed(data) else { return connection.cancel() }
                        for message in messages { self.framed(message, from: connection) }
                    }
                    if done || error != nil { connection.cancel() } else if self.frames[id] != nil { self.read(connection) }
                }
            }
        }
    }

    private func framed(_ data: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard links[id] == nil else { return handle(data, from: id) }
        guard let invitation = try? JSONDecoder().decode(Invitation.self, from: data),
              let pairing = admit(invitation) else { return connection.cancel() }
        links[id] = Link(pipe: .far(connection), device: invitation.device, name: String(invitation.name.prefix(60)),
                         pairing: pairing.isEmpty ? nil : pairing)
        frames[id]?.limit = 1 << 20  // a proved phone: its commands, never more than a note's length
        challenge(id)
    }

    /// This Mac's Tailscale IPv4 address (100.64.0.0/10, on a utun interface), if Tailscale is up.
    static func tailscaleAddress() -> String? {
        #if DEBUG
        // NOTCHBAN_LISTEN=127.0.0.1: a simulator on this Mac cannot reach the Mac's own Tailscale address
        if let ip = ProcessInfo.processInfo.environment["NOTCHBAN_LISTEN"] { return ip }
        #endif
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("utun") else { continue }
            let bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            if bytes[0] == 100, (64...127).contains(bytes[1]) { return bytes.map(String.init).joined(separator: ".") }
        }
        return nil
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
                if offer.remote != nil {
                    Button("Copy Link to Pair over Tailscale") {
                        // marked concealed, so clipboard managers do not keep it
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(offer.link, forType: .string)
                        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    }
                    .buttonStyle(.link).font(.callout)
                    .help("For a phone away from home: paste the link on its pairing screen. Send it only to yourself.")
                }
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
