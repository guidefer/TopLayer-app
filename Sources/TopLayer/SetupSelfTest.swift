import Foundation

/// Runs the installers against copies in a scratch directory and prints what happened.
/// Used to check them without going near the real Claude or Codex files.
enum SetupSelfTest {
    static func run(in dir: String) {
        let bin = dir + "/bin"
        let settings = dir + "/settings.json"
        let config = dir + "/config.toml"
        func show(_ label: String, _ value: Any) { print("\(label): \(value)") }
        func attempt(_ label: String, _ work: () throws -> String?) {
            do { show(label, try work() ?? "done") } catch { show(label, "FAILED \(error.localizedDescription)") }
        }

        print("== Claude hooks")
        show("before", ClaudeHooks.status(settingsPath: settings, bin: bin))
        attempt("install") { try ClaudeHooks.install(settingsPath: settings, bin: bin).map { ($0 as NSString).lastPathComponent } }
        show("after install", ClaudeHooks.status(settingsPath: settings, bin: bin))
        attempt("install again") { try ClaudeHooks.install(settingsPath: settings, bin: bin).map { _ in "backed up" } }
        show("after second install", ClaudeHooks.status(settingsPath: settings, bin: bin))
        attempt("remove") { try ClaudeHooks.remove(settingsPath: settings).map { _ in "backed up" } }
        show("after remove", ClaudeHooks.status(settingsPath: settings, bin: bin))

        print("== Note for Claude")
        let notes = dir + "/CLAUDE.md"
        show("before", ClaudeNote.status(path: notes))
        attempt("install") { try ClaudeNote.install(path: notes).map { ($0 as NSString).lastPathComponent } }
        show("after install", ClaudeNote.status(path: notes))
        attempt("install again") { try ClaudeNote.install(path: notes).map { _ in "backed up" } }
        show("after second install", ClaudeNote.status(path: notes))
        attempt("remove") { try ClaudeNote.remove(path: notes).map { _ in "backed up" } }
        show("after remove", ClaudeNote.status(path: notes))

        print("== Codex tool")
        show("before", CodexTool.status(configPath: config, bin: bin))
        attempt("install") { try CodexTool.install(configPath: config, bin: bin).map { ($0 as NSString).lastPathComponent } }
        show("after install", CodexTool.status(configPath: config, bin: bin))
        attempt("install again") { try CodexTool.install(configPath: config, bin: bin).map { _ in "backed up" } }
        show("after second install", CodexTool.status(configPath: config, bin: bin))
        attempt("remove") { try CodexTool.remove(configPath: config).map { _ in "backed up" } }
        show("after remove", CodexTool.status(configPath: config, bin: bin))

        print("== Helpers")
        show("status", Helpers.status(bin: bin, bundled: dir + "/bundled"))
        attempt("install") { try Helpers.install(bin: bin, bundled: dir + "/bundled"); return nil }
        show("after install", Helpers.status(bin: bin, bundled: dir + "/bundled"))
    }
}
