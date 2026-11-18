import AppKit
import Foundation

/// Claude Code sessions that TopLayer starts itself, with the `claude` command.
///
/// A session needs a terminal to live in. TopLayer gives it one that nobody is looking
/// at: a detached `screen` session. The session is then an ordinary interactive Claude
/// Code session: it runs the same hooks as any other, so it shows up in the overlay, can
/// be replied to and can ask permission like the rest. Because `screen` owns it and not
/// TopLayer, it keeps running when TopLayer quits or restarts.
/// A model a new thread can be started with, and the effort levels it takes.
struct ModelChoice: Equatable, Identifiable {
    var id: String
    var name: String
    var efforts: [String]
    /// The effort the model uses when none is chosen, where that is known.
    var defaultEffort: String?
}

/// A thread's model and effort. An empty value means "not chosen".
struct ThreadSettings: Equatable {
    var model = ""
    var effort = ""
}

enum ClaudeCLI {
    /// A session TopLayer started, remembered so it can be attached to, imported or ended.
    struct Started: Codable, Equatable {
        var id: String          // the Claude session id
        var name: String
        var cwd: String
        var screen: String      // the name of the screen session it runs in
        var started: Date
    }

    static let screen = "/usr/bin/screen"

    /// True when TopLayer itself was started from inside a Claude Code session (by an
    /// agent running a command, say). Claude Code marks everything started that way, and
    /// a session TopLayer starts would inherit the mark: Claude would treat it as part of
    /// that other session and not save its conversation. Opening TopLayer yourself, from
    /// the Dock or Spotlight, has no such mark.
    static var startedInsideClaude: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_CODE_CHILD_SESSION"] != nil
    }

    static var binary: String? {
        [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func screenName(for id: String) -> String { "toplayer-" + id.prefix(8) }

    /// A session's name when you don't give one: the start of what you asked.
    static func name(from prompt: String) -> String {
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)[0]
        let words = line.split(separator: " ")
        var name = ""
        for word in words {
            if name.count + word.count + 1 > 40 { break }
            name += (name.isEmpty ? "" : " ") + word
        }
        return name.isEmpty ? String(line.prefix(40)) : name
    }

    /// The models the claude command knows by a short name that always means the newest
    /// of its kind, and the effort levels it accepts.
    static let models: [ModelChoice] = ["fable", "opus", "sonnet", "haiku"].map {
        ModelChoice(id: $0, name: $0.prefix(1).uppercased() + $0.dropFirst(), efforts: efforts, defaultEffort: nil)
    }
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// What `screen` is asked to run. The session goes through your login shell so it
    /// has the same PATH a terminal would give it; the prompt and name are passed as
    /// arguments, never spliced into a command line. With no model or effort, the
    /// session uses what your Claude settings say.
    static func arguments(id: String, name: String, prompt: String, binary: String, shell: String,
                          model: String? = nil, effort: String? = nil) -> [String] {
        // TOPLAYER_DEBUG_CLAUDE_ARGS adds arguments, e.g. a permission mode, for testing.
        var options = (ProcessInfo.processInfo.environment["TOPLAYER_DEBUG_CLAUDE_ARGS"] ?? "").split(separator: " ").map(String.init)
        if let model, !model.isEmpty { options += ["--model", model] }
        if let effort, !effort.isEmpty { options += ["--effort", effort] }
        return ["-dmS", screenName(for: id), shell, "-lic", "exec \"$0\" \"$@\"",
                binary, "--session-id", id, "-n", name] + options + [prompt]
    }

    /// Starts a session in the background. Returns once `screen` has taken it; the
    /// session itself appears in the overlay when Claude Code has started.
    static func start(id: String, name: String, cwd: String, prompt: String,
                      model: String? = nil, effort: String? = nil) throws -> Started {
        guard let binary else { throw SetupError(message: "The claude command is not installed.") }
        guard FileManager.default.isExecutableFile(atPath: screen) else {
            throw SetupError(message: "The screen command is missing, so there is nothing to run the session in.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: screen)
        process.arguments = arguments(id: id, name: name, prompt: prompt, binary: binary,
                                      shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                      model: model, effort: effort)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"          // an app has no terminal type of its own
        process.environment = environment
        try process.run()
        process.waitUntilExit()                         // screen -dm returns at once
        guard process.terminationStatus == 0 else {
            throw SetupError(message: "screen could not start the session (exit \(process.terminationStatus)).")
        }
        return Started(id: id, name: name, cwd: cwd, screen: screenName(for: id), started: Date())
    }

    /// The names of the screen sessions that are alive, read from `screen -ls`.
    static func alive() -> Set<String> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: screen)
        process.arguments = ["-ls"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return names(inScreenList: text)
    }

    /// `screen -ls` prints one line per session, like "\t77205.toplayer-1422b988\t(Detached)".
    static func names(inScreenList text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            guard let entry = line.split(whereSeparator: \.isWhitespace).first,
                  let dot = entry.firstIndex(of: "."), entry[..<dot].allSatisfy(\.isNumber) else { continue }
            names.insert(String(entry[entry.index(after: dot)...]))
        }
        return names
    }

    /// Ends a session by closing the screen it runs in.
    static func end(_ screenName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: screen)
        process.arguments = ["-S", screenName, "-X", "quit"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Opens Terminal on a command, for the things that need a real terminal: signing in,
/// or looking at a background session.
enum TerminalWindow {
    /// Runs one command line in a new Terminal window. It is written to a small script
    /// that Terminal opens, which needs no permission to control other apps.
    @discardableResult
    static func run(_ command: String, name: String) -> Bool {
        let dir = SetupPaths.toplayer + "/run"
        let path = "\(dir)/\(name).command"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "#!/bin/zsh -l\n\(command)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
