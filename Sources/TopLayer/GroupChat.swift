import Foundation

// A group chat links one Claude session and one Codex thread, with you as the third
// member. These are the plain values; `GroupChatBroker` owns them and enforces the rules.

/// Who wrote a message in a group chat.
enum ChatAuthor: String, Codable {
    case claude, codex, you

    init(_ source: AgentSource) { self = source == .claude ? .claude : .codex }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .you: "You"
        }
    }

    var source: AgentSource? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .you: nil
        }
    }
}

/// One agent's side of a group chat. The token is how the agent proves which side it is.
struct ChatMember: Codable, Equatable {
    let source: AgentSource
    let rawId: String
    var title: String
    let token: String
}

struct GroupMessage: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        /// Sent through the chat: an agent to the other agent, or you to one or both.
        case message
        /// An agent's answer to something you posted, picked up from its own thread.
        /// Only you see it; it is never forwarded to the other agent.
        case reply
    }

    let id: String
    let from: ChatAuthor
    let to: [AgentSource]
    let text: String
    let time: Date
    let kind: Kind
    /// Delivery state per recipient (keyed by the recipient's name): needs approval,
    /// queued, delivered, rejected, or "failed: …".
    var delivery: [String: String] = [:]

    var needsApproval: Bool { delivery.values.contains("needs approval") }
}

/// The constraints you set on a group chat. All of them are enforced by the broker.
struct GroupChatSettings: Codable, Equatable {
    /// Minimum time between exchanges one agent starts. A direct answer to the other
    /// agent's message is exempt, once.
    var minInterval: TimeInterval = 300
    /// Agent-to-agent messages allowed in total. 0 means no limit.
    var maxMessages = 20
    /// How long the chat stays connected. 0 means until you disconnect it.
    var duration: TimeInterval = 3600
    /// Hold every agent-to-agent message until you approve it.
    var requireApproval = false
    /// Tell both agents when you pause, resume or end the chat.
    var notifyAgents = false

    static let intervalChoices: [(label: String, value: TimeInterval)] = [
        ("No delay", 0), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900),
    ]
    static let capChoices: [(label: String, value: Int)] = [
        ("10", 10), ("20", 20), ("50", 50), ("100", 100), ("No limit", 0),
    ]
    static let durationChoices: [(label: String, value: TimeInterval)] = [
        ("1 hour", 3600), ("5 hours", 18000), ("12 hours", 43200), ("1 day", 86400), ("Until disconnected", 0),
    ]

    /// New chats start with whatever you last chose.
    static var defaults: GroupChatSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "groupChatDefaults"),
                  let saved = try? JSONDecoder().decode(GroupChatSettings.self, from: data) else { return GroupChatSettings() }
            return saved
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "groupChatDefaults") }
    }

    var intervalLabel: String {
        Self.intervalChoices.first { $0.value == minInterval }?.label ?? "\(Int(minInterval)) seconds"
    }
}

struct GroupChat: Identifiable, Codable, Equatable {
    let id: String
    var claude: ChatMember
    var codex: ChatMember
    var messages: [GroupMessage] = []
    var settings: GroupChatSettings
    var started = Date()
    var expires: Date?
    var paused = false

    /// When each member (by token) last started an exchange.
    var lastInitiated: [String: Date] = [:]
    /// Members (by token) who may answer the other agent once without waiting.
    var replyCredit: [String] = []
    /// Agents (by name) whose next finished turn is their answer to something you posted.
    var awaitingReply: [String] = []
    /// Of those, the ones your message has actually reached.
    var captureArmed: [String] = []

    var rowId: String { "chat:\(id)" }
    var title: String { "\(claude.title) ⇄ \(codex.title)" }

    func member(token: String) -> ChatMember? {
        token == claude.token ? claude : token == codex.token ? codex : nil
    }
    func member(_ source: AgentSource) -> ChatMember { source == .claude ? claude : codex }
    func other(of member: ChatMember) -> ChatMember { member.source == .claude ? codex : claude }

    /// Agent-to-agent messages that count against the cap.
    var agentMessageCount: Int {
        messages.filter { $0.kind == .message && $0.from != .you && !$0.delivery.values.contains("rejected") }.count
    }

    var remaining: Int? {
        settings.maxMessages == 0 ? nil : max(0, settings.maxMessages - agentMessageCount)
    }

    var isExpired: Bool { expires.map { Date() > $0 } ?? false }

    var pendingApprovals: Int { messages.filter(\.needsApproval).count }

    /// One line for the sidebar and the pane header.
    var statusLine: String {
        if paused { return "Paused" }
        if pendingApprovals > 0 { return "\(pendingApprovals) waiting for your approval" }
        let used = settings.maxMessages == 0 ? "\(agentMessageCount) messages" : "\(agentMessageCount) of \(settings.maxMessages) messages"
        return used
    }
}
