import NotchbanCore
import SwiftUI

/// Two rows over the board: the board switcher, live counts and search; then filters, grouping and
/// the critical path.
struct Toolbar: View {
    @EnvironmentObject var model: Model
    @ObservedObject var state: BoardState
    let board: Board
    let graph: BoardGraph
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                switcher
                stats
                Spacer(minLength: 8)
                filters
                Picker("Group by", selection: $state.grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Group into lanes (G)")
                Toggle(isOn: $state.agents) { Label("\(model.providers.reduce(0) { $0 + $1.active })", systemImage: "point.3.filled.connected.trianglepath.dotted") }
                    .toggleStyle(PillToggle(tint: Theme.good)).fixedSize()
                    .help("Who works where: the working agents, their subagents and their cards (A)")
                Toggle(isOn: $state.critical) { Image(systemName: "flame") }
                    .toggleStyle(PillToggle(tint: Theme.critical))
                    .help("Critical path: the heaviest open dependency chain (C)")
                search
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
        }
        .background(LinearGradient(colors: [.black, Theme.ink], startPoint: .top, endPoint: .bottom))  // the notch's black, deepening into ink
        .overlay(alignment: .bottom) { LinearGradient(colors: [Theme.upstream.opacity(0), Theme.upstream.opacity(0.35), Theme.good.opacity(0.35), Theme.good.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(height: 1) }
        .environment(\.colorScheme, .dark)
        .onChange(of: state.focusSearch) { searching = $0 }
        .onChange(of: searching) { state.focusSearch = $0 }
    }

    private var switcher: some View {
        Menu {
            ForEach(model.boards) { b in
                Button { state.show(b.path) } label: {
                    Text("\(b.name)   \(b.count(.progress)) active · \(b.count(.blocked)) blocked · \(b.cards.count) cards")
                }
            }
            Divider()
            Button("Boards Folder: \((model.root.path as NSString).abbreviatingWithTildeInPath)…") { model.chooseRoot() }
            Toggle("Claude Limits from Anthropic", isOn: Binding(get: { model.claudeEndpoint }, set: { model.setClaudeEndpoint($0) }))
            Divider()
            Button("Quit Notchban") { NSApp.terminate(nil) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2").foregroundStyle(.secondary)
                Text(board.name).font(.system(size: 16, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Switch board ([ and ])")
    }

    private var stats: some View {
        let stale = board.stale(at: model.now).count
        let ready = board.cards.filter(graph.isActionable).count
        return HStack(spacing: 6) {
            Stat(value: board.count(.progress), label: "active", tint: Theme.column(.progress))
            Stat(value: board.count(.review), label: "review", tint: Theme.column(.review))
            Stat(value: ready, label: "takeable", tint: Theme.column(.ready))
            Stat(value: board.count(.blocked), label: "blocked", tint: Theme.alarm)
            if stale > 0 { StaleBadge(count: stale) }
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search cards", text: $state.filter.text).textFieldStyle(.plain).focused($searching)
            if !state.filter.text.isEmpty {
                Button { state.filter.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Clear search")
            } else {
                Text("/").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10).frame(width: 170, height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searching ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private var filters: some View {
        let owners = Set(board.cards.compactMap(\.owner)).sorted()
        let tracks = Set(board.cards.compactMap(\.track)).sorted()
        let risks = Set(board.cards.compactMap(\.risk)).sorted()
        return HStack(spacing: 6) {
            Toggle(isOn: $state.filter.actionable) { Label("Ready", systemImage: "bolt.fill") }
                .toggleStyle(PillToggle(tint: Theme.column(.ready))).fixedSize()
                .help("Only cards someone can take now (R)")
            FilterMenu(title: "Owner", icon: "person.crop.circle", value: state.filter.owner.map(Format.owner),
                       options: owners.map { ($0, Format.owner($0)) }) { state.filter.owner = $0 }
            if !tracks.isEmpty {
                FilterMenu(title: "Track", icon: "point.3.connected.trianglepath.dotted", value: state.filter.track.map { "Track \($0)" },
                           options: tracks.map { ($0, "Track \($0)") }) { state.filter.track = $0 }
            }
            if !risks.isEmpty {
                FilterMenu(title: "Risk", icon: "shield.lefthalf.filled", value: state.filter.risk,
                           options: risks.map { ($0, $0) }) { state.filter.risk = $0 }
            }
            if !state.filter.isEmpty {
                Button("Clear") { state.filter = CardFilter() }.buttonStyle(.link).font(.system(size: 11.5))
            }
        }
    }
}

struct Stat: View {
    let value: Int, label: String, tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(value)").font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
            
        }
        .padding(.horizontal, 4).frame(height: 22)
        .opacity(value == 0 ? 0.45 : 1)
        .help("\(value) \(label)")
    }
}

struct StaleBadge: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Label("\(count) stale lease\(count == 1 ? "" : "s")", systemImage: "bell.badge.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Theme.alarm).shadow(color: Theme.alarm.opacity(on ? 0.7 : 0.2), radius: on ? 8 : 2))
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatCount(5)) { on = true } } }
            .help("In Progress with an expired lease: nobody is working on it")
    }
}

struct PillToggle: ToggleStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .labelStyle(TightLabel())
                .foregroundStyle(configuration.isOn ? .white : .primary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(configuration.isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Theme.well)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct FilterMenu<Value: Hashable>: View {
    let title: String, icon: String
    let value: String?
    let options: [(Value, String)]
    let set: (Value?) -> Void
    var body: some View {
        Menu {
            Button("Any \(title.lowercased())") { set(nil) }
            Divider()
            ForEach(options, id: \.0) { option in Button(option.1) { set(option.0) } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(value ?? title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(value == nil ? Color.primary : Color.accentColor)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(value == nil ? Theme.well : Color.accentColor.opacity(0.15)))
        .disabled(options.isEmpty)
    }
}
