import AppKit
import Foundation

enum HealthState: Int, Comparable {
    case ok, info, attention, broken
    static func < (a: HealthState, b: HealthState) -> Bool { a.rawValue < b.rawValue }
}

struct HealthAction: Identifiable {
    let id = UUID()
    let title: String
    let run: () -> Void
}

/// One thing TopLayer depends on: whether it is in place, and what to do if it is not.
struct HealthCheck: Identifiable {
    let id: String
    let group: String
    let title: String
    let state: HealthState
    let detail: String
    var actions: [HealthAction] = []
}

/// Watches everything TopLayer depends on outside itself, and can install or repair it.
///
/// TopLayer leans on things it does not control: hooks registered in Claude's settings, a
/// tool entry in Codex's config, an experimental Codex protocol, and Claude's session
/// files. Any of them can go missing or change shape, so each is checked and shown.
/// Main thread only.
final class HealthMonitor: ObservableObject {
    /// The versions this build was developed and tested against.
    static let testedClaude = "2.1.321"
    static let testedCodex = "0.167.1"

    @Published private(set) var checks: [HealthCheck] = []
    /// The command-line tools and desktop apps, as last looked at. Looking runs a few
    /// commands and a lookup on the network, so it is done when the Setup tab opens,
    /// on "Check Again", and otherwise a few times a day.
    @Published private(set) var tools = ToolVersions()
    private var checkingTools = false
    private var updating: CLITools.Tool?
    /// Whether the link tool started the last time it was tried, and which file that was
    /// (its identity and date), so it is tried again only when the file changes.
    private var linkRuns: Bool?
    private var linkStamp: String?
    private var checkingLink = false
    /// What the last install or removal did, including where the backup went.
    @Published var lastResult: String?

    weak var store: Store?

    var worst: HealthState { checks.map(\.state).max() ?? .ok }
    var problems: Int { checks.filter { $0.state >= .attention }.count }

    var summary: String {
        switch worst {
        case .broken: problems == 1 ? "1 thing is not working" : "\(problems) things need attention"
        case .attention: problems == 1 ? "1 thing needs attention" : "\(problems) things need attention"
        default: "Everything is working"
        }
    }

    /// Looks at the command-line tools again. Without `force`, only if the last look is old.
    func refreshTools(force: Bool = false) {
        if force { linkStamp = nil }
        if checkingTools { return }
        if !force, let checked = tools.checked, Date().timeIntervalSince(checked) < 6 * 3600 { return }
        checkingTools = true
        CLITools.check { [weak self] found in
            guard let self else { return }
            self.checkingTools = false
            self.tools = found
            self.refresh()
        }
    }

    func refresh() {
        guard let store else { return }
        refreshTools()
        checkLink()
        var result = [HealthCheck]()
        result.append(helpersCheck())
        result.append(hooksCheck())
        result.append(noteCheck())
        result.append(sessionsCheck(store))
        result.append(versionCheck(group: "Claude", id: "claude.version", name: "Claude Code",
                                   running: ClaudeBridge.runningVersions(), tested: Self.testedClaude))
        result.append(commandCheck(.claude))
        if let check = usageCheck(.claude, store) { result.append(check) }
        if let app = tools.claudeApp { result.append(appCheck(group: "Claude", id: "claude.app", name: "Claude desktop app", version: app)) }
        result.append(daemonCheck(store))
        if store.codexConnected {
            result.append(protocolCheck(store))
        }
        result.append(toolCheck())
        result.append(commandCheck(.codex))
        if let check = usageCheck(.codex, store) { result.append(check) }
        if let app = tools.codexApp { result.append(appCheck(group: "Codex", id: "codex.app", name: "Codex desktop app", version: app)) }
        checks = result
    }

    // MARK: TopLayer

    private func helpersCheck() -> HealthCheck {
        let install = HealthAction(title: "Install") { [weak self] in
            self?.perform("Helper scripts installed in ~/.toplayer/bin.") { try Helpers.install(); return nil }
        }
        let title = "Helper scripts"
        let status = Helpers.status()
        if linkRuns == false, status == .current || status == .unknown {
            return HealthCheck(id: "helpers", group: "TopLayer", title: title, state: .broken,
                               detail: "toplayer-link is installed, but macOS stops it the moment it starts, so no agent can send a group chat message. Reinstalling replaces the file, which fixes it.",
                               actions: [HealthAction(title: "Reinstall", run: install.run)])
        }
        switch status {
        case .current:
            return HealthCheck(id: "helpers", group: "TopLayer", title: title, state: .ok,
                               detail: "Installed in ~/.toplayer/bin and up to date.")
        case .unknown:
            return HealthCheck(id: "helpers", group: "TopLayer", title: title, state: .info,
                               detail: "Installed. This is a development build, so it can't tell whether they are current.")
        case .missing(let names):
            return HealthCheck(id: "helpers", group: "TopLayer", title: title, state: .broken,
                               detail: "Missing from ~/.toplayer/bin: \(names.joined(separator: ", ")). Hooks and group chats can't work without them.",
                               actions: [install])
        case .outdated(let names):
            return HealthCheck(id: "helpers", group: "TopLayer", title: title, state: .attention,
                               detail: "Older than this version of TopLayer: \(names.joined(separator: ", ")).",
                               actions: [HealthAction(title: "Update", run: install.run)])
        }
    }

    /// Tries the link tool, off the main thread, when its file is new or has changed.
    private func checkLink() {
        let path = SetupPaths.bin + "/toplayer-link"
        guard let found = try? FileManager.default.attributesOfItem(atPath: path) else {
            linkRuns = nil; linkStamp = nil       // missing: the helper check says so
            return
        }
        let stamp = "\(found[.systemFileNumber] ?? 0) \(found[.modificationDate] ?? 0)"
        if stamp == linkStamp || checkingLink { return }
        checkingLink = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let runs = Helpers.linkRuns()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingLink = false
                self.linkStamp = stamp
                let changed = self.linkRuns != runs
                self.linkRuns = runs
                if changed { self.refresh() }
            }
        }
    }

    /// Whether the plan's limits could be read. Nothing is shown before the first try.
    private func usageCheck(_ source: AgentSource, _ store: Store) -> HealthCheck? {
        let id = source == .claude ? "claude.usage" : "codex.usage"
        let how = source == .claude
            ? "Read by running the claude command's own /usage report, with no model call. Anthropic marks that report as experimental."
            : "Read from Codex's background service."
        if let problem = store.usageProblem[source] {
            // Codex being down already has a check of its own.
            if source == .codex && !store.codexConnected { return nil }
            return HealthCheck(id: id, group: source.rawValue, title: "Plan usage", state: .attention,
                               detail: "Could not be read: \(problem) The usage button shows the last reading, if there was one.",
                               actions: [HealthAction(title: "Try Again") { store.refreshUsage(source, force: true) }])
        }
        guard let report = store.usage[source] else { return nil }
        return HealthCheck(id: id, group: source.rawValue, title: "Plan usage", state: .ok,
                           detail: report.limits.isEmpty ? "\(how) No limits were reported for this account." : how)
    }

    // MARK: Claude

    private func hooksCheck() -> HealthCheck {
        let status = ClaudeHooks.status()
        let add = HealthAction(title: status.present.isEmpty && status.outdated.isEmpty ? "Add hooks" : "Repair hooks") { [weak self] in
            self?.perform("Hooks added to Claude's settings.") { try ClaudeHooks.install() }
        }
        let remove = HealthAction(title: "Remove hooks") { [weak self] in
            self?.perform("Hooks removed from Claude's settings.") { try ClaudeHooks.remove() }
        }
        let title = "Hooks in Claude's settings"
        if let problem = status.problem {
            return HealthCheck(id: "claude.hooks", group: "Claude", title: title, state: .broken, detail: problem)
        }
        if status.isComplete {
            return HealthCheck(id: "claude.hooks", group: "Claude", title: title, state: .ok,
                               detail: "All \(status.present.count) hooks are registered in ~/.claude/settings.json. They let you reply, report finished turns, and relay permission prompts.",
                               actions: [remove])
        }
        var parts = [String]()
        if !status.missing.isEmpty { parts.append("Missing: \(status.missing.joined(separator: ", ")).") }
        if !status.outdated.isEmpty { parts.append("Pointing at an old location: \(status.outdated.joined(separator: ", ")).") }
        let nothing = status.present.isEmpty && status.outdated.isEmpty
        return HealthCheck(id: "claude.hooks", group: "Claude", title: title, state: nothing ? .broken : .attention,
                           detail: (nothing ? "Not registered, so Claude sessions can be watched but not replied to. " : "")
                               + parts.joined(separator: " ") + " A backup of the settings file is made first.",
                           actions: nothing ? [add] : [add, remove])
    }

    private func noteCheck() -> HealthCheck {
        let add = HealthAction(title: "Add note") { [weak self] in
            self?.perform("Note added to ~/.claude/CLAUDE.md. Sessions read it when they start.") { try ClaudeNote.install() }
        }
        let remove = HealthAction(title: "Remove note") { [weak self] in
            self?.perform("Note removed from ~/.claude/CLAUDE.md.") { try ClaudeNote.remove() }
        }
        let title = "Note for Claude about TopLayer"
        switch ClaudeNote.status() {
        case .current:
            return HealthCheck(id: "claude.note", group: "Claude", title: title, state: .ok,
                               detail: "In ~/.claude/CLAUDE.md. It tells every session that a reply arriving as hook feedback from TopLayer is yours.",
                               actions: [remove])
        case .outdated:
            return HealthCheck(id: "claude.note", group: "Claude", title: title, state: .attention,
                               detail: "In ~/.claude/CLAUDE.md, but written for another version of TopLayer.",
                               actions: [HealthAction(title: "Update note", run: add.run), remove])
        case .missing:
            return HealthCheck(id: "claude.note", group: "Claude", title: title, state: .info,
                               detail: "Optional. Your replies reach Claude as hook feedback, marked as not typed by you, so a session that has never heard of TopLayer may hesitate to act on them. This adds a short explanation to ~/.claude/CLAUDE.md, which every session reads. A backup is made first.",
                               actions: [add])
        case .unreadable:
            return HealthCheck(id: "claude.note", group: "Claude", title: title, state: .broken,
                               detail: "~/.claude/CLAUDE.md could not be read.")
        }
    }

    private func sessionsCheck(_ store: Store) -> HealthCheck {
        let title = "Running sessions"
        if let problem = ClaudeBridge.registryProblem() {
            return HealthCheck(id: "claude.sessions", group: "Claude", title: title, state: .broken, detail: problem)
        }
        let rows = store.runningClaudeRows
        guard !rows.isEmpty else {
            return HealthCheck(id: "claude.sessions", group: "Claude", title: title, state: .info,
                               detail: "No Claude Code sessions are running right now.")
        }
        let silent = rows.filter { store.hookSilentSessions.contains($0.rawId) }.map(\.title)
        if !silent.isEmpty {
            return HealthCheck(id: "claude.sessions", group: "Claude", title: title, state: .attention,
                               detail: "Finished a turn without the hook reporting it: \(silent.joined(separator: ", ")). The hooks may not be loading in that session; restarting it usually fixes this.")
        }
        let reachable = rows.filter(\.canReply).count
        if reachable == rows.count {
            return HealthCheck(id: "claude.sessions", group: "Claude", title: title, state: .ok,
                               detail: "\(rows.count == 1 ? "The running session" : "All \(rows.count) running sessions") can be reached from TopLayer.")
        }
        return HealthCheck(id: "claude.sessions", group: "Claude", title: title, state: .info,
                           detail: "\(reachable) of \(rows.count) running sessions can be reached. A session becomes reachable the first time it starts or finishes a turn after the hooks were added.")
    }

    private func versionCheck(group: String, id: String, name: String, running: [String], tested: String) -> HealthCheck {
        let title = "\(name) version"
        guard !running.isEmpty else {
            return HealthCheck(id: id, group: group, title: title, state: .info,
                               detail: "Not known yet. TopLayer was tested with \(tested).")
        }
        if running.allSatisfy({ $0 == tested }) {
            return HealthCheck(id: id, group: group, title: title, state: .ok,
                               detail: "\(tested), the version TopLayer was tested with.")
        }
        return HealthCheck(id: id, group: group, title: title, state: .info,
                           detail: "Running \(running.joined(separator: ", ")). TopLayer was tested with \(tested). It relies on parts of \(name) that are not officially stable, so if something stops working after an update, this is the likely cause.")
    }

    // MARK: Codex

    private func daemonCheck(_ store: Store) -> HealthCheck {
        let title = "Codex daemon"
        if store.codexConnected {
            return HealthCheck(id: "codex.daemon", group: "Codex", title: title, state: .ok,
                               detail: "Connected. TopLayer reads threads and sends replies through it.")
        }
        let start = HealthAction(title: "Start the daemon") { [weak self] in self?.startCodexDaemon() }
        // TopLayer starts it by itself; the button is there for when that did not work.
        let trying = store.codexStartAttempts > 0
            ? " TopLayer has tried to start it \(store.codexStartAttempts == 1 ? "once" : "\(store.codexStartAttempts) times") and will keep trying."
            : " TopLayer will start it in a moment."
        return HealthCheck(id: "codex.daemon", group: "Codex", title: title, state: .broken,
                           detail: "Not connected (\(store.codexStatus)). Codex threads can't be read or replied to." + trying,
                           actions: [start])
    }

    private func protocolCheck(_ store: Store) -> HealthCheck {
        if store.codexListFailures >= 2 {
            return HealthCheck(id: "codex.version", group: "Codex", title: "Codex version", state: .broken,
                               detail: "Connected, but the thread list came back in a form TopLayer doesn't understand. Codex has probably changed its protocol (running \(store.codexVersion ?? "an unknown version"), tested with \(Self.testedCodex)).")
        }
        return versionCheck(group: "Codex", id: "codex.version", name: "Codex",
                            running: store.codexVersion.map { [$0] } ?? [], tested: Self.testedCodex)
    }

    private func toolCheck() -> HealthCheck {
        let add = HealthAction(title: "Add to Codex config") { [weak self] in
            self?.perform("Group chat tool added to Codex's config. Threads already open in Codex pick it up when reopened.") { try CodexTool.install() }
        }
        let remove = HealthAction(title: "Remove") { [weak self] in
            self?.perform("Group chat tool removed from Codex's config.") { try CodexTool.remove() }
        }
        let title = "Group chat tool in Codex's config"
        switch CodexTool.status() {
        case .configured:
            return HealthCheck(id: "codex.tool", group: "Codex", title: title, state: .ok,
                               detail: "Registered in ~/.codex/config.toml. Codex threads can send group chat messages without asking you each time.",
                               actions: [remove])
        case .needsApproval:
            return HealthCheck(id: "codex.tool", group: "Codex", title: title, state: .info,
                               detail: "Registered, but Codex will ask you to approve every send.",
                               actions: [HealthAction(title: "Allow without asking", run: add.run), remove])
        case .different(let command):
            return HealthCheck(id: "codex.tool", group: "Codex", title: title, state: .attention,
                               detail: "There is a \"toplayer\" entry pointing somewhere else (\(command.isEmpty ? "no command" : command)).",
                               actions: [HealthAction(title: "Repair", run: add.run), remove])
        case .missing:
            return HealthCheck(id: "codex.tool", group: "Codex", title: title, state: .attention,
                               detail: "Not registered. A Codex thread can receive group chat messages, but can't send one unless its sandbox lets it run the helper directly. A backup of the config file is made first.",
                               actions: [add])
        case .unreadable:
            return HealthCheck(id: "codex.tool", group: "Codex", title: title, state: .broken,
                               detail: "~/.codex/config.toml could not be read.")
        }
    }

    // MARK: The command-line tools and desktop apps

    private func appCheck(group: String, id: String, name: String, version: String) -> HealthCheck {
        HealthCheck(id: id, group: group, title: name, state: .ok,
                    detail: "Version \(version). The app updates itself, so there is nothing to do here.")
    }

    private func commandCheck(_ tool: CLITools.Tool) -> HealthCheck {
        let command = tool.rawValue.lowercased()
        let id = "\(command).command"
        let title = "\(tool.rawValue) command-line tool"
        let installed = tool == .claude ? tools.claude : tools.codex
        let latest = tool == .claude ? tools.claudeLatest : tools.codexLatest
        guard tools.checked != nil else {
            return HealthCheck(id: id, group: tool.rawValue, title: title, state: .info, detail: "Checking…")
        }
        guard let installed else {
            let why = tool == .claude
                ? "Not installed. It is only needed to start Claude sessions in the background; sessions in the desktop app do not use it."
                : "Not installed. TopLayer needs it: it runs the background service all Codex threads go through."
            let install = HealthAction(title: "Copy Install Command") { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CLITools.installCommand(tool), forType: .string)
                self?.lastResult = "Copied. Paste it into a terminal, then press Check Again."
            }
            return HealthCheck(id: id, group: tool.rawValue, title: title, state: tool == .claude ? .info : .broken,
                               detail: why, actions: [install])
        }
        if updating == tool {
            return HealthCheck(id: id, group: tool.rawValue, title: title, state: .info, detail: "Updating from \(installed)…")
        }
        if tool == .claude, tools.claudeSignedIn == false {
            let signIn = HealthAction(title: "Sign In…") { [weak self] in
                TerminalWindow.run("claude auth login", name: "claude-sign-in")
                self?.lastResult = "Sign in in the terminal window that opened, then press Check Again."
            }
            return HealthCheck(id: id, group: tool.rawValue, title: title, state: .info,
                               detail: "Version \(installed), not signed in. The desktop app has its own sign-in and does not share it, so background sessions cannot start until this one is signed in too.",
                               actions: [signIn])
        }
        let signedIn = tool == .claude ? ", signed in" : ""
        guard let latest else {
            return HealthCheck(id: id, group: tool.rawValue, title: title, state: .ok,
                               detail: "Version \(installed)\(signedIn). Could not look up whether a newer one exists.")
        }
        if CLITools.isNewer(latest, than: installed) {
            let update = HealthAction(title: "Update to \(latest)") { [weak self] in self?.update(tool) }
            // Shown, but not counted as a problem: nothing is broken by being a version behind.
            return HealthCheck(id: id, group: tool.rawValue, title: title, state: .info,
                               detail: "Version \(installed)\(signedIn). Version \(latest) is available. Updating runs the tool's own updater.",
                               actions: [update])
        }
        return HealthCheck(id: id, group: tool.rawValue, title: title, state: .ok,
                           detail: "Version \(installed)\(signedIn), the newest there is.")
    }

    private func update(_ tool: CLITools.Tool) {
        guard updating == nil else { return }
        updating = tool
        lastResult = "Updating the \(tool.rawValue) command-line tool…"
        refresh()
        CLITools.update(tool) { [weak self] ok, text in
            guard let self else { return }
            self.updating = nil
            self.lastResult = (ok ? "" : "That didn't work: ") + text
            log("setup: update \(tool.rawValue): \(text)")
            self.refreshTools(force: true)
            self.refresh()
        }
    }

    // MARK: Actions

    /// Runs an install or removal, reports what happened, and re-checks.
    private func perform(_ success: String, _ work: () throws -> String?) {
        do {
            let backup = try work()
            lastResult = success + (backup.map { " Backup: \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "")
        } catch {
            lastResult = "That didn't work: \(error.localizedDescription)"
        }
        log("setup: \(lastResult ?? "")")
        refresh()
    }

    private func startCodexDaemon() {
        CodexDaemon.start { [weak self] _, text in
            self?.lastResult = text
            self?.refresh()
        }
    }
}
