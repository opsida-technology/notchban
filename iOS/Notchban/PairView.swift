import MultipeerConnectivity
import SwiftUI

/// First run: find the Mac nearby and type the code it shows.
struct PairView: View {
    @EnvironmentObject var link: Link
    @State private var code = ""
    @State private var chosen: MCPeerID?
    @FocusState private var typing: Bool

    /// The Mac to pair with: the one tapped, or the only one nearby.
    private var target: MCPeerID? {
        if let chosen, link.nearby.contains(chosen) { return chosen }
        return link.nearby.count == 1 ? link.nearby[0] : nil
    }

    var body: some View {
        DesignScroll(spacing: 18) {
            island
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                FieldLabel(text: "Type the code your Mac shows")
                codeBoxes
                Text(link.pairingError ?? "On the Mac: board menu › Pair iPhone… The code works once, for two minutes.")
                    .font(Theme.font(13)).foregroundStyle(link.pairingError == nil ? Theme.onNotch2 : Theme.late.text)
                Button(action: pair) {
                    HStack(spacing: 8) {
                        if link.state == .connecting { ProgressView().tint(Theme.notch) }
                        Text(link.state == .connecting ? "Pairing…" : "Pair")
                    }
                }
                .buttonStyle(WhiteCapsuleStyle())
                .disabled(!ready)
                .padding(.top, 2)
            }
            .padding(18)
            .floatingIsland(radius: 34)
            VStack(alignment: .leading, spacing: 12) {
                fact("wifi", "Wi-Fi or Bluetooth, straight to your Mac")
                fact("lock", "Encrypted. No account, no server.")
                fact("doc.text", "Your boards stay KANBAN.md files on the Mac")
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
            if link.nearby.count > 1 {
                Text("Which Mac?").font(Theme.font(26, .bold)).frame(maxWidth: .infinity)
                FlowLayout(spacing: 8) {
                    ForEach(link.nearby, id: \.self) { peer in
                        let on = target == peer
                        Button { chosen = peer } label: {
                            Text(peer.displayName).font(Theme.font(14, .semibold))
                                .foregroundStyle(on ? Color.black : Theme.onNotch)
                                .padding(.horizontal, 16).frame(height: 44)
                                .background(Capsule().fill(on ? Theme.onNotch : Theme.notchWell)
                                    .overlay(Capsule().strokeBorder(on ? .clear : Theme.notchLine)))
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(target?.displayName ?? "Looking for your Mac…").font(Theme.font(26, .bold)).kerning(-0.6)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                Text(target == nil ? "Open notchban on the Mac, on the same Wi-Fi" : "Found on this Wi-Fi")
                    .font(Theme.font(13)).foregroundStyle(Theme.onNotch2).frame(maxWidth: .infinity)
            }
        }
    }

    /// Six boxes over one hidden text field, so the code can be typed or pasted from the keyboard's suggestion.
    private var codeBoxes: some View {
        let digits = Array(code)
        return ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($typing)
                .foregroundStyle(.clear).tint(.clear)
                .accessibilityLabel("Pairing code")
                .onChange(of: code) { _, new in
                    let only = String(new.filter(\.isNumber).prefix(6))
                    if only != new { code = only } else if only.count == 6 { pair() }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Text(i < digits.count ? String(digits[i]) : "")
                        .font(Theme.code).foregroundStyle(Theme.onNotch)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.notchWell))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(typing && i == min(digits.count, 5) ? Theme.sky.fill : Theme.notchLine,
                                          lineWidth: typing && i == min(digits.count, 5) ? 2 : 1))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { typing = true }
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

    private var ready: Bool { code.count == 6 && target != nil && link.state != .connecting }

    private func pair() {
        guard ready, let target else { return }
        link.pair(with: target, code: code)
    }
}
