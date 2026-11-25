import NotchbanCore
import SwiftUI
import UIKit

@main
struct NotchbanApp: App {
    @StateObject private var link = Link()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if link.paired == nil { PairView() } else { RootView() }
            }
            .environmentObject(link)
            .onChange(of: phase) { _, now in if now == .active { link.browse() } }
        }
    }
}

/// Where a row leads.
struct BoardRef: Hashable { let path: String }
struct CardRef: Hashable { let board: String, card: String }

/// Which tab shows, and the new-card sheet (opened from the + in the tab bar, on a board when one is open).
@MainActor final class Nav: ObservableObject {
    enum Tab { case needs, boards }
    struct NewCard: Identifiable { let board: String?; var id: String { board ?? "" } }
    @Published var tab = Tab.needs
    @Published var newCard: NewCard?
    /// The Boards tab's stack: a board, then its cards. One path for both, so pushing a card keeps the board under it.
    @Published var boards = NavigationPath()
}

/// The two tabs, each with its own navigation, under the design's tab bar (drawn by each screen that shows it).
struct RootView: View {
    @StateObject private var nav = Nav()

    var body: some View {
        TabView(selection: $nav.tab) {
            NavigationStack { HomeView().destinations() }
                .tag(Nav.Tab.needs)
                .toolbar(.hidden, for: .tabBar)
            NavigationStack(path: $nav.boards) { BoardsView().destinations() }
                .tag(Nav.Tab.boards)
                .toolbar(.hidden, for: .tabBar)
        }
        .environmentObject(nav)
        .sheet(item: $nav.newCard) { NewCardView(preset: $0.board) }
    }
}

extension View {
    func destinations() -> some View {
        navigationDestination(for: BoardRef.self) { BoardScreen(path: $0.path) }
            .navigationDestination(for: CardRef.self) { CardScreen(ref: $0) }
    }

    /// A screen of the design: its own black island on top instead of a navigation bar, on the mode's background.
    func designScreen() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .background(Theme.bg.ignoresSafeArea())
            // the notch's black behind the status bar, so content scrolling under it never meets the white clock
            .overlay(alignment: .top) { Theme.notch.frame(height: 0).ignoresSafeArea(edges: .top) }
    }
}

/// Keeps the edge swipe back working while the system navigation bar is hidden.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}

/// Days as the boards write them: YYYY-MM-DD in the phone's time zone.
enum Day {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var today: String { format.string(from: Date()) }
    static func string(_ date: Date) -> String { format.string(from: date) }
    static func date(_ day: String) -> Date? { format.date(from: day) }
    /// Days from today to `day` (negative when past).
    static func offset(_ day: String) -> Int? {
        guard let d = date(day), let t = date(today) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: t, to: d).day
    }
    /// "Fri 21 Nov"
    static func short(_ day: String) -> String {
        date(day)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "en_GB"))) ?? day
    }
    /// "Monday 24 Nov"
    static var long: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }
    /// "3 days late", "1 day late", "today", "tomorrow", "in 4 days", "Fri 5 Dec".
    static func relative(_ day: String) -> String {
        guard let n = offset(day) else { return day }
        switch n {
        case ..<(-1): return "\(-n) days late"
        case -1: return "1 day late"
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: return "in \(n) days"
        default: return short(day)
        }
    }
}

extension Date {
    /// "21:40", or "23 Nov, 21:40" when not today.
    var asOf: String {
        Calendar.current.isDateInToday(self) ? formatted(date: .omitted, time: .shortened)
            : formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

extension Board {
    /// "~/development/pro-muhasebe": the Mac's folder of the board, home shortened.
    var folder: String {
        var p = (path as NSString).deletingLastPathComponent
        if let r = p.range(of: #"^/Users/[^/]+"#, options: .regularExpression) { p.replaceSubrange(r, with: "~") }
        return p
    }

    /// The id the Mac will give the next card: the board's own scheme, one higher (as BoardEditor.nextID does).
    var nextID: String {
        var found: [String: (max: Int, width: Int, count: Int)] = [:]
        for card in cards {
            guard let m = card.id.firstMatch(of: /^([A-Za-z][A-Za-z0-9]*[-_])(\d+)$/), let value = Int(m.2) else { continue }
            let prefix = String(m.1), old = found[prefix] ?? (0, 0, 0)
            found[prefix] = (max(old.max, value), max(old.width, m.2.count), old.count + 1)
        }
        guard let (prefix, best) = found.max(by: { $0.value.count < $1.value.count }).map({ ($0.key, $0.value) }) else {
            return String(name.filter(\.isLetter).prefix(2)).uppercased() + "-1"
        }
        let number = String(best.max + 1)
        return prefix + String(repeating: "0", count: max(0, best.width - number.count)) + number
    }
}

// MARK: - island

/// The black that comes down from the Dynamic Island, with big rounded bottom corners. Its content renders in the
/// dark scheme, so the tokens give light text on the black in both modes.
struct Island<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.onNotch)
            .background {
                UnevenRoundedRectangle(bottomLeadingRadius: 36, bottomTrailingRadius: 36, style: .continuous)
                    .fill(Theme.notch)
                    .padding(.top, -800) // under the status bar and the pull-down bounce
                    .shadow(color: Theme.notchLine, radius: 0, y: 1)
            }
            .environment(\.colorScheme, .dark)
    }
}

/// A screen: the island, then the content, scrolling under the status bar.
struct DesignScroll<Top: View, Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let top: Top
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                top
                VStack(alignment: .leading, spacing: spacing) { content }.padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .designScreen()
    }
}

/// "Ada's MacBook Pro · live", or how far the Mac is.
struct LivePill: View {
    @EnvironmentObject var link: Link
    /// Shown as a button (a chevron): tapping it opens what the pill is a handle for.
    var opens = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 8, height: 8)
                .background(Circle().fill(dot.opacity(0.18)).frame(width: 14, height: 14))
            Group {
                switch link.state {
                case .connected: Text("**\(link.paired?.name ?? "Your Mac")** · live")
                case .connecting: Text("**Connecting to your Mac**\(asOf)")
                case .searching: Text("**Mac not nearby**\(asOf)")
                }
            }
            .lineLimit(1)
            if opens { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onNotch2.opacity(0.7)) }
        }
        .font(Theme.metaBold)
        .foregroundStyle(Theme.onNotch2)
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(height: 28)
        .background(Capsule().fill(Theme.notchWell))
        .accessibilityElement(children: .combine)
    }

    private var dot: Color { link.isConnected ? Color(hex: 0x40E69E) : Color(hex: 0xFF9563) }
    private var asOf: String { link.snapshot.map { " · as of \($0.at.asOf)" } ?? "" }
}

/// The round grey button in the island's top row.
struct IconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.notchWell).overlay(Circle().strokeBorder(Theme.notchLine)))
                .foregroundStyle(Theme.onNotch)
        }
        .accessibilityLabel(label)
    }
}

/// "‹ Needs you" in the island.
struct BackButton: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                Text(title).font(Theme.font(15, .semibold))
            }
            .foregroundStyle(Theme.onNotch)
            .padding(.leading, 12).padding(.trailing, 16)
            .frame(height: 44)
            .background(Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine)))
        }
        .accessibilityLabel("Back to \(title)")
    }
}

// MARK: - tab bar

struct TabBar: View {
    var board: String? = nil
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var link: Link
    @Environment(\.dismiss) private var dismiss

    private var waiting: Int { (link.snapshot?.boards ?? []).reduce(0) { $0 + $1.count(.review) } }

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var typing = false

    /// The island steps aside while the keyboard is up (a rename, a search), so it never rides on top of the keys.
    var body: some View {
        VStack(spacing: 0) {
            if !typing { bar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: typing)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
    }

    /// The notch, dropped to the bottom: a floating black island. The open tab is a lit pill that slides
    /// between the two; the + in the middle is the one white thing on it.
    private var bar: some View {
        HStack(spacing: 6) {
            tab(.needs, "Needs you", "tray.fill", count: waiting)
            Button { nav.newCard = .init(board: board) } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.notch)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.onNotch))
                    .shadow(color: .white.opacity(0.25), radius: 8)
            }
            .disabled(!link.isConnected || (link.snapshot?.boards ?? []).isEmpty)
            .accessibilityLabel(board.flatMap(link.board).map { "New card on \($0.displayName)" } ?? "New card")
            tab(.boards, "Boards", "rectangle.split.3x1.fill", count: 0)
        }
        .padding(6)
        .background {
            Capsule().fill(Theme.notch)
                .overlay(Capsule().strokeBorder(Theme.notchLine))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .background {  // content fades out above the island and is gone under it, down past the home indicator
            LinearGradient(stops: [.init(color: Theme.bg.opacity(0), location: 0), .init(color: Theme.bg, location: 0.55)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -28).ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
        }
        .sensoryFeedback(.selection, trigger: nav.tab)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: nav.tab)
    }

    private func tab(_ tab: Nav.Tab, _ title: String, _ icon: String, count: Int) -> some View {
        let on = nav.tab == tab && (tab == .boards || board == nil)
        return Button {
            if nav.tab == tab { dismiss() } else { nav.tab = tab }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(Theme.font(13, .semibold)).lineLimit(1).fixedSize()
                if count > 0 {
                    Text("\(count)").font(Theme.font(11, .bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minHeight: 18)
                        .background(Capsule().fill(Theme.stale))
                }
            }
            .foregroundStyle(on ? Theme.onNotch : Theme.onNotch2.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                if on {
                    Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab == .needs && count > 0 ? "\(title), \(count) waiting" : title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - small parts

/// A board's coloured square.
struct BoardDot: View {
    let board: Board
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3, style: .continuous).fill(Theme.board(board)).frame(width: size, height: size)
    }
}

/// The owner's black chip: his card.
struct HumanChip: View {
    var height: CGFloat = 22

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "person").font(.system(size: 10, weight: .bold))
            Text("Human Entered")
        }
        .font(Theme.chip)
        .foregroundStyle(Theme.onNotch)
        .padding(.leading, 7).padding(.trailing, 9)
        .frame(height: height)
        .background(Capsule().fill(Theme.notch))
        .overlay(Capsule().strokeBorder(Theme.notchLine))
        .fixedSize()
    }
}

/// A quiet grey tag: track, size, "2 wait for it".
struct Tag: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(Theme.font(11.5, .medium))
        .foregroundStyle(Theme.fg2)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
        .fixedSize()
    }
}

/// A tinted capsule: a column, a review day.
struct Pill: View {
    let text: String
    let tone: Theme.Tone
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
            Text(text)
        }
        .font(Theme.metaBold)
        .foregroundStyle(tone.text)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(tone.fill.opacity(0.16)))
        .fixedSize()
    }
}

/// A section header: "LATE 2".
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var color: Color = Theme.fg3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased()).kerning(0.8)
            if let count { Text("\(count)").fontWeight(.semibold) }
        }
        .font(Theme.section)
        .foregroundStyle(color)
        .padding(.horizontal, 4).padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The white (or navy) rounded card every row sits on.
struct Surface<Content: View>: View {
    var padding: CGFloat = 16
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
            .cardShadow(radius: 22)
    }
}

/// The owner's black button.
struct BlackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.button)
            .foregroundStyle(enabled ? Theme.onNotch : Theme.onNotch.opacity(0.4))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.notch))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.notchLine))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// "Add note", "Review by…".
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(15, .medium))
            .foregroundStyle(Theme.fg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// A form field's small capital label.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).kerning(0.6).font(Theme.label).foregroundStyle(Theme.fg3)
    }
}

extension View {
    /// An input on an island: a dark well with a faint line, sky when focused.
    func inputBox(focused: Bool = false) -> some View {
        font(Theme.font(16))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.notchWell))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(focused ? Theme.sky.fill : Theme.notchLine, lineWidth: focused ? 2 : 1))
    }
}

/// A sheet's top row: "Cancel   Title   (trailing)".
struct SheetHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.font(26, .bold)).kerning(-0.5).foregroundStyle(Theme.fg)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.fg)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.notchWell).overlay(Circle().strokeBorder(Theme.notchLine)))
            }
            .accessibilityLabel("Cancel")
        }
        .padding(.top, 22)
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.last.map { $0.x + $0.size.width } ?? 0 }.max() ?? 0
        let height = rows.last.flatMap { row in row.map { $0.y + $0.size.height }.max() } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var i = 0
        for row in rows(bounds.width, subviews) {
            for item in row {
                subviews[i].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + item.y), proposal: ProposedViewSize(item.size))
                i += 1
            }
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(x: CGFloat, y: CGFloat, size: CGSize)]] {
        var rows: [[(x: CGFloat, y: CGFloat, size: CGSize)]] = [[]]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            rows[rows.count - 1].append((x, y, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}

/// The coloured lane bar: one segment per non-empty column, in board order.
struct Lanes: View {
    let board: Board
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let columns = Column.allCases.filter { board.count($0) > 0 }
            let total = CGFloat(max(board.cards.count, 1))
            let gap: CGFloat = height >= 10 ? 4 : 2
            let usable = geo.size.width - CGFloat(max(columns.count - 1, 0)) * gap
            HStack(spacing: gap) {
                ForEach(columns, id: \.self) { column in
                    Capsule().fill(Theme.column(column).fill)
                        .frame(width: max(height, usable * CGFloat(board.count(column)) / total))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - islands (v2)

extension View {
    /// A floating black island: the notch's black, a faint line, a deep shadow; its content renders in the dark scheme.
    func floatingIsland(radius: CGFloat = 30) -> some View {
        foregroundStyle(Theme.onNotch)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.notch)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.notchLine))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            }
            .environment(\.colorScheme, .dark)
    }
}

/// The one white thing on an island: its primary action.
struct WhiteCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.button)
            .foregroundStyle(Theme.notch)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(Capsule().fill(Theme.onNotch))
            .shadow(color: .white.opacity(enabled ? 0.22 : 0), radius: 10)
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A lit capsule on an island: a secondary action.
struct IslandCapsuleStyle: ButtonStyle {
    var tint: Color = Theme.onNotch
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(15, .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine)))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

/// A black capsule of choices with one lit capsule that slides to the chosen one, as in the tab bar.
struct LitSwitcher<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var count: Int? = nil
        var accent: Color? = nil
        var dot: Color? = nil
    }

    let options: [Option]
    @Binding var selection: Value
    /// Share the width equally instead of scrolling.
    var fill = false
    var label = "Show"

    @Namespace private var lit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if fill {
                row
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { row }
                        .scrollIndicators(.hidden)
                        .onAppear { proxy.scrollTo(selection, anchor: .center) }
                        .onChange(of: selection) { _, new in
                            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8)) {
                                proxy.scrollTo(new, anchor: .center)
                            }
                        }
                }
            }
        }
        .clipShape(Capsule())
        .background {
            Capsule().fill(Theme.notch)
                .overlay(Capsule().strokeBorder(Theme.notchLine))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.selection, trigger: selection)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        if let dot = option.dot {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(dot).frame(width: 9, height: 9)
                        }
                        Text(option.title).lineLimit(1).fixedSize()
                        if let count = option.count {
                            Text("\(count)").font(Theme.font(12, .bold).monospacedDigit()).lineLimit(1).fixedSize()
                                .foregroundStyle(option.accent ?? (on ? Theme.onNotch : Theme.onNotch2))
                        }
                    }
                    .font(Theme.font(13.5, .semibold))
                    .foregroundStyle(on ? Theme.onNotch : Theme.onNotch2.opacity(0.8))
                    .padding(.horizontal, fill ? 8 : 14)  // four shared segments: room for "Later 116"
                    .frame(maxWidth: fill ? .infinity : nil, minHeight: 44)
                    .background {
                        if on {
                            Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine))
                                .matchedGeometryEffect(id: "lit", in: lit)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .id(option.value)
                .accessibilityLabel(option.count.map { "\(option.title), \($0)" } ?? option.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(5)
    }
}

extension View {
    /// A prompt that rises as a black island over a dimmed screen, instead of a stock alert or confirmation sheet.
    func islandPrompt<Prompt: View>(isPresented: Binding<Bool>, @ViewBuilder prompt: @escaping () -> Prompt) -> some View {
        modifier(IslandPromptModifier(isPresented: isPresented, prompt: prompt))
    }

    /// A short black capsule message at the top that leaves on its own.
    func toast(_ message: Binding<String?>) -> some View { modifier(ToastModifier(message: message)) }
}

private struct IslandPromptModifier<Prompt: View>: ViewModifier {
    @Binding var isPresented: Bool
    let prompt: () -> Prompt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .bottom) {
                if isPresented {
                    Color.black.opacity(0.4).ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Close")
                        .transition(.opacity)
                    VStack(alignment: .leading, spacing: 14) { prompt() }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .floatingIsland(radius: 32)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isModal)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85), value: isPresented)
        }
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(Theme.font(14, .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .floatingIsland(radius: 24)
                    .padding(.horizontal, 24).padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { self.message = nil }
                    .task(id: message) {
                        UIAccessibility.post(notification: .announcement, argument: message)
                        try? await Task.sleep(for: .seconds(3.5))
                        self.message = nil
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: message)
    }
}
