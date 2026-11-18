import Foundation

/// Codex's background service (its "app-server daemon"), which TopLayer talks to.
///
/// It runs on its own, whether or not the Codex desktop app is open, but it can stop:
/// after an update, a crash, or a restart of the Mac. TopLayer cannot do anything with
/// Codex while it is down, so it starts it again by itself.
enum CodexDaemon {
    /// Where the `codex` command may be installed.
    static var binary: String? {
        [NSHomeDirectory() + "/.local/bin/codex",
         NSHomeDirectory() + "/.codex/packages/standalone/current/bin/codex",
         "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// How long the connection has to be down before the next attempt to start the
    /// service, counted from the previous attempt (or from when it went down).
    ///
    /// The first wait is short but not zero: the service restarts itself now and then,
    /// and a plain reconnect is all that needs. After that the waits grow, so a service
    /// that cannot start is not hammered.
    static func wait(beforeAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 5
        case 2: 30
        case 3: 120
        default: 300
        }
    }

    /// Asks Codex to start the service. `done` is called on the main thread with
    /// whether the command succeeded; the connection itself comes back a moment later.
    static func start(done: @escaping (Bool, String) -> Void) {
        guard let binary else { return done(false, "Couldn't find the codex command to start its background service.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "daemon", "start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                finished.terminationStatus == 0
                    ? done(true, "Asked Codex to start its background service. TopLayer reconnects within a few seconds.")
                    : done(false, "Codex could not start its background service (exit \(finished.terminationStatus)).")
            }
        }
        do { try process.run() } catch { done(false, "Couldn't run codex: \(error.localizedDescription)") }
    }
}
