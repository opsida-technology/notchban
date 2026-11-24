import NotchbanCore
import SwiftUI

/// Every board on the Mac as a big tile: the board's colour glowing in a corner, how many wait for review as the hero
/// number, the column mix as a thick segmented bar. Long-press a tile to rename its board.
struct BoardsView: View {
    @EnvironmentObject var link: Link
    @State private var renaming: Board?
    @State private var open: BoardRef?
    @State private var pressed: String?

    private var boards: [Board] {
        (link.snapshot?.boards ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        DesignScroll(spacing: 14) {
            Island(spacing: 10) {
                LivePill()
                Text("Boards").font(Theme.islandTitle).kerning(-0.8)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(Theme.font(13)).foregroundStyle(Theme.onNotch2)
            }
        } content: {
            if link.snapshot == nil {
                CalmIsland(systemImage: "antenna.radiowaves.left.and.right", title: "Waiting for your Mac",
                           line: "The boards arrive when your Mac is nearby.")
            }
            ForEach(boards) { board in
                BoardTile(board: board)
                    .scaleEffect(pressed == board.path ? 0.97 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
                    .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .onTapGesture { open = BoardRef(path: board.path) }
                    .onLongPressGesture(minimumDuration: 0.45) {
                        if link.isConnected { renaming = board }
                    } onPressingChanged: { pressed = $0 ? board.path : nil }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open = BoardRef(path: board.path) }
                    .accessibilityAction(named: "Rename") { if link.isConnected { renaming = board } }
            }
        }
        .navigationDestination(item: $open) { BoardScreen(path: $0.path) }
        .safeAreaInset(edge: .bottom, spacing: 0) { TabBar() }
        .sensoryFeedback(.impact(weight: .medium), trigger: renaming?.path) { _, new in new != nil }
        .islandPrompt(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            if let board = renaming { RenameBox(board: board) { renaming = nil } }
        }
    }

    private var subtitle: String {
        let n = "\(boards.count) board\(boards.count == 1 ? "" : "s") on your Mac. Hold one to rename it."
        return link.isConnected ? n : "\(boards.count) board\(boards.count == 1 ? "" : "s") on your Mac. Changes wait until your Mac is back."
    }
}

struct BoardTile: View {
    let board: Board

    var body: some View {
        let review = board.count(.review)
        let color = Theme.board(board)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        BoardDot(board: board, size: 11)
                        Text(board.displayName).font(Theme.font(20, .bold)).kerning(-0.3).foregroundStyle(Theme.fg).lineLimit(1)
                    }
                    if board.displayName != board.name {
                        Text(board.name).font(Theme.id).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.fg3)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.well))
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("\(review)").font(.system(size: 58, weight: .heavy).monospacedDigit()).kerning(-2)
                    .foregroundStyle(review > 0 ? Theme.fg : Theme.fg3)
                    .lineLimit(1).minimumScaleFactor(0.6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(review == 1 ? "card to review" : "cards to review").font(Theme.font(15, .semibold))
                        .foregroundStyle(review > 0 ? Theme.review.text : Theme.fg3)
                    Counts(board: board)
                }
                .padding(.bottom, 8)
            }
            if board.cards.isEmpty {
                Text("No cards yet").font(Theme.meta).foregroundStyle(Theme.fg3)
            } else {
                Lanes(board: board, height: 14)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.surface)
                .overlay {
                    RadialGradient(colors: [color.opacity(0.42), color.opacity(0)], center: .topTrailing, startRadius: 0, endRadius: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                }
        }
        .cardShadow(radius: 34)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the board. Rename is in the actions.")
    }
}

/// "8 active · 8 stale · 3 blocked · 112 done", zeros left out.
struct Counts: View {
    let board: Board

    var body: some View {
        let stale = board.stale().count
        let parts: [(Int, String, Bool)] = [
            (board.count(.progress), "active", false), (stale, "stale", true),
            (board.count(.blocked), "blocked", false), (board.count(.done), "done", false),
        ].filter { $0.0 > 0 }
        HStack(spacing: 10) {
            ForEach(parts, id: \.1) { n, word, bad in
                Text("\(Text("\(n)").fontWeight(.semibold).foregroundColor(bad ? Theme.late.text : Theme.fg)) \(word)")
                    .foregroundStyle(bad ? Theme.late.text : Theme.fg2)
                    .lineLimit(1).fixedSize()
            }
            if parts.isEmpty { Text("\(board.cards.count) waiting to start").foregroundStyle(Theme.fg2) }
        }
        .font(Theme.meta)
    }
}

/// The board's display name, typed on an island; empty means the folder name.
struct RenameBox: View {
    let board: Board
    let close: () -> Void
    @EnvironmentObject var link: Link
    @State private var name = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BoardDot(board: board, size: 12)
                Text("Rename board").font(Theme.font(22, .bold))
            }
            TextField("", text: $name, prompt: Text(board.name).foregroundStyle(Theme.onNotch2))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(save)
                .font(Theme.font(17, .semibold))
                .inputBox(focused: focused)
                .accessibilityLabel("Name for \(board.name)")
            Text(problem ?? "Shown here and on the Mac instead of the folder name \(board.name). Leave it empty to use the folder.")
                .font(Theme.font(13)).foregroundStyle(problem == nil ? Theme.onNotch2 : Theme.late.text)
            HStack(spacing: 10) {
                Button("Cancel", action: close).buttonStyle(IslandCapsuleStyle())
                Button(action: save) {
                    if sending { ProgressView().tint(Theme.notch) } else { Text("Save") }
                }
                .buttonStyle(WhiteCapsuleStyle())
                .disabled(sending || !link.isConnected)
            }
        }
        .onAppear {
            name = board.title ?? ""
            focused = true
        }
    }

    private func save() {
        sending = true
        Task {
            let outcome = await link.run(.rename(board: board.path, name: name))
            sending = false
            if let error = outcome.error { problem = error } else { close() }
        }
    }
}
