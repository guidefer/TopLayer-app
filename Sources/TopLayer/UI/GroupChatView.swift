import AppKit
import SwiftUI

/// A group chat: the two agents' messages to each other, your posts, their answers to
/// you, and the constraints you set.
struct GroupChatView: View {
    @ObservedObject var store: Store
    @ObservedObject var drafts: Drafts
    let chat: GroupChat
    @State private var showSettings = ProcessInfo.processInfo.environment["TOPLAYER_DEBUG_SETTINGS"] == "1"
    @FocusState private var inputFocused: Bool

    private var broker: GroupChatBroker { store.groupChats }

    var body: some View {
        PaneHeader(icon: nil, title: chat.title, subtitle: subtitle, fill: .white.opacity(0.14),
                   onClose: { store.deselect() }) {
            IconButton("slider.horizontal.3", help: showSettings ? "Hide settings" : "Chat settings") {
                withAnimation(Motion.panel) { showSettings.toggle() }
            }
            ActionButton(chat.paused ? "Resume" : "Pause") { broker.setPaused(chat.id, !chat.paused) }
            ActionButton("End") {
                store.deselect()
                broker.end(chat.id)
            }
        }
        if showSettings {
            settings.transition(.opacity.combined(with: .move(edge: .top)))
        }
        messages
        composer
    }

    private var subtitle: String {
        let ends = chat.expires.map { "ends \($0.formatted(date: .omitted, time: .shortened))" } ?? "until disconnected"
        let pace = chat.settings.minInterval == 0 ? "no delay" : "\(chat.settings.intervalLabel) between exchanges"
        return "\(chat.statusLine) · \(pace) · \(ends)"
    }

    // MARK: Settings

    private func binding<Value>(_ keyPath: WritableKeyPath<GroupChatSettings, Value>) -> Binding<Value> {
        Binding(get: { chat.settings[keyPath: keyPath] },
                set: { new in
                    var changed = chat.settings
                    changed[keyPath: keyPath] = new
                    broker.setSettings(chat.id, changed)
                })
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 9) {
            setting("Delay between exchanges", "How long an agent waits before starting another. A direct answer is exempt, once.") {
                Picker("", selection: binding(\.minInterval)) {
                    ForEach(GroupChatSettings.intervalChoices, id: \.value) { Text($0.label).tag($0.value) }
                }
            }
            setting("Message limit", "Agent-to-agent messages allowed in total.") {
                Picker("", selection: binding(\.maxMessages)) {
                    ForEach(GroupChatSettings.capChoices, id: \.value) { Text($0.label).tag($0.value) }
                }
            }
            setting("Stay connected for", "Changing this restarts the clock from now.") {
                Picker("", selection: binding(\.duration)) {
                    ForEach(GroupChatSettings.durationChoices, id: \.value) { Text($0.label).tag($0.value) }
                }
            }
            setting("Approve each message", "Hold every agent-to-agent message until you approve it.") {
                Toggle("", isOn: binding(\.requireApproval)).toggleStyle(.switch)
            }
            setting("Tell the agents", "Send both agents a notice when you pause, resume or end the chat.") {
                Toggle("", isOn: binding(\.notifyAgents)).toggleStyle(.switch)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(12)
        .background(.white.opacity(0.07), in: squircle(Radius.bubble + 2))
        .padding(.horizontal, Metrics.contentInset)
        .padding(.top, Metrics.contentInset)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
    }

    private func setting<Control: View>(_ title: String, _ detail: String,
                                        @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).opacity(0.65).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control().frame(width: 170, alignment: .trailing)
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if chat.messages.isEmpty {
                    Text("No messages yet. Write to both agents below, or ask one of them in its own thread to message the other.")
                        .font(.system(size: 12)).opacity(0.75)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.white.opacity(0.07), in: squircle(Radius.bubble + 2))
                }
                ForEach(chat.messages) { message in
                    row(message)
                }
            }
            .padding(Metrics.contentInset)
            .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .keyboardScrolling()
    }

    /// Yours sit to the right in a neutral bubble. Each agent's sit to the left in its
    /// own colour, so the two are told apart at a glance.
    @ViewBuilder
    private func row(_ message: GroupMessage) -> some View {
        let mine = message.from == .you
        let tint = message.from.source.map(Brand.color) ?? .white
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if !mine { Circle().fill(tint).frame(width: 6, height: 6) }
                Text(label(message)).font(.system(size: 10, weight: .semibold)).opacity(0.7)
            }
            MarkdownText(text: message.text)
            if message.needsApproval {
                HStack(spacing: 6) {
                    Text("Held for your approval").font(.system(size: 11)).opacity(0.75)
                    Spacer(minLength: 0)
                    ActionButton("Reject") { broker.reject(message.id, in: chat.id) }
                    ActionButton("Approve", prominent: true) { broker.approve(message.id, in: chat.id) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(mine ? Color.white.opacity(0.15) : tint.opacity(message.kind == .reply ? 0.12 : 0.2),
                    in: squircle(Radius.bubble + 2))
        .overlay {
            // An answer meant only for you is outlined, not filled like a relayed message.
            if message.kind == .reply { squircle(Radius.bubble + 2).strokeBorder(tint.opacity(0.45)) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 56)
    }

    private func label(_ message: GroupMessage) -> String {
        let time = message.time.formatted(date: .omitted, time: .shortened)
        if message.kind == .reply {
            return "\(message.from.name) answered you · \(time) · only you see this"
        }
        let targets = message.to.map(\.rawValue).joined(separator: " and ")
        let delivery = message.to.count > 1
            ? message.to.map { "\($0.rawValue) \(message.delivery[$0.rawValue] ?? "queued")" }.joined(separator: ", ")
            : message.to.first.flatMap { message.delivery[$0.rawValue] } ?? ""
        return "\(message.from.name) → \(targets) · \(time) · \(delivery)"
    }

    // MARK: Composer

    private var draft: Binding<String> {
        Binding(get: { drafts[chat.rowId] }, set: { drafts[chat.rowId] = $0 })
    }

    private var composer: some View {
        let empty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Message both agents…  (@claude or @codex for one)", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(submit)
                .padding(.vertical, 5)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(empty ? 0.3 : 0.92), in: squircle(Radius.control))
            }
            .buttonStyle(PressScale())
            .disabled(empty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(.white.opacity(0.09), in: squircle(Radius.bubble + 3))
        .overlay { squircle(Radius.bubble + 3).strokeBorder(.white.opacity(inputFocused ? 0.28 : 0.12)) }
        .padding(Metrics.contentInset)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
        .animation(Motion.quick, value: inputFocused)
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let text = drafts[chat.rowId]
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts[chat.rowId] = ""
        broker.post(text, in: chat.id)
    }
}
