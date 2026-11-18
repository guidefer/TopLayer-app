import AppKit
import SwiftUI

/// The form for starting a new thread: where it works, what to ask first and, for
/// Claude, whether it runs in the background or in the desktop app.
struct NewThreadView: View {
    @ObservedObject var store: Store
    @ObservedObject var drafts: Drafts
    let source: AgentSource
    @State private var folder = ""
    /// Empty means "whatever my settings say".
    @State private var model = ""
    @State private var effort = ""
    @State private var target = ClaudeTarget(rawValue: UserDefaults.standard.string(forKey: "claudeTarget") ?? "") ?? .cli
    @FocusState private var focused: Bool

    private var key: String { "new:\(source.rawValue)" }
    private var prompt: Binding<String> { Binding(get: { drafts[key] }, set: { drafts[key] = $0 }) }
    private var ready: Bool {
        !folder.isEmpty && !drafts[key].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.creating
            && blocked == nil
    }

    /// Why a background Claude session cannot be started right now, if it can't.
    private var blocked: String? {
        guard source == .claude, target == .cli else { return nil }
        if ClaudeCLI.startedInsideClaude {
            return "TopLayer was opened by a Claude session this time, so a session started now would be treated as part of that one and its conversation would not be saved. Quit TopLayer and open it yourself, then try again."
        }
        let tools = store.health.tools
        if tools.checked != nil, tools.claude == nil {
            return "The claude command is not installed. Settings → Setup shows how to install it."
        }
        if tools.claudeSignedIn == false {
            return "The claude command is not signed in. Sign in from Settings → Setup first."
        }
        return nil
    }

    var body: some View {
        PaneHeader(icon: Brand.icon(source), title: source == .codex ? "New Codex thread" : "New Claude session",
                   subtitle: subtitle, fill: Brand.color(source).opacity(0.3), onClose: { store.deselect() }) { EmptyView() }
        Spacer(minLength: 0)
        // Only when there is something to say: why it can't start, or what happens next.
        if let blocked {
            note(blocked) {
                if !ClaudeCLI.startedInsideClaude { ActionButton("Open Setup") { store.openSettings() } }
            }
        }
        if let said = store.newThreadNote {
            note(said) {
                if let stuck = store.stuckCLI { ActionButton("Open in Terminal") { store.openInTerminal(sessionId: stuck) } }
            }
        }
        options
        messageField
            .onAppear {
                if folder.isEmpty { folder = store.knownFolders(for: source).first ?? "" }
                model = store.lastChoice("model", for: source)
                effort = store.lastChoice("effort", for: source)
                focused = true
            }
    }

    /// Everything a new thread needs besides its first message, in one row above it.
    private var options: some View {
        HStack(spacing: 6) {
            OptionMenu(symbol: "folder.fill", title: folder.isEmpty ? "Folder" : (folder as NSString).lastPathComponent,
                       help: folder.isEmpty ? "Folder" : "Folder: \((folder as NSString).abbreviatingWithTildeInPath)") {
                ForEach(store.knownFolders(for: source), id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) { folder = path }
                }
                Divider()
                Button("Choose Folder…", action: chooseFolder)
            }
            // The desktop app's link takes no model or effort; you choose them in the app.
            if source == .codex || target == .cli {
                ModelEffortMenus(models: store.models(for: source), model: model, effort: effort,
                                 chooseModel: { model = $0; store.rememberChoice("model", $0, for: source) },
                                 chooseEffort: { effort = $0; store.rememberChoice("effort", $0, for: source) })
            }
            Spacer(minLength: 0)
            if source == .claude {
                TargetSwitch(target: Binding(get: { target }, set: {
                    target = $0
                    UserDefaults.standard.set($0.rawValue, forKey: "claudeTarget")
                }))
            }
        }
        .padding(.horizontal, Metrics.contentInset + 2)
        .padding(.top, 6)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
    }

    private func note<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.08), in: squircle(Radius.bubble))
        .padding(.horizontal, Metrics.contentInset)
        .padding(.top, 4)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        if store.creating { return "Starting…" }
        return folder.isEmpty ? "Choose a folder" : (folder as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.level = .modalPanel           // above the overlay, which floats over everything
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private var messageField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("What should \(source.rawValue) do first?", text: prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(create)
                .padding(.vertical, 5)
            Button(action: create) {
                Image(systemName: source == .claude && target == .desktop ? "arrow.up.forward.app" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Brand.color(source).opacity(ready ? 1 : 0.35), in: squircle(Radius.control))
            }
            .buttonStyle(PressScale())
            .disabled(!ready)
            .accessibilityLabel("Create")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(.white.opacity(0.09), in: squircle(Radius.bubble + 3))
        .overlay { squircle(Radius.bubble + 3).strokeBorder(.white.opacity(focused ? 0.28 : 0.12)) }
        .padding(.horizontal, Metrics.contentInset).padding(.bottom, Metrics.contentInset).padding(.top, 6)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
    }

    private func create() {
        guard ready else { return }
        store.stuckCLI = nil
        switch source {
        case .codex: store.createCodexThread(folder: folder, prompt: drafts[key], model: model, effort: effort)
        case .claude: store.createClaudeSession(folder: folder, prompt: drafts[key], target: target, model: model, effort: effort)
        }
    }
}
