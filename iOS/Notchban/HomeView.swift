import NotchbanCore
import SwiftUI

/// "Needs you": how many cards wait for the owner and the agents at work in the island; then the Human Review cards
/// as a deck. Drag the top card for a verdict (right Approve, left Changes, up Done, down Hold) or use the round
/// buttons under it; tap it to open the card.
struct HomeView: View {
    @EnvironmentObject var link: Link
    @State private var forgetting = false
    @State private var searching = false
    @State private var query = ""
    @State private var due = Due.all
    /// Cards sent off the deck, hidden until the Mac's next snapshot no longer shows them in review.
    @State private var gone: Set<String> = []
    @State private var noteFor: Pending?
    @State private var message: String?
    @FocusState private var searchFocused: Bool

    enum Due: Hashable { case all, late, today, later }

    struct Pending: Identifiable {
        let item: Item
        let verdict: Verdict
        var id: String { key(item) + verdict.rawValue }
    }

    private var boards: [Board] {
        (link.snapshot?.boards ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    typealias Item = (board: Board, card: Card)

    /// Human Review cards, soonest review day first (none last), then by board.
    private var waiting: [Item] {
        boards.flatMap { b in b.cards.filter { $0.column == .review }.map { (b, $0) } }.sorted { a, b in
            switch (a.card.due, b.card.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.board.displayName.localizedStandardCompare(b.board.displayName) == .orderedAscending
            }
        }
    }

    private func bucket(_ card: Card) -> Due {
        guard let n = card.due.flatMap(Day.offset) else { return .later }
        return n < 0 ? .late : n == 0 ? .today : .later
    }

    /// The deck: waiting cards not sent off, matching the search, in the chosen day filter.
    private var deck: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return waiting.filter { item in
            !gone.contains(key(item))
                && (due == .all || bucket(item.card) == due)
                && (q.isEmpty || "\(item.card.title) \(item.card.id) \(item.board.displayName)".localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        let left = waiting.filter { !gone.contains(key($0)) }
        DesignScroll(spacing: 14) {
            island(left)
        } content: {
            if link.snapshot == nil {
                CalmIsland(systemImage: "antenna.radiowaves.left.and.right", title: "Waiting for your Mac",
                           line: "The boards arrive when your Mac is nearby.")
            } else if left.isEmpty {
                CalmIsland(systemImage: "checkmark", title: "Nothing waits for you",
                           line: "When an agent needs your verdict, its card lands here.")
            } else {
                filters(left)
                if deck.isEmpty {
                    CalmIsland(systemImage: query.isEmpty ? "checkmark" : "magnifyingglass",
                               title: query.isEmpty ? "Nothing \(due == .late ? "late" : due == .today ? "due today" : "for later")"
                                   : "No card matches “\(query)”",
                               line: query.isEmpty ? "\(left.count) other\(left.count == 1 ? "" : "s") wait\(left.count == 1 ? "s" : "") under All." : "Try another word.")
                } else {
                    Deck(items: deck, connected: link.isConnected, verdict: verdict)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TabBar() }
        .sheet(item: $noteFor) { pending in
            NoteSheet(ref: ref(pending.item), verdict: pending.verdict) { send(pending.item, pending.verdict, sent: true) }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: link.snapshot?.at) {
            // a card that left review is no longer hidden: if it ever comes back, it shows
            let still = Set(waiting.map(key))
            gone = gone.filter(still.contains)
        }
        .toast($message)
        .islandPrompt(isPresented: $forgetting) {
            Text("Forget \(link.paired?.name ?? "this Mac")?").font(Theme.font(24, .bold))
            Text("The boards on this phone are removed. To use the Mac again, pair with a new code.")
                .font(Theme.body).foregroundStyle(Theme.onNotch2)
            HStack(spacing: 10) {
                Button("Forget") { forgetting = false; link.forget() }.buttonStyle(IslandCapsuleStyle(tint: Theme.late.text))
                Button("Keep") { forgetting = false }.buttonStyle(WhiteCapsuleStyle())
            }
            .padding(.top, 4)
        }
    }

    // MARK: verdicts

    /// A verdict on a card from the deck. Returns false (the card comes back) when it can't be sent now.
    private func verdict(_ item: Item, _ verdict: Verdict) -> Bool {
        guard link.isConnected else {
            message = "Mac not nearby – changes wait"
            return false
        }
        if verdict.needsNote {
            noteFor = Pending(item: item, verdict: verdict)
            return false
        }
        send(item, verdict, sent: false)
        return true
    }

    /// Takes the card off the deck and, unless a note sheet already sent it, sends the verdict; puts it back on error.
    private func send(_ item: Item, _ verdict: Verdict, sent: Bool) {
        let k = key(item)
        Deck.exit = verdict
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { _ = gone.insert(k) }
        guard !sent else { return }
        Task {
            let outcome = await link.run(.review(board: item.board.path, card: item.card.id, verdict: verdict, note: ""))
            if let error = outcome.error {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { _ = gone.remove(k) }
                message = error
            }
        }
    }

    private func ref(_ item: Item) -> CardRef { CardRef(board: item.board.path, card: item.card.id) }

    // MARK: island

    private func island(_ left: [Item]) -> some View {
        Island {
            HStack(spacing: 10) {
                Button { forgetting = true } label: { LivePill() }
                    .buttonStyle(.plain)
                    .accessibilityHint("Forget this Mac")
                Spacer()
                IconButton(systemImage: searching ? "xmark" : "magnifyingglass", label: searching ? "Close search" : "Search cards") {
                    searching.toggle()
                    if searching { searchFocused = true } else { query = "" }
                }
            }
            if searching {
                TextField("", text: $query, prompt: Text("Search cards").foregroundStyle(Theme.onNotch2))
                    .focused($searchFocused)
                    .font(Theme.font(16))
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine)))
                    .submitLabel(.search)
            }
            hero(left)
            ears
        }
    }

    private func hero(_ left: [Item]) -> some View {
        let n = left.count
        let boardCount = Set(left.map(\.board.path)).count
        return HStack(alignment: .bottom, spacing: 14) {
            Text("\(n)").font(Theme.big).kerning(-5).lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: Double(n)))
                .padding(.bottom, -10)
            VStack(alignment: .leading, spacing: 2) {
                Text(n == 1 ? "card waits for\nyour verdict" : n == 0 ? "nothing waits for\nyour verdict" : "cards wait for\nyour verdict")
                    .font(Theme.heroLine).lineSpacing(-2)
                Text(n == 0 ? Day.long : "on \(boardCount) board\(boardCount == 1 ? "" : "s") · \(Day.long)")
                    .font(Theme.font(13.5)).foregroundStyle(Theme.onNotch2)
            }
            .padding(.bottom, 6)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: n)
        .accessibilityElement(children: .combine)
    }

    /// Codex and Claude: In Progress cards held by each, from the owners on the boards.
    private var ears: some View {
        let working = boards.flatMap(\.cards).filter { $0.column == .progress }
        func count(_ name: String) -> Int { working.filter { ($0.owner ?? "").localizedCaseInsensitiveContains(name) }.count }
        return HStack(spacing: 8) {
            ear("Codex", count("codex"), of: working.count, color: Theme.sky.text)
            ear("Claude", count("claude"), of: working.count, color: Theme.ok.text)
        }
    }

    private func ear(_ name: String, _ n: Int, of total: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(n == 0 ? Theme.onNotch2.opacity(0.4) : color).frame(width: 7, height: 7)
                .shadow(color: n == 0 ? .clear : color, radius: 4)
            Text(name).fontWeight(.semibold).foregroundStyle(Theme.onNotch).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Text(n == 0 ? "idle" : "\(n) at work").font(Theme.font(12)).monospacedDigit().lineLimit(1).fixedSize()
                .foregroundStyle(n == 0 ? Theme.onNotch2 : color)
        }
        .font(Theme.font(13))
        .foregroundStyle(Theme.onNotch2)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine)))
        .accessibilityElement(children: .combine)
    }

    // MARK: filters

    private func filters(_ left: [Item]) -> some View {
        let late = left.filter { bucket($0.card) == .late }.count
        let today = left.filter { bucket($0.card) == .today }.count
        return LitSwitcher(options: [
            .init(value: Due.all, title: "All", count: left.count),
            .init(value: .late, title: "Late", count: late, accent: late > 0 ? Theme.late.fill : nil),
            .init(value: .today, title: "Today", count: today),
            .init(value: .later, title: "Later", count: left.count - late - today),
        ], selection: $due, fill: true, label: "Review day")
    }
}

private func key(_ item: HomeView.Item) -> String { item.board.path + "|" + item.card.id }

// MARK: - deck

/// The top card full size, the next two peeking behind it; a row of four round verdict buttons under it.
private struct Deck: View {
    let items: [HomeView.Item]
    let connected: Bool
    /// Sends a verdict on a card; false means the card stays (offline, or a note is asked first).
    let verdict: (HomeView.Item, Verdict) -> Bool

    /// Where the last card sent went, read by the leaving card's transition.
    @MainActor static var exit = Verdict.approved

    @State private var drag = CGSize.zero
    @State private var armed: Verdict?
    @State private var bounced = 0
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 248
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let threshold: CGFloat = 110

    var body: some View {
        let visible = Array(items.prefix(3))
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                ForEach(Array(visible.enumerated()), id: \.element.card.id) { i, item in
                    card(item, at: i)
                }
            }
            .frame(height: height + 26, alignment: .top)
            buttons(visible.first)
            if !connected {
                Label("Mac not nearby – changes wait", systemImage: "wifi.slash").labelStyle(TightLabel())
                    .font(Theme.metaBold).foregroundStyle(Theme.ember.text)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new != nil }
        .sensoryFeedback(.warning, trigger: bounced)
    }

    // MARK: cards

    private func card(_ item: HomeView.Item, at i: Int) -> some View {
        let top = i == 0
        let pull = top ? 0 : progress
        let depth = CGFloat(i) - pull
        let ref = CardRef(board: item.board.path, card: item.card.id)
        let pointing: Verdict? = top ? direction(drag) : nil
        let strength: CGFloat = top ? progress : 0
        let shown: CGFloat = top ? 1 : i == 1 ? progress : 0
        let angle: Double = top && !reduceMotion ? Double(drag.width / 22) : 0
        return NavigationLink(value: ref) {
            DeckCard(board: item.board, card: item.card, height: height, verdict: pointing, progress: strength, shown: shown)
        }
        .buttonStyle(.plain)
        .disabled(!top)
        .scaleEffect(1 - 0.06 * depth, anchor: .bottom)
        .offset(y: 13 * depth)
        .offset(top ? drag : .zero)
        .rotationEffect(.degrees(angle), anchor: .bottom)
        .opacity(i == 2 ? 0.6 + 0.4 * pull : 1)
        .zIndex(Double(10 - i))
        .highPriorityGesture(top ? dragGesture(item) : nil)
        .transition(.asymmetric(insertion: .opacity, removal: reduceMotion ? .opacity : .modifier(
            active: Fly(verdict: Deck.exit), identity: Fly(verdict: nil))))
        .accessibilityHidden(!top)
        .accessibilityHint(top ? "Opens the card. Verdicts are in the actions." : "")
        .accessibilityAction(named: "Approve") { _ = verdict(item, .approved) }
        .accessibilityAction(named: "Changes") { _ = verdict(item, .changes) }
        .accessibilityAction(named: "Done") { _ = verdict(item, .done) }
        .accessibilityAction(named: "Hold") { _ = verdict(item, .hold) }
    }

    /// The verdict a drag points at: the stronger axis decides.
    private func direction(_ t: CGSize) -> Verdict? {
        guard t != .zero else { return nil }
        if abs(t.width) > abs(t.height) { return t.width > 0 ? .approved : .changes }
        return t.height < 0 ? .done : .hold
    }

    private var progress: CGFloat { min(1, max(abs(drag.width), abs(drag.height)) / Self.threshold) }

    private func dragGesture(_ item: HomeView.Item) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                drag = value.translation
                armed = progress >= 1 ? direction(drag) : nil
            }
            .onEnded { value in
                // past the threshold, or a quick flick (judged by where it was thrown)
                let thrown = value.predictedEndTranslation
                let chosen = progress >= 1 ? direction(drag)
                    : max(abs(thrown.width), abs(thrown.height)) > Self.threshold * 1.8 ? direction(thrown) : nil
                if let v = chosen, verdict(item, v) {
                    drag = .zero // the leaving card keeps its place and flies from there
                } else {
                    if chosen != nil && !connected { bounced += 1 }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.66)) {
                        drag = .zero
                    }
                }
                armed = nil
            }
    }

    // MARK: buttons

    private func buttons(_ top: HomeView.Item?) -> some View {
        HStack(spacing: 0) {
            round(.changes, "Changes", "arrow.uturn.left", top)
            round(.hold, "Hold", "pause.fill", top)
            round(.done, "Done", "checkmark", top)
            round(.approved, "Approve", "arrow.right", top)
        }
    }

    private func round(_ v: Verdict, _ title: String, _ icon: String, _ top: HomeView.Item?) -> some View {
        let tone = Theme.verdict(v)
        let primary = v == .done
        return Button {
            if let top { _ = verdict(top, v) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: primary ? 23 : 19, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0B1220))
                    .frame(width: primary ? 62 : 54, height: primary ? 62 : 54)
                    .background(Circle().fill(tone.fill))
                    .shadow(color: tone.fill.opacity(0.45), radius: primary ? 14 : 8, y: 4)
                Text(title).font(Theme.font(12, .semibold)).foregroundStyle(Theme.fg2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(top == nil || !connected)
        .opacity(connected ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityHint(hint(v))
    }

    private func hint(_ v: Verdict) -> String {
        switch v {
        case .done: "Finished. The top card goes to Done."
        case .approved: "Go ahead. The top card goes back to Ready."
        case .changes: "Say what to fix. The top card goes back to Ready."
        case .hold: "Say why. The top card goes to Blocked."
        }
    }
}

/// The leaving card's flight in the verdict's direction.
private struct Fly: ViewModifier {
    let verdict: Verdict?

    func body(content: Content) -> some View {
        let (x, y, angle): (CGFloat, CGFloat, Double) = switch verdict {
        case .approved?: (720, 60, 18)
        case .changes?: (-720, 60, -18)
        case .done?: (0, -1100, 0)
        case .hold?: (0, 1100, 0)
        case nil: (0, 0, 0)
        }
        content.offset(x: x, y: y).rotationEffect(.degrees(angle)).opacity(verdict == nil ? 1 : 0.6)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A card on the deck: board and id, review day, the big title, what it needs, chips; a stamp and a glowing edge in
/// the verdict's colour while it is dragged.
private struct DeckCard: View {
    let board: Board
    let card: Card
    let height: CGFloat
    let verdict: Verdict?
    let progress: CGFloat
    /// How much of the content shows: all on the top card, coming in on the next one as the top is dragged away.
    var shown: CGFloat = 1

    var body: some View {
        let tone = verdict.map(Theme.verdict)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BoardDot(board: board, size: 10)
                Text(board.displayName).font(Theme.metaBold).foregroundStyle(Theme.fg2).lineLimit(1)
                Text(card.id).font(Theme.id).foregroundStyle(Theme.fg3)
                Spacer(minLength: 4)
                if let due = card.due {
                    let late = (Day.offset(due) ?? 0) < 0
                    Pill(text: Day.relative(due), tone: late ? Theme.late : Theme.review, systemImage: "calendar")
                }
            }
            Text(card.title).font(Theme.font(23, .bold)).kerning(-0.5).foregroundStyle(Theme.fg)
                .multilineTextAlignment(.leading).lineLimit(4).minimumScaleFactor(0.8)
            if let needs = card.needs {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEEDS YOU TO").kerning(0.9).font(Theme.font(10.5, .bold)).foregroundStyle(Theme.review.text)
                    Text(needs.prefix(1).uppercased() + needs.dropFirst()).font(Theme.font(14.5, .semibold))
                        .foregroundStyle(Theme.fg).lineLimit(4)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.review.fill.opacity(0.12)))
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if card.isHumanEntered { HumanChip() }
                if let track = card.track { Tag(text: track) }
                if card.total > 0 { Tag(text: "\(card.checked)/\(card.total)", systemImage: "checklist") }
            }
        }
        .padding(18)
        .opacity(shown)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.surface))
        .overlay {
            if let tone {
                RoundedRectangle(cornerRadius: 34, style: .continuous).fill(tone.fill.opacity(0.10 * progress))
                RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(tone.fill, lineWidth: 3)
                    .opacity(progress)
                    .shadow(color: tone.fill.opacity(progress), radius: 16)
            }
        }
        .overlay(alignment: stampPlace) {
            if let verdict, let tone {
                Text(stamp(verdict))
                    .font(.system(size: 30, weight: .black)).kerning(2)
                    .foregroundStyle(tone.text)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tone.text, lineWidth: 4))
                    .rotationEffect(.degrees(verdict == .approved ? -14 : verdict == .changes ? 14 : -6))
                    .opacity(Double(progress))
                    .scaleEffect(0.8 + 0.2 * progress)
                    .padding(28)
                    .accessibilityHidden(true)
            }
        }
        .cardShadow(radius: 34)
        .accessibilityElement(children: .combine)
    }

    private var stampPlace: Alignment {
        switch verdict {
        case .approved?: .topLeading
        case .changes?: .topTrailing
        case .done?: .bottom
        default: .center
        }
    }

    private func stamp(_ v: Verdict) -> String {
        switch v {
        case .approved: "APPROVE"
        case .changes: "CHANGES"
        case .done: "DONE"
        case .hold: "HOLD"
        }
    }
}

/// A calm black island for an empty screen: an icon, a big line, a small one.
struct CalmIsland: View {
    let systemImage: String
    let title: String
    let line: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.ok.text)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Theme.notchWell).overlay(Circle().strokeBorder(Theme.notchLine)))
            Text(title).font(Theme.font(22, .bold)).multilineTextAlignment(.center)
            Text(line).font(Theme.body).foregroundStyle(Theme.onNotch2).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .floatingIsland(radius: 34)
        .accessibilityElement(children: .combine)
    }
}

/// "3 days late" in red, "today" / "in 2 days" in lavender.
struct DueLabel: View {
    let day: String

    var body: some View {
        let late = (Day.offset(day) ?? 0) < 0
        Label(Day.relative(day), systemImage: "calendar")
            .labelStyle(TightLabel())
            .font(Theme.metaBold)
            .foregroundStyle(late ? Theme.late.text : Theme.review.text)
            .lineLimit(1)
            .fixedSize()
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}
