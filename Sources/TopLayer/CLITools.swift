import AppKit
import Foundation

/// What Setup knows about the two command-line tools and the two desktop apps.
struct ToolVersions: Equatable {
    var claude: String?             // installed version of the claude command, nil if not installed
    var claudeSignedIn: Bool?
    var claudeLatest: String?       // newest published version, nil if it could not be looked up
    var codex: String?
    var codexLatest: String?
    var claudeApp: String?
    var codexApp: String?
    var checked: Date?
}

/// Looks at the `claude` and `codex` commands: whether they are installed, signed in
/// and current, and runs their own updaters.
///
/// TopLayer needs them for different things. Codex's command runs the background
/// service everything Codex goes through. Claude's is only needed to start sessions in
/// the background; sessions in the desktop app use the copy that app carries.
enum CLITools {
    enum Tool: String { case claude = "Claude", codex = "Codex" }

    static func binary(_ tool: Tool) -> String? { tool == .claude ? ClaudeCLI.binary : CodexDaemon.binary }

    /// What to paste into a terminal to install the tool, as its maker documents it.
    static func installCommand(_ tool: Tool) -> String {
        tool == .claude ? "curl -fsSL https://claude.ai/install.sh | bash" : "npm install -g @openai/codex"
    }

    /// The first thing that looks like a version number in a command's output.
    static func version(in text: String) -> String? {
        text.split(whereSeparator: { !($0.isNumber || $0 == ".") })
            .map(String.init)
            .first { $0.split(separator: ".").count >= 2 && $0.first?.isNumber == true && $0.last?.isNumber == true }
    }

    /// Whether version `a` is newer than `b`, comparing number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Runs a command and returns what it printed. Call off the main thread.
    static func run(_ binary: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// The newest version of a package published on the npm registry, which is where
    /// both tools publish theirs. Nothing about you is sent: it is a plain lookup.
    private static func latest(_ package: String) -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/\(package)/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("TopLayer", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var version: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = object["version"] as? String
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return version
    }

    private static func appVersion(_ path: String) -> String? {
        Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Checks everything. Calls back on the main thread.
    static func check(_ done: @escaping (ToolVersions) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var found = ToolVersions()
            if let claude = binary(.claude) {
                found.claude = version(in: run(claude, ["--version"]).output)
                let status = run(claude, ["auth", "status", "--json"]).output
                found.claudeSignedIn = (try? JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])?["loggedIn"] as? Bool
            }
            if let codex = binary(.codex) {
                found.codex = version(in: run(codex, ["--version"]).output)
            }
            found.claudeLatest = latest("@anthropic-ai/claude-code")
            found.codexLatest = latest("@openai/codex")
            found.claudeApp = appVersion("/Applications/Claude.app")
            found.codexApp = appVersion("/Applications/ChatGPT.app")
            found.checked = Date()
            DispatchQueue.main.async { done(found) }
        }
    }

    /// Runs a tool's own updater. Calls back on the main thread with what it said last.
    static func update(_ tool: Tool, _ done: @escaping (Bool, String) -> Void) {
        guard let binary = binary(tool) else { return done(false, "The \(tool.rawValue.lowercased()) command is not installed.") }
        DispatchQueue.global(qos: .utility).async {
            let result = run(binary, ["update"])
            let last = result.output.split(whereSeparator: \.isNewline).map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            DispatchQueue.main.async {
                done(result.ok, last ?? (result.ok ? "\(tool.rawValue) is up to date." : "The update did not finish."))
            }
        }
    }
}
