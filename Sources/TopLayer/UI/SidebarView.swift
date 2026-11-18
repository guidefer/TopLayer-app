import AppKit
import SwiftUI

/// The header, the group chat (when there is one), and one section per environment.
/// Each environment's thread list scrolls inside its own section.
///
/// The header is the squircle and the TopLayer bar in one: collapsed, it is all there is.
struct SidebarView: View {
    @ObservedObject var store: Store
    var showMenu: (NSEvent, NSView) -> Void
    @State private var hovered: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let share = PanelLayout.split(store, available: geo.size.height)
            // Each section comes down from the piece above it: the group chat and Claude
            // from the header (Claude from the group chat, when there is one), Codex
            // from Claude.
            let fromHeader = Metrics.barHeight + Metrics.gap
            let groupHeight = store.groupChats.chats.isEmpty ? 0 : sectionHeight("group", Metrics.rowsHeight(store.groupChats.chats.count))
            VStack(spacing: Metrics.gap) {
                header.zIndex(4)
                if store.isShown(.group) { groupChat(drop(fromHeader)).zIndex(3) }
                if store.isShown(.claude) {
                    environment(.claude, rows: store.shown(.claude), listHeight: share.claude)
                        .transition(drop(groupHeight > 0 ? groupHeight + Metrics.gap : fromHeader))
                        .zIndex(2)
                }
                if store.isShown(.codex) {
                    environment(.codex, rows: store.shown(.codex), listHeight: share.codex)
                        .transition(drop(sectionHeight("Claude", share.claude) + Metrics.gap))
                        .zIndex(1)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func drop(_ distance: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .arrival(from: .top, distance: distance)
    }

    /// A section's height: its header, plus its list unless it is folded.
    private func sectionHeight(_ key: String, _ list: CGFloat) -> CGFloat {
        Metrics.headerHeight + (store.collapsedSections.contains(key) ? 0 : list)
    }

    // MARK: The header: a squircle when collapsed, the TopLayer bar when open

    /// One piece of glass in both forms, so opening stretches the squircle into the bar
    /// and the layers glyph travels to its place in front of the name. Dragging it moves
    /// the overlay.
    private var header: some View {
        let collapsed = store.squircle
        let radius = collapsed ? Radius.squircle : Radius.surface
        let glyph: CGFloat = collapsed ? 34 : 20
        return HStack(spacing: 7) {
            // The glyph keeps its notification colours in both forms.
            LayersGlyph(claudeActive: store.claudeRows.contains { store.needsYou($0.id) },
                        codexActive: store.codexRows.contains { store.needsYou($0.id) })
                .frame(width: glyph, height: glyph)
                .allowsHitTesting(false)
            if !collapsed {
                Group {
                    Text("TopLayer").font(.system(size: 12, weight: .semibold)).fixedSize()
                    Circle().fill(healthColor).frame(width: 7, height: 7)
                    if store.health.worst >= .attention {
                        // Short enough for the bar; the full sentence is in the tooltip and the window.
                        Text(store.health.problems == 1 ? "1 issue" : "\(store.health.problems) issues")
                            .font(.system(size: 10.5)).opacity(0.75).lineLimit(1)
                    }
                }
                .allowsHitTesting(false)
                // The name waits for the glyph to shrink out of its way.
                .transition(.asymmetric(insertion: .opacity.animation(Motion.panel.delay(0.1 * Motion.slow)),
                                        removal: .opacity.animation(Motion.quick)))
                Spacer(minLength: 0)
                Group {
                    IconButton(store.mode == .expanded
                               ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: store.mode == .expanded ? "Compact" : "Expand") { store.toggleExpanded() }
                    IconButton("chevron.down", help: "Collapse") { store.setMode(.collapsed) }
                }
                .transition(.opacity)
            }
        }
        // Centred in the squircle (11 + 34 + 11), at the leading edge of the bar.
        .padding(.leading, 11).padding(.trailing, collapsed ? 11 : Metrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: collapsed ? Metrics.squircle : Metrics.barHeight)
        .background {
            // Open: behind the bar's buttons. A click opens setup and health.
            if !collapsed { ClickDragArea(onClick: { store.openSettings() }, onRightClick: showMenu) }
        }
        // While the bar is still narrow, what has not fitted in yet stays out of sight.
        .clipShape(squircle(radius))
        // Clear glass for the squircle: it is small and bold, and should read as a piece of glass.
        .glassEffect(collapsed ? .clear.interactive() : .regular, in: squircle(radius))
        .overlay {
            // A light edge, brightest at the top left, where light would catch the glass.
            squircle(radius)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .white.opacity(0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                .opacity(collapsed ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(collapsed ? 0.35 : 0), radius: 5, y: 2)
        .overlay(alignment: .topTrailing) {
            if collapsed && store.unreadCount > 0 {
                Text("\(min(store.unreadCount, 99))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 10)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.red, in: Capsule())      // a fill on glass, never more glass
                    .offset(x: 6, y: -6)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: store.unreadCount > 0)
        .overlay {
            // Collapsed: over the whole squircle. A click opens the overlay.
            if collapsed { ClickDragArea(onClick: { store.toggle() }, onRightClick: showMenu) }
        }
        .help(collapsed ? "" : "\(store.health.summary). Click for setup and health.")
        .accessibilityLabel(collapsed ? "TopLayer, \(store.unreadCount) unread" : "TopLayer. \(store.health.summary)")
    }

    private var healthColor: Color {
        switch store.health.worst {
        case .broken: .red
        case .attention: .yellow
        default: .green
        }
    }

    // MARK: Group chat

    @ViewBuilder
    private func groupChat(_ arrival: AnyTransition) -> some View {
        let chats = store.groupChats.chats
        if !chats.isEmpty {
            VStack(spacing: 0) {
                header(title: chats.count == 1 ? "Group chat" : "Group chats",
                       subtitle: chats.count == 1 ? chats[0].statusLine : "\(chats.count) connected",
                       fill: .white.opacity(0.14), icon: nil, key: "group") { EmptyView() }
                if !store.collapsedSections.contains("group") {
                    VStack(spacing: Metrics.rowSpacing) {
                        ForEach(chats) { chat in
                            row(id: chat.rowId, selected: store.selectedId == chat.rowId) {
                                Circle()
                                    .fill(chat.paused ? Color.gray : chat.pendingApprovals > 0 ? Color.yellow : Color.green)
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chat.title).font(.system(size: 12)).lineLimit(1)
                                    Text(chat.statusLine).font(.system(size: 10)).opacity(0.7).lineLimit(1)
                                }
                            }
                            .onTapGesture { store.selectChat(chat.id) }
                            .contextMenu {
                                Button(chat.paused ? "Resume" : "Pause") { store.groupChats.setPaused(chat.id, !chat.paused) }
                                Button("End group chat") {
                                    if store.selectedId == chat.rowId { store.deselect() }
                                    store.groupChats.end(chat.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Metrics.rowInset)
                    .transition(.opacity)
                }
            }
            .surface()
            .transition(arrival)
        }
    }

    // MARK: One environment: a coloured header, then its threads

    private func environment(_ source: AgentSource, rows: [SessionRow], listHeight: CGFloat) -> some View {
        let key = source.rawValue
        let color = Brand.color(source)
        let search = store.searches[source]
        let searching = search != nil
        let typed = !(search?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 0) {
            header(title: source.rawValue, subtitle: statusLine(source), fill: color.opacity(0.55),
                   icon: Brand.icon(source), key: key) {
                IconButton("plus", help: source == .codex ? "New Codex thread" : "New Claude session") {
                    store.showNewThread(source)
                }
                // The list is only part of what exists: Codex shows its recent threads and
                // Claude its running sessions. This reaches the rest.
                IconButton("magnifyingglass", help: searching ? "Close search" : "Search all \(source.rawValue) threads") {
                    searching ? store.endSearch(source) : store.beginSearch(source)
                }
                IconButton("globe", help: "\(source.rawValue) web interface") { store.showWeb(source) }
                UsageButton(store: store, source: source)
            }
            if !store.collapsedSections.contains(key) {
                if searching {
                    SearchField(store: store, source: source).transition(.opacity)
                }
                ScrollView {
                    VStack(spacing: Metrics.rowSpacing) {
                        if rows.isEmpty {
                            Text(emptyText(source, searching: searching && typed))
                                .font(.system(size: 11)).opacity(0.65)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                        }
                        ForEach(rows) { item in threadRow(item, tint: color) }
                    }
                    .padding(.vertical, Metrics.rowInset)
                }
                .frame(height: listHeight)
                .transition(.opacity)
            }
        }
        .surface()
    }

    private func emptyText(_ source: AgentSource, searching: Bool) -> String {
        if source == .codex && !store.codexConnected { return "Not connected" }
        if searching { return store.searches[source]?.pending == true ? "Searching…" : "No thread matches that" }
        return "Nothing here yet"
    }

    /// Kept very short: the header also holds five buttons. What is waiting for you
    /// comes before anything else.
    private func statusLine(_ source: AgentSource) -> String {
        if source == .codex && !store.codexConnected { return "Not connected" }
        let rows = source == .codex ? store.codexRows : store.runningClaudeRows
        let waiting = rows.filter { store.needsYou($0.id) }.count
        let busy = rows.filter(\.isBusy).count
        if waiting > 0 { return "\(waiting) waiting" }
        if busy > 0 { return "\(busy) working" }
        return source == .claude ? "\(rows.count) running" : "Recent"
    }

    private func header<Trailing: View>(title: String, subtitle: String, fill: Color, icon: NSImage?,
                                        key: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        let folded = store.collapsedSections.contains(key)
        return HStack(alignment: .center, spacing: 9) {
            Group {
                if let icon {
                    // App icons carry their own margin, so draw slightly oversized to match the text block.
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10.5)).opacity(0.85).lineLimit(1)
            }
            Spacer(minLength: 0)
            // The buttons sit shoulder to shoulder, so five of them leave room for the title.
            HStack(spacing: 0) {
                trailing()
                IconButton("chevron.down", help: folded ? "Show threads" : "Hide threads") { store.toggleSection(key) }
                    .rotationEffect(.degrees(folded ? -90 : 0))
            }
        }
        .padding(.leading, 11).padding(.trailing, Metrics.rowInset)
        .frame(height: Metrics.headerHeight)
        // A brighter, more opaque fill on the section's frost. The section clips it, so it
        // follows the rounded corners whether or not the threads are showing.
        .background(fill)
    }

    private func threadRow(_ item: SessionRow, tint: Color) -> some View {
        // The dot is a notification and nothing else: it is there, in the environment's
        // colour like the layers of the logo, only while the thread is waiting for you.
        // Whether a thread is working or idle is said in words under its title.
        let waiting = store.needsYou(item.id)
        let working = item.isBusy && !waiting
        let state = store.asksPermission(item.id) ? "asks permission" : waiting ? "waiting for you"
            : item.statusWord
        return row(id: item.id, selected: store.selectedId == item.id) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .opacity(waiting ? 1 : 0)
                .scaleEffect(waiting ? 1 : 0.4)
                .animation(Motion.panel, value: waiting)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: waiting ? .bold : .regular))
                    .lineLimit(1)
                // The state word carries the colour: the environment's while it works,
                // bright while it waits for you, grey like the rest when idle.
                let place = Text("\((item.cwd as NSString).lastPathComponent) · ").foregroundStyle(.white.opacity(0.6))
                let word = Text(state)
                    .foregroundStyle(working ? AnyShapeStyle(tint.mix(with: .white, by: 0.3))
                                     : AnyShapeStyle(.white.opacity(waiting ? 0.95 : 0.6)))
                    .fontWeight(working || waiting ? .semibold : .regular)
                Text("\(place)\(word)")
                    .font(.system(size: 10)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)       // what follows sits at the row's far edge
            if item.ended {
                // A session that is no longer running: there to read, not to reply to.
                tag("read-only")
            } else if item.cli {
                // Runs in a terminal (the claude command), not in the desktop app.
                tag("CLI")
            }
            if store.isPinned(item) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(45))
                    .opacity(0.5)
                    .accessibilityLabel("Pinned")
            }
        }
        .accessibilityLabel("\(item.title), \(state)")
        // A search result is opened through the store, which keeps it in the list afterwards.
        .onTapGesture { store.isSearching(item.source) ? store.openSearchResult(item) : store.select(item) }
        .contextMenu {
            Button(store.isPinned(item) ? "Unpin" : "Pin to Top") { store.togglePin(item) }
            if store.cliSession(for: item) != nil {
                // A session TopLayer started in the background.
                Divider()
                Button("Import to Desktop") { store.importToDesktop(item) }.disabled(item.isBusy)
                Button("Open in Terminal") { store.openInTerminal(sessionId: item.rawId) }
                Button("End Session") { store.endCLISession(item) }
            }
            if !item.ended {
                Divider()
                groupChatMenu(for: item)            // an ended session cannot take part in one
            }
        }
    }

    /// A small label at the far edge of a row.
    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.white.opacity(0.14), in: squircle(5))
            .opacity(0.8)
            .fixedSize()
    }

    @ViewBuilder
    private func groupChatMenu(for item: SessionRow) -> some View {
        let others = item.source == .claude ? store.codexRows : store.runningClaudeRows
        if let chat = store.groupChat(for: item) {
            // A thread can be in one group chat at a time.
            Button("Open group chat") { store.selectChat(chat.id) }
            Button("End group chat") {
                if store.selectedId == chat.rowId { store.deselect() }
                store.groupChats.end(chat.id)
            }
        } else {
            let free = others.filter { store.groupChat(for: $0) == nil }
            Menu("Start group chat with…") {
                if free.isEmpty { Button("No free threads on the other side") {}.disabled(true) }
                ForEach(free) { other in
                    Button(other.title) { store.startGroupChat(item, other) }
                }
            }
        }
    }

    /// Shared row chrome. Hover and selection use the same bright fill as the headers,
    /// and the row's radius is the section's radius minus the row inset.
    private func row<Content: View>(id: String, selected: Bool,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .background(Color.white.opacity(selected ? 0.22 : hovered == id ? 0.11 : 0), in: squircle(Radius.row))
        .padding(.horizontal, Metrics.rowInset)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
        .animation(Motion.quick, value: hovered)
        .animation(Motion.quick, value: selected)
    }
}

/// The search field under a section's header. It looks through every thread of that
/// environment by title and folder, so it finds the ones that are not on the list:
/// Codex threads too old for it, and Claude sessions that are no longer running.
private struct SearchField: View {
    @ObservedObject var store: Store
    let source: AgentSource
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).opacity(0.6)
            TextField(source == .codex ? "Search all threads" : "Search all sessions",
                      text: Binding(get: { store.searches[source]?.text ?? "" }, set: { store.setSearch(source, $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                // Return opens the first result.
                .onSubmit { if let first = store.searches[source]?.results.first { store.openSearchResult(first) } }
            if store.searches[source]?.pending == true {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Metrics.searchHeight - Metrics.rowInset)
        .background(.white.opacity(0.1), in: squircle(Radius.control))
        .padding(.horizontal, Metrics.rowInset)
        .padding(.top, Metrics.rowInset)
        .onAppear { focused = true }
        .onExitCommand { store.endSearch(source) }
    }
}
