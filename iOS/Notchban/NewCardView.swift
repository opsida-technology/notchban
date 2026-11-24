import NotchbanCore
import SwiftUI

/// A card the owner types in. The Mac writes it on top of Backlog or Ready, tagged Human Entered.
struct NewCardView: View {
    /// The board to start on (the open board when the + was tapped there).
    var preset: String? = nil
    @EnvironmentObject var link: Link
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastBoard") private var board = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var column = Column.ready
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var field: Field?

    enum Field { case title, notes }

    private var boards: [Board] {
        (link.snapshot?.boards ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        let target = link.board(board)
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "New card").padding(.horizontal, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        HumanChip(height: 26)
                        Text("Agents keep your words and write theirs below.").font(Theme.font(13)).foregroundStyle(Theme.fg2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8).padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine)))
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Board")
                        boardChips
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Title")
                        TextField("", text: $title, prompt: Text("What needs doing").foregroundStyle(Theme.fg3), axis: .vertical)
                            .lineLimit(1...3)
                            .focused($field, equals: .title)
                            .inputBox(focused: field == .title)
                            .accessibilityLabel("Title")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Notes")
                        TextField("", text: $notes, prompt: Text("Anything the agent should know").foregroundStyle(Theme.fg3), axis: .vertical)
                            .lineLimit(3...8)
                            .focused($field, equals: .notes)
                            .inputBox(focused: field == .notes)
                            .accessibilityLabel("Notes")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        FieldLabel(text: "Goes to")
                        segment
                        (Text(column == .ready ? "Ready: an agent may take it now." : "Backlog: kept for later.")
                         + Text(target == nil ? "" : " It lands on top as ")
                         + Text(target?.nextID ?? "").font(Theme.font(13, mono: true)).foregroundColor(Theme.fg)
                         + Text(target == nil ? "" : "."))
                            .font(Theme.font(13)).foregroundStyle(Theme.fg3)
                    }
                    if let problem { Text(problem).font(Theme.font(13)).foregroundStyle(Theme.late.text) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            Button(action: add) {
                if sending { ProgressView().tint(Theme.notch) } else {
                    Label(target.map { "Add to \($0.displayName)" } ?? "Add", systemImage: "plus").labelStyle(TightLabel())
                }
            }
            .buttonStyle(WhiteCapsuleStyle())
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == nil || !link.isConnected || sending)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .onAppear {
            if let preset, link.board(preset) != nil { board = preset }
            if link.board(board) == nil { board = boards.first?.path ?? "" }
        }
        .designSheet()
    }

    private var boardChips: some View {
        LitSwitcher(options: boards.map { .init(value: $0.path, title: $0.displayName, dot: Theme.board($0)) },
                    selection: $board, label: "Board")
    }

    private var segment: some View {
        LitSwitcher(options: [.init(value: Column.backlog, title: Column.backlog.rawValue), .init(value: .ready, title: Column.ready.rawValue)],
                    selection: $column, fill: true, label: "Goes to")
    }

    private func add() {
        sending = true
        Task {
            let outcome = await link.run(.add(board: board, title: title, notes: notes, column: column))
            sending = false
            if let error = outcome.error { problem = error } else { dismiss() }
        }
    }
}
