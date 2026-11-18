import Foundation

/// One limit of a plan: how much of it is used, and when it starts again.
struct UsageLimit: Equatable, Identifiable {
    var id: String
    var name: String
    /// Percent used, 0 to 100.
    var used: Int
    var resets: Date?

    var left: Int { max(0, 100 - used) }
}

/// What a tool says about your plan's limits, as last read.
struct UsageReport: Equatable {
    var limits: [UsageLimit] = []
    var plan: String?
    /// Codex only: the credit balance, and how many free resets of the limits are banked.
    var credits: String?
    var freeResets = 0
    var fetched = Date()

    /// The limit closest to running out, which is the one worth showing first.
    var tightest: UsageLimit? { limits.max { $0.used < $1.used } }

    /// One line for a tooltip: "36% of this week (Fable) used, 64% left. Resets in 5 days."
    func summary(now: Date = Date()) -> String {
        guard let limit = tightest else { return "No limits reported" }
        var text = "\(limit.used)% of \(limit.name.lowercasedFirst) used, \(limit.left)% left."
        if let resets = limit.resets { text += " Resets \(Self.until(resets, now: now))." }
        return text
    }

    /// "in 5 days", "in 3 hours", "in 12 minutes", "now".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return "in \(hours) hour\(hours == 1 ? "" : "s")" }
        let days = Int((seconds / 86400).rounded())
        return "in \(days) days"
    }

    // MARK: Codex

    /// Reads the answer to Codex's `account/rateLimits/read`.
    static func codex(from result: [String: Any], now: Date = Date()) -> UsageReport {
        var report = UsageReport(fetched: now)
        let main = result["rateLimits"] as? [String: Any] ?? [:]
        var groups = [(name: String?, limits: [String: Any])]()
        groups.append((nil, main))
        // Limits that apply to one model or feature come under their own id and name.
        let byId = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        for (id, limits) in byId.sorted(by: { $0.key < $1.key }) where id != main["limitId"] as? String {
            groups.append((limits["limitName"] as? String ?? id, limits))
        }
        for (name, limits) in groups {
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any], let used = number(window["usedPercent"]) else { continue }
                let minutes = Int(number(window["windowDurationMins"]) ?? 0)
                let label = self.window(minutes: minutes)
                let stamp = number(window["resetsAt"])
                report.limits.append(UsageLimit(id: "\(name ?? "codex").\(key)",
                                                name: name.map { "\(label) (\($0))" } ?? label,
                                                used: min(100, max(0, Int(used.rounded()))),
                                                resets: stamp.map { Date(timeIntervalSince1970: $0) }))
            }
        }
        report.plan = (main["planType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let credits = main["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                report.credits = "Unlimited"
            } else if credits["hasCredits"] as? Bool == true, let balance = number(credits["balance"]) {
                let format = NumberFormatter()
                format.numberStyle = .decimal
                format.maximumFractionDigits = 0
                report.credits = format.string(from: NSNumber(value: balance))
            }
        }
        report.freeResets = Int(number((result["rateLimitResetCredits"] as? [String: Any])?["availableCount"]) ?? 0)
        return report
    }

    /// A limit's window in words: 300 minutes is "5-hour window", 10080 is "This week".
    static func window(minutes: Int) -> String {
        switch minutes {
        case 10080: return "This week"
        case 1440: return "Today"
        case 43200...44640: return "This month"
        case 0: return "Limit"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day window" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
            return "\(minutes)-minute window"
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    // MARK: Claude

    /// Reads the report Claude Code attaches to its answer to `/usage`. `output` is what
    /// the command printed: one JSON object per line.
    static func claude(fromOutput output: String, now: Date = Date()) -> UsageReport? {
        for line in output.split(separator: "\n") {
            guard line.contains("usage_report"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let found = object["usage_report"] as? [String: Any] else { continue }
            var report = UsageReport(fetched: now)
            let limits = (found["rate_limits"] as? [String: Any])?["limits"] as? [[String: Any]] ?? []
            for (index, limit) in limits.enumerated() {
                guard let percent = number(limit["percent"]) else { continue }
                let kind = limit["kind"] as? String ?? "limit"
                report.limits.append(UsageLimit(id: "\(kind).\(index)", name: claudeName(limit),
                                                used: min(100, max(0, Int(percent.rounded()))),
                                                resets: (limit["resets_at"] as? String).flatMap(date)))
            }
            return report
        }
        return nil
    }

    /// "Current session", "This week", "This week (Fable)".
    private static func claudeName(_ limit: [String: Any]) -> String {
        let kind = limit["kind"] as? String ?? ""
        let base: String
        if kind.hasPrefix("session") { base = "Current session" }
        else if kind.hasPrefix("weekly") || limit["group"] as? String == "weekly" { base = "This week" }
        else { base = kind.replacingOccurrences(of: "_", with: " ").capitalizedFirst }
        let scope = limit["scope"] as? [String: Any]
        let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
        let surface = scope?["surface"] as? String ?? (scope?["surface"] as? [String: Any])?["display_name"] as? String
        let detail = [model, surface].compactMap { $0 }.joined(separator: ", ")
        return detail.isEmpty ? base : "\(base) (\(detail))"
    }

    /// Claude's reset times look like 2026-11-23T00:00:00.775078+00:00. The fraction is
    /// longer than the system's date reader accepts, and nothing here needs it.
    static func date(_ text: String) -> Date? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Asks Claude Code for your plan's limits, the way `/usage` shows them.
///
/// There is no file or service to read them from, so TopLayer runs the `claude` command
/// once, without a terminal, with `/usage` as its only input. That is a local command: no
/// model is called and it costs nothing. The run has your hooks and tool servers switched
/// off (for that run only, your saved settings are untouched) and saves no session, so it
/// leaves no trace in your sessions or in the overlay. Claude uses its own sign-in, as it
/// does in any session; TopLayer never sees it.
enum ClaudeUsage {
    /// Where the command runs: a folder of its own, so that anything Claude keeps per
    /// folder stays away from your projects.
    static let folder = SetupPaths.toplayer + "/usage"

    static let arguments = ["-p", "/usage", "--output-format", "stream-json", "--verbose",
                            "--no-session-persistence", "--strict-mcp-config",
                            "--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#]

    enum Failure: Error, Equatable {
        case notInstalled, timedOut, noReport(String)

        var message: String {
            switch self {
            case .notInstalled: return "The claude command is not installed."
            case .timedOut: return "The claude command did not answer in time."
            case .noReport(let said):
                return said.isEmpty ? "Claude Code gave no usage report." : "Claude Code gave no usage report: \(said)"
            }
        }
    }

    /// Runs the command and hands back the report, on the main thread.
    static func fetch(timeout: TimeInterval = 40, done: @escaping (Result<UsageReport, Failure>) -> Void) {
        guard let binary = ClaudeCLI.binary else { return done(.failure(.notInstalled)) }
        DispatchQueue.global(qos: .utility).async {
            let result = run(binary: binary, timeout: timeout)
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func run(binary: String, timeout: TimeInterval) -> Result<UsageReport, Failure> {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failure(.notInstalled) }
        let started = Date()
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        watchdog.cancel()
        if let report = UsageReport.claude(fromOutput: output) { return .success(report) }
        if Date().timeIntervalSince(started) >= timeout { return .failure(.timedOut) }
        return .failure(.noReport(said(in: output)))
    }

    /// What the command answered in words, when it gave no report: usually why.
    static func said(in output: String) -> String {
        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "result", let text = object["result"] as? String else { continue }
            return String(text.components(separatedBy: .newlines)[0].prefix(140))
        }
        return ""
    }
}
