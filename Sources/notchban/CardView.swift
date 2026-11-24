import NotchbanCore
import SwiftUI

/// How a card relates to the current focus (the selected card, or the critical path).
enum Role: Equatable {
    case plain, selected, upstream, downstream, critical(Int), dimmed

    var ring: Color? {
        switch self {
        case .selected: .accentColor
        case .upstream: Theme.upstream
        case .downstream: Theme.downstream
        case .critical: Theme.critical
        case .plain, .dimmed: nil
        }
    }
}

struct CardView: View {
    let card: Card
    let graph: BoardGraph
    let now: Date
    let role: Role
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var hover = false

    private var stale: Bool { card.isStale(at: now) }
    private var waits: Int { graph.waitsFor(card.id).count }
    private var unlocks: Int { graph.successors[card.id]?.count ?? 0 }
    private var gated: Bool { !graph.gateOpen(card) && card.column != .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            Text(Format.markdown(card.title))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(card.column == .done ? .secondary : .primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let blocker = card.blocker, card.column == .blocked {
                Text(Format.markdown(blocker)).lineLimit(2)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.alarm)
            }
            footer
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .topTrailing) { criticalBadge }
        .opacity(role == .dimmed ? 0.3 : 1)
        .scaleEffect(role == .selected ? 1.025 : hover ? 1.01 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: role)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        // a few beats, then it glows still: nothing redraws while idle
        .onAppear { if stale, !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatCount(5)) { pulse = true } } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(role == .selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The design's card: id and the owner's chip on top, the lease at the top right; tags below, and on the right
    /// what matters most for this column (review day, owner, what it waits for, or that the owner typed it in).
    private var header: some View {
        HStack(spacing: 5) {
            Text(card.id)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if gated {
                Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                    .help("Gated: waits for every Tier 0 card")
            }
            if card.isHumanEntered { HumanChip() }
            Spacer(minLength: 4)
            if card.column == .progress {
                Label(Format.lease(card.leaseExpires, now: now), systemImage: stale ? "bell.badge.fill" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stale ? Theme.alarm : Theme.good)
                    .lineLimit(1).fixedSize()
            } else {
                card.riskChip()
            }
        }
        .labelStyle(TightLabel())
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if let track = card.track { Chip(text: Format.track(track)).fixedSize() }
            if let size = card.size { Chip(text: size).fixedSize() }
            if unlocks > 0 {
                Label("\(unlocks)", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.downstream)
                    .help("Unlocks \(unlocks) card\(unlocks == 1 ? "" : "s")")
            }
            Spacer(minLength: 4)
            trailing.font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .labelStyle(TightLabel())
    }

    @ViewBuilder private var trailing: some View {
        if card.column == .review, let day = card.due {
            let due = Format.due(day, now: now)
            Label(due.text, systemImage: "calendar").fontWeight(.semibold)
                .foregroundStyle(due.late ? Theme.alarm : Theme.lavender)
        } else if let owner = card.owner {
            HStack(spacing: 4) {
                Avatar(owner: owner, size: 15)
                Text(Format.owner(owner)).foregroundStyle(.secondary)
            }
        } else if waits > 0 {
            let first = graph.waitsFor(card.id).first ?? ""
            Text(waits == 1 ? "after \(first)" : "after \(first) +\(waits - 1)").foregroundStyle(.secondary)
                .help("Waits for \(waits) open card\(waits == 1 ? "" : "s")")
        } else if card.isHumanEntered, card.column != .done {
            Text("from you").foregroundStyle(.secondary)
        } else if card.total > 0 {
            HStack(spacing: 4) {
                Text("\(card.checked)/\(card.total)").monospacedDigit().foregroundStyle(.secondary)
                Ring(done: card.checked, total: card.total)
            }
        }
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let ring = stale ? Theme.alarm : role == .selected ? Theme.column(card.column) : role.ring
        return shape.fill(Theme.card)
            .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            .overlay(shape.strokeBorder(ring ?? .clear, lineWidth: ring == nil ? 0 : (role == .selected ? 2 : 1)))
            .shadow(color: (ring ?? .black).opacity(ring == nil ? (hover ? 0.12 : 0.06) : (stale && pulse ? 0.45 : 0.18)),
                    radius: ring == nil ? (hover ? 8 : 3) : (stale && pulse ? 10 : 5), y: ring == nil ? 1.5 : 0)
    }

    @ViewBuilder private var criticalBadge: some View {
        if case .critical(let n) = role {
            Text("\(n)")
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Theme.critical))
                .offset(x: 6, y: -6)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(card.id), \(card.title)", card.column.rawValue]
        if card.isHumanEntered { parts.append("human entered") }
        if card.column == .review, let due = card.due { parts.append(Format.due(due, now: now).text) }
        if let owner = card.owner { parts.append("owner \(Format.owner(owner))") }
        if stale { parts.append("lease expired") }
        if let size = card.size { parts.append("size \(size)") }
        if let risk = card.risk, risk != "none" { parts.append("risk \(risk)") }
        if card.total > 0 { parts.append("\(card.checked) of \(card.total) checked") }
        if waits > 0 { parts.append("waits for \(waits)") }
        if unlocks > 0 { parts.append("unlocks \(unlocks)") }
        if let blocker = card.blocker { parts.append("blocked: \(blocker)") }
        return parts.joined(separator: ", ")
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}
