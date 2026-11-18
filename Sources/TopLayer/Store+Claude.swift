import Foundation

/// Claude Code sessions running on this Mac.
///
/// Presence comes from each session's registry file, conversation text from its
/// transcript, and everything interactive (replies, finished/needs-input events,
/// permission prompts) from the TopLayer hook the session runs itself.
extension Store {
    func refreshClaude() {
        let sessions = ClaudeBridge.liveSessions()
        let unreadIds = Set(claudeRows.filter(\.unread).map(\.id))
        var rows = [SessionRow]()
        var seen = [String: ClaudeBridge.Session]()
        // The short run that reads usage is not a session of yours.
        for s in sessions where s.cwd != ClaudeUsage.folder {
            seen[s.sessionId] = s
            var row = SessionRow(id: "claude:\(s.sessionId)", source: .claude, rawId: s.sessionId,
                                 title: s.name, cwd: s.cwd, status: s.status, updatedAt: s.updatedAt)
            row.remoteId = s.remoteId
            row.cli = s.entrypoint == "cli"
            row.canReply = ClaudeBridge.isHooked(s.sessionId)
            row.unread = unreadIds.contains(row.id) || restoredUnread.remove(row.id) != nil
            if let previous = claudeStatus[s.sessionId], previous != s.status, previous == "busy" {
                expectHookStop(s.sessionId)
            }
            if let previous = claudeStatus[s.sessionId], previous != s.status, previous == "busy",
               !hookEventSessions.contains(s.sessionId) {
                rows.append(row)
                addEvent("Claude · \(s.name): \(s.status == "idle" ? "finished, waiting for you" : s.status)", rowId: row.id)
                row.unread = !(expanded && selectedId == row.id)
                rows[rows.count - 1] = row
            } else {
                rows.append(row)
            }
            claudeStatus[s.sessionId] = s.status
        }
        claudeSessions = seen
        // Background sessions TopLayer started that Claude's own list does not have.
        for var row in backgroundRows(notIn: Set(seen.keys)) {
            row.unread = unreadIds.contains(row.id) || restoredUnread.remove(row.id) != nil
            rows.append(row)
        }
        claudeLive = rows
        claudeShelf.absorb(recent: rows, paths: [:])
        composeClaudeRows()
        restoreSelectionIfNeeded()
        if selectedRow?.source == .claude { loadClaudeTranscript(force: false) }
    }

    /// Rebuilds the list from the running sessions and the kept ones. A kept session
    /// that is not running is listed as ended: it can be read, not replied to.
    func composeClaudeRows() {
        let rows = claudeShelf.rows(recent: claudeLive) { thread in
            var row = SessionRow(id: "claude:\(thread.id)", source: .claude, rawId: thread.id, title: thread.title,
                                 cwd: thread.cwd, status: "ended", updatedAt: 0)
            row.ended = true
            return row
        }
        if rows != claudeRows { claudeRows = rows }
    }

    /// Collects every session for the search: the running ones, then every other
    /// session that left a transcript on disk, newest first.
    func loadClaudeIndex(run: Int) {
        let running = claudeLive
        DispatchQueue.global(qos: .userInitiated).async {
            let past = ClaudeBridge.pastSessions()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let live = Set(running.map(\.rawId))
                let ended = past.filter { !live.contains($0.sessionId) }.map { session in
                    var row = SessionRow(id: "claude:\(session.sessionId)", source: .claude, rawId: session.sessionId,
                                         title: session.title, cwd: session.cwd, status: "ended",
                                         updatedAt: session.modified.timeIntervalSince1970)
                    row.ended = true
                    return row
                }
                self.finishIndex(.claude, run: run, rows: running + ended)
            }
        }
    }

    func loadClaudeTranscript(force: Bool) {
        guard let row = selectedRow, row.source == .claude,
              let path = ClaudeBridge.transcriptPath(sessionId: row.rawId, cwd: row.cwd) else { return }
        let stamp = ClaudeBridge.modificationDate(path)
        if !force && stamp == transcriptStamp { return }
        transcriptStamp = stamp
        let rowId = row.id
        let sessionId = row.rawId
        let pending = sentReplies[sessionId] ?? []
        transcriptQueue.async { [transcript] in
            let recorded = transcript.read(path: path)
            // A sent reply is shown from the overlay's own copy only until Claude's
            // transcript records it; after that the transcript is the source.
            let fromOverlay = recorded.filter(\.fromOverlay)
            let stillPending = pending.filter { reply in
                !fromOverlay.contains { $0.text == reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    && $0.time > reply.time.addingTimeInterval(-10) }
            }
            var timed = recorded.map { message in
                (time: message.time, message: ChatMessage(id: message.id, role: message.role, text: message.text,
                                                          status: message.fromOverlay ? "delivered" : nil, label: message.label))
            }
            timed.append(contentsOf: stillPending.map {
                (time: $0.time, message: ChatMessage(id: $0.id, role: "user", text: $0.text,
                                                     status: $0.delivered ? "delivered" : "waiting"))
            })
            let loaded = timed.sorted { $0.time < $1.time }.map(\.message)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if stillPending.count != pending.count {
                    // Forget the copies the transcript now covers.
                    let keep = Set(stillPending.map(\.id))
                    self.sentReplies[sessionId]?.removeAll { reply in pending.contains { $0.id == reply.id } && !keep.contains(reply.id) }
                    if self.sentReplies[sessionId]?.isEmpty == true { self.sentReplies[sessionId] = nil }
                    self.saveSentReplies()
                }
                guard self.selectedId == rowId else { return }
                if loaded != self.messages { self.messages = loaded }
            }
        }
    }

    func sendClaude(_ row: SessionRow, _ text: String) {
        guard let file = ClaudeBridge.dropReply(sessionId: row.rawId, text: text) else {
            notice = "Not sent: could not write to the TopLayer inbox."
            return
        }
        let reply = SentReply(id: UUID().uuidString, text: text, time: Date(), file: file)
        sentReplies[row.rawId, default: []].append(reply)
        saveSentReplies()
        messages.append(ChatMessage(id: reply.id, role: "user", text: text, status: "waiting"))
        let alive = ClaudeBridge.listenerAlive(row.rawId)
        if alive {
            notice = nil
        } else if row.isBusy {
            notice = "Queued: Claude gets it at its next step or when the turn ends."
        } else {
            // Idle with no listener: nothing will pick this up until the session
            // next finishes a turn, which means the hook did not arm last time.
            notice = "Queued, but this idle session has no listener armed. It will only arrive after the "
                + "session's next turn. Check that the TopLayer hook is still registered."
        }
        if cliStatus[row.rawId] != nil { cliStatus[row.rawId] = "busy" }     // until the hook reports the turn's end
        log("claude: reply queued for \(row.rawId.prefix(8)) listener=\(alive)")
    }

    /// Marks overlay replies as delivered once the hook has left a receipt for them.
    func checkReceipts() {
        for (sessionId, replies) in sentReplies {
            for (index, reply) in replies.enumerated() where !reply.delivered {
                guard ClaudeBridge.wasDelivered(sessionId: sessionId, name: reply.file) else { continue }
                sentReplies[sessionId]?[index].delivered = true
                saveSentReplies()
                log("claude: reply delivered to \(sessionId.prefix(8))")
                if selectedId == "claude:\(sessionId)" {
                    if let i = messages.firstIndex(where: { $0.id == reply.id }) { messages[i].status = "delivered" }
                    if notice?.hasPrefix("Queued") == true { notice = nil }
                }
            }
        }
    }

    /// Turn-finished and needs-input events reported by the session's own hook.
    func pollHookEvents() {
        // The first read after launch covers the time TopLayer was closed: those events
        // mark threads unread, quietly, without a sound or a notification for each.
        catchingUp = tick == 0
        defer { catchingUp = false }
        for event in ClaudeBridge.readNewEvents(offset: &eventsOffset) {
            guard let sessionId = event["session_id"] as? String,
                  let kind = event["hook_event_name"] as? String else { continue }
            hookEventSessions.insert(sessionId)
            let rowId = "claude:\(sessionId)"
            let name = claudeRows.first { $0.rawId == sessionId }?.title ?? "session"
            switch kind {
            case "Stop":
                if cliStatus[sessionId] != nil { cliStatus[sessionId] = "idle" }
                lastHookStop[sessionId] = Date()
                hookSilentSessions.remove(sessionId)
                hookMisses[sessionId] = nil
                let reply = (event["last_assistant_message"] as? String ?? "")
                    .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                addEvent("Claude · \(name): finished" + (reply.isEmpty ? "" : " — \(reply.prefix(70))"), rowId: rowId)
                // If this turn answered something you posted in a group chat, bring it there.
                groupChats.turnFinished(source: .claude, rawId: sessionId,
                                        finalMessage: event["last_assistant_message"] as? String)
            case "TopLayerDelivered":
                // The hook handed over what was waiting in this session's inbox. It writes
                // this in order with the session's turn endings, so "the next finished turn
                // is the answer" holds exactly.
                groupChats.deliveryConfirmed(source: .claude, rawId: sessionId)
            case "Notification":
                addEvent("Claude · \(name): \(event["message"] as? String ?? "needs your attention")", rowId: rowId)
            default:
                break
            }
        }
    }

    func pollPermissions() {
        let pending = ClaudeBridge.pendingPermissions()
        guard pending != permissions else { return }
        for request in pending where !permissions.contains(where: { $0.id == request.id }) {
            let name = claudeRows.first { $0.rawId == request.sessionId }?.title ?? "session"
            let what = request.isQuestion
                ? "asks: \(request.questions[0].text.prefix(70))"
                : "asks permission: \(request.tool) \(request.summary.prefix(50))"
            addEvent("Claude · \(name) \(what)", rowId: "claude:\(request.sessionId)")
        }
        animate { permissions = pending }
        questionDrafts = questionDrafts.filter { draft in pending.contains { $0.id == draft.key } }
        questionBodies = questionBodies.filter { body in pending.contains { body.key.hasPrefix($0.id + "#") } }
    }

    func sessionName(for request: ClaudeBridge.PermissionRequest) -> String {
        claudeRows.first { $0.rawId == request.sessionId }?.title ?? "Claude session"
    }

    /// `decision`: allow | deny | ask (ask hands the prompt back to the Claude app).
    func answer(_ request: ClaudeBridge.PermissionRequest, _ decision: String) {
        ClaudeBridge.answerPermission(id: request.id, decision: decision)
        permissions.removeAll { $0.id == request.id }
        questionDrafts[request.id] = nil
        log("claude: permission \(decision.hasPrefix("{") ? "answered" : decision) for \(request.tool)")
    }

    // MARK: Questions Claude asks (its AskUserQuestion tool)

    /// Changes what is picked for a question, then publishes it.
    func editQuestion(_ request: ClaudeBridge.PermissionRequest, _ change: (inout ClaudeBridge.QuestionDraft) -> Void) {
        var draft = questionDrafts[request.id] ?? ClaudeBridge.QuestionDraft()
        change(&draft)
        draft.page = min(max(0, draft.page), request.questions.count - 1)
        questionDrafts[request.id] = draft
    }

    /// Moves to the next question once the one showing has an answer, and sends them
    /// all after the last. Returns false when there is nothing to move on from yet.
    @discardableResult
    func advanceQuestion(_ request: ClaudeBridge.PermissionRequest) -> Bool {
        let draft = questionDrafts[request.id] ?? ClaudeBridge.QuestionDraft()
        guard request.questions.indices.contains(draft.page),
              draft.answer(for: request.questions[draft.page]) != nil else { return false }
        if draft.page < request.questions.count - 1 {
            animate { editQuestion(request) { $0.page += 1 } }
            return true
        }
        return sendAnswers(request)
    }

    /// Sends every answer at once, which is how Claude takes them: one ask, one reply.
    @discardableResult
    func sendAnswers(_ request: ClaudeBridge.PermissionRequest) -> Bool {
        let draft = questionDrafts[request.id] ?? ClaudeBridge.QuestionDraft()
        guard let answers = draft.answers(for: request.questions),
              let reply = ClaudeBridge.questionReply(input: request.input, answers: answers) else { return false }
        animate { answer(request, reply) }
        return true
    }

    /// A session just went from busy to idle. Its Stop hook should report within a few
    /// seconds; if it keeps not doing so, the hooks are not running in that session.
    ///
    /// One miss is not a fault: a turn that is interrupted or cut short ends without
    /// running the hook. It takes two in a row to be reported.
    func expectHookStop(_ sessionId: String) {
        let ended = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            let reported = (self.lastHookStop[sessionId] ?? .distantPast) > ended.addingTimeInterval(-10)
            let changed: Bool
            if reported {
                self.hookMisses[sessionId] = nil
                changed = self.hookSilentSessions.remove(sessionId) != nil
            } else {
                self.hookMisses[sessionId, default: 0] += 1
                changed = (self.hookMisses[sessionId] ?? 0) >= 2 && self.hookSilentSessions.insert(sessionId).inserted
            }
            if changed { self.health.refresh() }
        }
    }


    /// Group chat messages for Claude are "queued" until the hook leaves its receipt.
    func checkClaudeDeliveries() {
        claudeDeliveries.removeAll { waiting in
            guard ClaudeBridge.wasDelivered(sessionId: waiting.sessionId, name: waiting.file) else { return false }
            waiting.status("delivered")
            return true
        }
    }
}
