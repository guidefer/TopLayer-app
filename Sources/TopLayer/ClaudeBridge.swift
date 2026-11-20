import Foundation

/// Read-mostly bridge to Claude Code sessions already running on this Mac.
///
/// - Presence and status come from `~/.claude/sessions/<pid>.json`, which each
///   running session keeps up to date (undocumented, observed on 2.1.321).
/// - Conversation text comes from the session transcript JSONL (path is
///   documented, entry format is explicitly unstable).
/// - Replies are EXPERIMENTAL: they run `claude -p --resume <id>` in a second
///   process. The app that owns the live session will not see that turn until
///   it reloads the transcript.
enum ClaudeBridge {
    struct Session {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String
        let status: String
        let updatedAt: Double
        let entrypoint: String
        /// Remote Control id (`session_…`), present when the session is connected to claude.ai.
        let remoteId: String?
    }

    struct Message {
        let id: String
        let role: String        // user | assistant | peer (the other agent, through a group chat)
        let text: String
        let time: Date
        /// Extra context for the label, such as "group chat".
        var label: String? = nil
        /// True for something you sent from the overlay, as opposed to typed in Claude.
        var fromOverlay = false
    }

    static let home = NSHomeDirectory() + "/.claude"

    static func liveSessions() -> [Session] {
        let dir = home + "/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out = [Session]()
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  let sessionId = obj["sessionId"] as? String else { continue }
            // Skip registry files left behind by dead processes.
            guard kill(Int32(pid), 0) == 0 else { continue }
            let cwd = obj["cwd"] as? String ?? ""
            out.append(Session(
                pid: Int32(pid),
                sessionId: sessionId,
                cwd: cwd,
                name: obj["name"] as? String ?? (cwd as NSString).lastPathComponent,
                status: obj["status"] as? String ?? "unknown",
                updatedAt: (obj["statusUpdatedAt"] as? Double ?? obj["updatedAt"] as? Double ?? 0) / 1000,
                entrypoint: obj["entrypoint"] as? String ?? "cli",
                remoteId: obj["bridgeSessionId"] as? String
            ))
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The Claude Code versions of the sessions running now.
    static func runningVersions() -> [String] {
        let dir = home + "/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var versions = Set<String>()
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int, kill(Int32(pid), 0) == 0,
                  let version = obj["version"] as? String else { continue }
            versions.insert(version)
        }
        return versions.sorted()
    }

    /// Non-nil when a live session's registry file no longer has the fields TopLayer
    /// reads, which means Claude Code changed the format.
    static func registryProblem() -> String? {
        let dir = home + "/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".json") {
            guard let pid = Int32((file as NSString).deletingPathExtension), kill(pid, 0) == 0 else { continue }
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "A running session's file in ~/.claude/sessions could not be read. Claude Code may have changed how it records sessions."
            }
            if obj["sessionId"] as? String == nil || obj["status"] as? String == nil {
                return "A running session's file in ~/.claude/sessions is missing the fields TopLayer reads. Claude Code has probably changed its format."
            }
        }
        return nil
    }

    static func transcriptPath(sessionId: String, cwd: String) -> String? {
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = "\(home)/projects/\(encoded)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: direct) { return direct }
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: home + "/projects")) ?? []
        for p in projects {
            let candidate = "\(home)/projects/\(p)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Sessions that are no longer running

    /// A session found on disk by its transcript.
    struct PastSession: Equatable {
        let sessionId: String
        let title: String
        let cwd: String
        let path: String
        let modified: Date

        /// Reads a session's title and folder from its transcript without reading all
        /// of it: a transcript can be tens of megabytes, and the title is recorded near
        /// both ends. Only the first and last stretch of the file are looked at.
        static func read(path: String, window: Int = 96 * 1024) -> PastSession? {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: 0)
            let head = (try? handle.read(upToCount: window)) ?? Data()
            var tail = Data()
            if size > UInt64(window) {
                try? handle.seek(toOffset: size - UInt64(window))
                tail = (try? handle.readToEnd()) ?? Data()
            }
            let lines = [head, tail].flatMap { $0.split(separator: UInt8(ascii: "\n")) }

            var custom: String?, generated: String?, firstPrompt: String?, cwd: String?
            for line in lines {
                // Most lines are messages, and some are megabytes long. Only the few that
                // can carry a title or the folder are parsed.
                let start = String(decoding: line.prefix(400), as: UTF8.self)
                let interesting = start.contains("-title\"") || start.contains("\"summary\"")
                    || (firstPrompt == nil && start.contains("\"type\":\"user\"")) || (cwd == nil && line.count < 20_000)
                guard interesting, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if cwd == nil, let found = object["cwd"] as? String, !found.isEmpty { cwd = found }
                switch object["type"] as? String {
                case "custom-title": custom = (object["customTitle"] as? String) ?? custom     // the last one wins
                case "ai-title": generated = (object["aiTitle"] as? String) ?? generated
                case "summary": generated = generated ?? (object["summary"] as? String)
                case "user" where firstPrompt == nil:
                    let content = (object["message"] as? [String: Any])?["content"]
                    let text = (content as? String)
                        ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
                    // Skip what the harness injects ahead of the first thing actually typed.
                    if let text, !text.hasPrefix("<"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        firstPrompt = text
                    }
                default: break
                }
            }
            let folder = cwd ?? ""
            let name = [custom, generated, firstPrompt].compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")[0] }
                .first { !$0.isEmpty } ?? "Untitled session"
            return PastSession(sessionId: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                               title: String(name.prefix(60)), cwd: folder, path: path,
                               modified: modificationDate(path) ?? .distantPast)
        }
    }

    /// Every session with a transcript on disk, newest first. Reads a little of each
    /// file, so call it off the main thread.
    static func pastSessions(projects: String = home + "/projects") -> [PastSession] {
        let fm = FileManager.default
        var out = [PastSession]()
        for project in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let dir = projects + "/" + project
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".jsonl") {
                if let session = PastSession.read(path: dir + "/" + file) { out.append(session) }
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Parses transcript lines into the visible user/assistant text.
    static func parse(_ lines: [Data.SubSequence]) -> [Message] {
        var out = [Message]()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "queue-operation" {
                // What the TopLayer hook handed to the session is recorded here, not as a
                // user message, so replies sent from the overlay are read back from it.
                if obj["operation"] as? String == "enqueue", let content = obj["content"] as? String,
                   content.contains("TopLayer") {
                    let stamp = obj["timestamp"] as? String ?? ""
                    let time = isoFormatter.date(from: stamp) ?? .distantPast
                    out.append(contentsOf: overlayDeliveries(in: content, time: time, key: stamp))
                }
                continue
            }
            guard type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Harness-injected user entries (reminders, task notifications) are noise here.
            if text.isEmpty || (type == "user" && text.hasPrefix("<")) { continue }
            let id = obj["uuid"] as? String ?? UUID().uuidString
            let time = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? .distantPast
            out.append(Message(id: id, role: type, text: text, time: time))
        }
        return out
    }

    private static let userHeaders = [
        "Message incoming from TopLayer. The user typed this in their TopLayer overlay as a reply in this session:",
        "Message from the user, typed in their TopLayer overlay as a reply in this session:",
    ]
    private static let peerHeader = "Message incoming from a TopLayer group chat."
    private static let separator = try! NSRegularExpression(pattern: #"--- TopLayer message \d+ of \d+ ---\n"#)

    /// Pulls the messages out of one hook delivery: what you typed in the overlay, and
    /// what the other agent sent through a group chat. Notices are left out.
    static func overlayDeliveries(in content: String, time: Date, key: String) -> [Message] {
        guard let start = content.range(of: #"hook blocking error from command "[^"]*": "#, options: .regularExpression) else { return [] }
        var body = String(content[start.upperBound...])
        for closing in ["</system-reminder>", "&lt;/system-reminder&gt;"] {
            if let end = body.range(of: closing, options: .backwards) { body = String(body[..<end.lowerBound]) }
        }
        // Several messages delivered at once are divided by a marker line.
        let whole = NSRange(body.startIndex..., in: body)
        let parts = separator.stringByReplacingMatches(in: body, range: whole, withTemplate: "\u{1}")
            .split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var out = [Message]()
        for (index, part) in parts.enumerated() {
            var paragraphs = part.components(separatedBy: "\n\n")
            guard paragraphs.count >= 2 else { continue }
            let header = paragraphs.removeFirst()
            let id = "overlay-\(key)-\(index)"
            if userHeaders.contains(header) {
                var label: String?
                if paragraphs.first?.hasPrefix("From the user, in the TopLayer group chat") == true {
                    paragraphs.removeFirst()
                    label = "group chat"
                    if paragraphs.last?.hasPrefix("(Answer here as usual.") == true { paragraphs.removeLast() }
                }
                let text = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(Message(id: id, role: "user", text: text, time: time, label: label, fromOverlay: true)) }
            } else if header.hasPrefix(peerHeader) {
                var sender = "The other agent"
                if let first = paragraphs.first, first.hasPrefix("From the linked ") {
                    sender = first.dropFirst("From the linked ".count).split(separator: " ").first.map(String.init) ?? sender
                    paragraphs.removeFirst()
                }
                if let last = paragraphs.last, last.hasPrefix("(Repl") { paragraphs.removeLast() }
                let text = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(Message(id: id, role: "peer", text: text, time: time, label: sender)) }
            }
        }
        return out
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Hook inbox
    //
    // Replies reach a live session through Hooks/toplayer-hook.sh, a background hook
    // the session runs itself (asyncRewake). The overlay only drops files into
    // ~/.toplayer/inbox/<session id>/; the hook hands them to Claude, wakes the
    // session, and leaves a receipt per message.

    static let root = NSHomeDirectory() + "/.toplayer"
    static let inbox = root + "/inbox"

    /// The session has run the TopLayer hook at least once, so replies will be picked up.
    static func isHooked(_ sessionId: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(inbox)/\(sessionId)/hooked")
    }

    /// A listener is waiting right now, so delivery is immediate. Otherwise replies
    /// wait for the next listener the session arms.
    static func listenerAlive(_ sessionId: String) -> Bool {
        guard let text = try? String(contentsOfFile: "\(inbox)/\(sessionId)/listener.pid", encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    /// Queues a reply and returns its file name (the receipt key), or nil on failure.
    /// Names sort by time, so several queued replies are delivered in the order typed.
    ///
    /// `kind` tells the hook who is speaking: "" is the user, "peer" another agent in a
    /// group chat, "notice" TopLayer itself. The hook words its header accordingly.
    static func dropReply(sessionId: String, text: String, kind: String = "") -> String? {
        let dir = "\(inbox)/\(sessionId)"
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
            + (kind.isEmpty ? "" : ".\(kind)") + ".msg"
        let temp = "\(dir)/.\(name).tmp"      // hidden: the hook only globs *.msg
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try text.write(toFile: temp, atomically: false, encoding: .utf8)
            try FileManager.default.moveItem(atPath: temp, toPath: "\(dir)/\(name)")  // atomic
            return name
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            return nil
        }
    }

    /// The hook writes a receipt once it has handed the message to Claude.
    static func wasDelivered(sessionId: String, name: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(inbox)/\(sessionId)/delivered/\(name)")
    }

    /// The permission hook only waits for an answer while this file is fresh.
    static func heartbeat() {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data().write(to: URL(fileURLWithPath: root + "/overlay.alive"))
    }

    // MARK: Permission requests (Hooks/toplayer-permission.sh)

    struct PermissionRequest: Identifiable, Equatable {
        let id: String          // request file name without ".json"
        let sessionId: String
        let tool: String
        let summary: String
        /// Set when this is not a permission at all but Claude asking you something
        /// (its AskUserQuestion tool). One ask can carry several questions.
        var questions: [AskedQuestion] = []
        /// What Claude sent with the ask, kept to hand back with your answers.
        var input = Data()

        var isQuestion: Bool { !questions.isEmpty }
        /// An ask whose questions could not be read. Allowing or denying it would answer
        /// nothing, so the only thing to do with it here is hand it to Claude's own dialog.
        var needsClaude: Bool { tool == "AskUserQuestion" && questions.isEmpty }
    }

    /// One question Claude asks, with the answers it offers.
    struct AskedQuestion: Identifiable, Equatable {
        struct Option: Equatable {
            let label: String
            let detail: String
        }
        let id: Int             // its place in the ask
        let header: String
        let text: String
        let options: [Option]
        let multiSelect: Bool

        /// Reads the `questions` of an AskUserQuestion call. A question without text or
        /// without options can't be answered here, so the whole ask is treated as one
        /// TopLayer doesn't understand and is left to Claude's own dialog.
        static func parse(_ input: [String: Any]) -> [AskedQuestion] {
            guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty else { return [] }
            var out = [AskedQuestion]()
            for (index, question) in raw.enumerated() {
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                    guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                    return Option(label: label, detail: option["description"] as? String ?? "")
                }
                guard let text = question["question"] as? String, !text.isEmpty, !options.isEmpty else { return [] }
                out.append(AskedQuestion(id: index, header: question["header"] as? String ?? "", text: text,
                                         options: options, multiSelect: question["multiSelect"] as? Bool ?? false))
            }
            return out
        }
    }

    static func pendingPermissions() -> [PermissionRequest] {
        let dir = root + "/permissions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out = [PermissionRequest]()
        for file in files.sorted() where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(file)"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = obj["session_id"] as? String else { continue }
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            var summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? ""
            if summary.isEmpty, let raw = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
                summary = String(decoding: raw, as: UTF8.self)
            }
            var request = PermissionRequest(id: String(file.dropLast(5)), sessionId: sessionId,
                                            tool: obj["tool_name"] as? String ?? "tool",
                                            summary: String(summary.prefix(240)))
            if request.tool == "AskUserQuestion" {
                request.questions = AskedQuestion.parse(input)
                request.input = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
            }
            out.append(request)
        }
        return out
    }

    /// What you have picked so far for one ask.
    struct QuestionDraft: Equatable {
        /// The option labels picked for each question, by the question's place.
        var picked: [Int: Set<String>] = [:]
        /// An answer typed in place of the options, and which questions use one.
        var typed: [Int: String] = [:]
        var typing: Set<Int> = []
        /// Which question is showing.
        var page = 0

        /// Picks an option, or takes it back. A question that allows one answer keeps
        /// only the last pick, and picking an option there drops a typed answer.
        mutating func toggle(_ label: String, in question: AskedQuestion) {
            var labels = picked[question.id] ?? []
            if question.multiSelect {
                if labels.contains(label) { labels.remove(label) } else { labels.insert(label) }
            } else {
                labels = labels == [label] ? [] : [label]
                typing.remove(question.id)
            }
            picked[question.id] = labels
        }

        /// Turns typing an answer on or off. Where one answer is allowed, it replaces the pick.
        mutating func toggleTyping(in question: AskedQuestion) {
            if typing.contains(question.id) {
                typing.remove(question.id)
            } else {
                typing.insert(question.id)
                if !question.multiSelect { picked[question.id] = [] }
            }
        }

        /// The answer as Claude Code takes it: the label, several labels joined with a
        /// comma in the order they were offered, or the text you typed. Nil while there is none.
        func answer(for question: AskedQuestion) -> String? {
            var parts = question.options.map(\.label).filter { picked[question.id]?.contains($0) == true }
            if typing.contains(question.id) {
                let text = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        /// Every question's answer, keyed by the question's text. Nil until all have one.
        func answers(for questions: [AskedQuestion]) -> [String: String]? {
            var out = [String: String]()
            for question in questions {
                guard let answer = answer(for: question) else { return nil }
                out[question.text] = answer
            }
            return out
        }
    }

    /// Whether a session is one TopLayer started for itself: the short run that reads
    /// usage, or a run of `Scripts/check-claude.sh`, which works in a scratch folder
    /// named `toplayer-check.<something>`. Those are not threads of yours.
    static func isOwnRun(cwd: String) -> Bool {
        cwd == ClaudeUsage.folder || cwd.split(separator: "/").contains { $0.hasPrefix("toplayer-check.") }
    }

    /// Whether a turn ended with agents of its own still at work. Each one reports back
    /// to the session, which then carries on by itself, so the session is not waiting on
    /// you. A shell command or a monitor left running does not count: a server can run
    /// for as long as the session does, and the turn that started it is finished.
    static func hasAgentsRunning(_ event: [String: Any]) -> Bool {
        let tasks = event["background_tasks"] as? [[String: Any]] ?? []
        return tasks.contains { task in
            task["status"] as? String == "running" && ["subagent", "workflow"].contains(task["type"] as? String ?? "")
        }
    }

    /// The reply the permission hook prints to answer an ask: Claude's own input handed
    /// back whole, with the answers added. That is the form Claude Code documents for
    /// answering AskUserQuestion from a hook.
    static func questionReply(input: Data, answers: [String: String]) -> String? {
        guard var updated = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        updated["answers"] = answers
        let reply: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow", "updatedInput": updated] as [String: Any],
        ] as [String: Any]]
        // One line: the hook passes it on as it is.
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `decision` is "allow", "deny", "ask" (hand the prompt back to the Claude app), or
    /// the whole reply to a question, from `questionReply`.
    static func answerPermission(id: String, decision: String) {
        let dir = root + "/permissions"
        let temp = "\(dir)/.\(id).tmp"
        guard (try? decision.write(toFile: temp, atomically: false, encoding: .utf8)) != nil else { return }
        try? FileManager.default.moveItem(atPath: temp, toPath: "\(dir)/\(id).decision")
    }

    // MARK: Hook events (~/.toplayer/events.jsonl)

    static let eventsPath = root + "/events.jsonl"

    static func eventsFileSize() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: eventsPath))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Returns complete event lines appended since `offset` and advances it.
    static func readNewEvents(offset: inout UInt64) -> [[String: Any]] {
        let size = eventsFileSize()
        if size < offset { offset = 0 }             // file was truncated or replaced
        guard size > offset, let handle = FileHandle(forReadingAtPath: eventsPath) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        offset += UInt64(lastNewline - data.startIndex + 1)
        return data[data.startIndex...lastNewline]
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
}

/// Reads one transcript at a time and only parses what was appended since last time.
///
/// Transcripts are append-only, and entries can be huge (a pasted screenshot is megabytes
/// of base64 on one line). Parsing the whole tail on every change would redo that work
/// every couple of seconds while a session is busy. Not thread-safe: use from one queue.
final class TranscriptReader {
    private var path = ""
    private var offset: UInt64 = 0          // end of the last complete line already parsed
    private var messages: [ClaudeBridge.Message] = []
    private let keep = 60

    func read(path: String) -> [ClaudeBridge.Message] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if path != self.path || size < offset {
            self.path = path
            loadTail(handle, size: size)
        } else if size > offset {
            try? handle.seek(toOffset: offset)
            append((try? handle.readToEnd()) ?? Data(), startingAt: offset)
        }
        return messages
    }

    /// First read of a file: widen the window from the end until it holds enough messages.
    private func loadTail(_ handle: FileHandle, size: UInt64) {
        var window: UInt64 = 1_000_000
        while true {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            var data = (try? handle.readToEnd()) ?? Data()
            var base = start
            if start > 0 {                                  // drop the partial first line
                guard let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) else {
                    if window >= 48_000_000 { break }
                    window *= 4
                    continue
                }
                base += UInt64(firstNewline - data.startIndex + 1)
                data = data[(firstNewline + 1)...]
            }
            messages = []
            offset = base
            append(data, startingAt: base)
            if messages.count >= 12 || start == 0 || window >= 48_000_000 { break }
            window *= 4
        }
    }

    private func append(_ data: Data, startingAt base: UInt64) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        messages.append(contentsOf: ClaudeBridge.parse(complete.split(separator: UInt8(ascii: "\n"))))
        if messages.count > keep { messages.removeFirst(messages.count - keep) }
        offset = base + UInt64(complete.count)
    }
}
