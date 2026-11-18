import AppKit
import SwiftUI

/// The state behind the welcome guide: what was found on this Mac, which pieces you
/// chose to add, and how adding them went. Main thread only.
final class OnboardingModel: ObservableObject {
    enum Page: Int { case welcome, connect, ready }

    @Published var page = Page.welcome
    @Published private(set) var found: FoundTools
    @Published private(set) var steps: [SetupStep]
    @Published var chosen: Set<SetupPiece>
    @Published private(set) var outcomes: [SetupPiece: Onboarding.Outcome] = [:]

    let targets: SetupTargets
    let health: HealthMonitor
    let preferences: Preferences
    private let lookForTools: () -> FoundTools
    /// Called when the guide's last button is pressed.
    var finish: () -> Void = {}

    init(health: HealthMonitor, preferences: Preferences, targets: SetupTargets, lookForTools: @escaping () -> FoundTools) {
        self.health = health
        self.preferences = preferences
        self.targets = targets
        self.lookForTools = lookForTools
        let found = lookForTools()
        let steps = Onboarding.steps(found: found, targets: targets)
        self.found = found
        self.steps = steps
        chosen = Set(steps.filter { !$0.inPlace }.map(\.piece))
    }

    /// Looks for the tools again, after you installed one.
    func look() {
        found = lookForTools()
        steps = Onboarding.steps(found: found, targets: targets)
        chosen = Set(steps.filter { !$0.inPlace }.map(\.piece))
        outcomes = [:]
        health.refreshTools(force: true)
    }

    /// The pieces still to add: chosen, and not there yet.
    var remaining: [SetupPiece] { steps.filter { !$0.inPlace && chosen.contains($0.piece) }.map(\.piece) }
    var ran: Bool { !outcomes.isEmpty }

    func run() {
        let results = Onboarding.run(remaining, targets: targets)
        outcomes.merge(results) { _, new in new }
        steps = Onboarding.steps(found: found, targets: targets)
        for (piece, outcome) in results { log("welcome: \(piece.rawValue): \(outcome)") }
        health.refresh()
    }

    func has(_ piece: SetupPiece) -> Bool { steps.contains { $0.piece == piece && $0.inPlace } }
}

/// The welcome guide's window: an ordinary window, like Settings.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var model: OnboardingModel?
    private let store: Store
    /// Replaced by the debug switches, to try the guide against copies of the files.
    var targets = SetupTargets()
    var lookForTools: () -> FoundTools = FoundTools.look

    init(store: Store) { self.store = store }

    /// Shows the guide at launch if it was never finished and something is missing.
    func showIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Onboarding.doneKey) { return }
        if Onboarding.isNeeded(found: lookForTools(), targets: targets, done: false) {
            show()
        } else {
            // Already set up, by hand or by an earlier version: never ask.
            defaults.set(true, forKey: Onboarding.doneKey)
        }
    }

    func show() {
        if window == nil {
            let model = OnboardingModel(health: store.health, preferences: store.preferences,
                                        targets: targets, lookForTools: lookForTools)
            model.finish = { [weak self] in self?.finished() }
            self.model = model
            let new = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                               styleMask: [.titled, .closable, .fullSizeContentView],
                               backing: .buffered, defer: false)
            new.title = "Welcome to TopLayer"
            new.titleVisibility = .hidden
            new.titlebarAppearsTransparent = true
            new.isMovableByWindowBackground = true
            new.isReleasedWhenClosed = false
            new.delegate = self
            new.contentView = NSHostingView(rootView: OnboardingView(model: model, health: store.health))
            new.center()
            window = new
            store.health.refreshTools(force: true)
            store.health.refresh()
        }
        // TopLayer has no Dock icon, so it has to step forward for its window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finished() {
        UserDefaults.standard.set(true, forKey: Onboarding.doneKey)
        window?.close()
        store.setMode(.open)
    }

    /// Closed without finishing: the next launch offers it again, while something is missing.
    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var health: HealthMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls when a page runs long (a long path, a failure's explanation), so the
            // buttons below never leave the window.
            ScrollView {
                Group {
                    switch model.page {
                    case .welcome: welcome
                    case .connect: connect
                    case .ready: ready
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .frame(width: 540, height: 620)
    }

    // MARK: 1. What is on this Mac

    private var welcome: some View {
        VStack(spacing: 0) {
            header(title: "Welcome to TopLayer",
                   text: "It floats above every app, fullscreen ones included, and lets you follow and answer your Claude Code and Codex threads without switching to them.") {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
            }
            section("On this Mac") {
                toolRow(.claude)
                Divider().padding(.leading, 44)
                toolRow(.codex)
            }
            Text(model.found.claude || model.found.codex
                 ? "TopLayer works with either one, or with both."
                 : "TopLayer needs at least one of them. Install it, then press Check Again.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 10)
        }
    }

    private func toolRow(_ tool: CLITools.Tool) -> some View {
        let state = toolState(tool)
        return HStack(alignment: .top, spacing: 12) {
            icon(state.icon).font(.system(size: 18)).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool == .claude ? "Claude Code" : "Codex").font(.body.weight(.medium))
                Text(state.text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.offerInstall {
                    CopyButton(title: "Copy Install Command", text: CLITools.installCommand(tool))
                        .controlSize(.small).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private enum Mark { case ok, missing, warning, failed, waiting }

    /// What a tool's row says. Which tool is here comes from files that exist; its
    /// version comes a moment later, from running it.
    private func toolState(_ tool: CLITools.Tool) -> (icon: Mark, text: String, offerInstall: Bool) {
        let found = model.found
        let versions = health.tools
        let looking = versions.checked == nil
        func version(_ text: String?) -> String { text.map { " \($0)" } ?? "" }
        switch tool {
        case .claude:
            var parts = [String]()
            if found.claudeCommand {
                parts.append("Command-line tool\(version(versions.claude))" + (versions.claudeSignedIn == false ? ", not signed in" : ""))
            }
            if found.claudeApp { parts.append("Desktop app\(version(versions.claudeApp))") }
            if !parts.isEmpty {
                let note = found.claudeCommand ? "" : " Starting sessions in the background also needs the claude command."
                return (looking ? .waiting : .ok, parts.joined(separator: " · ") + "." + note, !found.claudeCommand)
            }
            if found.claudeFolder {
                return (.warning, "Its settings are here, but neither the claude command nor the desktop app was found.", true)
            }
            return (.missing, "Not found. Install it to follow and answer Claude Code sessions.", true)
        case .codex:
            if found.codexCommand {
                var parts = ["Command-line tool\(version(versions.codex))"]
                if found.codexApp { parts.append("Desktop app\(version(versions.codexApp))") }
                return (looking ? .waiting : .ok, parts.joined(separator: " · ") + ".", false)
            }
            if found.codexApp {
                return (.warning, "The desktop app is here, but TopLayer needs the codex command: it runs the background service all Codex threads go through.", true)
            }
            return (.missing, "Not found. Install it to follow and answer Codex threads.", true)
        }
    }

    // MARK: 2. Connecting

    private var connect: some View {
        VStack(spacing: 0) {
            header(title: "Connect TopLayer",
                   text: "Claude Code and Codex have no way in for another app, so TopLayer adds a few small pieces to reach them. Untick what you don't want.") {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(.tint)
            }
            section(nil) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 44) }
                    stepRow(step)
                }
            }
            Text("Each file is copied beside itself before it is edited. Settings → Setup can undo every one of these later.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 10)
        }
    }

    private func stepRow(_ step: SetupStep) -> some View {
        let outcome = model.outcomes[step.piece]
        let settled = step.inPlace || outcome != nil
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if settled {
                    icon(mark(step, outcome)).font(.system(size: 18))
                } else {
                    Toggle("Add \(step.piece.title)", isOn: Binding(
                        get: { model.chosen.contains(step.piece) },
                        set: { if $0 { model.chosen.insert(step.piece) } else { model.chosen.remove(step.piece) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                        // Everything else points at the helper scripts.
                        .disabled(step.piece == .helpers)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.piece.title).font(.body.weight(.medium))
                    if step.piece.optional {
                        Text("Optional").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(result(step, outcome) ?? step.piece.detail(model.targets))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func mark(_ step: SetupStep, _ outcome: Onboarding.Outcome?) -> Mark {
        switch outcome {
        case .failed: .failed
        case .skipped: .warning
        default: .ok
        }
    }

    /// What to say in place of the description, once a piece is settled.
    private func result(_ step: SetupStep, _ outcome: Onboarding.Outcome?) -> String? {
        switch outcome {
        case .done(let backup):
            guard let backup else { return "Added." }
            return "Added. The file as it was is kept beside it, as \((backup as NSString).lastPathComponent)."
        case .failed(let why): return "That didn't work: \(why)"
        case .skipped: return "Not tried, because the helper scripts it points at could not be installed."
        case nil: return step.inPlace ? "Already in place." : nil
        }
    }

    // MARK: 3. Ready

    private var ready: some View {
        VStack(spacing: 0) {
            header(title: "TopLayer is ready",
                   text: "It sits in a corner of the screen as a small squircle. Drag it to move it to another corner.") {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46, weight: .light)).foregroundStyle(.green)
            }
            section(nil) {
                tip("keyboard", "Press \(model.preferences.toggleShortcut.display) in any app to open or collapse it. \(model.preferences.expandShortcut.display) switches to the larger reading layout, and Escape steps back one size.")
                if model.has(.claudeHooks) {
                    Divider().padding(.leading, 44)
                    tip("clock.arrow.circlepath", "A Claude session that is already running becomes reachable the first time it starts or finishes a turn.")
                }
                if model.found.codex {
                    Divider().padding(.leading, 44)
                    tip("bolt.horizontal", "Codex threads appear as soon as Codex's background service answers. TopLayer starts it when it is not running.")
                }
                Divider().padding(.leading, 44)
                tip("stethoscope", "If something stops working, Settings → Setup checks every piece again and can repair it. TROUBLESHOOTING.md in the repository lists the usual causes.")
            }
            if model.preferences.canOpenAtLogin {
                Toggle("Open TopLayer at login", isOn: Binding(
                    get: { model.preferences.opensAtLogin },
                    set: { model.preferences.setOpensAtLogin($0) }))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 14)
            }
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // MARK: Shared pieces

    private func header(title: String, text: String, @ViewBuilder image: () -> some View) -> some View {
        VStack(spacing: 8) {
            image().frame(height: 76)
            Text(title).font(.title.weight(.semibold))
            Text(text).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 22)
    }

    private func section(_ name: String?, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name { Text(name).font(.headline) }
            VStack(spacing: 0) { rows() }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 24)
    }

    /// The state is always shown as a symbol as well as a colour.
    @ViewBuilder
    private func icon(_ mark: Mark) -> some View {
        switch mark {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .waiting: ProgressView().controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(index == model.page.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(model.page.rawValue + 1) of 3")
            Spacer()
            switch model.page {
            case .welcome:
                Button("Check Again") { model.look() }
                Button("Continue") { model.page = .connect }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(model.found.claude || model.found.codex))
            case .connect:
                Button("Back") { model.page = .welcome }
                if model.remaining.isEmpty {
                    Button("Continue") { model.page = .ready }.keyboardShortcut(.defaultAction)
                } else if model.ran {
                    Button("Continue Without") { model.page = .ready }
                    Button("Try Again") { model.run() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Set Up") { model.run() }.keyboardShortcut(.defaultAction)
                }
            case .ready:
                Button("Back") { model.page = .connect }
                Button("Open TopLayer") { model.finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

/// A button that copies text and says so for a moment.
private struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        }
        .help(text)
    }
}
