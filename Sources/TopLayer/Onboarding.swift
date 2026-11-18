import Foundation

/// The files setup reads and edits. The defaults are the real ones; the tests and the
/// debug switch point every one of them at a copy.
struct SetupTargets: Equatable {
    var bin = SetupPaths.bin
    var bundled = SetupPaths.bundledBin
    var claudeSettings = SetupPaths.claudeSettings
    var claudeInstructions = SetupPaths.claudeInstructions
    var codexConfig = SetupPaths.codexConfig

    /// Everything inside one folder, for trying setup without going near the real files.
    static func scratch(_ dir: String) -> SetupTargets {
        SetupTargets(bin: dir + "/bin", bundled: dir + "/bundled", claudeSettings: dir + "/settings.json",
                     claudeInstructions: dir + "/CLAUDE.md", codexConfig: dir + "/config.toml")
    }
}

/// Which of the two tools are on this Mac. Looking runs nothing: it only checks that
/// files exist, so it can be done at launch.
struct FoundTools: Equatable {
    var claudeCommand = false
    var claudeApp = false
    /// `~/.claude` exists: Claude Code has run here at some point.
    var claudeFolder = false
    var codexCommand = false
    var codexApp = false

    /// Claude sessions can be followed whichever way Claude Code is installed.
    var claude: Bool { claudeCommand || claudeApp || claudeFolder }
    /// Codex threads all go through the command's background service, so only the
    /// command counts.
    var codex: Bool { codexCommand }

    static func look() -> FoundTools {
        let fm = FileManager.default
        return FoundTools(claudeCommand: ClaudeCLI.binary != nil,
                          claudeApp: fm.fileExists(atPath: "/Applications/Claude.app"),
                          claudeFolder: fm.fileExists(atPath: NSHomeDirectory() + "/.claude"),
                          codexCommand: CodexDaemon.binary != nil,
                          codexApp: fm.fileExists(atPath: "/Applications/ChatGPT.app"))
    }
}

/// One thing the welcome guide can put in place.
enum SetupPiece: String, CaseIterable, Identifiable {
    case helpers, claudeHooks, claudeNote, codexTool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helpers: "Helper scripts"
        case .claudeHooks: "Hooks in Claude's settings"
        case .claudeNote: "Note for Claude about TopLayer"
        case .codexTool: "Group chat tool in Codex's config"
        }
    }

    /// The note is the one piece TopLayer works without.
    var optional: Bool { self == .claudeNote }

    /// What adding it changes, and where.
    func detail(_ targets: SetupTargets) -> String {
        func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
        switch self {
        case .helpers:
            return "Copies two hook scripts and the toplayer-link tool to \(short(targets.bin)), where Claude and Codex call them."
        case .claudeHooks:
            return "Adds \(ClaudeHooks.wanted().count) hooks to \(short(targets.claudeSettings)). They let you reply to a session, report finished turns and relay permission prompts. Hooks you already have are left alone."
        case .claudeNote:
            return "Adds a short section to \(short(targets.claudeInstructions)) that tells every session a reply from TopLayer is yours. Without it, a session may hesitate to act on your replies."
        case .codexTool:
            return "Adds a \"toplayer\" entry to \(short(targets.codexConfig)), so a Codex thread can send group chat messages."
        }
    }
}

/// A piece that applies to this Mac, and whether it is already there.
struct SetupStep: Identifiable, Equatable {
    let piece: SetupPiece
    var inPlace: Bool
    var id: String { piece.rawValue }
}

/// What the welcome guide decides and does. The window is in `UI/OnboardingView.swift`.
enum Onboarding {
    /// Saved once the guide was finished, or was never needed.
    static let doneKey = "onboarding.done"

    enum Outcome: Equatable {
        /// Added. `backup` is the copy made of the file that was edited, if it existed.
        case done(backup: String?)
        case failed(String)
        /// Not tried, because the helper scripts it points at could not be installed.
        case skipped
    }

    /// The pieces that apply here: the helper scripts always, and the rest for the
    /// tools that were found.
    static func steps(found: FoundTools, targets: SetupTargets) -> [SetupStep] {
        var pieces: [SetupPiece] = [.helpers]
        if found.claude { pieces += [.claudeHooks, .claudeNote] }
        if found.codex { pieces.append(.codexTool) }
        return pieces.map { SetupStep(piece: $0, inPlace: inPlace($0, targets)) }
    }

    static func inPlace(_ piece: SetupPiece, _ targets: SetupTargets) -> Bool {
        switch piece {
        case .helpers:
            let status = Helpers.status(bin: targets.bin, bundled: targets.bundled)
            return status == .current || status == .unknown
        case .claudeHooks:
            return ClaudeHooks.status(settingsPath: targets.claudeSettings, bin: targets.bin).isComplete
        case .claudeNote:
            return ClaudeNote.status(path: targets.claudeInstructions) == .current
        case .codexTool:
            return CodexTool.status(configPath: targets.codexConfig, bin: targets.bin) == .configured
        }
    }

    /// Whether to show the guide at launch: it was never finished, and something
    /// TopLayer needs is missing. A missing note alone is not a reason.
    static func isNeeded(found: FoundTools, targets: SetupTargets, done: Bool) -> Bool {
        !done && steps(found: found, targets: targets).contains { !$0.inPlace && !$0.piece.optional }
    }

    /// Adds the pieces, helper scripts first. The hooks and the Codex entry point at
    /// those scripts, so if the scripts can't be installed the rest is left alone:
    /// a hook pointing at a missing file would fail in every Claude session.
    static func run(_ pieces: [SetupPiece], targets: SetupTargets) -> [SetupPiece: Outcome] {
        var outcomes = [SetupPiece: Outcome]()
        var helpersReady = inPlace(.helpers, targets)
        for piece in SetupPiece.allCases where pieces.contains(piece) {
            if piece != .helpers && !helpersReady {
                outcomes[piece] = .skipped
                continue
            }
            do {
                outcomes[piece] = .done(backup: try install(piece, targets))
                if piece == .helpers { helpersReady = true }
            } catch {
                outcomes[piece] = .failed(error.localizedDescription)
            }
        }
        return outcomes
    }

    private static func install(_ piece: SetupPiece, _ targets: SetupTargets) throws -> String? {
        switch piece {
        case .helpers:
            try Helpers.install(bin: targets.bin, bundled: targets.bundled)
            return nil
        case .claudeHooks:
            return try ClaudeHooks.install(settingsPath: targets.claudeSettings, bin: targets.bin)
        case .claudeNote:
            return try ClaudeNote.install(path: targets.claudeInstructions)
        case .codexTool:
            return try CodexTool.install(configPath: targets.codexConfig, bin: targets.bin)
        }
    }
}
