import Foundation

/// One usage window (the 5-hour or the weekly limit): how much is used and when it rolls over.
struct Window: Equatable {
    var used: Double  // 0...100
    var resets: Date
    func current(at now: Date) -> Double { resets < now ? 0 : min(max(used, 0), 100) }  // a window that has rolled is empty
}

/// A provider's two windows, read from what its own tool already writes on this Mac. Nothing is sent anywhere.
struct Agent: Equatable, Identifiable {
    var id: String
    var title: String
    var folder: String
    var working: Bool
    var note: String          // model, or how long it has run
    var branch = ""           // the folder's checked-out branch, when it is a git checkout
    var subs: [Agent] = []
}

struct Provider: Equatable {
    var name: String
    var fiveHour: Window?
    var week: Window?
    var agents: [Agent] = []
    var recorded: Date?       // when the limits were last written by the tool itself
    var active: Int { agents.reduce(0) { $0 + ($1.working ? 1 : 0) + $1.subs.filter(\.working).count } }
    var rows: Int { max(1, agents.reduce(0) { $0 + 1 + $1.subs.count }) }
}

enum Usage {
    /// $HOME, where Claude Code and Codex write their sessions; the account's home only when it is unset.
    static let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())

    static func read() -> [Provider] {
        var codex = codex(), claude = claude()
        codex.agents = codexAgents()
        claude.agents = claudeAgents()
        return [codex, claude]
    }

    /// Codex logs its rate limits in every session's `token_count` events: the last one of the newest session.
    static func codex() -> Provider {
        var limits = Provider(name: "Codex")
        let root = home.appendingPathComponent(".codex/sessions")
        var checked = 0
        for year in names(root) {
            for month in names(root.appendingPathComponent(year)) {
                for day in names(root.appendingPathComponent("\(year)/\(month)")) {
                    let dir = root.appendingPathComponent("\(year)/\(month)/\(day)")
                    for file in names(dir).filter({ $0.hasSuffix(".jsonl") }) {
                        if let found = codexLimits(dir.appendingPathComponent(file)) {
                            limits.fiveHour = found.0; limits.week = found.1; limits.recorded = modified(dir.appendingPathComponent(file)); return limits
                        }
                        checked += 1
                        if checked >= 4 { return limits }
                    }
                }
            }
        }
        return limits
    }

    private static func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted(by: >)
    }

    private static func codexLimits(_ file: URL) -> (Window?, Window?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        // Some records carry null windows (plan only); walk back to the last one that measured something.
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = ((json["payload"] as? [String: Any]) ?? json)["rate_limits"] as? [String: Any] else { continue }
            func window(_ key: String) -> Window? {
                guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double,
                      let at = date(w["resets_at"]) else { return nil }
                return Window(used: used, resets: at)
            }
            let (primary, secondary) = (window("primary"), window("secondary"))
            if primary != nil || secondary != nil { return (primary, secondary) }
        }
        return nil
    }

    /// Claude Code hands its status line the limits as JSON; `notchban-statusline.sh` keeps the last one in a file.
    static let claudeFile = home.appendingPathComponent(".claude/notchban-usage.json")

    static func claude() -> Provider {
        var limits = Provider(name: "Claude")
        guard let data = try? Data(contentsOf: claudeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rate_limits"] as? [String: Any] else { return limits }
        func window(_ key: String) -> Window? {
            guard let w = rates[key] as? [String: Any], let used = (w["used_percentage"] as? Double) ?? (w["used_percentage"] as? Int).map(Double.init),
                  let at = date(w["resets_at"]) else { return nil }
            return Window(used: used, resets: at)
        }
        limits.recorded = modified(claudeFile)
        limits.fiveHour = window("five_hour")
        limits.week = window("seven_day")
        return limits
    }

    /// Claude's own usage endpoint, with the token Claude Code keeps in the Keychain. Only when the person turned it on (Model.claudeEndpoint).
    /// Nothing is stored or shown but the two windows.
    static func claudeOnline() async -> (fiveHour: Window?, week: Window?)? {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        find.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        find.standardOutput = pipe
        find.standardError = FileHandle.nullDevice
        guard (try? find.run()) != nil else { return nil }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        find.waitUntilExit()
        guard let creds = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let token = (creds["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let reply = try? await URLSession.shared.data(for: request)
        guard let (data, response) = reply, (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = json[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue,
                  let at = date(w["resets_at"]) else { return nil }
            return Window(used: used, resets: at)
        }
        return (window("five_hour"), window("seven_day"))
    }

    /// Epoch seconds or an ISO-8601 string.
    private static func date(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        if let s = value as? String {
            let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return plain.date(from: s) ?? fractional.date(from: s)
        }
        return nil
    }
}

// MARK: who is working where

extension Usage {
    static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return s < 5400 ? "\(max(s / 60, 1))m" : "\(s / 3600)h"  // whole minutes: a read that finds nothing new publishes nothing
    }

    /// The branch a folder has checked out, from its HEAD file (a worktree's `.git` file points at its own): two small reads.
    static func branch(_ folder: String) -> String {
        var git = URL(fileURLWithPath: folder).appendingPathComponent(".git")
        if let link = try? String(contentsOf: git, encoding: .utf8), link.hasPrefix("gitdir: ") {
            git = URL(fileURLWithPath: link.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: git.deletingLastPathComponent())
        }
        let head = (try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst(16)) : ""
    }

    /// Live Claude Code sessions: `~/.claude/sessions/<pid>.json` (alive while its process is), and the subagents
    /// each one started (`projects/*/<session>/subagents/`), working while their transcript is still being written.
    static func claudeAgents() -> [Agent] {
        let root = home.appendingPathComponent(".claude")
        let projects = names(root.appendingPathComponent("projects"))
        var found: [Agent] = []
        for file in names(root.appendingPathComponent("sessions")) where file.hasSuffix(".json") {
            guard let s = json(root.appendingPathComponent("sessions/\(file)")), let pid = s["pid"] as? Int,
                  kill(pid_t(pid), 0) == 0, let cwd = s["cwd"] as? String else { continue }
            let sid = s["sessionId"] as? String ?? ""
            var subs: [Agent] = []
            if let project = projects.first(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/\($0)/\(sid)").path) }) {
                let dir = root.appendingPathComponent("projects/\(project)/\(sid)/subagents")
                for sub in names(dir) where sub.hasSuffix(".jsonl") {
                    let when = modified(dir.appendingPathComponent(sub))
                    guard Date().timeIntervalSince(when) < 600 else { continue }
                    let meta = json(dir.appendingPathComponent(sub.replacingOccurrences(of: ".jsonl", with: ".meta.json"))) ?? [:]
                    subs.append(Agent(id: sub, title: meta["description"] as? String ?? "subagent", folder: cwd,
                                      working: Date().timeIntervalSince(when) < 90, note: meta["model"] as? String ?? ""))
                }
            }
            let started = Date(timeIntervalSince1970: (s["startedAt"] as? Double ?? 0) / 1000)
            found.append(Agent(id: file, title: s["name"] as? String ?? (cwd as NSString).lastPathComponent, folder: cwd,
                               working: s["status"] as? String == "busy", note: ago(started), branch: branch(cwd), subs: subs))
        }
        return found.sorted { ($0.working ? 0 : 1, $0.title) < ($1.working ? 0 : 1, $1.title) }
    }

    /// Codex sessions written to in the last two minutes; the folder is in the file's first line.
    static func codexAgents() -> [Agent] {
        let root = home.appendingPathComponent(".codex/sessions")
        var found: [Agent] = []
        var days = 0
        outer: for year in names(root) { for month in names(root.appendingPathComponent(year)) { for day in names(root.appendingPathComponent("\(year)/\(month)")) {
            let dir = root.appendingPathComponent("\(year)/\(month)/\(day)")
            for file in names(dir) where file.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(file)
                let when = modified(url)
                guard Date().timeIntervalSince(when) < 120, let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                guard let line = String(data: handle.readData(ofLength: 16_384), encoding: .utf8)?.split(separator: "\n").first,
                      let meta = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["payload"] as? [String: Any],
                      let cwd = meta["cwd"] as? String else { continue }
                found.append(Agent(id: file, title: (cwd as NSString).lastPathComponent, folder: cwd, working: true,
                                   note: meta["originator"] as? String ?? "", branch: branch(cwd)))
            }
            days += 1
            if days >= 2 { break outer }
        } } }
        return found
    }
}
