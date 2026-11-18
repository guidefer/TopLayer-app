import AppKit
import Combine
import Foundation
import SwiftUI

/// Single source of truth for the overlay. Main thread only.
///
/// The class is split by concern:
///   Store.swift            state, panel size, notifications, selection, sending
///   Store+Codex.swift      the Codex daemon: thread list, reading, replies, approvals
///   Store+Claude.swift     Claude sessions: registry, transcripts, the hook inbox, permissions
///   Store+GroupChat.swift  how group chat messages reach a thread (the rules live in GroupChatBroker)
///
/// Views read the `@Published` state and call the actions. Everything below the
/// "Working state" line belongs to the Store+ files and is only non-private because
/// Swift extensions in other files could not reach it otherwise.
final class Store: ObservableObject {
    /// The size the user asked for. Keyboard focus follows this at once.
    @Published var mode: PanelMode = .collapsed
    /// What is drawn. Opening and closing play as a sequence (see `setMode`), so for a
    /// moment this lags behind `mode`: the header is still a bar while the pieces under
    /// it leave, and only then turns back into the squircle.
    @Published private(set) var squircle = true
    /// The last piece of the cascade that is drawn; every piece up to it is showing.
    @Published private(set) var shown = 0
    private var sequence = 0
    @Published var peek: Peek?
    @Published var corner: Corner = Corner(rawValue: UserDefaults.standard.string(forKey: "corner") ?? "") ?? .topRight {
        didSet { UserDefaults.standard.set(corner.rawValue, forKey: "corner") }
    }
    /// Sidebar sections the user has folded away.
    @Published var collapsedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections") }
    }
    var lastOpenMode: PanelMode = .open
    /// The size the views and the window are laid out for.
    var drawnMode: PanelMode { squircle ? .collapsed : mode == .collapsed ? lastOpenMode : mode }
    func isShown(_ piece: Piece) -> Bool { shown >= piece.rawValue }
    /// Usable size of the screen the overlay is on; the window keeps this current.
    @Published var visibleSize = CGSize(width: 1440, height: 900)
    /// Called just before an animated change, so the window can give the content room
    /// to move in while it still shows the old state.
    var makeRoom: (() -> Void)?
    /// Called after one, with how long the content needs before the window may shrink
    /// back around it.
    var settleWindow: ((TimeInterval) -> Void)?
    /// Unsent reply text per thread. Its own object, so typing redraws only the reply field.
    let drafts = Drafts()
    /// Anything other than the squircle counts as "the user can see the conversation".
    var expanded: Bool { mode != .collapsed }
    /// The Codex list: pinned threads, the thread last opened from a search, then the
    /// recent ones (see `ThreadShelf`).
    @Published var codexRows: [SessionRow] = []
    /// The models Codex offers for a new thread.
    @Published var codexModels: [ModelChoice] = []
    /// A model or effort chosen in the overlay for a Codex thread, waiting to go out with
    /// its next turn. Codex keeps using them for the turns after that.
    @Published var codexPending: [String: ThreadSettings] = [:]
    /// The model and effort each Codex thread last ran with, as Codex lists them.
    var codexSettings: [String: ThreadSettings] = [:]
    /// Each tool's plan limits as last read, why the last read failed, and which are
    /// being read now (see `Store+Usage`).
    @Published var usage: [AgentSource: UsageReport] = [:]
    @Published var usageProblem: [AgentSource: String] = [:]
    @Published var usageLoading = Set<AgentSource>()
    /// The section whose usage detail is open, and when each reading was last tried.
    @Published var usageShown: AgentSource?
    var usageTried: [AgentSource: Date] = [:]
    /// True while a new thread is being created.
    @Published var creating = false
    /// What the new-thread form has to say: why it failed, or what happens next.
    @Published var newThreadNote: String?
    /// A background session that was started but never appeared; its terminal can be opened.
    @Published var stuckCLI: String?
    /// Claude sessions TopLayer started with the claude command.
    @Published var cliSessions: [ClaudeCLI.Started] = UserDefaults.standard.data(forKey: "cliSessions")
        .flatMap { try? JSONDecoder().decode([ClaudeCLI.Started].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(cliSessions), forKey: "cliSessions") }
    }
    var pendingCLI: (id: String, since: Date)?
    /// The screen sessions that are alive, and whether each background session is in a
    /// turn. Kept by TopLayer itself: a session started with the claude command is not
    /// always in Claude's own list of running sessions, so the overlay cannot rely on
    /// that list for the sessions it started.
    var aliveScreens = Set<String>()
    var cliStatus: [String: String] = [:]
    var lastFolder = UserDefaults.standard.dictionary(forKey: "lastFolder") as? [String: String] ?? [:]
    /// The searches that are open, by section.
    @Published var searches: [AgentSource: ThreadSearch] = [:]
    /// The Claude list: pinned sessions, the session last opened from a search, then the
    /// running ones. A pinned or searched-for session that has ended is still listed,
    /// read-only.
    @Published var claudeRows: [SessionRow] = []
    var runningClaudeRows: [SessionRow] { claudeRows.filter { !$0.ended } }
    @Published var selectedId: String? {
        didSet {
            // Remember the open thread (not a web page) for the next launch.
            let keep = selectedId.flatMap { $0.hasPrefix("web:") ? nil : $0 }
            UserDefaults.standard.set(keep, forKey: "selectedId")
        }
    }
    @Published var messages: [ChatMessage] = []
    @Published var streaming = ""
    @Published var sending = false
    @Published var codexStatus = "connecting…"
    @Published var codexConnected = false
    @Published var unreadCount = 0
    @Published var approvals: [PendingApproval] = []
    @Published var notice: String?
    /// Codex threads with a message of ours waiting in the owner's queue.
    @Published var queuedThreadIds = Set<String>()
    /// Claude permission prompts waiting for an answer from the overlay.
    @Published var permissions: [ClaudeBridge.PermissionRequest] = []
    /// Group chats and their rules. Its changes are republished here, so views that
    /// watch the store redraw for them too.
    let groupChats = GroupChatBroker()
    var groupChatSink: AnyCancellable?
    /// Checks and repairs what TopLayer depends on outside itself.
    let health = HealthMonitor()
    var healthSink: AnyCancellable?
    /// What you choose in the settings window.
    let preferences = Preferences()
    var preferencesSink: AnyCancellable?
    /// Opens the settings window on its Setup tab; set by the app delegate.
    var openSettings: () -> Void = {}
    var codexVersion: String? { codex.serverVersion }
    /// Thread lists in a row that came back unusable: a sign the protocol changed.
    var codexListFailures = 0
    /// Sessions that ended a turn without their hook reporting it.
    var hookSilentSessions = Set<String>()
    var hookMisses: [String: Int] = [:]             // turns in a row that ended without the hook reporting
    var lastHookStop: [String: Date] = [:]
    /// Group chat messages dropped for a Claude session, waiting for the hook's receipt.
    var claudeDeliveries: [(sessionId: String, file: String, status: (String) -> Void)] = []
    /// Group chat messages waiting in a Codex thread's queue: submission id -> (thread, status callback).
    var pendingQueueStatus: [String: (threadId: String, status: (String) -> Void)] = [:]


    // MARK: Working state (used by the Store+ files, not by views)

    let codex = CodexClient()
    var resumedThreads = Set<String>()      // threads this connection is subscribed to
    var ownTurnThreads = Set<String>()      // threads with a turn we started
    // Threads running in the Codex app live in the app's own server process, so the
    // daemon reports them as "notLoaded" and sends no events. Their rollout file on
    // disk is the only live signal, so activity is inferred from it.
    var codexPaths: [String: String] = [:]          // threadId -> rollout file
    var codexRecent: [SessionRow] = []              // what the daemon last listed, newest first
    var codexShelf = Store.loadShelf("codexShelf") {
        didSet { saveShelf(codexShelf, was: oldValue, "codexShelf") }
    }
    var claudeLive: [SessionRow] = []               // the sessions running now
    var claudeShelf = Store.loadShelf("claudeShelf") {
        didSet { saveShelf(claudeShelf, was: oldValue, "claudeShelf") }
    }
    var searchRun: [AgentSource: Int] = [:]
    var searchIndex: [AgentSource: [SessionRow]] = [:]      // everything findable, while a search is open

    private static func loadShelf(_ key: String) -> ThreadShelf {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ThreadShelf.self, from: $0) } ?? ThreadShelf()
    }

    private func saveShelf(_ shelf: ThreadShelf, was old: ThreadShelf, _ key: String) {
        guard shelf != old else { return }
        objectWillChange.send()         // a pin shows on its row even when the list's order is unchanged
        UserDefaults.standard.set(try? JSONEncoder().encode(shelf), forKey: key)
    }
    var codexDaemonStatus: [String: String] = [:]
    /// When the connection to Codex's background service was lost (or TopLayer started
    /// without one), and how often TopLayer has tried to start the service since.
    var codexDownSince: Date? = Date()
    var codexStartAttempts = 0
    var codexLastStartAttempt: Date?
    var codexWorking = Set<String>()                // rollout written to recently
    var codexChecking = Set<String>()
    var codexLoadedStamp: Date?
    /// Messages handed to a thread's queue because another process owns the thread:
    /// threadId -> (queued submission id, when, whether the slow-pickup warning was shown).
    var codexQueued: [String: (id: String, since: Date, warned: Bool)] = [:]
    var codexQueueChecking = Set<String>()
    var codexLoadInFlight = false
    var claudeStatus: [String: String] = [:]
    var claudeSessions: [String: ClaudeBridge.Session] = [:]
    var transcriptStamp: Date?
    let transcript = TranscriptReader()
    let transcriptQueue = DispatchQueue(label: "toplayer.transcript", qos: .userInitiated)
    /// Replies sent through the hook inbox. They reach Claude as hook text, not as a
    /// user entry in the transcript, so the overlay keeps its own copy to display.
    var sentReplies: [String: [SentReply]] = Store.loadSentReplies()
    var sentRepliesSave: DispatchWorkItem?
    /// Threads that were unread when TopLayer last quit, applied as each list first loads.
    var restoredUnread = Set(UserDefaults.standard.stringArray(forKey: "unreadRows") ?? [])
    /// The thread that was open when TopLayer last quit, reselected once it appears.
    var restoredSelection = UserDefaults.standard.string(forKey: "selectedId")
    /// True while catching up on hook events from when TopLayer was not running.
    var catchingUp = false
    /// Where reading of the hook event log has got to. It starts from where the last run
    /// stopped, so turns that finished while TopLayer was closed still show as unread.
    var eventsOffset: UInt64 = Store.savedEventsOffset() {
        didSet { UserDefaults.standard.set(Double(eventsOffset), forKey: "eventsOffset") }
    }
    /// Sessions whose hook reports events, so status-file guesses are not needed for them.
    var hookEventSessions = Set<String>()
    var timer: Timer?
    var tick = 0

    var selectedRow: SessionRow? {
        (codexRows + claudeRows).first { $0.id == selectedId }
    }

    func start() {
        codex.onState = { [weak self] ok, text in
            guard let self else { return }
            let wasConnected = self.codexConnected
            self.codexConnected = ok
            self.codexStatus = text
            if ok {
                self.codexDownSince = nil
                self.codexStartAttempts = 0
                self.codexLastStartAttempt = nil
            } else if self.codexDownSince == nil {
                self.codexDownSince = Date()
            }
            if ok && !wasConnected {
                self.resumedThreads.removeAll()
                self.refreshCodex()
            }
            log("codex: \(text)")
        }
        codex.onNotification = { [weak self] method, params in self?.handleCodex(method, params) }
        codex.onServerRequest = { [weak self] id, method, params in self?.handleCodexRequest(id, method, params) }
        codex.start()

        ClaudeBridge.heartbeat()
        refreshClaude()
        pollHookEvents()        // catch up on what happened while TopLayer was closed
        groupChats.transport = self
        groupChats.notify = { [weak self] text, rowId in self?.addEvent(text, rowId: rowId) }
        groupChats.animate = { [weak self] change in
            if let self { self.animate(change) } else { change() }
        }
        groupChatSink = groupChats.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        groupChats.start()
        preferencesSink = preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        unreadCount = UserDefaults.standard.integer(forKey: "unreadCount")
        health.store = self
        healthSink = health.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        health.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            self.refreshClaude()
            ClaudeBridge.heartbeat()
            self.checkReceipts()
            self.pollHookEvents()
            self.pollPermissions()
            self.checkClaudeDeliveries()
            self.watchLinkQueue()
            self.watchCodexRollouts()
            self.startCodexDaemonIfDown()
            self.watchPendingCLI()
            if self.tick % 4 == 0 { self.checkCLISessions() }
            if self.tick % 2 == 0 { self.watchCodexQueue() }
            if self.tick % 3 == 0 { self.refreshCodex() }
            if self.tick % 8 == 0 { self.health.refresh() }
            if self.tick % 10 == 2 { self.refreshUsageIfStale() }
        }
    }

    /// Applies a change that moves or resizes the overlay.
    ///
    /// The window is resized first, on its own and without animation, and only then does
    /// the content animate inside it. Doing both in one step makes SwiftUI animate where
    /// the content sits in the window as well, which shows as a jump.
    func animate(_ change: () -> Void) {
        animate(with: Motion.panel, settle: Motion.settle, change)
    }

    func animate(with animation: Animation, settle: TimeInterval, _ change: () -> Void) {
        makeRoom?()
        withAnimation(animation) { change() }
        settleWindow?(settle)
    }

    /// Opening and closing are sequences, not one animation.
    ///
    /// Opening: the squircle becomes the header, then the pieces follow one after another
    /// (group chat, Claude, Codex, the conversation). Closing plays that back, faster:
    /// the pieces leave in the opposite order and the header turns into the squircle last.
    /// A new request cancels the steps still waiting and carries on from what is drawn.
    func setMode(_ new: PanelMode) {
        guard new != mode else { return }
        usageShown = nil
        sequence += 1
        let run = sequence
        let old = mode
        let everything = Piece.conversation.rawValue
        let present = Piece.allCases.filter { piece in
            switch piece {
            case .group: !groupChats.chats.isEmpty
            case .conversation: hasConversation
            default: true
            }
        }
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if new == .collapsed {
            mode = new
            let leaving = present.filter { isShown($0) }.reversed()
            if calm || leaving.isEmpty {
                animate(with: Motion.close, settle: Motion.closeSettle) { squircle = true; shown = 0 }
                return
            }
            makeRoom?()
            for (index, piece) in leaving.enumerated() {
                step(run, after: Motion.closeStep * Double(index), Motion.close) { self.shown = piece.rawValue - 1 }
            }
            let last = Motion.closeStep * Double(leaving.count)
            step(run, after: last, Motion.close) { self.squircle = true; self.shown = 0 }
            settleWindow?(last + Motion.closeSettle)
            return
        }

        lastOpenMode = new
        guard old == .collapsed || squircle else {
            animate { mode = new; shown = everything }  // open <-> expanded: one move
            return
        }
        let arriving = present.filter { !isShown($0) }
        animate(with: Motion.panel, settle: Motion.openStep * Double(arriving.count) + Motion.settle) {
            peek = nil
            markAllSeen()
            mode = new
            squircle = false
            if calm { shown = everything }
        }
        guard !calm else { return }
        for (index, piece) in arriving.enumerated() {
            let value = index == arriving.count - 1 ? everything : piece.rawValue
            step(run, after: Motion.openStep * Double(index + 1), Motion.panel) { self.shown = value }
        }
        if arriving.isEmpty { shown = everything }
    }

    /// One step of an opening or closing sequence, dropped if a newer request has started.
    private func step(_ run: Int, after delay: TimeInterval, _ animation: Animation, _ change: @escaping () -> Void) {
        let work = { [weak self] in
            guard let self, self.sequence == run else { return }
            withAnimation(animation) { change() }
        }
        if delay <= 0 { work() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Squircle click and the main shortcut: collapsed <-> the last open size.
    func toggle() { setMode(mode == .collapsed ? lastOpenMode : .collapsed) }

    func toggleExpanded() { setMode(mode == .expanded ? .open : .expanded) }

    /// Escape: expanded -> open -> collapsed.
    func stepBack() {
        if usageShown != nil { usageShown = nil; return }       // Escape closes the usage detail first
        if endSearches() { return }                             // then a search
        switch mode {
        case .expanded: setMode(.open)
        case .open: setMode(.collapsed)
        case .collapsed: break
        }
    }

    func toggleSection(_ name: String) {
        // Folding a section away closes its search with it.
        if let source = AgentSource(rawValue: name), isSearching(source), !collapsedSections.contains(name) { endSearch(source) }
        animate {
            if collapsedSections.contains(name) { collapsedSections.remove(name) } else { collapsedSections.insert(name) }
        }
    }

    /// Opens the thread a notification was about.
    func open(rowId: String) {
        select(rowId: rowId)
        setMode(lastOpenMode)
    }

    func select(rowId: String) {
        if let chat = groupChats.chats.first(where: { $0.rowId == rowId }) {
            selectChat(chat.id)
        } else if let row = (claudeRows + codexRows).first(where: { $0.id == rowId }) {
            select(row)
        }
    }

    // MARK: Keyboard

    /// Everything selectable in the sidebar, top to bottom, skipping folded sections.
    var navigationOrder: [String] {
        var ids = [String]()
        if !collapsedSections.contains("group") { ids += groupChats.chats.map(\.rowId) }
        if !collapsedSections.contains("Claude") { ids += claudeRows.map(\.id) }
        if !collapsedSections.contains("Codex") { ids += codexRows.map(\.id) }
        return ids
    }

    /// Whether a thread is asking you to approve something: a Claude permission prompt
    /// or a Codex approval.
    func asksPermission(_ rowId: String) -> Bool {
        permissions.contains { "claude:\($0.sessionId)" == rowId } || approvals.contains { "codex:\($0.threadId)" == rowId }
    }

    /// Whether a thread is waiting on you: it asks permission, it holds a group chat
    /// message for approval, or it finished a turn you have not looked at. A thread that
    /// has gone back to work is not waiting on you, whatever it finished earlier.
    func needsYou(_ rowId: String) -> Bool {
        if asksPermission(rowId) { return true }
        if let chat = groupChats.chats.first(where: { $0.rowId == rowId }) { return chat.pendingApprovals > 0 }
        guard let row = (claudeRows + codexRows).first(where: { $0.id == rowId }) else { return false }
        return row.unread && !row.isBusy
    }

    /// Moves the selection up or down the sidebar, wrapping at the ends. With
    /// `onlyNeedingYou`, it skips to the next thread that is waiting on you.
    @discardableResult
    func selectAdjacent(_ step: Int, onlyNeedingYou: Bool = false) -> Bool {
        let order = navigationOrder
        guard !order.isEmpty else { return false }
        let start = selectedId.flatMap { order.firstIndex(of: $0) }
        for offset in 1...order.count {
            let index = start.map { (($0 + step * offset) % order.count + order.count) % order.count }
                ?? (step > 0 ? offset - 1 : order.count - offset)
            if !onlyNeedingYou || needsYou(order[index]) {
                select(rowId: order[index])
                return true
            }
        }
        return false
    }

    /// Answers whatever is waiting for a yes or no, most urgent first: a Claude permission
    /// prompt, then a Codex approval in the open thread, then a held group chat message.
    @discardableResult
    func answerPending(approve: Bool) -> Bool {
        if let request = permissions.first {
            answer(request, approve ? "allow" : "deny")
            return true
        }
        if let approval = approvals.first {
            resolve(approval, accept: approve)
            return true
        }
        if let chat = selectedChat, let held = chat.messages.first(where: \.needsApproval) {
            if approve { groupChats.approve(held.id, in: chat.id) } else { groupChats.reject(held.id, in: chat.id) }
            return true
        }
        return false
    }

    func showPeek(_ text: String, rowId: String) {
        let new = Peek(text: text, rowId: rowId)
        animate { peek = new }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.peek?.id == new.id else { return }
            self.animate { self.peek = nil }
        }
    }

    func markAllSeen() {
        unreadCount = 0
        saveUnread()
    }

    func saveUnread() {
        UserDefaults.standard.set((claudeRows + codexRows).filter(\.unread).map(\.id), forKey: "unreadRows")
        UserDefaults.standard.set(unreadCount, forKey: "unreadCount")
    }

    /// Where to resume the hook event log. If the log is much longer than where we
    /// stopped (TopLayer was closed for a long time), skip to the end instead of replaying it all.
    static func savedEventsOffset() -> UInt64 {
        let size = ClaudeBridge.eventsFileSize()
        guard let saved = UserDefaults.standard.object(forKey: "eventsOffset") as? Double else { return size }
        let offset = UInt64(max(0, saved))
        return offset <= size && size - offset < 2_000_000 ? offset : size
    }

    /// Reselects the thread that was open last time, once its list has loaded.
    func restoreSelectionIfNeeded() {
        guard let wanted = restoredSelection, selectedId == nil else {
            if selectedId != nil { restoredSelection = nil }
            return
        }
        let known = (claudeRows + codexRows).contains { $0.id == wanted } || groupChats.chats.contains { $0.rowId == wanted }
        guard known else { return }
        restoredSelection = nil
        select(rowId: wanted)
    }

    // MARK: Replies sent to Claude from the overlay

    private static let sentPath = NSHomeDirectory() + "/.toplayer/sent.json"

    static func loadSentReplies() -> [String: [SentReply]] {
        guard let data = FileManager.default.contents(atPath: sentPath),
              let saved = try? JSONDecoder().decode([String: [SentReply]].self, from: data) else { return [:] }
        // Anything this old has long since been delivered or abandoned.
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        return saved.mapValues { $0.filter { $0.time > cutoff } }.filter { !$0.value.isEmpty }
    }

    func saveSentReplies() {
        sentRepliesSave?.cancel()
        let snapshot = sentReplies
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: URL(fileURLWithPath: Store.sentPath), options: .atomic)
        }
        sentRepliesSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func addEvent(_ text: String, rowId: String) {
        log("event: \(text)")
        if !(expanded && selectedId == rowId) {
            unreadCount += 1
            setUnread(rowId, true)
            if preferences.playSound, !catchingUp { NSSound(named: "Tink")?.play() }
        }
        if mode == .collapsed, !catchingUp { showPeek(text, rowId: rowId) }
        saveUnread()
    }

    func setUnread(_ rowId: String, _ value: Bool) {
        if let i = codexRows.firstIndex(where: { $0.id == rowId }) { codexRows[i].unread = value }
        if let i = claudeRows.firstIndex(where: { $0.id == rowId }) { claudeRows[i].unread = value }
        saveUnread()
    }

    // MARK: Selection

    func select(_ row: SessionRow) {
        guard row.id != selectedId else { return }
        animate { selectedId = row.id }
        messages = []
        streaming = ""
        notice = nil
        transcriptStamp = nil
        codexLoadedStamp = nil
        setUnread(row.id, false)
        switch row.source {
        case .codex: loadCodexThread(row.rawId)
        case .claude: loadClaudeTranscript(force: true)
        }
    }

    // MARK: Navigation

    /// Shows an environment's own web client in the conversation pane.
    func showWeb(_ source: AgentSource) {
        animate { selectedId = "web:\(source.rawValue)" }
        messages = []
        streaming = ""
        notice = nil
    }

    /// Whether there is anything to show beside the sidebar. With nothing selected the
    /// overlay is just the sidebar.
    var hasConversation: Bool {
        selectedRow != nil || webPaneSource != nil || selectedChat != nil || newThreadSource != nil
    }

    /// The group chat showing in the conversation pane, if one is.
    var selectedChat: GroupChat? {
        guard let selectedId else { return nil }
        return groupChats.chats.first { $0.rowId == selectedId }
    }

    func selectChat(_ id: String) {
        animate { selectedId = "chat:\(id)" }
        messages = []
        streaming = ""
        notice = nil
    }

    func deselect() {
        animate { selectedId = nil }
        messages = []
        streaming = ""
        notice = nil
    }

    var webPaneSource: AgentSource? {
        selectedId == "web:Claude" ? .claude : selectedId == "web:Codex" ? .codex : nil
    }

    // MARK: Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, let row = selectedRow else { return }
        notice = nil
        switch row.source {
        case .codex:
            sending = true
            streaming = ""
            messages.append(ChatMessage(id: UUID().uuidString, role: "user", text: trimmed))
            sendCodex(row.rawId, trimmed)
        case .claude:
            guard row.canReply else {
                notice = "This session is not running the TopLayer hook. Use the Web tab to reply."
                return
            }
            sendClaude(row, trimmed)
        }
    }
}
