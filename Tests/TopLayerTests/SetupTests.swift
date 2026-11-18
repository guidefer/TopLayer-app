import Foundation
import Testing
@testable import TopLayer

/// A scratch folder standing in for ~/.claude, ~/.codex and ~/.toplayer/bin.
private struct Scratch {
    let dir: String
    var settings: String { dir + "/settings.json" }
    var config: String { dir + "/config.toml" }
    var notes: String { dir + "/CLAUDE.md" }
    var bin: String { dir + "/bin" }

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("toplayer-setup-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func write(_ text: String, to path: String) { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    var backups: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains("toplayer-backup") }
    }
    func hookCommands(_ event: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = (json["hooks"] as? [String: Any])?[event] as? [[String: Any]] else { return [] }
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }
}

struct ClaudeHooksTests {
    private static let someoneElses = """
    {
      "theme": "dark",
      "hooks": {
        "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/guard.sh" } ] } ],
        "Stop": [
          { "hooks": [ { "type": "command", "command": "/usr/local/bin/their-stop.sh" } ] },
          { "hooks": [ { "type": "command", "command": "/old/place/toplayer-inbox.sh" } ] }
        ]
      }
    }
    """

    @Test func installingAddsEveryHookAndKeepsOtherPeoplesHooks() throws {
        let s = Scratch()
        s.write(Self.someoneElses, to: s.settings)
        #expect(ClaudeHooks.status(settingsPath: s.settings, bin: s.bin).outdated == ["Stop"])

        try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin)

        #expect(ClaudeHooks.status(settingsPath: s.settings, bin: s.bin).isComplete)
        #expect(s.hookCommands("PreToolUse") == ["/usr/local/bin/guard.sh"])
        #expect(s.hookCommands("Stop") == ["/usr/local/bin/their-stop.sh", s.bin + "/toplayer-hook.sh"],
                "the old TopLayer hook is replaced, the other one stays")
        #expect(s.read(s.settings).contains("\"theme\""))
    }

    @Test func installingTwiceDoesNotDuplicate() throws {
        let s = Scratch()
        try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin)
        try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin)
        #expect(s.hookCommands("Stop").count == 1)
    }

    @Test func removingTakesOutOnlyOurHooks() throws {
        let s = Scratch()
        s.write(Self.someoneElses, to: s.settings)
        try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin)
        try ClaudeHooks.remove(settingsPath: s.settings)
        #expect(s.hookCommands("Stop") == ["/usr/local/bin/their-stop.sh"])
        #expect(s.hookCommands("PreToolUse") == ["/usr/local/bin/guard.sh"])
        #expect(s.hookCommands("SessionStart").isEmpty)
    }

    @Test func aSettingsFileThatIsNotValidJSONIsLeftAlone() {
        let s = Scratch()
        s.write("{ this is not json", to: s.settings)
        #expect(ClaudeHooks.status(settingsPath: s.settings, bin: s.bin).problem != nil)
        #expect(throws: (any Error).self) { try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin) }
        #expect(s.read(s.settings) == "{ this is not json")
    }

    @Test func everyEditLeavesItsOwnBackup() throws {
        let s = Scratch()
        s.write(Self.someoneElses, to: s.settings)
        try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin)
        try ClaudeHooks.install(settingsPath: s.settings, bin: s.bin)     // same second as the first
        #expect(s.backups.count == 2)
    }
}

struct CodexToolTests {
    private static let existing = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n"

    @Test func addingThenRemovingLeavesTheFileExactlyAsItWas() throws {
        let s = Scratch()
        s.write(Self.existing, to: s.config)
        #expect(CodexTool.status(configPath: s.config, bin: s.bin) == .missing)

        try CodexTool.install(configPath: s.config, bin: s.bin)
        #expect(CodexTool.status(configPath: s.config, bin: s.bin) == .configured)
        #expect(s.read(s.config).contains("[mcp_servers.other]"))

        try CodexTool.remove(configPath: s.config)
        #expect(s.read(s.config) == Self.existing)
    }

    @Test func installingTwiceKeepsOneEntry() throws {
        let s = Scratch()
        s.write(Self.existing, to: s.config)
        try CodexTool.install(configPath: s.config, bin: s.bin)
        try CodexTool.install(configPath: s.config, bin: s.bin)
        #expect(s.read(s.config).components(separatedBy: "[mcp_servers.toplayer]").count == 2)
    }

    @Test func anEntryPointingElsewhereIsReported() {
        let s = Scratch()
        s.write("[mcp_servers.toplayer]\ncommand = \"/somewhere/else\"\n", to: s.config)
        #expect(CodexTool.status(configPath: s.config, bin: s.bin) == .different("/somewhere/else"))
    }

    @Test func anEntryWithoutPreApprovalIsReported() {
        let s = Scratch()
        s.write("[mcp_servers.toplayer]\ncommand = \"\(s.bin)/toplayer-link\"\nargs = [\"mcp\"]\n", to: s.config)
        #expect(CodexTool.status(configPath: s.config, bin: s.bin) == .needsApproval)
    }

    @Test func aSectionAfterOursIsNotSwallowedOnRemoval() throws {
        let s = Scratch()
        s.write("[mcp_servers.toplayer]\ncommand = \"/x\"\n\n[mcp_servers.after]\ncommand = \"/bin/after\"\n", to: s.config)
        try CodexTool.remove(configPath: s.config)
        #expect(s.read(s.config).contains("[mcp_servers.after]"))
        #expect(!s.read(s.config).contains("[mcp_servers.toplayer]"))
    }
}

struct ClaudeNoteTests {
    private static let existing = "# Mine\n\nBe brief.\n"

    @Test func addingCreatesTheFileWhenThereIsNone() throws {
        let s = Scratch()
        #expect(ClaudeNote.status(path: s.notes) == .missing)
        try ClaudeNote.install(path: s.notes)
        #expect(ClaudeNote.status(path: s.notes) == .current)
        #expect(s.read(s.notes).hasPrefix(ClaudeNote.startMarker))
        #expect(s.backups.isEmpty)                       // nothing existed to back up
    }

    @Test func addingKeepsWhatWasThereAndRemovingRestoresItExactly() throws {
        let s = Scratch()
        s.write(Self.existing, to: s.notes)
        try ClaudeNote.install(path: s.notes)
        #expect(s.read(s.notes).hasPrefix(Self.existing))
        #expect(ClaudeNote.status(path: s.notes) == .current)

        try ClaudeNote.remove(path: s.notes)
        #expect(s.read(s.notes) == Self.existing)
        #expect(s.backups.count == 2)
    }

    @Test func removingFromAFileWithNothingElseRemovesTheFile() throws {
        let s = Scratch()
        try ClaudeNote.install(path: s.notes)
        try ClaudeNote.remove(path: s.notes)
        #expect(!FileManager.default.fileExists(atPath: s.notes))
        #expect(s.backups.count == 1)
    }

    @Test func addingTwiceKeepsOneSection() throws {
        let s = Scratch()
        s.write(Self.existing, to: s.notes)
        try ClaudeNote.install(path: s.notes)
        try ClaudeNote.install(path: s.notes)
        #expect(s.read(s.notes).components(separatedBy: ClaudeNote.endMarker).count == 2)
    }

    @Test func anOlderWordingIsReportedAndUpdatedInPlace() throws {
        let s = Scratch()
        let old = "# Mine\n\n<!-- TopLayer:start (an older marker) -->\nOld words.\n\(ClaudeNote.endMarker)\n\n## After\n\nStill here.\n"
        s.write(old, to: s.notes)
        #expect(ClaudeNote.status(path: s.notes) == .outdated)

        try ClaudeNote.install(path: s.notes)
        let text = s.read(s.notes)
        #expect(ClaudeNote.status(path: s.notes) == .current)
        #expect(!text.contains("Old words."))
        #expect(text.hasPrefix("# Mine\n\n\(ClaudeNote.startMarker)"))
        #expect(text.hasSuffix("## After\n\nStill here.\n"))
    }

    @Test func removingWhenThereIsNoSectionTouchesNothing() throws {
        let s = Scratch()
        s.write(Self.existing, to: s.notes)
        #expect(try ClaudeNote.remove(path: s.notes) == nil)
        #expect(s.read(s.notes) == Self.existing)
        #expect(s.backups.isEmpty)
    }

    /// The note quotes the first line of each kind of message. If the hook's wording
    /// changes and the note's does not, Claude is told to look for lines that never come.
    @Test func theNoteQuotesTheHookWordForWord() throws {
        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Hooks/toplayer-hook.sh")
        let script = try String(contentsOf: hook, encoding: .utf8)
        let openings = [
            "Message incoming from TopLayer. The user typed this in their TopLayer overlay as a reply in this session:",
            "Message incoming from a TopLayer group chat.",
            "Notice from TopLayer, triggered by the user in their TopLayer overlay:",
        ]
        for opening in openings {
            #expect(script.contains("echo \"\(opening)"), "the hook no longer prints: \(opening)")
            #expect(ClaudeNote.text.contains("\"\(opening)\""), "the note no longer quotes: \(opening)")
        }
    }
}

struct LinkToolTests {
    /// Stands in for toplayer-link with a small script.
    private func tool(_ body: String) -> Scratch {
        let scratch = Scratch()
        try? FileManager.default.createDirectory(atPath: scratch.bin, withIntermediateDirectories: true)
        let path = scratch.bin + "/toplayer-link"
        scratch.write("#!/bin/sh\n\(body)\n", to: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return scratch
    }

    @Test func aToolThatPrintsItsUsageCountsAsRunning() {
        #expect(Helpers.linkRuns(bin: tool("echo usage >&2; exit 2").bin))
    }

    @Test func aToolThatIsKilledDoesNot() {
        #expect(!Helpers.linkRuns(bin: tool("kill -9 $$").bin))
    }

    @Test func aMissingToolDoesNot() {
        #expect(!Helpers.linkRuns(bin: Scratch().bin))
    }
}
