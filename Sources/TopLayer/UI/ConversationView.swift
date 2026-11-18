import AppKit
import SwiftUI

/// What sits beside the sidebar: a thread, a group chat, an environment's web client, or
/// the form for starting a new thread.
struct ConversationView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if let source = store.webPaneSource {
                WebPane(store: store, source: source)
            } else if let source = store.newThreadSource {
                NewThreadView(store: store, drafts: store.drafts, source: source)
            } else if let chat = store.selectedChat {
                GroupChatView(store: store, drafts: store.drafts, chat: chat)
            } else if let row = store.selectedRow {
                ThreadView(store: store, drafts: store.drafts, row: row)
            }
        }
    }
}

/// The coloured bar at the top of every pane: what it is, and a way to close it.
struct PaneHeader<Trailing: View>: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    let fill: Color
    let onClose: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).opacity(0.85).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
            IconButton("xmark", help: "Close") { onClose() }
        }
        .padding(.leading, 12).padding(.trailing, Metrics.rowInset)
        .frame(height: Metrics.headerHeight)
        .background(fill)
    }
}

// MARK: A thread

struct ThreadView: View {
    @ObservedObject var store: Store
    @ObservedObject var drafts: Drafts
    let row: SessionRow
    @FocusState private var inputFocused: Bool

    var body: some View {
        PaneHeader(icon: Brand.icon(row.source), title: row.title,
                   subtitle: "\((row.cwd as NSString).lastPathComponent) · \(row.statusWord)",
                   fill: Brand.color(row.source).opacity(0.3), onClose: { store.deselect() }) { EmptyView() }
        messages
        ForEach(store.approvals) { approval in
            banner {
                Text(approval.summary).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                Spacer()
                ActionButton("Decline") { store.resolve(approval, accept: false) }
                ActionButton("Approve", prominent: true) { store.resolve(approval, accept: true) }
            }
        }
        if let notice = store.notice {
            banner {
                Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold))
                Text(notice).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                if store.queuedThreadIds.contains(row.rawId) {
                    ActionButton("Cancel queued") { store.cancelQueued() }
                }
            }
            .transition(.opacity)
        }
        if row.ended {
            banner {
                Text("This session is no longer running. You can read it and copy from it, but there is nothing to reply to.")
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, Metrics.contentInset)
        } else if row.source == .codex || row.canReply {
            if row.source == .codex { codexOptions }
            replyField
        } else {
            banner {
                Text("This session has not run the TopLayer hook yet, so it can't be reached from here.")
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                ActionButton("Open Claude web") { store.showWeb(.claude) }
            }
            .padding(.bottom, Metrics.contentInset)
        }
    }

    private var messages: some View {
        ScrollView {
            // Not lazy: there are at most 60 messages, and a content height that does not
            // change as you scroll keeps page-by-page scrolling exact.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.messages) { message in
                    MessageRow(message: message, source: row.source)
                        .equatable()        // the store changes often; unchanged messages are not redrawn
                }
                if !store.streaming.isEmpty {
                    MessageRow(message: ChatMessage(id: "streaming", role: "assistant", text: store.streaming),
                               source: row.source)
                }
                if store.sending && store.streaming.isEmpty {
                    Text("Working…")
                        .font(.system(size: 11)).opacity(0.7)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.07), in: squircle(Radius.control))
                }
            }
            .padding(Metrics.contentInset)
            // In the expanded layout, keep lines a readable length instead of full width.
            .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .keyboardScrolling()
    }

    /// A strip of information or a decision, between the messages and the reply field.
    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) { content() }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.08), in: squircle(Radius.bubble))
            .padding(.horizontal, Metrics.contentInset)
            .padding(.top, 4)
            .frame(maxWidth: Metrics.readingWidth)
            .frame(maxWidth: .infinity)
    }

    private var draft: Binding<String> {
        Binding(get: { drafts[row.id] }, set: { drafts[row.id] = $0 })
    }

    /// The thread's model and effort, changeable between turns. Only Codex threads have
    /// this: Codex takes both with any message. Claude has no such way in: its own model
    /// command asks for confirmation and saves the choice as your default for every new
    /// session, which is not something to do from a side panel.
    private var codexOptions: some View {
        let current = store.codexOptions(row.rawId)
        return HStack(spacing: 6) {
            ModelEffortMenus(models: store.codexModels, model: current.model, effort: current.effort,
                             unset: "Unchanged",
                             chooseModel: { store.setCodexOption(row.rawId, model: $0) },
                             chooseEffort: { store.setCodexOption(row.rawId, effort: $0) })
            if store.codexPending[row.rawId] != nil {
                Text("from your next message").font(.system(size: 10.5)).opacity(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.contentInset + 2)
        .padding(.top, 6)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
        .onAppear { if store.codexModels.isEmpty { store.loadCodexModels() } }
    }

    private var replyField: some View {
        let empty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply to \(row.source.rawValue)…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(submit)
                .padding(.vertical, 5)
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Brand.color(row.source).opacity(empty || store.sending ? 0.35 : 1), in: squircle(Radius.control))
            }
            .buttonStyle(PressScale())
            .disabled(empty || store.sending)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(.white.opacity(0.09), in: squircle(Radius.bubble + 3))
        .overlay { squircle(Radius.bubble + 3).strokeBorder(.white.opacity(inputFocused ? 0.28 : 0.12)) }
        .padding(.horizontal, Metrics.contentInset).padding(.bottom, Metrics.contentInset)
        .padding(.top, row.source == .codex ? 6 : Metrics.contentInset)
        .frame(maxWidth: Metrics.readingWidth)
        .frame(maxWidth: .infinity)
        .animation(Motion.quick, value: inputFocused)
        .onAppear { inputFocused = true }
        .onChange(of: row.id) { inputFocused = true }
    }

    private func submit() {
        let text = drafts[row.id]
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !store.sending else { return }
        drafts[row.id] = ""
        store.send(text)
    }
}

/// One message. Yours sit to the right in a neutral bubble; the agent's sit to the left
/// in a bubble tinted with its environment's colour; tool calls are a quiet single line.
struct MessageRow: View, Equatable {
    let message: ChatMessage
    let source: AgentSource

    static func == (a: MessageRow, b: MessageRow) -> Bool { a.message == b.message && a.source == b.source }

    var body: some View {
        switch message.role {
        case "system": toolLine
        case "user": bubble(label: "You" + statusSuffix, fill: .white.opacity(0.15))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.leading, 56)
        case "peer":
            // The other agent, speaking through a group chat: its own colour, not this thread's.
            let other: AgentSource = source == .claude ? .codex : .claude
            bubble(label: "\(message.label ?? other.rawValue) · through the group chat", fill: Brand.color(other).opacity(0.2))
                .padding(.trailing, 28)
        default: bubble(label: source.rawValue, fill: Brand.color(source).opacity(0.2))
                        .padding(.trailing, 28)
        }
    }

    private var statusSuffix: String {
        let via = message.label.map { " · \($0)" } ?? (message.status != nil ? " · from TopLayer" : "")
        return via + (message.status == "waiting" ? " · waiting for Claude" : "")
    }

    private func bubble(label: String, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).opacity(0.65)
            MarkdownText(text: message.text.count > 8000 ? String(message.text.prefix(8000)) + "…" : message.text)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(fill, in: squircle(Radius.bubble + 2))
    }

    private var toolLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 9, weight: .semibold))
            Text(message.text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .opacity(0.6)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.white.opacity(0.05), in: squircle(Radius.control))
        .padding(.trailing, 28)
    }
}

// MARK: Web fallback

struct WebPane: View {
    @ObservedObject var store: Store
    let source: AgentSource

    private var web: RemoteWeb { source == .claude ? .shared : .codex }

    var body: some View {
        PaneHeader(icon: Brand.icon(source), title: "\(source.rawValue) web interface",
                   subtitle: source == .claude ? "claude.ai/code" : "chatgpt.com/codex",
                   fill: Brand.color(source).opacity(0.3), onClose: { store.deselect() }) {
            ActionButton("Reload") { web.reload() }
        }
        RemoteControlView(web: web, remoteId: nil)
    }
}
