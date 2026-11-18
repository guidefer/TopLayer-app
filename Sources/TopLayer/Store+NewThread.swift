import AppKit
import Foundation

/// Where a new Claude session is created.
enum ClaudeTarget: String, CaseIterable {
    case cli            // in the background, with the claude command
    case desktop        // handed to the Claude desktop app
}

// Starting new threads from the overlay.
//
//   Codex            created through its background service; nothing else is involved.
//   Claude, CLI      started with the `claude` command in a detached terminal (see `ClaudeCLI`).
//   Claude, Desktop  handed to the desktop app through its own link, which opens its
//                    new-session screen with the folder and message filled in.
extension Store {
    /// Shows the new-thread form for an environment in the conversation pane.
    func showNewThread(_ source: AgentSource) {
        if source == .codex { loadCodexModels() }
        animate { selectedId = "new:\(source.rawValue)" }
        messages = []
        streaming = ""
        notice = nil
        newThreadNote = nil
    }

    var newThreadSource: AgentSource? {
        selectedId == "new:Claude" ? .claude : selectedId == "new:Codex" ? .codex : nil
    }

    /// Folders worth offering: the one used last, then the folders of the threads on
    /// the list, without repeats and only those that still exist.
    func knownFolders(for source: AgentSource) -> [String] {
        let mine = source == .codex ? codexRows : claudeRows
        let others = source == .codex ? claudeRows : codexRows
        var seen = Set<String>()
        return ([lastFolder[source.rawValue]].compactMap { $0 } + (mine + others).map(\.cwd)).filter { folder in
            var isDirectory: ObjCBool = false
            return !folder.isEmpty && seen.insert(folder).inserted
                && FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func remember(_ folder: String, for source: AgentSource) {
        lastFolder[source.rawValue] = folder
        UserDefaults.standard.set(lastFolder, forKey: "lastFolder")
    }

    // MARK: Models

    /// The models a new thread can use. Claude's are the short names its command
    /// accepts; Codex's come from Codex itself, with the effort levels each one takes.
    func models(for source: AgentSource) -> [ModelChoice] {
        source == .claude ? ClaudeCLI.models : codexModels
    }

    /// Asks Codex which models it offers. Asked each time the form opens, so a model
    /// added by an update shows up.
    func loadCodexModels() {
        guard codexConnected else { return }
        codex.request("model/list", [:]) { [weak self] result, _ in
            guard let self, let data = result?["data"] as? [[String: Any]] else { return }
            let models = data.compactMap { model -> ModelChoice? in
                guard let id = model["id"] as? String else { return nil }
                let efforts = (model["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                return ModelChoice(id: id, name: model["displayName"] as? String ?? id, efforts: efforts,
                                   defaultEffort: model["defaultReasoningEffort"] as? String)
            }
            if models != self.codexModels { self.codexModels = models }
        }
    }

    /// What an open Codex thread runs with: what you chose here for its next turn, over
    /// what it last ran with.
    func codexOptions(_ threadId: String) -> ThreadSettings {
        var current = codexSettings[threadId] ?? ThreadSettings()
        if let pending = codexPending[threadId] {
            if !pending.model.isEmpty { current.model = pending.model }
            if !pending.effort.isEmpty { current.effort = pending.effort }
        }
        return current
    }

    /// Changes the model or effort of a Codex thread. It goes out with the next message
    /// you send there, and Codex keeps it for the turns after.
    func setCodexOption(_ threadId: String, model: String? = nil, effort: String? = nil) {
        var pending = codexPending[threadId] ?? ThreadSettings()
        if let model { pending.model = model }
        if let effort { pending.effort = effort }
        codexPending[threadId] = pending
    }

    /// What was chosen last time, so the form opens the way you left it. An empty
    /// string means "whatever my settings say".
    func lastChoice(_ what: String, for source: AgentSource) -> String {
        UserDefaults.standard.string(forKey: "newThread.\(what).\(source.rawValue)") ?? ""
    }

    func rememberChoice(_ what: String, _ value: String, for source: AgentSource) {
        UserDefaults.standard.set(value, forKey: "newThread.\(what).\(source.rawValue)")
    }

    // MARK: Codex

    /// Creates a Codex thread in a folder and sends its first message. The thread uses
    /// the model, sandbox and approval settings from your Codex configuration.
    func createCodexThread(folder: String, prompt: String, model: String = "", effort: String = "") {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !creating else { return }
        guard codexConnected else { return newThreadNote = "Codex is not connected yet. Try again in a moment." }
        creating = true
        newThreadNote = nil
        var start: [String: Any] = ["cwd": folder]
        if !model.isEmpty { start["model"] = model }
        codex.request("thread/start", start) { [weak self] result, error in
            guard let self else { return }
            self.creating = false
            guard let thread = result?["thread"] as? [String: Any], let id = thread["id"] as? String else {
                self.newThreadNote = "Codex could not create the thread: \(error ?? "no thread came back")."
                return
            }
            log("codex: created thread \(id.prefix(13)) in \((folder as NSString).lastPathComponent)")
            self.remember(folder, for: .codex)
            if let path = thread["path"] as? String { self.codexPaths[id] = path }
            self.resumedThreads.insert(id)              // starting a thread subscribes us to it
            let row = SessionRow(id: "codex:\(id)", source: .codex, rawId: id, title: ClaudeCLI.name(from: text),
                                 cwd: folder, status: "idle", updatedAt: Date().timeIntervalSince1970)
            // Kept on the list from the start; it becomes an ordinary recent thread as
            // soon as Codex lists it.
            self.codexShelf.visit(KeptThread(id: id, title: row.title, cwd: folder, path: self.codexPaths[id], pinned: false))
            self.animate { self.composeCodexRows() }
            self.drafts["new:Codex"] = ""
            self.select(row)
            // The effort is given with the first turn and holds for the turns after it.
            if !effort.isEmpty { self.codexPending[id] = ThreadSettings(model: "", effort: effort) }
            self.send(text)
        }
    }

    // MARK: Claude

    func createClaudeSession(folder: String, prompt: String, target: ClaudeTarget, model: String = "", effort: String = "") {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !creating else { return }
        newThreadNote = nil
        switch target {
        case .desktop:
            guard let url = Self.claudeDesktopLink(folder: folder, prompt: text), NSWorkspace.shared.open(url) else {
                return newThreadNote = "The Claude app did not open. Is it installed?"
            }
            remember(folder, for: .claude)
            drafts["new:Claude"] = ""
            newThreadNote = "Handed to the Claude app. Confirm it there; the session appears here once it starts."
        case .cli:
            let id = UUID().uuidString.lowercased()
            do {
                let started = try ClaudeCLI.start(id: id, name: ClaudeCLI.name(from: text), cwd: folder, prompt: text,
                                                  model: model, effort: effort)
                log("claude: started CLI session \(id.prefix(8)) in \((folder as NSString).lastPathComponent)")
                cliSessions.append(started)
                cliStatus[id] = "busy"                  // it starts by answering the first message
                remember(folder, for: .claude)
                drafts["new:Claude"] = ""
                creating = true
                pendingCLI = (id, Date())
            } catch {
                newThreadNote = error.localizedDescription
            }
        }
    }

    /// The desktop app's own link for a new Claude Code session, with the folder and
    /// first message filled in. The app shows its new-session screen and waits for you.
    static func claudeDesktopLink(folder: String, prompt: String) -> URL? {
        var link = URLComponents()
        link.scheme = "claude"
        link.host = "code"
        link.path = "/new"
        link.queryItems = [URLQueryItem(name: "q", value: prompt), URLQueryItem(name: "folder", value: folder)]
        return link.url
    }

    /// The desktop app's link for taking over a session that was started with the claude command.
    static func claudeImportLink(sessionId: String) -> URL? {
        var link = URLComponents()
        link.scheme = "claude"
        link.host = "resume"
        link.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return link.url
    }

    /// Called as the session list refreshes: opens the session that was just started
    /// once it shows up, and says so if it does not.
    func watchPendingCLI() {
        guard let pending = pendingCLI else { return }
        if let row = claudeRows.first(where: { $0.rawId == pending.id }) {
            pendingCLI = nil
            creating = false
            select(row)
        } else if Date().timeIntervalSince(pending.since) > 30 {
            pendingCLI = nil
            creating = false
            newThreadNote = "The session was started but has not appeared. It may be waiting for an answer in its terminal."
            stuckCLI = pending.id
        }
    }

    // MARK: Sessions TopLayer started

    func cliSession(for row: SessionRow) -> ClaudeCLI.Started? {
        row.source == .claude ? cliSessions.first { $0.id == row.rawId } : nil
    }

    /// Shows the session's own terminal, to see or answer what the overlay cannot show.
    func openInTerminal(sessionId: String) {
        guard let session = cliSessions.first(where: { $0.id == sessionId }) else { return }
        TerminalWindow.run("screen -r \(session.screen)", name: "attach-\(session.screen)")
    }

    func endCLISession(_ row: SessionRow) {
        guard let session = cliSession(for: row) else { return }
        if selectedId == row.id { deselect() }
        ClaudeCLI.end(session.screen)
        cliSessions.removeAll { $0.id == session.id }
        refreshClaude()
    }

    /// Moves a session to the Claude desktop app: the background copy is ended first, so
    /// the session is never running in two places, and the app is asked to take it over.
    func importToDesktop(_ row: SessionRow) {
        guard let session = cliSession(for: row), let url = Self.claudeImportLink(sessionId: session.id) else { return }
        ClaudeCLI.end(session.screen)
        cliSessions.removeAll { $0.id == session.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSWorkspace.shared.open(url) }
    }

    /// Finds out which background sessions are still alive, and forgets the ones whose
    /// terminal is gone.
    func checkCLISessions() {
        guard !cliSessions.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let alive = ClaudeCLI.alive()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.aliveScreens = alive
                let kept = self.cliSessions.filter { self.isAlive($0) }
                if kept != self.cliSessions {
                    self.cliSessions = kept
                    self.cliStatus = self.cliStatus.filter { id, _ in kept.contains { $0.id == id } }
                }
            }
        }
    }

    /// A session that has only just been started counts as alive until the first check.
    func isAlive(_ session: ClaudeCLI.Started) -> Bool {
        aliveScreens.contains(session.screen) || Date().timeIntervalSince(session.started) < 20
    }

    /// Rows for the background sessions that Claude's own list of running sessions does
    /// not have. Their state comes from what TopLayer knows: the hook says when a turn
    /// ends, and TopLayer knows when it handed one a message.
    func backgroundRows(notIn listed: Set<String>) -> [SessionRow] {
        cliSessions.filter { !listed.contains($0.id) && isAlive($0) }.map { session in
            var row = SessionRow(id: "claude:\(session.id)", source: .claude, rawId: session.id, title: session.name,
                                 cwd: session.cwd, status: cliStatus[session.id] ?? "busy",
                                 updatedAt: session.started.timeIntervalSince1970)
            row.cli = true
            row.canReply = ClaudeBridge.isHooked(session.id)
            return row
        }
    }
}
