import NotchbanCore
import SwiftUI

/// A board turned on its side: every column on one screen, Human Review the widest, an empty column folded into a thin
/// rail. Tap a card and its sheet slides in from the right; the board stays where it is.
struct LandscapeBoard: View {
    let board: Board
    @EnvironmentObject var link: Link
    @EnvironmentObject var nav: Nav
    @State private var open: String?
    @State private var picking = false
    @State private var problem: String?

    private var boards: [Board] {
        (link.snapshot?.boards ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 6) {
            bar
            columns
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .overlay(alignment: .trailing) { sheet }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: open)
        .sheet(isPresented: $picking) {
            ProjectDial(title: "Board", options: boards.map { DialOption(path: $0.path, title: $0.displayName, count: $0.count(.review)) },
                        selection: Binding(get: { board.path }, set: { go($0) }))
                .presentationDetents([.height(310)])
        }
    }

    private func go(_ path: String?) {
        guard let path, path != board.path else { return }
        open = nil
        nav.boards.removeLast()
        nav.boards.append(BoardRef(path: path))
    }

    private var bar: some View {
        HStack(spacing: 10) {
            BackButton(title: "Boards")
            Button { picking = true } label: {
                HStack(spacing: 6) {
                    BoardDot(board: board, size: 10)
                    Text(board.displayName).font(Theme.font(14, .semibold)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.fg3)
                }
                .foregroundStyle(Theme.fg).padding(.horizontal, 12).frame(minHeight: 36)
                .background(Theme.fg.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Board: \(board.displayName)")
            .accessibilityHint("Opens the board dial")
            Spacer()
            let n = board.count(.review)
            if n > 0 { Text("\(n) need you").font(Theme.font(12, .semibold)).foregroundStyle(Theme.review.text) }
            LivePill()
        }
        .frame(height: 40)
    }

    private var columns: some View {
        GeometryReader { geo in
            let rail: CGFloat = 24, gap: CGFloat = 6
            let live = Column.allCases.filter { board.count($0) > 0 }
            let rails = Column.allCases.count - live.count
            let weights = live.map { $0 == .review ? 1.5 : 1.0 }
            let room = geo.size.width - CGFloat(rails) * rail - CGFloat(Column.allCases.count - 1) * gap
            let unit = room / max(weights.reduce(0, +), 1)
            HStack(spacing: gap) {
                ForEach(Column.allCases, id: \.self) { c in
                    if board.count(c) == 0 {
                        railView(c).frame(width: rail)
                    } else {
                        columnView(c).frame(width: unit * (c == .review ? 1.5 : 1.0))
                    }
                }
            }
        }
    }

    private func railView(_ c: Column) -> some View {
        VStack(spacing: 6) {
            Circle().fill(Theme.column(c).fill).frame(width: 7, height: 7)
            Text(c.rawValue).font(Theme.font(9.5, .medium)).foregroundStyle(Theme.fg3)
                .fixedSize().rotationEffect(.degrees(90)).frame(width: 12).fixedSize(horizontal: true, vertical: false)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 28)
        }
        .padding(.top, 8).frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.rawValue), empty")
    }

    private func columnView(_ c: Column) -> some View {
        let cards = board.cards.filter { $0.column == c }
        let review = c == .review
        return VStack(spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(Theme.column(c).fill).frame(width: 7, height: 7)
                Text(c.rawValue).font(Theme.font(10.5, .semibold)).foregroundStyle(Theme.fg2).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(cards.count)").font(Theme.font(10.5, .bold)).foregroundStyle(Theme.fg)
            }
            .padding(.horizontal, 4).padding(.top, 2)
            ScrollView {
                LazyVStack(spacing: 5) { ForEach(cards) { card in mini(card, big: review) } }
            }
            .scrollIndicators(.hidden)
        }
        .padding(6)
        .background(review ? Theme.review.fill.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if review { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.review.fill.opacity(0.7), lineWidth: 1.5) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(c.rawValue), \(cards.count) cards")
    }

    private func mini(_ card: Card, big: Bool) -> some View {
        Button { open = card.id } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(card.id).font(Theme.font(8.5, .semibold, mono: true)).foregroundStyle(Theme.fg3)
                Text(card.title).font(Theme.font(big ? 11 : 10.5)).foregroundStyle(Theme.fg).lineLimit(big ? 3 : 2)
                    .multilineTextAlignment(.leading)
                if card.column == .review {
                    chip(card.proof.isEmpty ? "No proof" : "Proof", warn: card.proof.isEmpty)
                } else if card.column == .blocked, let b = card.blocker {
                    chip(b, warn: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(open == card.id ? Theme.review.fill.opacity(0.25) : Theme.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.id), \(card.title)")
    }

    private func chip(_ text: String, warn: Bool) -> some View {
        Text(text).font(Theme.font(8.5, .semibold)).lineLimit(1)
            .foregroundStyle(warn ? Theme.late.text : Theme.ok.text)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((warn ? Theme.late.fill : Theme.ok.fill).opacity(0.16), in: Capsule())
    }

    @ViewBuilder
    private var sheet: some View {
        if let id = open, let card = board.card(id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(card.id).font(Theme.font(11, .semibold, mono: true)).foregroundStyle(Theme.fg3)
                    Spacer()
                    Button { open = nil } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                        .frame(width: 44, height: 44).accessibilityLabel("Close")
                }
                Text(card.title).font(Theme.font(16, .bold)).multilineTextAlignment(.leading)
                if let needs = card.needs, card.column == .review {
                    Text("**Needs:** \(needs)").font(Theme.font(12)).foregroundStyle(Theme.fg2)
                }
                if card.total > 0 { Text("\(card.checked)/\(card.total) done").font(Theme.font(12)).foregroundStyle(Theme.fg3) }
                if card.column == .review {
                    chip(card.proof.isEmpty ? "No proof yet" : "Proof \(card.proof.count)", warn: card.proof.isEmpty)
                }
                if let problem { Text(problem).font(Theme.font(11)).foregroundStyle(Theme.late.text) }
                Spacer(minLength: 0)
                if card.column == .review {
                    HStack(spacing: 6) {
                        verdictButton(card, .changes, "Changes", Theme.sky.fill)
                        verdictButton(card, .hold, "Hold", Theme.late.fill)
                        verdictButton(card, .done, "Done", Theme.ok.fill)
                        verdictButton(card, .approved, "Approve", Theme.indigo.fill)
                    }
                }
                NavigationLink(value: CardRef(board: board.path, card: card.id)) {
                    Text("Open card").font(Theme.font(13, .semibold)).frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.fg.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.fg)
            .padding(.leading, 14).padding(.trailing, 8).padding(.bottom, 8)
            .frame(width: 300).frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.bg.ignoresSafeArea())
            .overlay(alignment: .leading) { Rectangle().fill(Theme.fg.opacity(0.12)).frame(width: 1).ignoresSafeArea() }
            .transition(.move(edge: .trailing))
        }
    }

    /// Changes and Hold need a note, which the full card asks for; Done and Approve go straight.
    private func verdictButton(_ card: Card, _ verdict: Verdict, _ title: String, _ fill: Color) -> some View {
        Button {
            if verdict.needsNote { problem = "\(title) needs a note: open the card." } else {
                problem = nil
                Task {
                    let outcome = await link.review(board: board.path, card: card.id, verdict: verdict, note: "")
                    if let error = outcome.error { problem = error } else { open = nil }
                }
            }
        } label: {
            Text(title).font(Theme.font(11.5, .bold)).foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 40).background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
