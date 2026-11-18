import AppKit
import Foundation
import SwiftUI

enum AgentSource: String, Codable {
    case codex = "Codex"
    case claude = "Claude"
}

struct SessionRow: Identifiable, Equatable {
    let id: String          // "codex:<threadId>" or "claude:<sessionId>"
    let source: AgentSource
    let rawId: String
    var title: String
    var cwd: String
    var status: String      // idle | busy | active | notLoaded | ...
    var updatedAt: Double
    var unread = false
    var remoteId: String?   // Claude only: Remote Control session id
    var canReply = false    // Claude only: the session runs the TopLayer inbox hook
    /// Claude only: the session runs in a terminal (the claude command), not in the desktop app.
    var cli = false
    /// Claude only: the session is no longer running. Its transcript can be read, but
    /// there is nothing to deliver a reply to.
    var ended = false

    var isBusy: Bool { status == "busy" || status == "active" || status == "working" }
    /// The status in the overlay's words: every way of saying busy reads "working".
    var statusWord: String { isBusy ? "working" : status }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String        // user | assistant | system
    var text: String
    var status: String? = nil   // overlay replies to Claude: waiting | delivered
    var label: String? = nil    // extra context for the bubble's label, e.g. "group chat" or the peer's name
}

/// Timing shared by SwiftUI and the window, so content and frame move together.
enum Motion {
    /// TOPLAYER_DEBUG_SLOW=5 stretches every animation, to inspect the in-between frames.
    static let slow = ProcessInfo.processInfo.environment["TOPLAYER_DEBUG_SLOW"].flatMap(Double.init) ?? 1
    static let panel = Animation.spring(duration: 0.38 * slow, bounce: 0.16)
    /// Closing plays the opening back, faster and without the bounce.
    static let close = Animation.spring(duration: 0.22 * slow, bounce: 0)
    static let quick = Animation.easeOut(duration: 0.14 * slow)
    /// Opening is a cascade: the squircle becomes the header, then each piece follows the
    /// one before it after this long.
    static let openStep: TimeInterval = 0.11 * slow
    static let closeStep: TimeInterval = 0.06 * slow
    /// How long the window waits before shrinking, so content can finish animating out.
    static let settle: TimeInterval = 0.45 * slow
    static let closeSettle: TimeInterval = 0.3 * slow
}

/// The pieces that follow the header when the overlay opens, in the order they appear.
/// Closing removes them in the opposite order.
enum Piece: Int, CaseIterable {
    case group = 1, claude, codex, conversation
}

/// A reply sent to a Claude session from the overlay. Kept on disk until Claude's own
/// transcript shows it, so it is still in the thread after a restart.
struct SentReply: Codable, Equatable {
    let id: String
    let text: String
    let time: Date
    let file: String        // the inbox file name, which is also the receipt's name
    var delivered = false
}

/// Reply text typed but not sent, kept per thread and across restarts.
final class Drafts: ObservableObject {
    @Published private var text: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:]
    private var save: DispatchWorkItem?

    subscript(id: String) -> String {
        get { text[id] ?? "" }
        set {
            text[id] = newValue.isEmpty ? nil : newValue
            save?.cancel()
            let work = DispatchWorkItem { [weak self] in UserDefaults.standard.set(self?.text ?? [:], forKey: "drafts") }
            save = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
}

/// How much of the overlay is showing.
enum PanelMode: String {
    case collapsed      // the squircle, plus a short-lived notification pill
    case open           // compact panel in the squircle's corner
    case expanded       // large reading layout
}

/// The screen corner the overlay lives in. Panels grow out of this corner.
enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// A notification shown next to the squircle for a few seconds.
struct Peek: Equatable {
    let id = UUID()
    let text: String
    let rowId: String
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let rpcId: Any
    let threadId: String
    let summary: String
}

/// Single source of truth for the overlay UI. Main thread only.

func log(_ text: String) {
    FileHandle.standardError.write(Data("[toplayer] \(text)\n".utf8))
}
