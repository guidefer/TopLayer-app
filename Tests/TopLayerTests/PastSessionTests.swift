import Foundation
import Testing
@testable import TopLayer

/// Finding a Claude session's title and folder from its transcript, for sessions that
/// are no longer running.
struct PastSessionTests {
    private func transcript(_ lines: [String]) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toplayer-past-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("0f3c-session.jsonl").path
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private let prompt = #"{"type":"user","cwd":"/work/app","message":{"role":"user","content":"Fix the login page\nand the footer"}}"#

    @Test func theSessionIdIsTheFileName() {
        let session = ClaudeBridge.PastSession.read(path: transcript([prompt]))
        #expect(session?.sessionId == "0f3c-session")
        #expect(session?.cwd == "/work/app")
    }

    @Test func theNameYouGaveItWinsAndTheLatestOneCounts() {
        let session = ClaudeBridge.PastSession.read(path: transcript([
            #"{"type":"custom-title","customTitle":"First name","sessionId":"x"}"#,
            #"{"type":"ai-title","aiTitle":"Generated name","sessionId":"x"}"#,
            prompt,
            #"{"type":"custom-title","customTitle":"Renamed","sessionId":"x"}"#,
        ]))
        #expect(session?.title == "Renamed")
    }

    @Test func aGeneratedTitleIsUsedWhenYouGaveNone() {
        let session = ClaudeBridge.PastSession.read(path: transcript([#"{"type":"ai-title","aiTitle":"Generated name"}"#, prompt]))
        #expect(session?.title == "Generated name")
    }

    @Test func withNoTitleItIsTheFirstLineOfWhatYouFirstTyped() {
        let injected = #"{"type":"user","message":{"role":"user","content":"<system-reminder>not typed</system-reminder>"}}"#
        let session = ClaudeBridge.PastSession.read(path: transcript([injected, prompt]))
        #expect(session?.title == "Fix the login page")
    }

    @Test func aPromptMadeOfBlocksIsReadToo() {
        let blocks = #"{"type":"user","cwd":"/w","message":{"content":[{"type":"image"},{"type":"text","text":"Describe this"}]}}"#
        #expect(ClaudeBridge.PastSession.read(path: transcript([blocks]))?.title == "Describe this")
    }

    @Test func theTitleIsFoundAtTheEndOfALongTranscript() {
        // The middle of the file is never read, however long it is.
        let filler = #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 4000))"}}"#
        var lines = [prompt]
        lines += Array(repeating: filler, count: 120)
        lines.append(#"{"type":"custom-title","customTitle":"Named at the end"}"#)
        let session = ClaudeBridge.PastSession.read(path: transcript(lines), window: 16 * 1024)
        #expect(session?.title == "Named at the end")
        #expect(session?.cwd == "/work/app")
    }

    @Test func anEmptyTranscriptStillGetsAName() {
        #expect(ClaudeBridge.PastSession.read(path: transcript([]))?.title == "Untitled session")
    }

    @Test func sessionsAreListedNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toplayer-projects-\(UUID().uuidString)").path
        for (name, age) in [("old", 300.0), ("new", 10.0)] {
            let dir = root + "/-work-\(name)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/\(name).jsonl"
            try #"{"type":"custom-title","customTitle":"\#(name)"}"#.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
        }
        #expect(ClaudeBridge.pastSessions(projects: root).map(\.title) == ["new", "old"])
    }
}
