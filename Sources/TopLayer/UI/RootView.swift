import AppKit
import SwiftUI

/// Everything is laid out from the overlay's screen corner, and it is one layout in
/// every size: a column that holds the header (the squircle, when collapsed) with the
/// sidebar sections under it, and beside it either a notification pill or the open
/// conversation. Because the header is the same view throughout, the squircle can turn
/// into the TopLayer bar instead of being swapped for it.
///
/// The window is enlarged before any animation and fitted again afterwards, so the
/// content can move freely inside it.
struct RootView: View {
    @ObservedObject var store: Store
    var showMenu: (NSEvent, NSView) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = PanelLayout.size(store)
        VStack(spacing: Metrics.gap) {
            if !store.squircle {
                ForEach(store.permissions) { request in
                    Group {
                        if request.isQuestion {
                            QuestionCard(store: store, request: request, width: size.width - Metrics.inset * 2)
                        } else {
                            PermissionCard(store: store, request: request)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            HStack(alignment: .top, spacing: Metrics.gap) {
                if store.corner.isRight {
                    beside
                    column
                } else {
                    column
                    beside
                }
            }
        }
        .padding(Metrics.inset)
        .frame(width: size.width, height: size.height, alignment: store.corner.isRight ? .topTrailing : .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.corner.alignment)
        .environment(\.colorScheme, .dark)
    }

    private var column: some View {
        SidebarView(store: store, showMenu: showMenu)
            .frame(width: store.squircle ? Metrics.squircle : Metrics.sidebarWidth)
            .zIndex(1)                                  // the conversation slides out from behind it
    }

    /// What sits next to the column: a pill while collapsed, the conversation when open.
    @ViewBuilder
    private var beside: some View {
        if store.squircle {
            CollapsedPill(store: store)
        } else if store.hasConversation && store.isShown(.conversation) {
            ConversationView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .surface()
                // Comes out from where the sidebar is, fading in on the way.
                .transition(reduceMotion ? .opacity
                            : .arrival(from: store.corner.isRight ? .trailing : .leading,
                                       distance: Metrics.sidebarWidth + Metrics.gap))
        }
    }
}

/// A permission request in the open panel. Stacks so it also fits the sidebar-only width.
struct PermissionCard: View {
    @ObservedObject var store: Store
    let request: ClaudeBridge.PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.needsClaude ? "\(store.sessionName(for: request)) asks you something"
                                     : "\(store.sessionName(for: request)) asks permission: \(request.tool)")
                .font(.system(size: 12, weight: .semibold))
            Text(request.needsClaude ? "TopLayer could not read the question. Answer it in Claude's own window." : request.summary)
                .font(.system(size: 11, design: request.needsClaude ? .default : .monospaced)).lineLimit(3)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if request.needsClaude {
                    ActionButton("Ask in Claude", prominent: true, tint: Brand.color(.claude)) { store.answer(request, "ask") }
                } else {
                    ActionButton("Ask in Claude") { store.answer(request, "ask") }
                    ActionButton("Deny") { store.answer(request, "deny") }
                    ActionButton("Allow", prominent: true) { store.answer(request, "allow") }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}
