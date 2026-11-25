import NotchbanCore
import SwiftUI

/// One board: its name, folder and lane bar in the island; a column picker; the column's cards.
struct BoardScreen: View {
    let path: String
    @EnvironmentObject var link: Link
    @State private var column: Column?
    @State private var renaming = false
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        content
            .onAppear { Orientation.allowLandscape(true) }
            .onDisappear { Orientation.allowLandscape(false) }
    }

    @ViewBuilder private var content: some View {
        if let board = link.board(path), vertical == .compact {
            LandscapeBoard(board: board).designScreen()
        } else if let board = link.board(path) {
            let columns = Column.allCases.filter { board.count($0) > 0 }
            let shown = column.flatMap { columns.contains($0) ? $0 : nil } ?? defaultColumn(board, columns)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                    island(board)
                    if board.cards.isEmpty {
                        CalmIsland(systemImage: "tray", title: "No cards yet", line: "Tap + to give this board its first card.")
                            .padding(.horizontal, 16)
                    } else {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                if shown == .progress, case let stale = board.stale(), !stale.isEmpty {
                                    Alarm(text: "**\(stale.count) card\(stale.count == 1 ? " has" : "s have") an expired lease.** Nobody is working on \(stale.count == 1 ? "it" : "them").")
                                }
                                ForEach(board.cards.filter { $0.column == shown }) { card in
                                    NavigationLink(value: CardRef(board: path, card: card.id)) { CardRow(board: board, card: card) }
                                        .buttonStyle(PressDown())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        } header: {
                            LitSwitcher(options: columns.map { c in
                                .init(value: c, title: c.rawValue, count: board.count(c),
                                      accent: c == .blocked ? Theme.late.fill : c == .review ? Theme.review.fill : nil)
                            }, selection: Binding(get: { shown }, set: { column = $0 }), label: "Column")
                            .padding(.horizontal, 16).padding(.vertical, 6)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .designScreen()
            .safeAreaInset(edge: .bottom, spacing: 0) { TabBar(board: path) }
            .islandPrompt(isPresented: $renaming) { RenameBox(board: board) { renaming = false } }
        } else {
            ContentUnavailableView("This board isn't on the Mac any more", systemImage: "questionmark.folder")
                .designScreen()
                .toolbar(.visible, for: .navigationBar)
        }
    }

    private func island(_ board: Board) -> some View {
        Island(spacing: 10) {
            HStack {
                BackButton(title: "Boards")
                Spacer()
                IconButton(systemImage: "pencil", label: "Rename \(board.displayName)") { renaming = true }
                    .disabled(!link.isConnected)
            }
            HStack(spacing: 10) {
                BoardDot(board: board, size: 14)
                Text(board.displayName).font(Theme.islandTitle).kerning(-0.8).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 0) {
                Text(board.folder.replacing(/^\/Users\/[^\/]+/, with: "~")).font(Theme.font(12, mono: true))
                    .truncationMode(.middle)
                Text(" · \(board.cards.count) cards\(asOf)").font(Theme.font(13)).fixedSize()
            }
            .foregroundStyle(Theme.onNotch2).lineLimit(1)
            if !board.cards.isEmpty { Lanes(board: board, height: 14).padding(.top, 4) }
        }
    }

    private var asOf: String { link.isConnected ? "" : link.snapshot.map { " · as of \($0.at.asOf)" } ?? "" }

    /// In Progress when agents are at it, else Human Review, else the first column with cards.
    private func defaultColumn(_ board: Board, _ columns: [Column]) -> Column {
        [.progress, .review].first(where: columns.contains) ?? columns.first ?? .backlog
    }
}

/// A red-tinted warning row with a red icon square.
struct Alarm: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "bell").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.late.fill))
            Text(text).font(Theme.needs).foregroundStyle(Theme.fg)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.late.fill.opacity(0.13)))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A card on a board: id and lease (or review day); title; track, size, who waits for it, who holds it.
struct CardRow: View {
    let board: Board
    let card: Card

    var body: some View {
        let waiters = board.open(card.before).count
        Surface {
            HStack(spacing: 7) {
                Text(card.id).font(Theme.id).foregroundStyle(Theme.fg3)
                if card.total > 0 { Text("\(card.checked)/\(card.total)").font(Theme.meta).foregroundStyle(Theme.fg3) }
                Spacer(minLength: 4)
                if card.column == .progress { LeaseLabel(card: card) } else if let due = card.due { DueLabel(day: due) }
            }
            Text(card.title).font(Theme.rowTitle).foregroundStyle(Theme.fg).multilineTextAlignment(.leading)
            if let blocker = card.blocker, card.column == .blocked {
                Text(blocker).font(Theme.needs).foregroundStyle(Theme.late.text).lineLimit(2)
            } else if card.column == .review, let needs = card.needs {
                Text("**Needs:** \(needs)").font(Theme.needs).foregroundStyle(Theme.fg2).lineLimit(2)
            }
            if card.isHumanEntered || card.track != nil || card.size != nil || waiters > 0 || card.owner != nil {
                HStack(spacing: 6) {
                    if card.isHumanEntered { HumanChip() }
                    if let track = card.track { Tag(text: track) }
                    if let size = card.size { Tag(text: size) }
                    if waiters > 0 { Tag(text: "\(waiters) wait for it", systemImage: "arrow.triangle.branch") }
                    Spacer(minLength: 0)
                    if let owner = card.owner, card.column == .progress { Who(owner: owner) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "lease ran out 2 h ago" in red, "1 h 12 m left" in green.
struct LeaseLabel: View {
    let card: Card

    var body: some View {
        let left = card.leaseExpires.map { $0.timeIntervalSinceNow }
        let gone = left.map { $0 < 0 } ?? true
        Label(left.map { gone ? "lease ran out \(span(-$0)) ago" : "\(span($0)) left" } ?? "no lease", systemImage: "clock")
            .labelStyle(TightLabel())
            .font(Theme.metaBold)
            .foregroundStyle(gone ? Theme.late.text : Theme.ok.text)
            .lineLimit(1)
            .fixedSize()
    }

    private func span(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return "\(max(m, 1)) m" }
        if m < 60 * 24 { return m % 60 == 0 || m >= 600 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m" }
        return "\(m / 1440) d"
    }
}

/// The agent holding a card: a small coloured avatar and its name.
struct Who: View {
    let owner: String

    var body: some View {
        let (color, initials) = Theme.agent(owner)
        HStack(spacing: 4) {
            Text(initials).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(color))
            Text(owner.hasPrefix("agent:") ? String(owner.dropFirst(6)) : owner).lineLimit(1)
        }
        .font(Theme.font(11))
        .foregroundStyle(Theme.fg2)
    }
}
