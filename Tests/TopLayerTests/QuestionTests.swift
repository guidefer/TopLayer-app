import Foundation
import Testing
@testable import TopLayer

private typealias Question = ClaudeBridge.AskedQuestion
private typealias Draft = ClaudeBridge.QuestionDraft

/// What Claude sends with an ask of three questions: pick one, pick several, pick one.
private let input: [String: Any] = ["questions": [
    ["question": "Which name?", "header": "Name", "multiSelect": false,
     "options": [["label": "Alpha", "description": "The first."], ["label": "Beta", "description": "The second."]]],
    ["question": "Which parts?", "header": "Parts", "multiSelect": true,
     "options": [["label": "One"], ["label": "Two"], ["label": "Three"]]],
    ["question": "Which licence?", "header": "Licence", "multiSelect": false,
     "options": [["label": "MIT"], ["label": "Apache 2.0"]]],
]]

struct QuestionTests {
    @Test func everyQuestionOfAnAskIsRead() {
        let questions = Question.parse(input)
        #expect(questions.map(\.text) == ["Which name?", "Which parts?", "Which licence?"])
        #expect(questions.map(\.id) == [0, 1, 2])
        #expect(questions.map(\.multiSelect) == [false, true, false])
        #expect(questions[0].header == "Name")
        #expect(questions[0].options == [.init(label: "Alpha", detail: "The first."), .init(label: "Beta", detail: "The second.")])
        #expect(questions[1].options.map(\.detail) == ["", "", ""])
    }

    @Test func anAskThatCannotBeAnsweredHereIsLeftToClaude() {
        #expect(Question.parse([:]).isEmpty)
        #expect(Question.parse(["questions": [[String: Any]]()]).isEmpty)
        // One question with nothing to pick spoils the whole ask: answering only part of it is the bug.
        let broken: [String: Any] = ["questions": [
            ["question": "Fine?", "options": [["label": "Yes"]]],
            ["question": "No options", "options": [[String: Any]]()],
        ]]
        #expect(Question.parse(broken).isEmpty)
    }

    @Test func oneAnswerQuestionsKeepOnlyTheLastPick() {
        let question = Question.parse(input)[0]
        var draft = Draft()
        #expect(draft.answer(for: question) == nil)
        draft.toggle("Alpha", in: question)
        draft.toggle("Beta", in: question)
        #expect(draft.answer(for: question) == "Beta")
        draft.toggle("Beta", in: question)                  // picking it again takes it back
        #expect(draft.answer(for: question) == nil)
    }

    @Test func severalAnswersAreJoinedInTheOrderTheyWereOffered() {
        let question = Question.parse(input)[1]
        var draft = Draft()
        draft.toggle("Three", in: question)
        draft.toggle("One", in: question)
        #expect(draft.answer(for: question) == "One, Three")
        draft.toggle("One", in: question)
        #expect(draft.answer(for: question) == "Three")
    }

    @Test func aTypedAnswerReplacesThePickWhereOneIsAllowed() {
        let question = Question.parse(input)[2]
        var draft = Draft()
        draft.toggle("MIT", in: question)
        draft.toggleTyping(in: question)
        #expect(draft.answer(for: question) == nil)         // nothing typed yet, and the pick is gone
        draft.typed[question.id] = "  Something else  "
        #expect(draft.answer(for: question) == "Something else")
        draft.toggle("Apache 2.0", in: question)            // picking an option drops the typed answer
        #expect(draft.answer(for: question) == "Apache 2.0")
    }

    @Test func aTypedAnswerIsAddedToThePicksWhereSeveralAreAllowed() {
        let question = Question.parse(input)[1]
        var draft = Draft()
        draft.toggle("Two", in: question)
        draft.toggleTyping(in: question)
        draft.typed[question.id] = "and a fourth"
        #expect(draft.answer(for: question) == "Two, and a fourth")
    }

    @Test func nothingIsSentUntilEveryQuestionHasAnAnswer() {
        let questions = Question.parse(input)
        var draft = Draft()
        draft.toggle("Alpha", in: questions[0])
        #expect(draft.answers(for: questions) == nil)       // the first alone is not the whole ask
        draft.toggle("One", in: questions[1])
        #expect(draft.answers(for: questions) == nil)
        draft.toggle("MIT", in: questions[2])
        #expect(draft.answers(for: questions) == ["Which name?": "Alpha", "Which parts?": "One", "Which licence?": "MIT"])
    }

    @Test func theReplyHandsClaudeItsQuestionsBackWithTheAnswers() throws {
        let data = try JSONSerialization.data(withJSONObject: input)
        let reply = try #require(ClaudeBridge.questionReply(input: data, answers: ["Which name?": "Alpha"]))
        #expect(reply.hasPrefix("{"))                       // how the hook tells it from "allow" and "deny"
        #expect(!reply.contains("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(output["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Which name?": "Alpha"])
        #expect((updated["questions"] as? [[String: Any]])?.count == 3)
    }

    @Test func aRequestIsAQuestionOnlyWhenItsQuestionsCouldBeRead() {
        let plain = ClaudeBridge.PermissionRequest(id: "a", sessionId: "s", tool: "Bash", summary: "ls")
        #expect(!plain.isQuestion)
        var ask = ClaudeBridge.PermissionRequest(id: "b", sessionId: "s", tool: "AskUserQuestion", summary: "")
        #expect(!ask.isQuestion)                            // unreadable: shown as before, answered in Claude
        ask.questions = Question.parse(input)
        #expect(ask.isQuestion)
    }
}
