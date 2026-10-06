import NotchbanCore
import SwiftUI

/// The board's second screen: who works where. Each live agent is a node with its folder, branch and the card it
/// works on; its subagents branch off below it. Built from the 10 s limits read; nothing more is polled.
struct AgentFlow: View {
    @EnvironmentObject var model: Model
    @ObservedObject var state: BoardState

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                ForEach(model.providers, id: \.name) { provider in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Text(provider.name).font(.system(size: 15, weight: .bold))
                            Chip(text: "\(provider.active) working", icon: "bolt.fill", tint: provider.active > 0 ? Theme.good : .secondary)
                            Text("5h \(Limit.percent(provider.fiveHour, now: model.now)) · week \(Limit.percent(provider.week, now: model.now))")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        if provider.agents.isEmpty {
                            Text("No live sessions").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(provider.agents) { agent in
                            AgentTree(agent: agent, links: links(agent)) { state.open($0.card.id, on: $0.board.path) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }

    /// The cards an agent works on: a card id, or the owner of a card, named in its title, folder or branch.
    /// The board of the agent's own repository is searched first; only when it has no board are all searched.
    private func links(_ agent: Agent) -> [(board: Board, card: Card)] {
        let text = [agent.title, (agent.folder as NSString).lastPathComponent, agent.branch].joined(separator: " ").lowercased()
        let own = model.boards.filter { agent.folder.hasPrefix(($0.path as NSString).deletingLastPathComponent + "/") || agent.folder == ($0.path as NSString).deletingLastPathComponent }
        func names(_ s: String) -> Bool {
            text.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: s.lowercased()) + "(?![a-z0-9])", options: .regularExpression) != nil
        }
        var found: [(board: Board, card: Card)] = []
        for board in own.isEmpty ? model.boards : own {
            for card in board.cards where card.column != .done {
                let owner = card.owner.map(Format.owner) ?? ""
                if names(card.id) || (owner.count >= 4 && names(owner)) { found.append((board, card)) }
            }
        }
        return Array(found.prefix(3))
    }
}

/// One agent and its subagents as branches off a rail.
struct AgentTree: View {
    let agent: Agent
    let links: [(board: Board, card: Card)]
    let open: ((board: Board, card: Card)) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            node
            ForEach(agent.subs) { sub in
                HStack(spacing: 0) {
                    Branch(last: sub.id == agent.subs.last?.id).stroke(Theme.upstream.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                        .frame(width: 26)
                    HStack(spacing: 6) {
                        Circle().fill(sub.working ? Theme.good : .gray.opacity(0.5)).frame(width: 6, height: 6)
                        Text(sub.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !sub.note.isEmpty { Text(sub.note).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.well))
                    .padding(.vertical, 3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
            }
        }
        .padding(.bottom, 6)
    }

    private var node: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(agent.working ? Theme.good : .gray.opacity(0.5)).frame(width: 7, height: 7)
                Text(agent.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Text(agent.working ? "working" : "idle").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(agent.working ? Theme.good : .secondary)
                if !agent.note.isEmpty { Text(agent.note).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            HStack(spacing: 6) {
                Label(agent.folder.replacingOccurrences(of: Usage.home.path, with: "~"), systemImage: "folder")
                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                if !agent.branch.isEmpty { Chip(text: agent.branch, icon: "arrow.triangle.branch", tint: Theme.column(.review)) }
            }
            .font(.system(size: 11))
            if !links.isEmpty {
                HStack(spacing: 6) {
                    ForEach(links, id: \.card.id) { link in
                        Button { open(link) } label: {
                            HStack(spacing: 4) {
                                Text(link.card.id).font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                Text(link.card.title).font(.system(size: 11)).lineLimit(1)
                                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                            }
                            .foregroundStyle(Theme.upstream)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.upstream.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(link.card.id) on \(link.board.name)")
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(agent.working ? Theme.good : .gray.opacity(0.4)).frame(width: 3).padding(.vertical, 10)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// The rail down from the agent and the rounded turn into one subagent.
struct Branch: Shape {
    let last: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x = rect.minX + 1, y = rect.midY, r: CGFloat = 8
        p.move(to: CGPoint(x: x, y: rect.minY))
        p.addLine(to: CGPoint(x: x, y: y - r))
        p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: rect.maxX - 2, y: y))
        if !last {
            p.move(to: CGPoint(x: x, y: y - r))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return p
    }
}
