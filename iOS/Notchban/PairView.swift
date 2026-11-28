import AVFoundation
import NotchbanCore
import SwiftUI
import VisionKit

/// First run: scan the QR code the Mac shows. It carries the pairing token from the Mac's screen to the camera, so the
/// token never goes over the air. Away from home, the owner can paste the code's link instead and pair over Tailscale.
struct PairView: View {
    @EnvironmentObject var link: Link
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        DesignScroll(spacing: 18) {
            island
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                FieldLabel(text: "Scan the code your Mac shows")
                Text(problem ?? link.pairingError ?? "On the Mac: board menu › Pair iPhone… The code works once, for two minutes.")
                    .font(Theme.font(13))
                    .foregroundStyle(problem == nil && link.pairingError == nil ? Theme.onNotch2 : Theme.late.text)
                Button(action: scan) {
                    HStack(spacing: 8) {
                        if link.state == .connecting { ProgressView().tint(Theme.notch) } else { Image(systemName: "qrcode.viewfinder") }
                        Text(link.state == .connecting ? "Pairing…" : "Scan the Code")
                    }
                }
                .buttonStyle(WhiteCapsuleStyle())
                .disabled(link.state == .connecting)
                .padding(.top, 2)
                HStack(spacing: 10) {
                    Text("Away from home? Paste the code's link to pair over Tailscale.")
                        .font(Theme.font(13)).foregroundStyle(Theme.onNotch2)
                    Spacer(minLength: 0)
                    PasteButton(payloadType: String.self) { texts in
                        Task { @MainActor in paste(texts.first ?? "") }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.onNotch2)
                    .disabled(link.state == .connecting)
                }
            }
            .padding(18)
            .floatingIsland(radius: 34)
            VStack(alignment: .leading, spacing: 12) {
                fact("wifi", "Wi-Fi or Bluetooth, straight to your Mac")
                fact("lock", "Encrypted. No account, no server.")
                fact("doc.text", "Your boards stay KANBAN.md files on the Mac")
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { offer in
                scanning = false
                link.pair(offer)
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text("Point at the code on your Mac").font(Theme.font(15, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.top, 24)
            }
        }
    }

    private var island: some View {
        Island(spacing: 6) {
            // the rings sit in an overlay, so their 370 pt never widens the screen
            Color.clear.frame(maxWidth: .infinity).frame(height: 210).overlay {
                ForEach(Array([(130.0, 0.35), (210, 0.22), (290, 0.12), (370, 0.0)].enumerated()), id: \.offset) { _, ring in
                    Circle().strokeBorder(ring.1 == 0 ? Color.white.opacity(0.12) : Color(hex: 0x6CC4FF).opacity(ring.1))
                        .frame(width: ring.0, height: ring.0)
                }
                Image(systemName: "laptopcomputer").font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color(hex: 0x6CC4FF))
                    .frame(width: 66, height: 66)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(hex: 0x101828)))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color(hex: 0x6CC4FF).opacity(0.35)))
                    .shadow(color: Color(hex: 0x4DB8FF).opacity(0.35), radius: 20)
                    .opacity(link.nearby.isEmpty ? 0.5 : 1)
            }
            .clipped()
            .padding(.horizontal, -20) // out to the island's edges
            .accessibilityHidden(true)
            Text(link.nearby.count == 1 ? link.nearby[0].displayName : link.nearby.isEmpty ? "Looking for your Mac…" : "\(link.nearby.count) Macs nearby")
                .font(Theme.font(26, .bold)).kerning(-0.6)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Text(link.nearby.isEmpty ? "Open notchban on the Mac, on the same Wi-Fi" : "Found on this Wi-Fi")
                .font(Theme.font(13)).foregroundStyle(Theme.onNotch2).frame(maxWidth: .infinity)
        }
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.fg)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.well))
            Text(text).font(Theme.body).foregroundStyle(Theme.fg2)
        }
        .accessibilityElement(children: .combine)
    }

    private func paste(_ text: String) {
        problem = nil
        guard let offer = PairingOffer(link: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            problem = "That isn't a pairing link. Copy the whole link, from notchban:pair to its end."
            return
        }
        link.pair(offer)
    }

    private func scan() {
        problem = nil
        guard DataScannerViewController.isSupported else {
            problem = "This iPhone can't scan codes with its camera."
            return
        }
        Task {
            if await AVCaptureDevice.requestAccess(for: .video) {
                scanning = true
            } else {
                problem = "Notchban needs the camera to read the code. Allow it in Settings › Notchban."
            }
        }
    }
}

/// The camera, reading QR codes until one is a notchban pairing code.
struct QRScanner: UIViewControllerRepresentable {
    var found: (PairingOffer) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (PairingOffer) -> Void
        private var done = false

        init(_ found: @escaping (PairingOffer) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                guard !done, let text = code.payloadStringValue, let offer = PairingOffer(link: text) else { continue }
                done = true
                scanner.stopScanning()
                found(offer)
            }
        }
    }
}
