import AppKit
import CoreServices
import Foundation
import NotchbanCore

/// The app's state: every board under the projects folder (asked for the first time the board opens; ~/development until then). A board reloads the moment its file changes
/// (FSEvents); a slow full rescan finds boards that appear or vanish. It only ever reads.
@MainActor
final class Model: ObservableObject {
    @Published var boards: [Board] = []
    /// The panel is open size (the board is in it) …
    @Published var expanded = false
    /// … and the board is revealed: grown out of the notch. Shrinks back before the panel does.
    @Published var reveal = false
    @Published var providers: [Provider] = []
    /// Moves once a minute (checked every 15 s), so lease countdowns and stale alarms move without a file change,
    /// and the open board is not redrawn more often than its minutes change.
    @Published var now = Date()

    /// The folder searched for boards, kept between launches.
    @Published var root = UserDefaults.standard.url(forKey: "root")
        ?? Usage.home.appendingPathComponent("development") {
        didSet {
            UserDefaults.standard.set(root, forKey: "root")
            watch()
            rescan()
        }
    }
    /// Off unless the person turns it on: reads Claude Code's sign-in from the Keychain (macOS asks first)
    /// and calls Anthropic's usage endpoint, which is not a documented API.
    @Published var claudeEndpoint = UserDefaults.standard.bool(forKey: "claudeEndpoint") {
        didSet {
            UserDefaults.standard.set(claudeEndpoint, forKey: "claudeEndpoint")
            if claudeEndpoint { fetchClaude() } else { claudeOnline = nil; readLimits() }
        }
    }
    private var watcher: FileWatcher?
    private var timers: [Timer] = []

    var claudeOnline: (fiveHour: Window?, week: Window?, at: Date)?

    func start() {
        refresh()
        readLimits()
        fetchClaude()
        watch()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } },
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } },
            Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in Task { @MainActor in self?.fetchClaude() } },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.readLimits() } },
        ]
    }

    private func watch() {
        watcher = FileWatcher(root: root.path) { [weak self] paths in
            MainActor.assumeIsolated { self?.changed(paths) }
        }
    }

    /// Fetch every repository's origin, then read the boards again: other machines' pushes show within a minute.
    func refresh() {
        let known = boards
        Task.detached {
            Scanner.fetch(known)
            await MainActor.run { self.rescan() }
        }
    }

    /// Claude's limits from its usage endpoint, every few minutes; the status-line file wins when it has figures.
    func fetchClaude() {
        Task {
            guard claudeEndpoint, let got = await Usage.claudeOnline() else { return }
            claudeOnline = (got.fiveHour, got.week, Date())
            readLimits()
        }
    }

    func readLimits() {
        Task.detached {
            let fetched = Usage.read()
            await MainActor.run {
                var read = fetched
                // the endpoint's last good figures stand in while the status-line file has none or only a rolled window
                if let i = read.firstIndex(where: { $0.name == "Claude" }), let online = self.claudeOnline,
                   read[i].fiveHour.map({ $0.resets <= Date() }) ?? true {
                    read[i].fiveHour = online.fiveHour
                    read[i].week = online.week
                    read[i].recorded = online.at
                }
                if read != self.providers { self.providers = read }
            }
        }
    }

    private func tick() {
        let d = Date()
        if Int(d.timeIntervalSince1970 / 60) != Int(now.timeIntervalSince1970 / 60) { now = d }
    }

    func rescan() {
        let root = root
        Task.detached {
            let found = Scanner.boards(under: root)
            await MainActor.run { self.publish(found) }
        }
    }

    /// Asks for the folder to search for boards.
    func chooseRoot() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = root
        open.prompt = "Use This Folder"
        open.message = "Choose the folder that holds your projects. notchban shows every KANBAN.md up to three folders deep under it."
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url { root = url }
    }

    /// Turning the endpoint on says what it does first; macOS then asks before handing over the Keychain item.
    func setClaudeEndpoint(_ on: Bool) {
        guard on else { return claudeEndpoint = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Read Claude's limits from Anthropic?"
        alert.informativeText = "notchban will read Claude Code's sign-in from your Keychain (macOS asks you first) and ask Anthropic's usage endpoint for your 5-hour and weekly limits every three minutes. The endpoint is not a documented API and may stop working. Only the two figures are kept, and only in memory."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { claudeEndpoint = true }
    }

    func board(_ path: String?) -> Board? { boards.first { $0.path == path } }

    var working: Int { boards.reduce(0) { $0 + $1.count(.progress) } }
    var staleCount: Int { boards.reduce(0) { $0 + $1.stale(at: now).count } }

    private func changed(_ paths: [String]) {
        // a push or a fetch moved origin/main: the recorded boards moved with it
        if paths.contains(where: { $0.hasSuffix("/refs/remotes/origin/main") || $0.hasSuffix("/.git/packed-refs") }) { return rescan() }
        let touched = Set(paths.filter { $0.hasSuffix("/KANBAN.md") })
        guard !touched.isEmpty else { return }
        guard touched.isSubset(of: Set(boards.map(\.path))) else { return rescan() }
        Task.detached {
            let fresh = touched.map { ($0, Scanner.board(at: URL(fileURLWithPath: $0))) }
            await MainActor.run {
                var next = self.boards
                for (path, board) in fresh {
                    if let board { next = next.map { $0.path == path ? board : $0 } } else { next.removeAll { $0.path == path } }
                }
                self.publish(next)
            }
        }
    }

    private func publish(_ found: [Board]) {
        guard found != boards else { return }
        boards = found
    }
}

/// FSEvents on a folder tree, file-level, delivered on the main queue with the changed paths.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(root: String, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange(list)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
