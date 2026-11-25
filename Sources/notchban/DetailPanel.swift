import AppKit
import NotchbanCore
import SwiftUI

/// The side sheet of one card: facts, owner and lease, blocker, proof, dependencies, checklist, notes.
struct DetailPanel: View {
    @EnvironmentObject var model: Model
    @ObservedObject var state: BoardState
    let board: Board
    let graph: BoardGraph
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(card.id).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Chip(text: card.column.rawValue, icon: Theme.columnIcon(card.column), tint: Theme.column(card.column))
                Spacer()
                Button { state.detail = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Format.markdown(card.title)).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if card.track ?? card.phase ?? card.tier != nil || card.size ?? card.risk ?? card.gate ?? card.source ?? card.due != nil { facts }
                    if card.column == .review, let needs = card.needs { needsBlock(needs) }
                    if let owner = card.owner { ownerBlock(owner) }
                    if let blocker = card.blocker {
                        Callout(icon: "exclamationmark.octagon.fill", tint: Theme.alarm, title: "Blocked") { Text(Format.markdown(blocker)) }
                    }
                    if !card.proof.isEmpty {
                        Callout(icon: "checkmark.seal.fill", tint: Theme.column(.done), title: "Proof") {
                            ForEach(card.proof, id: \.self) { Text(Format.markdown($0)).font(.system(size: 12, design: .monospaced)) }
                        }
                    }
                    dependencies
                    if !card.checklist.isEmpty { checklist }
                    let notes = card.notes.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("Needs:") }.joined(separator: "\n")
                    if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        PanelSection(title: "Notes") {
                            Text(Format.markdown(Format.unwrap(notes))).font(.system(size: 12.5)).lineSpacing(2.5)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if card.column == .review { verdicts }
                    actions
                    footer
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(Glass(material: .popover, blending: .withinWindow).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.25), radius: 24, x: -4)
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card \(card.id) details")
    }

    private var facts: some View {
        let due = card.column == .review ? card.due.map { Format.due($0, now: model.now) } : nil
        let items: [(String, String, Color)] = [
            due.map { ($0.text, "calendar", $0.late ? Theme.alarm : .secondary) },
            card.track.map { (Format.track($0), "point.3.connected.trianglepath.dotted", Theme.track($0) ?? .secondary) },
            card.phase.map { ("Phase \($0)", "flag", .secondary) },
            card.size.map { ("Size \($0)", "ruler", .secondary) },
            card.risk.map { ("Risk \($0)", "shield.lefthalf.filled", $0 == "none" ? .secondary : Theme.alarm) },
            card.tier.map { ("Tier \($0)", "square.stack.3d.up", .secondary) },
            card.gate.map { ("Gate \($0)\(graph.gateOpen(card) ? " · open" : " · closed")", graph.gateOpen(card) ? "lock.open" : "lock.fill", .secondary) },
        ].compactMap { $0 }
        return FlowLayout {
            if card.isHumanEntered { HumanChip() }
            ForEach(items, id: \.0) { Chip(text: $0.0, icon: $0.1, tint: $0.2) }
        }
    }

    /// What the agent needs from the owner, in the notch's black: black is the owner's.
    private func needsBlock(_ needs: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEEDS YOU TO").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.75))
            Text(Format.markdown(needs)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14))))
        .accessibilityElement(children: .combine)
    }

    private func ownerBlock(_ owner: String) -> some View {
        let stale = card.isStale(at: model.now)
        return HStack(spacing: 10) {
            Avatar(owner: owner, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.owner(owner)).font(.system(size: 13, weight: .semibold))
                Text(card.task ?? owner).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if card.column == .progress {
                Label(Format.lease(card.leaseExpires, now: model.now), systemImage: stale ? "bell.badge.fill" : "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stale ? Theme.alarm : .secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(stale ? Theme.alarm.opacity(0.1) : Theme.well))
    }

    @ViewBuilder private var dependencies: some View {
        let before = graph.predecessors[card.id] ?? [], after = graph.successors[card.id] ?? []
        if !before.isEmpty || !after.isEmpty {
            PanelSection(title: "Dependencies") {
                Toggle(isOn: $state.chain) { Label("Show only this chain", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .toggleStyle(PillToggle(tint: Theme.upstream))
                    .help("Hide every card outside this card's dependency chain (F)")
                if !before.isEmpty { depList("Waits for", before, Theme.upstream) }
                if !after.isEmpty { depList("Unlocks", after, Theme.downstream) }
            }
        }
    }

    private func depList(_ title: String, _ ids: [String], _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tint)
            ForEach(ids, id: \.self) { id in
                if let other = board.card(id) {
                    Button { state.selection = id } label: {
                        HStack(spacing: 7) {
                            Image(systemName: Theme.columnIcon(other.column)).foregroundStyle(Theme.column(other.column)).frame(width: 14)
                            Text(id).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text(other.title).font(.system(size: 11.5)).lineLimit(1).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(id), \(other.title), \(other.column.rawValue)")
                }
            }
        }
    }

    private var checklist: some View {
        PanelSection(title: "Checklist  \(card.checked)/\(card.total)") {
            ProgressView(value: Double(card.checked), total: Double(card.total)).tint(Theme.column(.done))
            ForEach(Array(card.checklist.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? Theme.column(.done) : .secondary)
                    Text(Format.markdown(item.text)).font(.system(size: 12.5))
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.done ? "done" : "open")
            }
        }
    }

    /// The owner's verdict on a Human Review card; each button says where the card goes.
    private var verdicts: some View {
        let items: [(Verdict, String, String, String, Color)] = [
            (.done, "Done", "Finished. Goes to Done.", "checkmark", Theme.good),
            (.approved, "Approve", "Go ahead. Back to Ready.", "arrow.right", Theme.indigo),
            (.changes, "Changes…", "Say what to fix. Back to Ready.", "pencil", Theme.critical),
            (.hold, "Hold…", "Say why. Goes to Blocked.", "pause.fill", Theme.alarm),
        ]
        return PanelSection(title: "Your verdict") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(items, id: \.0) { item in
                    Button { review(item.0) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.3).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item.4))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.1).font(.system(size: 12.5, weight: .semibold))
                                Text(item.2).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Text("\((items.firstIndex { $0.0 == item.0 } ?? 0) + 1)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.secondary.opacity(0.5)))
                                .accessibilityHidden(true)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(item.4.opacity(0.13)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.1.replacingOccurrences(of: "…", with: "")): \(item.2)")
                    .help("Key \((items.firstIndex { $0.0 == item.0 } ?? 0) + 1) · ⌘Z takes the last verdict back")
                }
            }
        }
    }

    private func review(_ verdict: Verdict) { model.review(verdict, board: board.path, card: card.id) }

    /// Add a note (any card) and set the review day (Human Review), drawn like fields to type into.
    private var actions: some View {
        HStack(spacing: 8) {
            outlined("Add note…", "square.and.pencil") {
                if let text = model.ask("Note on \(card.id)", "Signed with your name and today's date.", button: "Add") {
                    model.perform(.note(board: board.path, card: card.id, text: text))
                }
            }
            if card.column == .review { outlined("Review by…", "calendar") { model.askDue(board, card) }.fixedSize() }
        }
    }

    private func outlined(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: board.path)) } label: { Label("Open KANBAN.md", systemImage: "doc.text") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: board.path)]) } label: { Label("Reveal", systemImage: "folder") }
            }
        }
        .buttonStyle(.link).font(.system(size: 11.5))
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.8).foregroundStyle(.tertiary)
            content
        }
    }
}

struct Callout<Content: View>: View {
    let icon: String, tint: Color, title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                content.font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

/// Chips that wrap onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let all = frames(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? all.map(\.maxX).max() ?? 0, height: all.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, view) in zip(frames(bounds.width, subviews), subviews) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, out: [CGRect] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            out.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return out
    }
}
