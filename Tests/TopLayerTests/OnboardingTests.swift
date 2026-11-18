import Foundation
import Testing
@testable import TopLayer

/// A scratch folder standing in for ~/.claude, ~/.codex and ~/.toplayer/bin, with the
/// scripts a build would carry.
private struct Scratch {
    let dir: String
    var targets: SetupTargets { .scratch(dir) }

    init(bundled: Bool = true) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("toplayer-welcome-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir + "/bundled", withIntermediateDirectories: true)
        guard bundled else { return }
        for name in Helpers.names {
            let path = "\(dir)/bundled/\(name)"
            try? "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: "\(dir)/\(name)") }
    var backups: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains("toplayer-backup") }
    }
}

private let both = FoundTools(claudeCommand: true, codexCommand: true)

struct OnboardingTests {
    @Test func onlyThePiecesForTheToolsThatWereFound() {
        let scratch = Scratch()
        func pieces(_ found: FoundTools) -> [SetupPiece] { Onboarding.steps(found: found, targets: scratch.targets).map(\.piece) }
        #expect(pieces(both) == [.helpers, .claudeHooks, .claudeNote, .codexTool])
        #expect(pieces(FoundTools(claudeApp: true)) == [.helpers, .claudeHooks, .claudeNote])
        #expect(pieces(FoundTools(codexCommand: true)) == [.helpers, .codexTool])
        #expect(pieces(FoundTools()) == [.helpers])
    }

    @Test func codexNeedsItsCommandButClaudeCanBeFoundAnyWay() {
        #expect(FoundTools(claudeFolder: true).claude)
        #expect(FoundTools(claudeApp: true).claude)
        #expect(!FoundTools(codexApp: true).codex)
        #expect(FoundTools(codexCommand: true).codex)
    }

    @Test func addsEverythingAndKeepsACopyOfWhatWasThere() throws {
        let scratch = Scratch()
        try #"{ "theme": "dark" }"#.write(toFile: scratch.dir + "/settings.json", atomically: true, encoding: .utf8)
        let before = Onboarding.steps(found: both, targets: scratch.targets)
        #expect(before.allSatisfy { !$0.inPlace })

        let outcomes = Onboarding.run(before.map(\.piece), targets: scratch.targets)
        #expect(outcomes[.helpers] == .done(backup: nil))
        #expect(outcomes[.claudeNote] == .done(backup: nil))        // there was no file to copy
        #expect(outcomes[.codexTool] == .done(backup: nil))
        guard case .done(let backup?) = outcomes[.claudeHooks] else {
            Issue.record("the settings file that existed was not backed up")
            return
        }
        let kept = try String(contentsOfFile: backup, encoding: .utf8)
        #expect(kept == #"{ "theme": "dark" }"#)
        #expect(scratch.backups.count == 1)
        let after = Onboarding.steps(found: both, targets: scratch.targets)
        #expect(after.allSatisfy { $0.inPlace })
    }

    @Test func withoutTheScriptsNothingElseIsTouched() {
        let scratch = Scratch(bundled: false)
        let outcomes = Onboarding.run(SetupPiece.allCases, targets: scratch.targets)
        guard case .failed = outcomes[.helpers] else {
            Issue.record("installing scripts that are not there should fail")
            return
        }
        #expect(outcomes[.claudeHooks] == .skipped)
        #expect(outcomes[.claudeNote] == .skipped)
        #expect(outcomes[.codexTool] == .skipped)
        #expect(!scratch.exists("settings.json"))
        #expect(!scratch.exists("CLAUDE.md"))
        #expect(!scratch.exists("config.toml"))
    }

    @Test func onlyTheChosenPiecesAreAdded() {
        let scratch = Scratch()
        let outcomes = Onboarding.run([.helpers, .codexTool], targets: scratch.targets)
        #expect(Set(outcomes.keys) == [.helpers, .codexTool])
        #expect(!scratch.exists("settings.json"))
        #expect(!scratch.exists("CLAUDE.md"))
        #expect(scratch.exists("config.toml"))
    }

    @Test func shownAtLaunchOnlyWhileSomethingNeededIsMissing() {
        let scratch = Scratch()
        #expect(Onboarding.isNeeded(found: both, targets: scratch.targets, done: false))
        #expect(!Onboarding.isNeeded(found: both, targets: scratch.targets, done: true))

        // Everything but the optional note: nothing TopLayer needs is missing.
        _ = Onboarding.run([.helpers, .claudeHooks, .codexTool], targets: scratch.targets)
        #expect(!Onboarding.isNeeded(found: both, targets: scratch.targets, done: false))
    }

    @Test func aMacWithNeitherToolIsStillOfferedTheGuide() {
        // The scripts are missing, and the guide is where installing a tool is explained.
        #expect(Onboarding.isNeeded(found: FoundTools(), targets: Scratch().targets, done: false))
    }

    @Test func eachPieceSaysWhichFileItChanges() {
        let targets = SetupTargets.scratch("/tmp/somewhere")
        #expect(SetupPiece.helpers.detail(targets).contains("/tmp/somewhere/bin"))
        #expect(SetupPiece.claudeHooks.detail(targets).contains("/tmp/somewhere/settings.json"))
        #expect(SetupPiece.claudeNote.detail(targets).contains("/tmp/somewhere/CLAUDE.md"))
        #expect(SetupPiece.codexTool.detail(targets).contains("/tmp/somewhere/config.toml"))
        #expect(SetupPiece.allCases.filter(\.optional) == [.claudeNote])
    }
}
