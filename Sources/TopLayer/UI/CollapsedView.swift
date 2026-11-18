import AppKit
import SwiftUI

/// The pill beside the squircle: a notification, or a permission request.
struct CollapsedPill: View {
    @ObservedObject var store: Store

    /// Slides out from the squircle's side.
    private var pillTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.85, anchor: store.corner.isRight ? .trailing : .leading))
    }

    // The squircle is clear glass and the pill is regular glass, so they are two separate
    // glass elements, not one group.
    var body: some View {
        if let request = store.permissions.first {
            PermissionPill(store: store, request: request).transition(pillTransition)
        } else if let peek = store.peek {
            HStack(spacing: 9) {
                Circle().fill(color(of: peek)).frame(width: 8, height: 8)
                Text(peek.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(width: Metrics.peekWidth, height: Metrics.squircle)
            .glassEffect(.regular.interactive(), in: squircle(Radius.squircle))
            .contentShape(Rectangle())
            .onTapGesture { store.open(rowId: peek.rowId) }
            .transition(pillTransition)
            .id(peek.id)
        }
    }

    private func color(of peek: Peek) -> Color {
        peek.rowId.hasPrefix("claude:") ? Brand.color(.claude)
            : peek.rowId.hasPrefix("codex:") ? Brand.color(.codex) : .white
    }
}

/// A permission request stays next to the squircle until answered: it blocks the agent.
struct PermissionPill: View {
    @ObservedObject var store: Store
    let request: ClaudeBridge.PermissionRequest

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if request.isQuestion {
                    let count = request.questions.count
                    Text("\(store.sessionName(for: request)) asks \(count == 1 ? "a question" : "\(count) questions")")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(request.questions[0].text)
                        .font(.system(size: 11)).lineLimit(1)
                } else {
                    Text("\(store.sessionName(for: request)) asks: \(request.tool)")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(request.summary)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if request.isQuestion {
                // Picking answers needs the open panel.
                ActionButton("Answer", prominent: true, tint: Brand.color(.claude)) { store.setMode(.open) }
            } else if request.needsClaude {
                ActionButton("Ask in Claude", prominent: true, tint: Brand.color(.claude)) { store.answer(request, "ask") }
            } else {
                ActionButton("Deny") { store.answer(request, "deny") }
                ActionButton("Allow", prominent: true) { store.answer(request, "allow") }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Metrics.permissionWidth, height: Metrics.squircle)
        .glassEffect(.regular, in: squircle(Radius.squircle))
    }
}
