import NotchbanCore
import SwiftUI

/// One card: what it says in the island, its checklist and notes below, and a dock with the owner's verdict (for a
/// Human Review card) plus a note or a review day for any card.
struct CardScreen: View {
    let ref: CardRef
    @EnvironmentObject var link: Link
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?
    @State private var confirming: Verdict?
    @State private var sending: Verdict?
    @State private var problem: String?

    enum Sheet: Identifiable {
        case note, due, verdict(Verdict)
        var id: String {
            switch self {
            case .note: "note"
            case .due: "due"
            case .verdict(let v): v.rawValue
            }
        }
    }

    var body: some View {
        if let board = link.board(ref.board), let card = board.card(ref.card) {
            DesignScroll(spacing: 14) {
                island(board, card)
            } content: {
                if let blocker = card.blocker {
                    Alarm(text: "**Blocked:** \(blocker)")
                }
                if !card.checklist.isEmpty { checklist(card) }
                ForEach(Array(noteLines(card).enumerated()), id: \.offset) { _, line in NoteLine(text: line) }
                ForEach(card.proof, id: \.self) { proof in
                    NoteLine(text: proof, systemImage: "checkmark.seal", links: true)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock(card) }
            .sheet(item: $sheet) { sheet in
                Group {
                    switch sheet {
                    case .note: NoteSheet(ref: ref, verdict: nil)
                    case .due: DueSheet(ref: ref, current: card.due)
                    case .verdict(let v): NoteSheet(ref: ref, verdict: v) { dismiss() }
                    }
                }
                .presentationDetents(sheet.id == "due" ? [.large] : [.medium, .large])
            }
            .toast($problem)
            .islandPrompt(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                let verdict = confirming ?? .done
                HStack(spacing: 10) {
                    Image(systemName: verdict == .done ? "checkmark" : "arrow.right").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0B1220))
                        .frame(width: 36, height: 36).background(Circle().fill(Theme.verdict(verdict).fill))
                    Text(verdict == .done ? "Mark \(card.id) done?" : "Let \(card.id) go ahead?").font(Theme.font(22, .bold))
                }
                Text(verdict == .done ? "It moves to Done on your Mac." : "It goes back to Ready, and an agent may take the next step.")
                    .font(Theme.body).foregroundStyle(Theme.onNotch2)
                HStack(spacing: 10) {
                    Button("Cancel") { confirming = nil }.buttonStyle(IslandCapsuleStyle())
                    Button(verdict == .done ? "Done" : "Approve") { confirming = nil; review(verdict) }
                        .buttonStyle(WhiteCapsuleStyle())
                }
                .padding(.top, 4)
            }
        } else {
            ContentUnavailableView("This card has moved or is gone", systemImage: "rectangle.on.rectangle.slash",
                                   description: Text("Its board changed since your phone last saw it."))
                .designScreen()
                .toolbar(.visible, for: .navigationBar)
        }
    }

    // MARK: island

    private func island(_ board: Board, _ card: Card) -> some View {
        Island(spacing: 12) {
            HStack {
                BackButton(title: backTitle(card))
                Spacer()
                HStack(spacing: 8) {
                    IconButton(systemImage: "note.text", label: "Add note") { sheet = .note }
                    IconButton(systemImage: "calendar", label: "Review by") { sheet = .due }
                }
                .disabled(!link.isConnected)
            }
            HStack(spacing: 7) {
                BoardDot(board: board)
                Text(board.displayName).font(Theme.metaBold).lineLimit(1)
                Text(card.id).font(Theme.id)
                if card.total > 0 { Text("· \(card.checked)/\(card.total)").font(Theme.meta) }
            }
            .foregroundStyle(Theme.onNotch2)
            .accessibilityElement(children: .combine)
            Text(card.title).font(Theme.font(30, .bold)).kerning(-0.8).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 6) {
                Pill(text: card.column.rawValue, tone: Theme.column(card.column))
                if let due = card.due {
                    let late = (Day.offset(due) ?? 0) < 0
                    Pill(text: late ? "\(Day.relative(due)) · due \(Day.short(due))" : "review by \(Day.short(due))",
                         tone: late ? Theme.late : Theme.review, systemImage: "calendar")
                }
                if card.isHumanEntered {
                    HStack(spacing: 5) {
                        Image(systemName: "person").font(.system(size: 10, weight: .bold))
                        Text("Human Entered")
                    }
                    .font(Theme.chip).padding(.leading, 10).padding(.trailing, 12).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Theme.notchLine))
                }
                if let owner = card.owner { Who(owner: owner).padding(.horizontal, 6).frame(height: 26) }
            }
            if let needs = card.needs {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEEDS YOU TO").kerning(0.9).font(Theme.font(11, .bold)).foregroundStyle(Theme.onNotch2)
                    Text(needs.prefix(1).uppercased() + needs.dropFirst()).font(Theme.font(15, .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.notchWell)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.notchLine)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func backTitle(_ card: Card) -> String { card.column == .review ? "Needs you" : "Back" }

    // MARK: body

    private func checklist(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(card.checklist.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Group {
                        if item.done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok.text)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ok.fill.opacity(0.2)))
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line, lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    Text(item.text).font(Theme.font(13.5)).foregroundStyle(item.done ? Theme.fg2 : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.done ? "done" : "open")
            }
        }
        .padding(.horizontal, 4)
    }

    /// The notes, line by line, without the `Needs:` line the island shows or a `Blocker:` line shown above.
    private func noteLines(_ card: Card) -> [String] {
        let lines = card.notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lastNeeds = lines.lastIndex { $0.hasPrefix("Needs:") }
        return lines.enumerated().filter { i, line in
            i != lastNeeds && !(card.blocker != nil && line.hasPrefix("Blocker:"))
        }.map(\.element)
    }

    // MARK: dock

    /// A black island docked at the bottom like the tab bar: four verdict capsules for a Human Review card (Done is
    /// the white one), else a note and a review day.
    private func dock(_ card: Card) -> some View {
        VStack(spacing: 8) {
            if !link.isConnected {
                Label(card.column == .review ? "Mac not nearby – a verdict waits on your phone" : "Mac not nearby – this needs your Mac",
                      systemImage: "wifi.slash").labelStyle(TightLabel())
                    .font(Theme.metaBold).foregroundStyle(Theme.ember.text)
                    .padding(.top, 6)
            }
            HStack(spacing: 6) {
                if card.column == .review {
                    capsule(.hold, "Hold", "pause.fill", "Say why. Goes to Blocked.") { sheet = .verdict(.hold) }
                    capsule(.changes, "Changes", "arrow.uturn.left", "Say what to fix. Back to Ready.") { sheet = .verdict(.changes) }
                    capsule(.approved, "Approve", "arrow.right", "Go ahead. Back to Ready.") { confirming = .approved }
                    capsule(.done, "Done", "checkmark", "Finished. Goes to Done.") { confirming = .done }
                } else {
                    Button { sheet = .due } label: { Label("Review by", systemImage: "calendar") }
                        .buttonStyle(IslandCapsuleStyle())
                    Button { sheet = .note } label: { Label("Add note", systemImage: "note.text") }
                        .buttonStyle(WhiteCapsuleStyle())
                }
            }
            .disabled(sending != nil || (card.column != .review && !link.isConnected))
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.notch)
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Theme.notchLine))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 14).padding(.bottom, 4)
        .background {
            LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func capsule(_ verdict: Verdict, _ title: String, _ icon: String, _ hint: String, action: @escaping () -> Void) -> some View {
        let tone = Theme.verdict(verdict)
        let primary = verdict == .approved
        return Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if sending == verdict { ProgressView().tint(primary ? Theme.notch : Theme.onNotch) } else {
                        Image(systemName: icon).font(.system(size: 17, weight: .bold))
                    }
                }
                .frame(height: 20)
                .foregroundStyle(tone.fill)
                Text(title).font(Theme.font(13, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(primary ? Theme.notch : Theme.onNotch)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background {
                if primary {
                    Capsule().fill(Theme.onNotch).shadow(color: .white.opacity(0.22), radius: 10)
                } else {
                    Capsule().fill(Theme.notchWell).overlay(Capsule().strokeBorder(Theme.notchLine))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressDown())
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func review(_ verdict: Verdict) {
        sending = verdict
        Task {
            let outcome = await link.review(board: ref.board, card: ref.card, verdict: verdict, note: "")
            sending = nil
            if let error = outcome.error { problem = error } else { dismiss() }
        }
    }
}

/// Sinks a little while pressed.
struct PressDown: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// A line of the card's notes. "Note (Ada, 2026-11-20): …" shows as **Ada, 20 Nov** · …
struct NoteLine: View {
    let text: String
    var systemImage = "note.text"
    /// Web addresses in the line open in the browser (a proof line often names a pull request).
    var links = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.fg3)
            Group { if links { Text(linked(text)) } else { styled } }
                .font(Theme.needs).foregroundStyle(Theme.fg2).tint(Theme.sky.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func linked(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        let found = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?
            .matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? []
        for m in found {
            if let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: out) { out[ar].link = url }
        }
        return out
    }

    private var styled: Text {
        if let m = text.firstMatch(of: /^(Note|Review) \(([^,]+), (\d{4}-\d{2}-\d{2})\): (.*)$/) {
            return Text("\(String(m.2)), \(dayMonth(String(m.3)))").bold().foregroundColor(Theme.fg) + Text(" · \(String(m.4))")
        }
        if let m = text.firstMatch(of: /^(\d{4}-\d{2}-\d{2}):? (.*)$/) {
            return Text(dayMonth(String(m.1))).bold().foregroundColor(Theme.fg) + Text(" · \(String(m.2))")
        }
        if let m = text.firstMatch(of: /^([A-Z][A-Za-z ]{1,20}):\s(.*)$/) {
            return Text("\(String(m.1)):").bold().foregroundColor(Theme.fg) + Text(" \(String(m.2))")
        }
        return Text(text)
    }

    private func dayMonth(_ day: String) -> String {
        Day.date(day)?.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB"))) ?? day
    }
}

/// A note on a card, or the note a "Changes" or "Hold" verdict needs.
struct NoteSheet: View {
    let ref: CardRef
    let verdict: Verdict?
    var done: () -> Void = {}
    @EnvironmentObject var link: Link
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var title: String { verdict == .hold ? "Put on Hold" : verdict == .changes ? "Request Changes" : "Add Note" }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: title)
            VStack(alignment: .leading, spacing: 7) {
                FieldLabel(text: verdict == .hold ? "What it waits for" : verdict == .changes ? "What to fix" : "Note")
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($focused)
                    .inputBox(focused: focused)
                    .accessibilityLabel(verdict == .hold ? "What it waits for" : verdict == .changes ? "What to fix" : "Note")
                Text(problem ?? (verdict == .hold ? "The card moves to Blocked; this note is its blocker."
                     : verdict == .changes ? "The card goes back to Ready with this note for the agent."
                     : "Added to the card with your name and today's date."))
                    .font(Theme.font(13)).foregroundStyle(problem == nil ? Theme.fg3 : Theme.late.text)
            }
            Button(action: send) {
                if sending { ProgressView().tint(Theme.notch) } else {
                    Text(verdict == .hold ? "Send to Blocked" : verdict == .changes ? "Send back to Ready" : "Add note")
                }
            }
            .buttonStyle(WhiteCapsuleStyle())
            .disabled(empty || sending || (verdict == nil && !link.isConnected))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .onAppear { focused = true }
        .designSheet()
    }

    private func send() {
        sending = true
        Task {
            let outcome: Outcome
            if let verdict {
                outcome = await link.review(board: ref.board, card: ref.card, verdict: verdict, note: text)
            } else {
                outcome = await link.run(.note(board: ref.board, card: ref.card, text: text))
            }
            sending = false
            if let error = outcome.error { problem = error } else { dismiss(); done() }
        }
    }
}

/// The owner's review day for a card.
struct DueSheet: View {
    let ref: CardRef
    let current: String?
    @EnvironmentObject var link: Link
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Review By") {
                if current != nil {
                    Button("Clear") { send(nil) }.font(Theme.font(16)).foregroundStyle(Theme.late.text)
                        .accessibilityLabel("Clear review day")
                }
            }
            DatePicker("Review by", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.sky.fill)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.notchWell))
            if let problem { Text(problem).font(Theme.font(13)).foregroundStyle(Theme.late.text) }
            Button { send(Day.string(day)) } label: {
                if sending { ProgressView().tint(Theme.notch) } else { Text("Review by \(Day.short(Day.string(day)))") }
            }
            .buttonStyle(WhiteCapsuleStyle())
            .disabled(sending || !link.isConnected)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .onAppear {
            day = current.flatMap(Day.date) ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        }
        .designSheet()
    }

    private func send(_ value: String?) {
        sending = true
        Task {
            let outcome = await link.run(.due(board: ref.board, card: ref.card, day: value))
            sending = false
            if let error = outcome.error { problem = error } else { dismiss() }
        }
    }
}

extension View {
    /// A sheet of the design: a black island rising from the bottom, big corners, a grabber; dark inside in both modes.
    func designSheet() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(Theme.onNotch)
            .environment(\.colorScheme, .dark)
            .presentationBackground(Theme.notch)
            .presentationCornerRadius(38)
            .presentationDragIndicator(.visible)
    }
}
