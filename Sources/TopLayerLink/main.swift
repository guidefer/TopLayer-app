import Foundation

// toplayer-link: how an agent talks to a TopLayer group chat.
//
// It is stateless. Every call drops one request file for the TopLayer overlay (the
// broker) and waits for the overlay's answer. All rules (who is linked, how often a
// member may send, pausing, limits) live in the overlay, never here.
//
//   toplayer-link mcp                       MCP server over stdio (tools: send_message, link_status)
//   toplayer-link send <token> <message>    same thing from a shell
//   toplayer-link status <token>

let root = NSHomeDirectory() + "/.toplayer"
let requestsDir = root + "/link/requests"
let responsesDir = root + "/link/responses"

func overlayAlive() -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/overlay.alive")
    guard let modified = attributes?[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(modified) < 15
}

/// Hands one request to the overlay and waits for its decision.
func broker(_ payload: [String: Any]) -> [String: Any] {
    guard overlayAlive() else {
        return ["status": "failed", "detail": "TopLayer is not running, so nothing was sent."]
    }
    let id = UUID().uuidString
    var body = payload
    body["id"] = id
    let fm = FileManager.default
    for dir in [requestsDir, responsesDir] {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let request = "\(requestsDir)/\(id).json"
    let response = "\(responsesDir)/\(id).json"
    guard let data = try? JSONSerialization.data(withJSONObject: body),
          (try? data.write(to: URL(fileURLWithPath: request + ".tmp"))) != nil,
          (try? fm.moveItem(atPath: request + ".tmp", toPath: request)) != nil else {
        return ["status": "failed", "detail": "Could not write the request for TopLayer."]
    }
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if let answer = fm.contents(atPath: response),
           let obj = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] {
            try? fm.removeItem(atPath: response)
            return obj
        }
        usleep(100_000)
    }
    try? fm.removeItem(atPath: request)
    return ["status": "failed", "detail": "TopLayer did not answer in time. Nothing was sent."]
}

func describe(_ result: [String: Any]) -> String {
    let status = result["status"] as? String ?? "failed"
    let detail = result["detail"] as? String ?? ""
    return detail.isEmpty ? "status: \(status)" : "status: \(status)\n\(detail)"
}

func isFailure(_ result: [String: Any]) -> Bool {
    let status = result["status"] as? String ?? "failed"
    return status != "queued" && status != "ok"
}

// MARK: Command line

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "send", arguments.count >= 3 {
    let result = broker(["action": "send", "token": arguments[1], "message": arguments[2...].joined(separator: " ")])
    print(describe(result))
    exit(isFailure(result) ? 1 : 0)
}
if arguments.first == "status", arguments.count >= 2 {
    let result = broker(["action": "status", "token": arguments[1]])
    print(describe(result))
    exit(isFailure(result) ? 1 : 0)
}
if !arguments.isEmpty && arguments.first != "mcp" {
    FileHandle.standardError.write(Data("usage: toplayer-link mcp | send <token> <message> | status <token>\n".utf8))
    exit(2)
}

// MARK: MCP server (JSON-RPC, one message per line, over stdio)

func emit(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(UInt8(ascii: "\n"))
    FileHandle.standardOutput.write(data)
}

let tokenProperty: [String: Any] = [
    "type": "string",
    "description": "Your member token for the group chat. TopLayer gave it to you when the user linked this conversation.",
]
let tools: [[String: Any]] = [
    [
        "name": "send_message",
        "description": "Send one message to the other AI agent in your TopLayer group chat. The user linked the two "
            + "conversations; the other agent sees only what you send here, not your conversation. TopLayer enforces "
            + "the user's limits and returns a status: queued, rate_limited, paused, limit_reached, not_linked or failed.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "token": tokenProperty,
                "message": ["type": "string", "description": "The message for the other agent. Make it self-contained."],
            ],
            "required": ["token", "message"],
        ],
    ],
    [
        "name": "link_status",
        "description": "Check your TopLayer group chat: whether it is active, how long until you may send again, "
            + "and how many messages are left.",
        "inputSchema": [
            "type": "object",
            "properties": ["token": tokenProperty],
            "required": ["token"],
        ],
    ],
]

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    let params = message["params"] as? [String: Any] ?? [:]
    guard let id = message["id"] else { continue }      // notifications need no answer

    switch method {
    case "initialize":
        emit(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "toplayer", "version": "0.0.1"],
        ] as [String: Any]])
    case "ping":
        emit(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
    case "tools/list":
        emit(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let input = params["arguments"] as? [String: Any] ?? [:]
        let token = input["token"] as? String ?? ""
        let result: [String: Any]
        switch name {
        case "send_message":
            result = broker(["action": "send", "token": token, "message": input["message"] as? String ?? ""])
        case "link_status":
            result = broker(["action": "status", "token": token])
        default:
            result = ["status": "failed", "detail": "Unknown tool \(name)."]
        }
        emit(["jsonrpc": "2.0", "id": id, "result": [
            "content": [["type": "text", "text": describe(result)]],
            "isError": isFailure(result),
        ] as [String: Any]])
    default:
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}
