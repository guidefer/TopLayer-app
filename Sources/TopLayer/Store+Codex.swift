import Foundation

/// Codex, through its local app-server daemon.
///
/// Threads the Codex app is running live in the app's own server process, so the daemon
/// reports them as "notLoaded" and sends no events for them. For those, activity is
/// inferred from the thread's rollout file, and replies go through the thread queue.
extension Store {
    /// Starts Codex's background service when the connection has been down long enough
    /// that a plain reconnect is clearly not going to fix it. See `CodexDaemon`.
    func startCodexDaemonIfDown() {
        guard !codexConnected, let down = codexDownSince, CodexDaemon.binary != nil else { return }
        let since = codexLastStartAttempt ?? down
        guard Date().timeIntervalSince(since) >= CodexDaemon.wait(beforeAttempt: codexStartAttempts + 1) else { return }
        codexStartAttempts += 1
        codexLastStartAttempt = Date()
        log("codex: not connected, starting its background service (attempt \(codexStartAttempts))")
        CodexDaemon.start { ok, text in
            if !ok { log("codex: \(text)") }
        }
    }

    func refreshCodex() {
        guard codexConnected else { return }
        codex.request("thread/list", ["limit": 12, "sortKey": "updated_at", "useStateDbOnly": true]) { [weak self] result, _ in
            guard let self else { return }
            guard let data = result?["data"] as? [[String: Any]] else {
                self.codexListFailures += 1
                return
            }
            self.codexListFailures = 0
            self.codexRecent = self.codexRows(from: data)
            self.codexShelf.absorb(recent: self.codexRecent, paths: self.codexPaths)
            self.composeCodexRows()
            // The list has loaded, so saved marks still unclaimed are for threads no longer on it.
            self.restoredUnread = self.restoredUnread.filter { !$0.hasPrefix("codex:") }
            self.restoreSelectionIfNeeded()
        }
    }

    /// Rows for threads as the daemon lists them, remembering each one's rollout file and status.
    func codexRows(from data: [[String: Any]]) -> [SessionRow] {
        var rows = [SessionRow]()
        for t in data {
            guard let id = t["id"] as? String else { continue }
            let updated = (t["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            let name = (t["name"] as? String) ?? (t["preview"] as? String) ?? "Untitled"
            if let path = t["path"] as? String { codexPaths[id] = path }
            codexDaemonStatus[id] = (t["status"] as? [String: Any])?["type"] as? String ?? "notLoaded"
            codexSettings[id] = ThreadSettings(model: t["model"] as? String ?? "", effort: t["reasoningEffort"] as? String ?? "")
            rows.append(SessionRow(id: "codex:\(id)", source: .codex, rawId: id,
                                   title: String(name.prefix(60)), cwd: t["cwd"] as? String ?? "",
                                   status: codexDisplayStatus(id), updatedAt: updated))
        }
        return rows
    }

    /// Rebuilds the list from the recent threads and the kept ones, carrying over what
    /// is unread.
    func composeCodexRows() {
        let unreadIds = Set(codexRows.filter(\.unread).map(\.id))
        var rows = codexShelf.rows(recent: codexRecent) { thread in
            // A kept thread the daemon did not list: followed through its rollout file.
            if let path = thread.path, self.codexPaths[thread.id] == nil { self.codexPaths[thread.id] = path }
            return SessionRow(id: "codex:\(thread.id)", source: .codex, rawId: thread.id, title: thread.title,
                              cwd: thread.cwd, status: self.codexDisplayStatus(thread.id), updatedAt: 0)
        }
        for index in rows.indices {
            rows[index].unread = unreadIds.contains(rows[index].id) || restoredUnread.remove(rows[index].id) != nil
        }
        if rows != codexRows { codexRows = rows }       // don't redraw for an identical list
    }

    /// Collects every thread for the search. Listing everything from Codex's index is
    /// quick: a few hundred threads take a fraction of a second.
    func loadCodexIndex(run: Int, cursor: String?, pages: Int, collected: [SessionRow]) {
        var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "useStateDbOnly": true]
        if let cursor { params["cursor"] = cursor }
        codex.request("thread/list", params) { [weak self] result, _ in
            guard let self, self.searchRun[.codex] == run else { return }      // the search was closed meanwhile
            let rows = collected + self.codexRows(from: result?["data"] as? [[String: Any]] ?? [])
            // 30 pages is 3,000 threads; past that the oldest are left out.
            if let next = result?["nextCursor"] as? String, pages < 29 {
                return self.loadCodexIndex(run: run, cursor: next, pages: pages + 1, collected: rows)
            }
            self.finishIndex(.codex, run: run, rows: rows)
        }
    }

    /// The daemon's status when it owns the thread, otherwise what the rollout file implies.
    func codexDisplayStatus(_ threadId: String) -> String {
        let daemon = codexDaemonStatus[threadId] ?? "notLoaded"
        if daemon != "notLoaded" { return daemon }
        return codexWorking.contains(threadId) ? "working" : "idle"
    }

    func applyCodexStatus(_ threadId: String) {
        if let i = codexRows.firstIndex(where: { $0.rawId == threadId }) {
            codexRows[i].status = codexDisplayStatus(threadId)
        }
    }

    /// Follows threads that another client (the Codex app, the CLI) is driving, by
    /// watching their rollout files: reloads the selected thread when it changes and
    /// raises an event when a thread that was being written to finishes its turn.
    func watchCodexRollouts() {
        guard codexConnected else { return }
        let now = Date()
        for row in codexRows {
            let id = row.rawId
            guard !ownTurnThreads.contains(id),     // our own turns stream over the socket
                  let path = codexPaths[id],
                  let modified = ClaudeBridge.modificationDate(path) else { continue }
            if row.id == selectedId, modified != codexLoadedStamp, !codexLoadInFlight {
                loadCodexThread(id)
            }
            let quiet = now.timeIntervalSince(modified)
            if quiet < 4 {
                if codexWorking.insert(id).inserted { applyCodexStatus(id) }
            } else if codexWorking.contains(id), !codexChecking.contains(id) {
                // Writes paused: either the turn ended or the agent is mid-step. Ask.
                codexChecking.insert(id)
                codex.request("thread/turns/list", ["threadId": id, "limit": 1, "itemsView": "summary"]) { [weak self] result, _ in
                    guard let self else { return }
                    self.codexChecking.remove(id)
                    let status = (result?["data"] as? [[String: Any]])?.first?["status"] as? String ?? ""
                    let finished = status == "completed" || status == "failed"
                    guard finished || quiet > 90 else { return }
                    self.codexWorking.remove(id)
                    self.applyCodexStatus(id)
                    if finished {
                        self.addEvent("Codex · \(row.title): turn \(status)", rowId: row.id)
                        self.captureCodexReply(id)
                    }
                }
            }
        }
    }

    /// Loads only the newest turns. Full-history reads are not an option: a long-lived
    /// thread's rollout can be gigabytes.
    func loadCodexThread(_ threadId: String) {
        codexLoadInFlight = true
        let stamp = codexPaths[threadId].flatMap { ClaudeBridge.modificationDate($0) }
        codex.request("thread/turns/list", ["threadId": threadId, "limit": 6, "itemsView": "full"]) { [weak self] result, error in
            guard let self else { return }
            self.codexLoadInFlight = false
            guard self.selectedId == "codex:\(threadId)" else { return }
            self.codexLoadedStamp = stamp
            guard let turns = result?["data"] as? [[String: Any]] else {
                self.notice = "Codex: \(error ?? "could not read thread")"
                return
            }
            var out = [ChatMessage]()
            for turn in turns.reversed() {          // the server returns newest first
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    if let m = Self.chatMessage(fromCodexItem: item) { out.append(m) }
                }
            }
            let recent = Array(out.suffix(60))
            if recent != self.messages { self.messages = recent }
        }
    }

    static func chatMessage(fromCodexItem item: [String: Any]) -> ChatMessage? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        switch type {
        case "userMessage":
            let text = (item["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : ChatMessage(id: id, role: "user", text: text)
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            return text.isEmpty ? nil : ChatMessage(id: id, role: "assistant", text: text)
        case "commandExecution":
            return ChatMessage(id: id, role: "system", text: "$ " + String((item["command"] as? String ?? "command").prefix(200)))
        default:
            return nil
        }
    }

    func sendCodex(_ threadId: String, _ text: String) {
        let startTurn = { [weak self] in
            guard let self else { return }
            self.ownTurnThreads.insert(threadId)
            var turn: [String: Any] = ["threadId": threadId, "input": [["type": "text", "text": text]]]
            if let chosen = self.codexPending.removeValue(forKey: threadId) {
                var now = self.codexSettings[threadId] ?? ThreadSettings()
                if !chosen.model.isEmpty { turn["model"] = chosen.model; now.model = chosen.model }
                if !chosen.effort.isEmpty { turn["effort"] = chosen.effort; now.effort = chosen.effort }
                self.codexSettings[threadId] = now
            }
            self.codex.request("turn/start", turn) { [weak self] result, error in
                if result == nil {
                    self?.sending = false
                    self?.notice = error == CodexClient.connectionClosed
                        ? "The connection to Codex dropped before it answered. Your message may or may not have arrived, so it was not sent again."
                        : "Codex: \(error ?? "turn/start failed")"
                }
            }
        }
        if resumedThreads.contains(threadId) {
            startTurn()
        } else {
            // Resuming loads the thread into the daemon and subscribes us to its events.
            codex.request("thread/resume", ["threadId": threadId, "excludeTurns": true]) { [weak self] result, error in
                guard let self else { return }
                guard result != nil else {
                    self.sending = false
                    let reason = error ?? "thread/resume failed"
                    if reason.contains("active writer") {
                        // Codex allows one writer per thread, and the Codex app holds this
                        // one. The lock is not ours to break, so hand the message to the
                        // thread's queue for the owner to run.
                        self.queueForOwner(threadId, text)
                    } else {
                        self.sending = false
                        self.notice = "Codex: \(reason)"
                        self.dropEcho(text)
                    }
                    return
                }
                self.resumedThreads.insert(threadId)
                startTurn()
            }
        }
    }

    func dropEcho(_ text: String) {
        if messages.last?.role == "user", messages.last?.text == text { messages.removeLast() }
    }

    /// Adds the message to the thread's queue (stored in Codex's shared state) so the
    /// process that owns the thread can start it. Verified on a thread the daemon owns;
    /// whether the Codex app drains a queue filled from outside is what this tests.
    func queueForOwner(_ threadId: String, _ text: String) {
        codex.request("thread/queue/add", [
            "threadId": threadId,
            "clientUserMessageId": UUID().uuidString,
            "input": [["type": "text", "text": text]],
        ]) { [weak self] result, error in
            guard let self else { return }
            self.sending = false
            guard let id = (result?["queuedSubmission"] as? [String: Any])?["id"] as? String else {
                self.notice = "Not sent: the Codex app holds this thread's writer lock, and queueing failed (\(error ?? "unknown"))."
                self.dropEcho(text)
                return
            }
            self.codexQueued[threadId] = (id, Date(), false)
            self.queuedThreadIds.insert(threadId)
            self.notice = "Queued: the Codex app owns this thread. Waiting for it to pick the message up…"
            if self.codexPending.removeValue(forKey: threadId) != nil {
                // A queued message runs with whatever the app has set for the thread.
                self.notice = (self.notice ?? "") + " The model and effort chosen here were not applied: the app decides them for a thread it has open."
            }
            log("codex: queued \(id) for thread \(threadId)")
        }
    }

    func cancelQueued() {
        guard let row = selectedRow, let queued = codexQueued[row.rawId] else { return }
        codex.request("thread/queue/delete", ["threadId": row.rawId, "queuedSubmissionId": queued.id]) { [weak self] result, error in
            guard let self else { return }
            let deleted = result?["deleted"] as? Bool ?? false
            self.codexQueued[row.rawId] = nil
            self.queuedThreadIds.remove(row.rawId)
            self.notice = deleted ? "Queued message cancelled." : "Could not cancel (\(error ?? "it may already have started"))."
            log("codex: cancel queued -> deleted=\(deleted)")
        }
    }

    /// Checks whether queued messages have been taken off the queue by the thread's owner.
    func watchCodexQueue() {
        for (threadId, queued) in codexQueued where !codexQueueChecking.contains(threadId) {
            codexQueueChecking.insert(threadId)
            codex.request("thread/queue/list", ["threadId": threadId]) { [weak self] result, _ in
                guard let self else { return }
                self.codexQueueChecking.remove(threadId)
                guard let data = result?["data"] as? [[String: Any]], self.codexQueued[threadId]?.id == queued.id else { return }
                let rowId = "codex:\(threadId)"
                let waited = Int(Date().timeIntervalSince(queued.since))
                if !data.contains(where: { $0["id"] as? String == queued.id }) {
                    self.codexQueued[threadId] = nil
                    self.queuedThreadIds.remove(threadId)
                    log("codex: queued message picked up after \(waited)s")
                    if self.selectedId == rowId { self.notice = "Codex picked up your queued message." }
                    self.addEvent("Codex · queued message started", rowId: rowId)
                } else if waited > 20, !queued.warned {
                    self.codexQueued[threadId]?.warned = true
                    log("codex: still queued after \(waited)s")
                    if self.selectedId == rowId {
                        self.notice = "Still queued after \(waited)s: the Codex app has not picked it up yet. "
                            + "It may only run once that thread is used in the Codex app."
                    }
                }
            }
        }
    }

    func handleCodex(_ method: String, _ params: [String: Any]) {
        guard let threadId = params["threadId"] as? String else { return }
        let rowId = "codex:\(threadId)"
        let isSelected = selectedId == rowId
        switch method {
        case "item/agentMessage/delta":
            if isSelected { streaming += params["delta"] as? String ?? "" }
        case "item/completed":
            guard isSelected, let item = params["item"] as? [String: Any],
                  let message = Self.chatMessage(fromCodexItem: item) else { return }
            if message.role == "assistant" { streaming = "" }
            // Our own user message was already echoed locally on send.
            if message.role == "user", messages.last?.role == "user", messages.last?.text == message.text { return }
            if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
        case "thread/status/changed":
            codexDaemonStatus[threadId] = (params["status"] as? [String: Any])?["type"] as? String ?? "idle"
            applyCodexStatus(threadId)
        case "turn/completed":
            if isSelected {
                sending = false
                streaming = ""
            }
            let title = codexRows.first { $0.id == rowId }?.title ?? "thread"
            let status = (params["turn"] as? [String: Any])?["status"] as? String ?? "completed"
            addEvent("Codex · \(title): turn \(status)", rowId: rowId)
            captureCodexReply(threadId)
            // Let the list poll absorb the updatedAt bump caused by our own turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.ownTurnThreads.remove(threadId)
            }
        default:
            break
        }
    }

    func handleCodexRequest(_ id: Any, _ method: String, _ params: [String: Any]) {
        let threadId = params["threadId"] as? String ?? ""
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String ?? "a command"
            approvals.append(PendingApproval(rpcId: id, threadId: threadId, summary: "Run: \(command)"))
            addEvent("Codex needs approval: \(command.prefix(60))", rowId: "codex:\(threadId)")
        case "item/fileChange/requestApproval":
            approvals.append(PendingApproval(rpcId: id, threadId: threadId, summary: "Apply file changes"))
            addEvent("Codex needs approval for file changes", rowId: "codex:\(threadId)")
        default:
            // Not handled in the prototype; tell the server so the turn doesn't hang.
            codex.respondError(to: id, message: "TopLayer prototype does not handle \(method)")
        }
    }

    func resolve(_ approval: PendingApproval, accept: Bool) {
        codex.respond(to: approval.rpcId, result: ["decision": accept ? "accept" : "decline"])
        approvals.removeAll { $0.id == approval.id }
    }
}
