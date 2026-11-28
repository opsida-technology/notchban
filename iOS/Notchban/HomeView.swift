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
    /// The board the deck is narrowed to (its path); nil shows every project.
    @State private var project: String?
    @State private var picking = false
    /// Cards sent off the deck, hidden until the Mac's next snapshot no longer shows them in review.
    @State private var gone: Set<String> = []
    @State private var noteFor: Pending?
    @State private var message: String?
    /// The last swiped verdict, not sent yet, and the wait before it goes.
    @State private var held: Pending?
    @State private var holding: Task<Void, Never>?
    /// A verdict the Mac refused while the app was in the background, to show on return.
    @State private var failure: String?
    @Environment(\.scenePhase) private var phase
    @AppStorage("deckHintSeen") private var hintSeen = false
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

    struct Item: Identifiable {
        let board: Board
        let card: Card
        var id: String { board.path + "|" + card.id }
    }

    /// Human Review cards, soonest review day first (none last), then by board.
    private var waiting: [Item] {
        boards.flatMap { b in b.cards.filter { $0.column == .review }.map { Item(board: b, card: $0) } }.sorted { a, b in
            switch (a.card.due, b.card.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.board.displayName.localizedStandardCompare(b.board.displayName) == .orderedAscending
            }
        }
    }

    /// Sent off the deck, or kept on the phone for the Mac.
    private func hidden(_ item: Item) -> Bool { gone.contains(key(item)) || link.isQueued(item.board.path, item.card.id) }

    private func bucket(_ card: Card) -> Due {
        guard let n = card.due.flatMap(Day.offset) else { return .later }
        return n < 0 ? .late : n == 0 ? .today : .later
    }

    /// The deck: waiting cards not sent off, matching the search, in the chosen day filter.
    private var deck: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return waiting.filter { item in
            !hidden(item)
                && (project == nil || item.board.path == project)
                && (due == .all || bucket(item.card) == due)
                && (q.isEmpty || "\(item.card.title) \(item.card.id) \(item.board.displayName)".localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        let left = waiting.filter { !hidden($0) }
        let scoped = project == nil ? left : left.filter { $0.board.path == project }
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
                projects(left)
                filters(scoped)
                if deck.isEmpty {
                    CalmIsland(systemImage: query.isEmpty ? "checkmark" : "magnifyingglass",
                               title: query.isEmpty ? "Nothing \(due == .late ? "late" : due == .today ? "due today" : "for later")"
                                   : "No card matches “\(query)”",
                               line: query.isEmpty ? "\(scoped.count) other\(scoped.count == 1 ? "" : "s") wait\(scoped.count == 1 ? "s" : "") under All." : "Try another word.")
                } else {
                    Deck(items: deck, connected: link.isConnected, queued: link.queued.count, verdict: verdict)
                    if !hintSeen {
                        Label("Swipe the card: right approves, left asks for changes, up is done, down holds.", systemImage: "hand.draw")
                            .font(Theme.font(12.5)).foregroundStyle(Theme.fg3).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if link.snapshot != nil { AlsoNeeds(rows: attention) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // the Undo bar takes the tab bar's place, not a spot over the verdict buttons: a tap that comes after it
            // has gone lands on a tab, never on Approve
            ZStack {
                if let held { undoBar(held) } else { TabBar() }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: held?.id)
        }
        .onChange(of: phase) {
            if phase != .active { commit() } else if let f = failure { message = f; failure = nil }
        }
        .onChange(of: link.notice) {
            if let n = link.notice { message = n; link.notice = nil }
        }
        .onChange(of: held?.id) {
            if let held { UIAccessibility.post(notification: .announcement, argument: "\(held.item.card.id) sent in 5 seconds. Undo is at the bottom.") }
        }
        .sheet(item: $noteFor) { pending in
            NoteSheet(ref: ref(pending.item), verdict: pending.verdict) { send(pending.item, pending.verdict, sent: true) }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: scoped.isEmpty && !left.isEmpty) { _, empty in if empty { project = nil } }
        .onChange(of: link.snapshot?.at) {
            // a card that left review is no longer hidden: if it ever comes back, it shows
            let still = Set(waiting.map(key))
            gone = gone.filter(still.contains)
        }
        .toast($message)
        .islandPrompt(isPresented: $forgetting) { MacBox { forgetting = false } }
    }

    // MARK: also needs you

    /// What else waits for the owner besides a verdict: a card nobody works on (its lease ran out), a blocked one, a limit
    /// nearly used up while agents work.
    private var attention: [AlsoNeeds.Row] {
        var rows: [AlsoNeeds.Row] = []
        for b in boards {
            for c in b.cards where c.isStale() {
                rows.append(.init(id: b.path + "|" + c.id, ref: CardRef(board: b.path, card: c.id), icon: "hourglass.bottomhalf.filled",
                                  tone: Theme.late, title: "\(c.id) \(c.title)", why: "Nobody is working on it: its lease ran out."))
            }
            for c in b.cards where c.column == .blocked {
                rows.append(.init(id: b.path + "|" + c.id, ref: CardRef(board: b.path, card: c.id), icon: "pause.circle.fill",
                                  tone: Theme.ember, title: "\(c.id) \(c.title)", why: c.blocker ?? "Blocked."))
            }
        }
        for ear in link.snapshot?.ears ?? [] where ear.working > 0 && (ear.fiveHour ?? 0) >= 0.85 {
            rows.append(.init(id: "limit-" + ear.name, ref: nil, icon: "gauge.with.dots.needle.100percent", tone: Theme.ember,
                              title: "\(ear.name) is at \(Int((ear.fiveHour ?? 0) * 100))% of its 5-hour limit",
                              why: "\(ear.working) agent\(ear.working == 1 ? "" : "s") working."))
        }
        return rows
    }

    // MARK: verdicts

    /// A verdict on a card from the deck. Returns false (the card stays) while a note is asked first. With the Mac away it
    /// waits on the phone.
    private func verdict(_ item: Item, _ verdict: Verdict) -> Bool {
        if verdict.needsNote {
            noteFor = Pending(item: item, verdict: verdict)
            return false
        }
        send(item, verdict, sent: false)
        return true
    }

    /// Takes the card off the deck and, unless a note sheet already sent it, holds the verdict for five seconds with an
    /// Undo bar before it goes to the Mac: a swipe is quick to make by mistake.
    private func send(_ item: Item, _ verdict: Verdict, sent: Bool) {
        Deck.exit = verdict
        hintSeen = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { _ = gone.insert(key(item)) }
        guard !sent else { return }
        commit() // one held at a time: the one before goes now
        held = Pending(item: item, verdict: verdict)
        holding = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { commit() }
        }
    }

    /// Sends the held verdict now; puts the card back on error.
    private func commit() {
        holding?.cancel()
        holding = nil
        guard let p = held else { return }
        held = nil
        Task {
            let outcome = await link.review(board: p.item.board.path, card: p.item.card.id, verdict: p.verdict, note: "")
            if let error = outcome.error {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { _ = gone.remove(key(p.item)) }
                // shown now, or when the owner is back: a toast over a phone in a pocket reaches nobody
                if phase == .active { message = error } else { failure = error }
            }
        }
    }

    /// Drops the held verdict before it is sent; the card comes back to the deck.
    private func undo() {
        holding?.cancel()
        holding = nil
        guard let p = held else { return }
        held = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { _ = gone.remove(key(p.item)) }
    }

    private func undoBar(_ p: Pending) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.verdict(p.verdict).fill).frame(width: 10, height: 10)
            Text("\(p.verdict == .approved ? "Approved" : "Done") · \(p.item.card.id)")
                .font(Theme.font(15, .semibold)).foregroundStyle(Theme.onNotch).lineLimit(1)
            Spacer()
            Button("Undo", action: undo)
                .font(Theme.font(15, .bold))
                .buttonStyle(WhiteCapsuleStyle())
                .frame(height: 48)
        }
        .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(Theme.notch).overlay(Capsule().strokeBorder(Theme.notchLine)))
        .padding(.horizontal, 18).padding(.bottom, 4)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private func ref(_ item: Item) -> CardRef { CardRef(board: item.board.path, card: item.card.id) }

    // MARK: island

    private func island(_ left: [Item]) -> some View {
        Island {
            HStack(spacing: 10) {
                Button { forgetting = true } label: { LivePill(opens: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this Mac's settings")
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

    /// Codex and Claude as the Mac's notch shows them: agents at work now, and the 5-hour (outer ring) and weekly
    /// (inner ring) limits.
    private var ears: some View {
        TimelineView(.everyMinute) { time in
            HStack(spacing: 8) {
                ear("Codex", color: Theme.sky.text, now: time.date)
                ear("Claude", color: Theme.ok.text, now: time.date)
            }
        }
    }

    private func ear(_ name: String, color: Color, now: Date) -> some View {
        let ear = link.snapshot?.ears?.first { $0.name == name }
        let n = ear?.working ?? 0
        let five = Self.used(ear?.fiveHour, resets: ear?.fiveHourResets, now: now)
        let week = Self.used(ear?.week, resets: ear?.weekResets, now: now)
        // as on the Mac: a figure that is unknown, or written more than half an hour ago, is dimmed
        let stale = five == nil || ear?.recorded.map { now.timeIntervalSince($0) > 1800 } == true
        func percent(_ used: Double) -> String { "\(Int((used * 100).rounded()))%" }
        let limits = five.map { "\(percent($0)) · ↻ \(Self.left(until: ear?.fiveHourResets, now: now))" }
            ?? week.map { "Week \(percent($0)) · ↻ \(Self.left(until: ear?.weekResets, now: now))" } ?? "Limits not known"
        return HStack(spacing: 10) {
            LimitRings(fiveHour: five, week: week).opacity(stale ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.semibold).foregroundStyle(Theme.onNotch).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    Text(n == 0 ? "idle" : "\(n) at work").font(Theme.font(12)).monospacedDigit().lineLimit(1).fixedSize()
                        .foregroundStyle(n == 0 ? Theme.onNotch2 : color)
                }
                Text(limits).font(Theme.font(11.5)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .opacity(stale ? 0.6 : 1)
            }
        }
        .font(Theme.font(13))
        .foregroundStyle(Theme.onNotch2)
        .padding(.leading, 10).padding(.trailing, 14)
        .frame(height: 44)
        .background(Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(five.map { "\(name): \(n) at work, \(Int(($0 * 100).rounded())) percent of the 5-hour limit used, resets in \(Self.left(until: ear?.fiveHourResets, now: now)); \(week.map { "\(Int(($0 * 100).rounded())) percent" } ?? "unknown") of the week" }
                            ?? "\(name): \(n) at work, limits not known")
    }

    /// A limit's used share (0...1), or nil when the Mac has no figure or the window has rolled over since.
    private static func used(_ percent: Double?, resets: Date?, now: Date) -> Double? {
        guard let percent, let resets, resets > now else { return nil }
        return min(max(percent, 0), 100) / 100
    }

    private static func left(until resets: Date?, now: Date) -> String {
        guard let resets, resets > now else { return "—" }
        let m = Int(resets.timeIntervalSince(now) / 60)
        return m >= 2880 ? "\(m / 1440)d \(m % 1440 / 60)h" : m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    // MARK: filters

    /// One button naming the chosen project; it opens the dial. Hidden when only one project has cards waiting.
    @ViewBuilder
    private func projects(_ left: [Item]) -> some View {
        let names = Dictionary(grouping: left, by: { $0.board.path })
        let order = boards.filter { names[$0.path] != nil }
        if order.count > 1 {
            let options = [DialOption(path: nil, title: "All projects", count: left.count)]
                + order.map { DialOption(path: $0.path, title: $0.displayName, count: names[$0.path]?.count ?? 0) }
            let current = options.first { $0.path == project } ?? options[0]
            Button { picking = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dial.low").font(.system(size: 15, weight: .semibold))
                    Text(current.title).font(Theme.font(15, .semibold)).lineLimit(1)
                    Text("\(current.count)").font(Theme.font(13, .bold)).foregroundStyle(Theme.fg3)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg3)
                }
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 16).frame(minHeight: 46)
                .background(Theme.fg.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project: \(current.title)")
            .accessibilityHint("Opens the project dial")
            .sheet(isPresented: $picking) {
                ProjectDial(title: "Project", options: options, selection: $project)
                    .presentationDetents([.height(310)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

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

private func key(_ item: HomeView.Item) -> String { item.id }

// MARK: - deck

/// The top card full size, the next two peeking behind it; a row of four round verdict buttons under it.
private struct Deck: View {
    let items: [HomeView.Item]
    let connected: Bool
    let queued: Int
    /// Sends a verdict on a card; false means the card stays (a note is asked first).
    let verdict: (HomeView.Item, Verdict) -> Bool

    /// Where the last card sent went, read by the leaving card's transition.
    @MainActor static var exit = Verdict.approved

    @State private var drag = CGSize.zero
    @State private var armed: Verdict?
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 248
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var type

    private static let threshold: CGFloat = 110

    var body: some View {
        let visible = Array(items.prefix(3))
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                    card(item, at: i)
                }
            }
            .frame(height: height + 26, alignment: .top)
            buttons(visible.first)
            if !connected {
                Label(queued == 0 ? "Mac not nearby – verdicts wait on your phone"
                      : "Mac not nearby – \(queued) verdict\(queued == 1 ? "" : "s") waiting to send", systemImage: "wifi.slash").labelStyle(TightLabel())
                    .font(Theme.metaBold).foregroundStyle(Theme.ember.text)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new != nil }
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
                // at the big text sizes the screen scrolls: an up or down drag there is a scroll, not Done or Hold
                drag = type.isAccessibilitySize ? CGSize(width: value.translation.width, height: 0) : value.translation
                armed = progress >= 1 ? direction(drag) : nil
            }
            .onEnded { value in
                // past the threshold, or a quick flick (judged by where it was thrown)
                let thrown = type.isAccessibilitySize ? CGSize(width: value.predictedEndTranslation.width, height: 0) : value.predictedEndTranslation
                let chosen = progress >= 1 ? direction(drag)
                    : max(abs(thrown.width), abs(thrown.height)) > Self.threshold * 1.8 ? direction(thrown) : nil
                if let v = chosen, verdict(item, v) {
                    drag = .zero // the leaving card keeps its place and flies from there
                } else {
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
        let primary = v == .approved
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
        .disabled(top == nil)
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
                .multilineTextAlignment(.leading).lineLimit(3).minimumScaleFactor(0.8)
            if let needs = card.needs {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEEDS YOU TO").kerning(0.9).font(Theme.font(10.5, .bold)).foregroundStyle(Theme.review.text)
                    Text(needs.prefix(1).uppercased() + needs.dropFirst()).font(Theme.font(14.5, .semibold))
                        .foregroundStyle(Theme.fg).lineLimit(3)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.review.fill.opacity(0.12)))
            }
            Spacer(minLength: 0)
            // what the verdict rests on first; the rest drops out when the row is too wide
            ViewThatFits(in: .horizontal) {
                chips(all: true)
                chips(all: false)
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

    private func chips(all: Bool) -> some View {
        HStack(spacing: 6) {
            if card.proof.isEmpty { Pill(text: "No proof", tone: Theme.ember, systemImage: "exclamationmark.triangle") }
            else { Pill(text: card.proof.count == 1 ? "Proof" : "Proof \(card.proof.count)", tone: Theme.ok, systemImage: "checkmark.seal") }
            if card.notes.contains("): changes") { Pill(text: "Back after changes", tone: Theme.sky, systemImage: "arrow.uturn.left") }
            if all, card.isHumanEntered { HumanChip() }
            if all, let track = card.track { Tag(text: track) }
            if card.total > 0 { Tag(text: "\(card.checked)/\(card.total)", systemImage: "checklist") }
        }
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

/// The Mac's two limit arcs: the outer one the 5-hour limit, the inner one the weekly; none for a figure not known.
private struct LimitRings: View {
    let fiveHour: Double?
    let week: Double?

    var body: some View {
        ZStack {
            arc(fiveHour, size: 26)
            arc(week, size: 14)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private func arc(_ used: Double?, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Theme.onNotch.opacity(0.12), lineWidth: 3)
            Circle().trim(from: 0, to: used.map { max($0, 0.015) } ?? 0)
                .stroke(used.map { $0 < 0.6 ? Theme.ok.fill : $0 < 0.85 ? Theme.ember.fill : Theme.late.fill } ?? .clear,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Under the deck: the things besides a verdict that wait for the owner. A card opens; a limit is just said.
private struct AlsoNeeds: View {
    struct Row: Identifiable {
        let id: String
        let ref: CardRef?
        let icon: String
        let tone: Theme.Tone
        let title: String
        let why: String
    }

    let rows: [Row]
    @State private var all = false

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Also needs you · \(rows.count)")
                ForEach(all ? rows : Array(rows.prefix(4))) { row in
                    if let ref = row.ref {
                        NavigationLink(value: ref) { content(row, chevron: true) }.buttonStyle(.plain)
                    } else {
                        content(row, chevron: false)
                    }
                }
                if rows.count > 4 {
                    Button(all ? "Show fewer" : "Show all \(rows.count)") { all.toggle() }
                        .font(Theme.metaBold).foregroundStyle(Theme.fg2).padding(.leading, 4)
                }
            }
            .padding(.top, 8)
        }
    }

    private func content(_ row: Row, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(row.tone.text)
                .frame(width: 36, height: 36).background(Circle().fill(row.tone.fill.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.font(14.5, .semibold)).foregroundStyle(Theme.fg).lineLimit(2)
                Text(row.why).font(Theme.font(12.5)).foregroundStyle(Theme.fg2).lineLimit(2)
            }
            Spacer(minLength: 4)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }
}

/// The paired Mac: its Tailscale address, for reaching it away from home, and forgetting it.
struct MacBox: View {
    let close: () -> Void
    @EnvironmentObject var link: Link
    @State private var address = ""
    @State private var confirming = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if confirming {
                Text("Forget \(link.paired?.name ?? "this Mac")?").font(Theme.font(24, .bold))
                Text("The boards on this phone are removed. To use the Mac again, pair with a new code.")
                    .font(Theme.body).foregroundStyle(Theme.onNotch2)
                HStack(spacing: 10) {
                    Button("Forget") { close(); link.forget() }.buttonStyle(IslandCapsuleStyle(tint: Theme.late.text))
                    Button("Keep") { confirming = false }.buttonStyle(WhiteCapsuleStyle())
                }
            } else {
                Text(link.paired?.name ?? "Your Mac").font(Theme.font(22, .bold))
                TextField("", text: $address, prompt: Text("100.x.y.z or Mac name").foregroundStyle(Theme.onNotch2))
                    .focused($focused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                    .font(Theme.font(17, .semibold))
                    .inputBox(focused: focused)
                    .accessibilityLabel("Tailscale address of your Mac")
                Text("Away from home, the phone reaches the Mac over Tailscale at this address. Turn on \u{201C}Reach the iPhone over Tailscale\u{201D} in the Mac's board menu; it then fills this in itself.")
                    .font(Theme.font(13)).foregroundStyle(Theme.onNotch2)
                HStack(spacing: 10) {
                    Button("Forget Mac…") { confirming = true }.buttonStyle(IslandCapsuleStyle(tint: Theme.late.text))
                    Spacer()
                    Button("Done", action: save).buttonStyle(WhiteCapsuleStyle())
                }
            }
        }
        .onAppear { address = link.paired?.remote ?? "" }
    }

    private func save() {
        if address != (link.paired?.remote ?? "") { link.setRemote(address) }
        close()
    }
}
