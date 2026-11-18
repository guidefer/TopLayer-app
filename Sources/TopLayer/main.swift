import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Borderless panel that floats above every Space, including other apps'
/// fullscreen Spaces, and can take keyboard input without activating this app
/// (so the app underneath stays frontmost).
final class OverlayPanel: NSPanel {
    var allowsKey = false
    var onEscape: (() -> Void)?
    /// Offered every key press first; returns true if it handled it.
    var onKeyDown: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // Liquid Glass draws its own; a window shadow would box it in
        isReleasedWhenClosed = false
        animationBehavior = .none       // it is taken off screen and put back to give up the keyboard
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// The reply field is usually focused, and it would treat ⌥↓ or ⌘↩ as editing keys.
    /// Looking at key presses here, before they are dispatched, keeps the panel's own
    /// shortcuts working while you type.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let panel = OverlayPanel()
    private var statusItem: NSStatusItem?
    private lazy var settings = SettingsWindowController(store: store)
    private lazy var welcome = OnboardingWindowController(store: store)
    private var cancellables = Set<AnyCancellable>()
    private var hotKeys: [EventHotKeyRef?] = []
    private var hidden = false
    private var applyingFrame = false
    private var snapWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var lastLayout = ""
    /// The SwiftUI content: as large as the screen and fixed to it, whatever the window does.
    private var canvas: NSView?
    /// True while the window is enlarged for an animation.
    private var roomy = false
    private var registeredShortcuts: [Shortcut] = []
    private var alignWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: RootView(store: store, showMenu: { [weak self] event, view in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.buildMenu(), with: event, for: view)
        }))
        // The SwiftUI content is not the window's content view. It is a canvas the size of
        // the screen that stays put on screen, and the window is a frame that moves over
        // it (see `apply`). SwiftUI therefore never sees the window change size.
        hosting.sizingOptions = []
        hosting.autoresizingMask = []
        let container = NSView()
        container.addSubview(hosting)
        panel.contentView = container
        canvas = hosting
        panel.onEscape = { [weak self] in self?.store.stepBack() }
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        // An animated change gets the whole screen to move in first and the window fits
        // itself around the result afterwards; everything else (a thread list growing,
        // say) is picked up by the store observer below.
        store.makeRoom = { [weak self] in self?.makeRoom() }
        store.settleWindow = { [weak self] delay in self?.settle(after: delay) }
        store.openSettings = { [weak self] in self?.settings.show(.setup) }
        store.preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &cancellables)
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: nil)
        installStatusItem()
        installShortcutHandler()
        store.start()
        applyPreferences()
        runDebugSwitches()
        // On a Mac where TopLayer was never set up, start with the welcome guide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.welcome.showIfNeeded() }
    }

    /// Environment switches for checking states and animations without clicking:
    ///   TOPLAYER_MODE=open|expanded         start in that size
    ///   TOPLAYER_DEBUG_SELECT=claude|codex  select the first thread on that side
    ///   TOPLAYER_DEBUG_SEQUENCE=4:open,8:select,12:collapsed   timed steps, in seconds
    ///       (also: fold, settings, setup, key-opt-down and the like; dragtext, which
    ///       drags the mouse across the longest message on screen; search-<text> and
    ///       csearch-<text> (search Codex or Claude), pick and pickended (open the first
    ///       search result, or the first read-only one) and pin (pin or unpin the open thread))
    ///   TOPLAYER_DEBUG_SLOW=5               stretch every animation
    ///   TOPLAYER_DEBUG_LINK=<session id>    link that session to a throwaway Codex thread
    ///   TOPLAYER_DEBUG_CLAUDE_ARGS=...      extra arguments for sessions started with the claude command
    ///   TOPLAYER_DEBUG_CLIPS=1              log every scroll position, to spot ones between pixels
    ///   TOPLAYER_DEBUG_SETUP_ROOT=<folder>  the welcome guide reads and edits copies in that folder
    ///       (settings.json, CLAUDE.md, config.toml, bin, and bundled as the scripts to install),
    ///       never the real files. Steps: welcome, welcome-next, welcome-run
    ///   TOPLAYER_DEBUG_FOUND=claude,codex   which tools the welcome guide finds ("none" for neither)
    private func runDebugSwitches() {
        let env = ProcessInfo.processInfo.environment
        if let root = env["TOPLAYER_DEBUG_SETUP_ROOT"] { welcome.targets = .scratch(root) }
        if let found = env["TOPLAYER_DEBUG_FOUND"] {
            let names = found.split(separator: ",").map(String.init)
            welcome.lookForTools = {
                FoundTools(claudeCommand: names.contains("claude"), claudeApp: names.contains("claude-app"),
                           codexCommand: names.contains("codex"), codexApp: names.contains("codex-app"))
            }
        }
        if let mode = env["TOPLAYER_MODE"].flatMap(PanelMode.init(rawValue:)) { store.setMode(mode) }
        let select: (String) -> Void = { [store] side in
            if let row = (side == "codex" ? store.codexRows : store.claudeRows).first { store.select(row) }
        }
        if let side = env["TOPLAYER_DEBUG_SELECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { select(side) }
        }
        for step in (env["TOPLAYER_DEBUG_SEQUENCE"] ?? "").split(separator: ",") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]) else { continue }
            let action = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [store] in
                log("debug step \(action)")
                switch action {
                case "select": select("claude")
                case "deselect": store.deselect()
                case "fold": store.toggleSection("Codex")
                case "settings": self.settings.show(.general)
                case "setup": self.settings.show(.setup)
                case "welcome": self.welcome.show()
                case "welcome-next":
                    if let model = self.welcome.model, let next = OnboardingModel.Page(rawValue: model.page.rawValue + 1) { model.page = next }
                case "welcome-run":
                    // Only against copies: a debug step must never edit the real files.
                    if self.welcome.targets != SetupTargets() { self.welcome.model?.run() }
                default:
                    if action.hasPrefix("key-") {
                        // Sends a real key event through the panel, e.g. key-opt-down, key-cmd-return.
                        let codes = ["down": kVK_DownArrow, "up": kVK_UpArrow, "return": kVK_Return,
                                     "period": kVK_ANSI_Period, "w": kVK_ANSI_W, "pagedown": kVK_PageDown,
                                     "pageup": kVK_PageUp, "home": kVK_Home, "end": kVK_End]
                        var flags: NSEvent.ModifierFlags = []
                        var code = 0
                        for part in action.dropFirst(4).split(separator: "-") {
                            switch part {
                            case "opt": flags.insert(.option)
                            case "cmd": flags.insert(.command)
                            case "shift": flags.insert(.shift)
                            default: code = codes[String(part)] ?? 0
                            }
                        }
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                        windowNumber: self.panel.windowNumber, context: nil, characters: "",
                                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                            self.panel.sendEvent(event)
                        }
                        let title = store.selectedRow?.title ?? store.selectedChat?.title ?? "nothing"
                        log("after \(action): selected=\(title) permissions=\(store.permissions.count)")
                    } else if action.hasPrefix("usage-") {
                        // usage-Claude opens that section's usage detail.
                        let source = AgentSource(rawValue: String(action.dropFirst(6))) ?? .codex
                        store.usageShown = source
                        store.refreshUsage(source, force: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            log("usage \(source.rawValue): \(store.usage[source]?.summary() ?? "none") problem=\(store.usageProblem[source] ?? "none") limits=\(store.usage[source]?.limits.map { "\($0.name) \($0.used)%" } ?? [])")
                        }
                    } else if action.hasPrefix("search-") || action.hasPrefix("csearch-") {
                        // Opens a section's search and types the rest: search-news for
                        // Codex, csearch-news for Claude.
                        let source: AgentSource = action.hasPrefix("c") ? .claude : .codex
                        store.beginSearch(source)
                        store.setSearch(source, String(action.split(separator: "-", maxSplits: 1).last ?? ""))
                    } else if action == "pick" || action == "pickended" {
                        // Opens the first search result; pickended, the first that is read-only.
                        let results = store.searches.values.flatMap(\.results)
                        log("search found \(results.count): \(results.prefix(6).map { $0.title + ($0.ended ? " (ended)" : "") })")
                        if let first = results.first(where: { action == "pick" || $0.ended }) { store.openSearchResult(first) }
                    } else if action == "pin" {
                        if let row = store.selectedRow { store.togglePin(row) }
                        log("pinned now: \((store.claudeRows + store.codexRows).filter { store.isPinned($0) }.map(\.title))")
                    } else if action.hasPrefix("newcodex-") || action.hasPrefix("newcli-") || action.hasPrefix("newform-") {
                        // newform-Claude shows the form; newcodex-<text> and newcli-<text>
                        // create a thread in the overlay's own project folder (set
                        // TOPLAYER_DEBUG_FOLDER for another) with that first message.
                        let text = String(action.split(separator: "-", maxSplits: 1).last ?? "")
                        let folder = env["TOPLAYER_DEBUG_FOLDER"] ?? NSHomeDirectory()
                        if action.hasPrefix("newform-") {
                            store.showNewThread(AgentSource(rawValue: text) ?? .codex)
                        } else if action.hasPrefix("newcodex-") {
                            // TOPLAYER_DEBUG_MODEL and TOPLAYER_DEBUG_EFFORT choose those for the test.
                            store.createCodexThread(folder: folder, prompt: text, model: env["TOPLAYER_DEBUG_MODEL"] ?? "",
                                                    effort: env["TOPLAYER_DEBUG_EFFORT"] ?? "")
                        } else {
                            store.createClaudeSession(folder: folder, prompt: text, target: .cli, model: env["TOPLAYER_DEBUG_MODEL"] ?? "",
                                                      effort: env["TOPLAYER_DEBUG_EFFORT"] ?? "")
                        }
                    } else if action.hasPrefix("setmodel-") || action.hasPrefix("seteffort-") {
                        // Chooses a model or effort for the open Codex thread's next turn.
                        guard let row = store.selectedRow, row.source == .codex else { return }
                        let value = String(action.split(separator: "-", maxSplits: 1).last ?? "")
                        if action.hasPrefix("setmodel-") { store.setCodexOption(row.rawId, model: value) } else { store.setCodexOption(row.rawId, effort: value) }
                    } else if action.hasPrefix("say-") {
                        // Sends a reply to the open thread, as typing it would.
                        store.send(String(action.dropFirst(4)))
                        log("said to \(store.selectedRow?.title ?? "nothing"): notice=\(store.notice ?? "none")")
                    } else if action == "state" {
                        log("claude rows: \(store.claudeRows.map { "\($0.title) [\($0.status)\($0.cli ? ", cli" : "")\($0.canReply ? ", reachable" : "")]" }) permissions=\(store.permissions.map(\.tool)) selected=\(store.selectedRow?.title ?? "none")")
                    } else if action == "dragtext" {
                        // A real mouse drag across the longest message on screen, from its
                        // first line to its last. For checking text selection.
                        var texts = [MessageTextView]()
                        func walk(_ view: NSView) {
                            // Fully inside the window, clear of the pane's header and reply field.
                            let room = NSRect(origin: .zero, size: self.panel.frame.size).insetBy(dx: 0, dy: 70)
                            if let text = view as? MessageTextView, room.contains(text.convert(text.bounds, to: nil)) {
                                texts.append(text)
                            }
                            view.subviews.forEach(walk)
                        }
                        if let content = self.panel.contentView { walk(content) }
                        guard let target = texts.max(by: { $0.string.count < $1.string.count }) else { return log("dragtext: no message fully on screen") }
                        let from = target.convert(NSPoint(x: 6, y: 6), to: nil)
                        let to = target.convert(NSPoint(x: target.bounds.maxX - 6, y: target.bounds.maxY - 6), to: nil)
                        func post(_ type: NSEvent.EventType, _ at: NSPoint) {
                            if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: self.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.postEvent(event, atStart: false)
                            }
                        }
                        post(.leftMouseDown, from)
                        for step in 1...8 {
                            let t = CGFloat(step) / 8
                            post(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                        }
                        post(.leftMouseUp, to)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let view = self.panel.firstResponder as? MessageTextView
                            let selected = view.map { $0.plainText(in: $0.selectedRange()) } ?? ""
                            log("dragtext: message has \(target.string.count) characters, selection has \(view?.selectedRange().length ?? -1), "
                                + "\(selected.components(separatedBy: "\n\n").count) paragraphs")
                        }
                    } else if let mode = PanelMode(rawValue: action) {
                        store.setMode(mode)
                    }
                }
            }
        }
        if env["TOPLAYER_DEBUG_CLIPS"] == "1" {
            // Reports where each scroll view is scrolled to, to spot positions between pixels.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [panel] _ in
                func walk(_ view: NSView) {
                    if let clip = view as? NSClipView {
                        let doc = clip.documentView?.frame ?? .zero
                        log("clip origin=(\(clip.bounds.origin.x), \(clip.bounds.origin.y)) size=\(clip.bounds.size) doc=\(doc.size) frameInWindow=\(clip.convert(clip.bounds, to: nil).origin)")
                    }
                    view.subviews.forEach(walk)
                }
                if let content = panel.contentView { walk(content) }
            }
        }
        if let claudeSessionId = env["TOPLAYER_DEBUG_LINK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [store] in store.debugLink(claudeSessionId: claudeSessionId) }
        }
        if env["TOPLAYER_DEBUG_CONTROL"] == "1" {
            // Drives the first group chat from a file, one command per line:
            //   post <text> | approve | reject | pause | resume | end | open
            //   set interval=<s> cap=<n> duration=<s> approval=on|off notify=on|off
            let path = NSHomeDirectory() + "/.toplayer/debug-command"
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [store] _ in
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(atPath: path)
                let broker = store.groupChats
                for line in text.split(separator: "\n") {
                    guard let chat = broker.chats.first else { return log("debug: no group chat") }
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    log("debug command \(line)")
                    switch parts[0] {
                    case "post": broker.post(parts.count > 1 ? parts[1] : "", in: chat.id)
                    case "approve": chat.messages.filter(\.needsApproval).forEach { broker.approve($0.id, in: chat.id) }
                    case "reject": chat.messages.filter(\.needsApproval).forEach { broker.reject($0.id, in: chat.id) }
                    case "pause": broker.setPaused(chat.id, true)
                    case "resume": broker.setPaused(chat.id, false)
                    case "end": broker.end(chat.id)
                    case "open": store.selectChat(chat.id); store.setMode(.open)
                    case "set":
                        var settings = chat.settings
                        for pair in (parts.count > 1 ? parts[1] : "").split(separator: " ") {
                            let kv = pair.split(separator: "=").map(String.init)
                            guard kv.count == 2 else { continue }
                            switch kv[0] {
                            case "interval": settings.minInterval = Double(kv[1]) ?? settings.minInterval
                            case "cap": settings.maxMessages = Int(kv[1]) ?? settings.maxMessages
                            case "duration": settings.duration = Double(kv[1]) ?? settings.duration
                            case "approval": settings.requireApproval = kv[1] == "on"
                            case "notify": settings.notifyAgents = kv[1] == "on"
                            default: break
                            }
                        }
                        broker.setSettings(chat.id, settings)
                    default: break
                    }
                }
            }
        }
    }

    // MARK: Layout: every size grows out of the chosen screen corner

    private var screen: NSScreen {
        if let name = UserDefaults.standard.string(forKey: "screen"),
           let saved = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return saved
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// The frame the window should end up with for the current state.
    private func targetFrame() -> NSRect {
        let visible = screen.visibleFrame
        if store.visibleSize != visible.size { store.visibleSize = visible.size }
        let size = PanelLayout.size(store)
        let margin = PanelLayout.margin
        let corner = store.corner
        return NSRect(x: corner.isRight ? visible.maxX - size.width - margin : visible.minX + margin,
                      y: corner.isTop ? visible.maxY - size.height - margin : visible.minY + margin,
                      width: size.width, height: size.height)
    }

    /// Where the content lives on screen: everything but a margin at the screen's edge.
    private var canvasFrame: NSRect {
        screen.visibleFrame.insetBy(dx: PanelLayout.margin, dy: PanelLayout.margin)
    }

    /// Opens the window over the whole canvas, so content can animate anywhere in it.
    /// The window is transparent and the content does not move, so nothing visibly changes.
    private func makeRoom() {
        settleWork?.cancel()
        settleWork = nil
        roomy = true
        guard !hidden else { return }
        apply(canvasFrame)
    }

    /// Fits the window around the content again once it has finished moving.
    private func settle(after delay: TimeInterval) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWork = nil
            self.roomy = false
            self.layout()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        layout()
    }

    /// Keeps the window fitted to the current state, and its keyboard focus in step with
    /// whether the overlay is open. While an animation has the window enlarged, the size
    /// is left alone.
    private func layout() {
        if !roomy { apply(targetFrame()) }

        let wantsKey = store.mode != .collapsed
        let key = "\(wantsKey)|\(hidden)"
        guard key != lastLayout else { return }
        lastLayout = key
        panel.allowsKey = wantsKey
        guard !hidden else { return }
        if wantsKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Dropping key status hands the keyboard back to the app underneath.
            if panel.isKeyWindow { panel.orderOut(nil) }
            panel.orderFrontRegardless()
        }
    }

    /// Moves the window, and moves the canvas the opposite way inside it so the content
    /// stays exactly where it is on screen.
    ///
    /// If the content were the window's content view, every resize would also be a
    /// SwiftUI layout change. One that lands in the same update as an animated state
    /// change gets animated with it: the content's position inside the window slides
    /// from its old value to its new one, which on screen is a jump away and a slide back.
    private func apply(_ frame: NSRect) {
        let visible = screen.visibleFrame
        if store.visibleSize != visible.size { store.visibleSize = visible.size }
        let inWindow = canvasFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        guard frame != panel.frame || canvas?.frame != inWindow else { return }
        applyingFrame = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false, animate: false)
        canvas?.frame = inWindow
        CATransaction.commit()
        panel.displayIfNeeded()
        applyingFrame = false
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        log("frame mode=\(store.mode.rawValue) "
            + "capture=\(Int(frame.minX)),\(Int(primaryHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
    }

    /// Keeps every scroll position in the overlay on a whole pixel.
    ///
    /// A scroll position can come to rest a fraction of a pixel off (the tail end of an
    /// animated scroll does this). On a display that is not Retina, everything inside is
    /// then drawn between pixels and the text looks smeared until something redraws it.
    /// Once scrolling has been still for a moment, this snaps it to the nearest pixel.
    @objc private func scrolled(_ note: Notification) {
        guard let clip = note.object as? NSClipView, clip.window === panel else { return }
        let key = ObjectIdentifier(clip)
        alignWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self, weak clip] in
            self?.alignWork[key] = nil
            guard let clip, let window = clip.window else { return }
            let scale = window.backingScaleFactor
            let origin = clip.bounds.origin
            let aligned = NSPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale)
            if abs(aligned.x - origin.x) > 0.001 || abs(aligned.y - origin.y) > 0.001 {
                clip.setBoundsOrigin(aligned)
            }
        }
        alignWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// After a drag, settle into the nearest corner of whichever screen it was dropped on.
    @objc private func panelMoved() {
        guard !applyingFrame else { return }
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 { return self.panelMoved() }   // still dragging
            let center = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            let target = NSScreen.screens.first { $0.frame.contains(center) } ?? self.screen
            UserDefaults.standard.set(target.localizedName, forKey: "screen")
            let right = center.x > target.visibleFrame.midX
            let top = center.y > target.visibleFrame.midY
            self.store.corner = top ? (right ? .topRight : .topLeft) : (right ? .bottomRight : .bottomLeft)
            self.lastLayout = ""
            self.layout()
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func screensChanged() {
        lastLayout = ""
        layout()
    }

    // MARK: Menu bar item (also the squircle's right-click menu)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "TopLayer")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add(hidden ? "Show TopLayer" : "Hide TopLayer", #selector(toggleHidden))
        _ = add(store.mode == .collapsed ? "Open" : "Collapse", #selector(toggleOpen))
        _ = add(store.mode == .expanded ? "Compact Size" : "Expand", #selector(toggleExpanded))
        menu.addItem(.separator())

        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let corners = NSMenu()
        for corner in Corner.allCases {
            let item = NSMenuItem(title: corner.title, action: #selector(pickCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = corner == store.corner ? .on : .off
            corners.addItem(item)
        }
        position.submenu = corners
        menu.addItem(position)
        menu.addItem(.separator())

        let reachable = store.runningClaudeRows.filter(\.canReply).count
        _ = add("Settings…", #selector(openSettings), key: ",")
        _ = add("Welcome Guide…", #selector(openWelcome))
        menu.addItem(.separator())
        _ = add("TopLayer: \(store.health.summary.lowercased())", nil)
        _ = add("Codex: \(store.codexConnected ? "connected" : store.codexStatus)", nil)
        _ = add("Claude: \(store.runningClaudeRows.count) running, \(reachable) reachable", nil)
        _ = add("Shortcuts: \(store.preferences.toggleShortcut.display) open · \(store.preferences.expandShortcut.display) expand · Esc back", nil)
        menu.addItem(.separator())
        _ = add("Restart TopLayer", #selector(restart))
        _ = add("Quit TopLayer", #selector(quit), key: "q")
        return menu
    }

    @objc private func openSettings() { settings.show(.general) }
    @objc private func openWelcome() { welcome.show() }

    @objc private func toggleHidden() {
        hidden.toggle()
        lastLayout = ""
        if hidden { panel.orderOut(nil) } else { layout() }
    }

    @objc private func toggleOpen() {
        if hidden { toggleHidden() }
        store.toggle()
    }

    @objc private func toggleExpanded() {
        if hidden { toggleHidden() }
        store.toggleExpanded()
    }

    @objc private func pickCorner(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let corner = Corner(rawValue: raw) {
            store.corner = corner
        }
    }

    /// For a bug or a freeze: start a fresh copy, then quit this one.
    @objc private func restart() {
        let bundle = Bundle.main.bundlePath
        let command = bundle.hasSuffix(".app")
            ? "sleep 0.7; /usr/bin/open -n \"\(bundle)\""
            : "sleep 0.7; \"\(CommandLine.arguments[0])\" >/dev/null 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Keys inside the panel

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(event.keyCode), flags) {
        case (kVK_DownArrow, [.option]): return store.selectAdjacent(1)
        case (kVK_UpArrow, [.option]): return store.selectAdjacent(-1)
        case (kVK_DownArrow, [.option, .shift]): return store.selectAdjacent(1, onlyNeedingYou: true)
        case (kVK_UpArrow, [.option, .shift]): return store.selectAdjacent(-1, onlyNeedingYou: true)
        case (kVK_Return, [.command]): return store.answerPending(approve: true)
        case (kVK_ANSI_Period, [.command]): return store.answerPending(approve: false)
        case (kVK_ANSI_W, [.command]):
            guard store.hasConversation else { return false }
            store.deselect()
            return true
        case (kVK_ANSI_Comma, [.command]):
            settings.show(.general)
            return true
        default:
            return scrollKey(Int(event.keyCode), flags)
        }
    }

    /// Scrolling the open conversation. Page Up, Page Down, Home and End always scroll.
    /// The arrow keys scroll only while the reply field is empty; once you have typed
    /// something they go back to moving the cursor.
    private func scrollKey(_ code: Int, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard store.selectedRow != nil || store.selectedChat != nil else { return false }   // not over a web page
        switch (code, flags) {
        case (kVK_PageDown, []): return TranscriptScroller.scroll(.pages(1))
        case (kVK_PageUp, []): return TranscriptScroller.scroll(.pages(-1))
        case (kVK_End, []): return TranscriptScroller.scroll(.bottom)
        case (kVK_Home, []): return TranscriptScroller.scroll(.top)
        default: break
        }
        let draft = store.selectedId.map { store.drafts[$0] } ?? ""
        guard draft.isEmpty else { return false }
        switch (code, flags) {
        case (kVK_DownArrow, []): return TranscriptScroller.scroll(.lines(1))
        case (kVK_UpArrow, []): return TranscriptScroller.scroll(.lines(-1))
        case (kVK_DownArrow, [.command]): return TranscriptScroller.scroll(.bottom)
        case (kVK_UpArrow, [.command]): return TranscriptScroller.scroll(.top)
        default: return false
        }
    }

    // MARK: Preferences that the window itself has to act on

    private func applyPreferences() {
        let preferences = store.preferences
        // Screen recordings and shared screens skip a window that opts out.
        panel.sharingType = preferences.hideFromScreenSharing ? .none : .readOnly
        let wanted = preferences.recording ? [] : [preferences.toggleShortcut, preferences.expandShortcut]
        if wanted != registeredShortcuts { registerShortcuts(wanted) }
        layout()
    }

    // MARK: Global shortcuts via Carbon: no Accessibility permission needed

    private func installShortcutHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let id = pressed.id
            DispatchQueue.main.async {
                if id == 1 { delegate.toggleOpen() } else { delegate.toggleExpanded() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Replaces the registered shortcuts. An empty list just releases them, which is what
    /// happens while a shortcut field in settings is listening for keys.
    private func registerShortcuts(_ shortcuts: [Shortcut]) {
        for ref in hotKeys { if let ref { UnregisterEventHotKey(ref) } }
        hotKeys = []
        registeredShortcuts = shortcuts
        var failed = [String]()
        for (index, shortcut) in shortcuts.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x544F_504C), id: UInt32(index + 1))    // 'TOPL'
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status != noErr {
                failed.append(shortcut.display)
                log("shortcut \(shortcut.display) could not be registered: \(status)")
            }
            hotKeys.append(ref)
        }
        if !shortcuts.isEmpty {
            let problem = failed.isEmpty ? nil : "\(failed.joined(separator: " and ")) could not be set. Another app may already use it."
            if store.preferences.shortcutProblem != problem { store.preferences.shortcutProblem = problem }
            log("shortcuts: \(shortcuts.map(\.display).joined(separator: ", "))")
        }
    }
}

// `TopLayer --setup-test <dir>` exercises the installers on copies inside <dir> and exits.
// It never touches the real Claude or Codex files.
if let flag = CommandLine.arguments.firstIndex(of: "--setup-test"), CommandLine.arguments.count > flag + 1 {
    SetupSelfTest.run(in: CommandLine.arguments[flag + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// An accessory app shows no menu bar, but ⌘C/⌘V/⌘A still route through the main
// menu's key equivalents, which the reply field and the web sign-in need.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
editItem.submenu = editMenu
let mainMenu = NSMenu()
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

app.run()
