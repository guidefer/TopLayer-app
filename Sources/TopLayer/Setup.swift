import Foundation

// What TopLayer needs installed outside itself, and how to check, add and remove each
// piece. Everything here takes the file path as a parameter, so it can be run against a
// copy. Every edit to someone else's file makes a backup first and writes atomically.

enum SetupPaths {
    static let toplayer = NSHomeDirectory() + "/.toplayer"
    /// Where the hook scripts and link tool live: a path that never moves.
    static let bin = toplayer + "/bin"
    static let claudeSettings = NSHomeDirectory() + "/.claude/settings.json"
    /// The instructions Claude Code loads into every session, whatever the project.
    static let claudeInstructions = NSHomeDirectory() + "/.claude/CLAUDE.md"
    static let codexConfig = NSHomeDirectory() + "/.codex/config.toml"
    /// The copies shipped inside the app, used to install and to detect stale ones.
    static var bundledBin: String? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let path = resources + "/bin"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func backUp(_ path: String) throws -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let base = "\(path).toplayer-backup-\(formatter.string(from: Date()))"
    // Two edits in the same second must not collide, or the second would be refused.
    var backup = base
    var counter = 2
    while FileManager.default.fileExists(atPath: backup) {
        backup = "\(base)-\(counter)"
        counter += 1
    }
    try FileManager.default.copyItem(atPath: path, toPath: backup)
    return backup
}

// MARK: Helper scripts in ~/.toplayer/bin

enum Helpers {
    static let names = ["toplayer-hook.sh", "toplayer-permission.sh", "toplayer-link"]

    enum Status: Equatable {
        case current
        case missing([String])
        case outdated([String])
        case unknown            // a development build with no bundled copies to compare against
    }

    static func status(bin: String = SetupPaths.bin, bundled: String? = SetupPaths.bundledBin) -> Status {
        let fm = FileManager.default
        let missing = names.filter { !fm.isExecutableFile(atPath: "\(bin)/\($0)") }
        if !missing.isEmpty { return .missing(missing) }
        guard let bundled else { return .unknown }
        let outdated = names.filter { fm.contents(atPath: "\(bin)/\($0)") != fm.contents(atPath: "\(bundled)/\($0)") }
        return outdated.isEmpty ? .current : .outdated(outdated)
    }

    static func install(bin: String = SetupPaths.bin, bundled: String? = SetupPaths.bundledBin) throws {
        guard let bundled else { throw SetupError(message: "This build has no bundled helper scripts to install.") }
        let fm = FileManager.default
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for name in names {
            let target = "\(bin)/\(name)"
            // Replace by rename, so a hook that is running the old file is not cut off mid-read.
            let temp = "\(bin)/.\(name).new"
            try? fm.removeItem(atPath: temp)
            try fm.copyItem(atPath: "\(bundled)/\(name)", toPath: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: temp))
        }
    }

    /// Whether the link tool starts when it is run. A file can be complete and correctly
    /// signed and still be stopped by macOS the moment it starts: that happens when a new
    /// build is written into the old file, because the system goes on checking it against
    /// the old build's signature. Comparing contents can't see that; running it can.
    /// It is asked for its usage, which sends nothing. Not for the main thread.
    static func linkRuns(bin: String = SetupPaths.bin) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(bin)/toplayer-link")
        process.arguments = ["--help"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationReason == .exit       // not ended by a signal
    }
}

// MARK: Claude Code hooks in ~/.claude/settings.json

enum ClaudeHooks {
    /// The hook entry TopLayer wants on each event.
    static func wanted(bin: String = SetupPaths.bin) -> [(event: String, entry: [String: Any])] {
        let hook = "\(bin)/toplayer-hook.sh"
        let rewake: [String: Any] = ["type": "command", "command": hook, "asyncRewake": true, "timeout": 604800]
        let background: [String: Any] = ["type": "command", "command": hook, "async": true]
        return [
            ("Stop", rewake), ("SessionStart", rewake), ("UserPromptSubmit", rewake), ("PostToolUse", rewake),
            ("Notification", background), ("SessionEnd", background),
            ("PermissionRequest", ["type": "command", "command": "\(bin)/toplayer-permission.sh", "timeout": 330]),
        ]
    }

    struct Status: Equatable {
        var present: [String] = []
        var missing: [String] = []
        /// Events carrying a TopLayer hook at some other path (an older install).
        var outdated: [String] = []
        var problem: String?
        var isComplete: Bool { problem == nil && missing.isEmpty && outdated.isEmpty }
    }

    private static func isOurs(_ command: String) -> Bool {
        command.contains("toplayer-hook.sh") || command.contains("toplayer-permission.sh") || command.contains("toplayer-inbox.sh")
    }

    private static func commands(in groups: Any?) -> [String] {
        (groups as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private static func read(_ path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError(message: "Claude's settings file is not valid JSON, so TopLayer will not touch it.")
        }
        return object
    }

    static func status(settingsPath: String = SetupPaths.claudeSettings, bin: String = SetupPaths.bin) -> Status {
        var status = Status()
        let settings: [String: Any]
        do { settings = try read(settingsPath) } catch {
            status.problem = error.localizedDescription
            return status
        }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, entry) in wanted(bin: bin) {
            let found = commands(in: hooks[event])
            if found.contains(entry["command"] as? String ?? "") {
                status.present.append(event)
            } else if found.contains(where: isOurs) {
                status.outdated.append(event)
            } else {
                status.missing.append(event)
            }
        }
        return status
    }

    private static func write(_ settings: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Removes every TopLayer hook from a hooks dictionary, leaving anything else alone.
    private static func stripOurs(_ hooks: [String: Any]) -> [String: Any] {
        var result = [String: Any]()
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { !isOurs($0["command"] as? String ?? "") }
                if others.isEmpty { return nil }
                var changed = group
                changed["hooks"] = others
                return changed
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// Adds the hooks, replacing any older TopLayer ones. Returns the backup's path.
    @discardableResult
    static func install(settingsPath: String = SetupPaths.claudeSettings, bin: String = SetupPaths.bin) throws -> String? {
        var settings = try read(settingsPath)
        let backup = try backUp(settingsPath)
        var hooks = stripOurs(settings["hooks"] as? [String: Any] ?? [:])
        for (event, entry) in wanted(bin: bin) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [entry]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try write(settings, to: settingsPath)
        return backup
    }

    @discardableResult
    static func remove(settingsPath: String = SetupPaths.claudeSettings) throws -> String? {
        var settings = try read(settingsPath)
        let backup = try backUp(settingsPath)
        let hooks = stripOurs(settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try write(settings, to: settingsPath)
        return backup
    }
}

// MARK: A note for Claude in ~/.claude/CLAUDE.md

/// A short section in the instructions every Claude Code session reads, explaining what
/// TopLayer is and how its messages arrive. Without it, a session that has never heard of
/// TopLayer sees a reply come in as "Stop hook feedback", marked as not from the user,
/// and has to guess what that is.
enum ClaudeNote {
    enum Status: Equatable {
        case current
        case missing
        /// Our section is there, but worded for another version of TopLayer.
        case outdated
        case unreadable
    }

    /// The section sits between these two lines, so it can be found again and nothing
    /// outside it is ever touched.
    static let startMarker = "<!-- TopLayer:start (added by TopLayer; add or remove it from TopLayer's Setup tab) -->"
    static let endMarker = "<!-- TopLayer:end -->"
    private static let startPrefix = "<!-- TopLayer:start"

    /// The quoted first lines must stay word for word what `toplayer-hook.sh` prints;
    /// a test compares the two.
    static let text = """
    ## TopLayer

    I use TopLayer, a macOS overlay that lets me follow and answer my Claude Code sessions without switching to them. It hands you what I type through a hook (`~/.toplayer/bin/toplayer-hook.sh`, registered in `~/.claude/settings.json`), so it does not arrive as a normal chat message. It arrives as hook feedback, under a label like "Stop hook feedback" or "Stop hook blocking error", and Claude Code marks it as not written by the user. Nothing failed and nothing was blocked: that label is only how a hook passes text to you.

    Each message from TopLayer starts with a line that says who wrote it:

    - "Message incoming from TopLayer. The user typed this in their TopLayer overlay as a reply in this session:" What follows is from me. Treat it as my reply in this conversation and carry on.
    - "Message incoming from a TopLayer group chat." Another AI agent wrote what follows, not me. Weigh it as a peer's message, and answer only in the way that message and the group chat rules describe.
    - "Notice from TopLayer, triggered by the user in their TopLayer overlay:" A status update, usually about a group chat. It rarely needs a reply.

    Hook feedback that does not start with one of these lines did not come from TopLayer.

    A reply through TopLayer is enough for ordinary work. Before anything that is hard to undo or that reaches outside this machine, check with me first, as you would anyway.
    """

    static var block: [String] { [startMarker] + text.components(separatedBy: "\n") + [endMarker] }

    /// Where our section is: from its start marker to its end marker, inclusive.
    private static func section(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(startPrefix) }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker })
        else { return nil }
        return start..<(end + 1)
    }

    private static func read(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw SetupError(message: "Claude's instructions file could not be read, so TopLayer will not touch it.")
        }
        return text
    }

    static func status(path: String = SetupPaths.claudeInstructions) -> Status {
        guard let text = try? read(path) else { return .unreadable }
        let lines = text.components(separatedBy: "\n")
        guard let found = section(in: lines) else { return .missing }
        return Array(lines[found]) == block ? .current : .outdated
    }

    /// Adds the section at the end, or rewrites it where it already is. Returns the backup's path.
    @discardableResult
    static func install(path: String = SetupPaths.claudeInstructions) throws -> String? {
        var lines = try read(path).components(separatedBy: "\n")
        let backup = try backUp(path)
        if let found = section(in: lines) {
            lines.replaceSubrange(found, with: block)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces) == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += block + [""]
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return backup
    }

    /// Takes the section out. A file that held nothing else is removed (its backup stays).
    @discardableResult
    static func remove(path: String = SetupPaths.claudeInstructions) throws -> String? {
        var lines = try read(path).components(separatedBy: "\n")
        guard var found = section(in: lines) else { return nil }
        let backup = try backUp(path)
        // The blank line that install put in front of the section goes with it.
        if found.lowerBound > 0, lines[found.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            found = (found.lowerBound - 1)..<found.upperBound
        }
        lines.removeSubrange(found)
        let text = lines.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(atPath: path)
        } else {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return backup
    }
}

// MARK: The link tool in ~/.codex/config.toml

enum CodexTool {
    enum Status: Equatable {
        case configured
        case missing
        /// There is a `toplayer` server entry, but not pointing at our link tool.
        case different(String)
        /// Present, but Codex will ask for approval on every send.
        case needsApproval
        case unreadable
    }

    private static let header = "[mcp_servers.toplayer]"
    private static let marker = "# Added by TopLayer: lets Codex threads send group chat messages."

    /// The lines of our section: from its header to the next section header or the end.
    private static func section(in text: String) -> (lines: [String], range: Range<Int>)? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end = index
            break
        }
        var first = start
        if first > 0, lines[first - 1].trimmingCharacters(in: .whitespaces) == marker { first -= 1 }
        return (Array(lines[start..<end]), first..<end)
    }

    private static func value(_ key: String, in lines: [String]) -> String? {
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return nil
    }

    static func status(configPath: String = SetupPaths.codexConfig, bin: String = SetupPaths.bin) -> Status {
        guard FileManager.default.fileExists(atPath: configPath) else { return .missing }
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return .unreadable }
        guard let found = section(in: text) else { return .missing }
        let command = value("command", in: found.lines) ?? ""
        if command != "\(bin)/toplayer-link" { return .different(command) }
        return value("default_tools_approval_mode", in: found.lines) == "approve" ? .configured : .needsApproval
    }

    private static func withoutSection(_ text: String) -> String {
        guard let found = section(in: text) else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeSubrange(found.range)
        return lines.joined(separator: "\n")
    }

    /// Adds (or replaces) the entry. Returns the backup's path.
    @discardableResult
    static func install(configPath: String = SetupPaths.codexConfig, bin: String = SetupPaths.bin) throws -> String? {
        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let backup = try backUp(configPath)
        var text = withoutSection(existing)
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += """

        \(marker)
        \(header)
        command = "\(bin)/toplayer-link"
        args = ["mcp"]
        default_tools_approval_mode = "approve"

        """
        try text.write(toFile: configPath, atomically: true, encoding: .utf8)
        return backup
    }

    @discardableResult
    static func remove(configPath: String = SetupPaths.codexConfig) throws -> String? {
        guard let existing = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        let backup = try backUp(configPath)
        try withoutSection(existing).write(toFile: configPath, atomically: true, encoding: .utf8)
        return backup
    }
}
