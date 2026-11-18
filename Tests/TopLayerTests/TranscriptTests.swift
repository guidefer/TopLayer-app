import Foundation
import Testing
@testable import TopLayer

struct OverlayDeliveryTests {
    private func delivery(_ body: String, command: String = "Stop") -> String {
        "<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\n"
            + "Stop hook blocking error from command \"\(command)\": \(body)\n</system-reminder>"
    }
    private let userHeader = "Message incoming from TopLayer. The user typed this in their TopLayer overlay as a reply in this session:"

    @Test func aReplyTypedInTheOverlayIsReadBackAsYours() {
        let found = ClaudeBridge.overlayDeliveries(in: delivery("\(userHeader)\n\ndid it work?\n"), time: .now, key: "k")
        #expect(found.count == 1)
        #expect(found.first?.role == "user")
        #expect(found.first?.text == "did it work?")
        #expect(found.first?.fromOverlay == true)
    }

    @Test func aReplyWithSeveralParagraphsStaysWhole() {
        let found = ClaudeBridge.overlayDeliveries(in: delivery("\(userHeader)\n\nFirst.\n\nSecond.\n"), time: .now, key: "k")
        #expect(found.first?.text == "First.\n\nSecond.")
    }

    @Test func theOlderHeaderWordingIsStillRecognised() {
        let old = "Message from the user, typed in their TopLayer overlay as a reply in this session:"
        #expect(ClaudeBridge.overlayDeliveries(in: delivery("\(old)\n\nhello\n"), time: .now, key: "k").first?.text == "hello")
    }

    @Test func aPostFromAGroupChatLosesItsWrapper() {
        let body = "\(userHeader)\n\nFrom the user, in the TopLayer group chat that links this conversation with the Codex "
            + "conversation \"Build\":\n\nWhat changed?\n\n(Answer here as usual. TopLayer shows your answer to the user.)\n"
        let found = ClaudeBridge.overlayDeliveries(in: delivery(body, command: "PostToolUse:Bash"), time: .now, key: "k")
        #expect(found.first?.text == "What changed?")
        #expect(found.first?.label == "group chat")
    }

    @Test func aMessageFromTheOtherAgentIsMarkedAsAPeer() {
        let body = "Message incoming from a TopLayer group chat. It was written by another AI agent, NOT by the user:\n\n"
            + "From the linked Codex agent (\"Build\"):\n\nPort 8080.\n\n(Reply only if this asks for something.)\n"
        let found = ClaudeBridge.overlayDeliveries(in: delivery(body), time: .now, key: "k")
        #expect(found.first?.role == "peer")
        #expect(found.first?.label == "Codex")
        #expect(found.first?.text == "Port 8080.")
        #expect(found.first?.fromOverlay == false)
    }

    @Test func noticesAreNotShown() {
        let body = "Notice from TopLayer, triggered by the user in their TopLayer overlay:\n\nThe user paused this chat.\n"
        #expect(ClaudeBridge.overlayDeliveries(in: delivery(body), time: .now, key: "k").isEmpty)
    }

    @Test func severalMessagesDeliveredTogetherAreSeparated() {
        let body = "--- TopLayer message 1 of 2 ---\n\(userHeader)\n\nfirst\n\n--- TopLayer message 2 of 2 ---\n\(userHeader)\n\nsecond\n"
        let found = ClaudeBridge.overlayDeliveries(in: delivery(body), time: .now, key: "k")
        #expect(found.map(\.text) == ["first", "second"])
        #expect(Set(found.map(\.id)).count == 2)
    }
}

struct TranscriptReaderTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }
    private func user(_ text: String) -> String {
        line(["type": "user", "uuid": UUID().uuidString, "timestamp": "2026-01-01T00:00:00.000Z", "message": ["role": "user", "content": text]])
    }
    private func assistant(_ text: String) -> String {
        line(["type": "assistant", "uuid": UUID().uuidString, "timestamp": "2026-01-01T00:00:01.000Z",
              "message": ["role": "assistant", "content": [["type": "text", "text": text], ["type": "tool_use", "name": "Bash"]]]])
    }
    private func scratchFile(_ contents: String) -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("toplayer-transcript-\(UUID().uuidString).jsonl").path
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    private func append(_ text: String, to path: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    @Test func itKeepsWhatWasSaidAndSkipsTheMachinery() {
        let noise = line(["type": "user", "uuid": "x", "timestamp": "2026-01-01T00:00:00.000Z",
                          "message": ["role": "user", "content": "<system-reminder>internal</system-reminder>"]])
            + line(["type": "file-history-snapshot"])
            + line(["type": "user", "isMeta": true, "uuid": "y", "message": ["role": "user", "content": "meta"]])
        let path = scratchFile(user("Hi") + noise + assistant("Hello there"))
        let messages = TranscriptReader().read(path: path)
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(messages.map(\.text) == ["Hi", "Hello there"])
    }

    @Test func itOnlyReadsWhatWasAddedSinceLastTime() {
        let path = scratchFile(user("One") + assistant("Two"))
        let reader = TranscriptReader()
        #expect(reader.read(path: path).count == 2)
        append(user("Three"), to: path)
        #expect(reader.read(path: path).map(\.text) == ["One", "Two", "Three"])
    }

    @Test func aHalfWrittenLineWaitsUntilItIsComplete() {
        let path = scratchFile(user("One"))
        let reader = TranscriptReader()
        _ = reader.read(path: path)
        let pending = assistant("Two")
        append(String(pending.dropLast(10)), to: path)
        #expect(reader.read(path: path).count == 1)
        append(String(pending.suffix(10)), to: path)
        #expect(reader.read(path: path).map(\.text) == ["One", "Two"])
    }

    @Test func hugeEntriesDoNotHideTheMessagesAroundThem() {
        // A pasted screenshot is megabytes of base64 on one line.
        let huge = line(["type": "attachment", "data": String(repeating: "A", count: 3_000_000)])
        let path = scratchFile(user("Before") + huge + huge + assistant("After"))
        #expect(TranscriptReader().read(path: path).map(\.text) == ["Before", "After"])
    }

    @Test func switchingFilesStartsFresh() {
        let reader = TranscriptReader()
        _ = reader.read(path: scratchFile(user("First file")))
        #expect(reader.read(path: scratchFile(user("Second file"))).map(\.text) == ["Second file"])
    }
}
