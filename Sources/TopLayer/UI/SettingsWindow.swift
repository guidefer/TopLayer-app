import AppKit
import SwiftUI

enum SettingsTab: Hashable { case general, setup }

/// The settings window. It is an ordinary window, not part of the overlay, so it uses
/// the system's own look and controls.
final class SettingsWindowController {
    private final class Model: ObservableObject { @Published var tab: SettingsTab = .general }

    private var window: NSWindow?
    private let store: Store
    private let model = Model()

    init(store: Store) { self.store = store }

    func show(_ tab: SettingsTab) {
        store.health.refreshTools(force: true)
        store.health.refresh()
        model.tab = tab
        if window == nil {
            let new = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            new.title = "TopLayer Settings"
            new.isReleasedWhenClosed = false
            new.contentMinSize = NSSize(width: 540, height: 460)
            new.contentView = NSHostingView(rootView: Root(store: store, model: model))
            new.center()
            window = new
        }
        // TopLayer has no Dock icon, so it has to step forward for its window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private struct Root: View {
        @ObservedObject var store: Store
        @ObservedObject var model: Model

        var body: some View {
            TabView(selection: $model.tab) {
                GeneralSettingsView(store: store, preferences: store.preferences)
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsTab.general)
                SetupView(health: store.health)
                    .tabItem { Label("Setup", systemImage: "checkmark.shield") }
                    .tag(SettingsTab.setup)
            }
            .frame(minWidth: 540, minHeight: 460)
        }
    }
}

/// General: where the overlay sits, how big it gets, its shortcuts, and how it behaves.
struct GeneralSettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Position", selection: $store.corner) {
                    ForEach(Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Open panel width", selection: $preferences.openWidth) {
                    ForEach(Preferences.widthChoices, id: \.value) { Text($0.label).tag($0.value) }
                }
                LabeledContent("Expanded size") {
                    HStack {
                        Slider(value: $preferences.expandedFraction, in: 0.55...0.9, step: 0.05)
                        Text("\(Int((preferences.expandedFraction * 100).rounded()))% of the screen")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .trailing)
                    }
                }
            }
            Section {
                LabeledContent("Open or collapse") {
                    ShortcutField(shortcut: $preferences.toggleShortcut, preferences: preferences)
                }
                LabeledContent("Expand or compact") {
                    ShortcutField(shortcut: $preferences.expandShortcut, preferences: preferences)
                }
                if let problem = preferences.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if preferences.toggleShortcut != .toggleDefault || preferences.expandShortcut != .expandDefault {
                    Button("Restore Default Shortcuts") { preferences.resetShortcuts() }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("These work in any app. Click one, then press the keys you want; it needs ⌘, ⌥ or ⌃. Escape steps the overlay back one size.")
            }
            Section {
                key("⌥↓  ⌥↑", "Next or previous thread")
                key("⌥⇧↓  ⌥⇧↑", "Next or previous thread waiting on you")
                key("⇞  ⇟", "Scroll the conversation by a page")
                key("↑  ↓", "Scroll it a few lines, while the reply field is empty")
                key("↖  ↘", "Jump to its start or end (also ⌘↑ ⌘↓ with an empty field)")
                key("↩", "Send the reply (⌥↩ for a new line)")
                key("⌘↩", "Allow or approve what is waiting")
                key("⌘.", "Deny or reject it")
                key("⌘W", "Close the open thread")
                key("⎋", "Step back one size")
            } header: {
                Text("In the panel")
            } footer: {
                Text("These work while the overlay is open, including while you are typing a reply.")
            }
            Section("Behaviour") {
                Toggle(isOn: $preferences.hideFromScreenSharing) {
                    Text("Hide from screen sharing")
                    Text("Keeps the overlay out of screen recordings, screenshots and shared screens. You still see it.")
                }
                Toggle("Play a sound for notifications", isOn: $preferences.playSound)
                if preferences.canOpenAtLogin {
                    Toggle("Open TopLayer at login",
                           isOn: Binding(get: { preferences.opensAtLogin }, set: { preferences.setOpensAtLogin($0) }))
                    if let problem = preferences.loginProblem {
                        Text(problem).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralSettingsView {
    fileprivate func key(_ keys: String, _ what: String) -> some View {
        LabeledContent(what) {
            Text(keys).foregroundStyle(.secondary)
        }
    }
}

/// Shows a shortcut and records a new one: click it, then press the keys.
struct ShortcutField: View {
    @Binding var shortcut: Shortcut
    @ObservedObject var preferences: Preferences
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { listening ? stop() : start() }) {
            Text(listening ? "Press keys…" : shortcut.display)
                // The system font draws ⌃ ⌥ ⇧ ⌘ properly; a monospaced one falls back to look-alikes.
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
        .accessibilityLabel(listening ? "Recording a shortcut" : "Shortcut \(shortcut.display). Click to change.")
    }

    private func start() {
        listening = true
        preferences.recording = true        // the global shortcuts step aside while this listens
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {        // Escape cancels
                stop()
            } else if let new = Shortcut(event: event) {
                shortcut = new
                stop()
            } else {
                NSSound.beep()              // no ⌘, ⌥ or ⌃: not usable as a global shortcut
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        if preferences.recording { preferences.recording = false }
    }
}

/// Setup and health: everything TopLayer depends on outside itself, whether it is in
/// place, and a button to install or repair it.
struct SetupView: View {
    @ObservedObject var health: HealthMonitor

    private var groups: [(name: String, checks: [HealthCheck])] {
        ["TopLayer", "Claude", "Codex"].compactMap { name in
            let checks = health.checks.filter { $0.group == name }
            return checks.isEmpty ? nil : (name, checks)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.name).font(.headline)
                            VStack(spacing: 0) {
                                ForEach(Array(group.checks.enumerated()), id: \.element.id) { index, check in
                                    if index > 0 { Divider().padding(.leading, 44) }
                                    row(check)
                                }
                            }
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            icon(health.worst).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text(health.summary).font(.title3.weight(.semibold))
                Text("TopLayer relies on hooks in Claude, a tool entry in Codex, and parts of both that can change between versions. This checks each of them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func row(_ check: HealthCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(check.state).font(.system(size: 18)).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !check.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(check.actions) { action in
                            Button(action.title, action: action.run)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let result = health.lastResult {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button("Check Again") {
                health.refreshTools(force: true)
                health.refresh()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// The state is always shown as a symbol as well as a colour.
    private func icon(_ state: HealthState) -> some View {
        let (symbol, color): (String, Color) = switch state {
        case .ok: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .secondary)
        case .attention: ("exclamationmark.triangle.fill", .yellow)
        case .broken: ("xmark.octagon.fill", .red)
        }
        return Image(systemName: symbol).foregroundStyle(color)
    }
}
