import Foundation
import Testing
@testable import TopLayer

/// A turn that ends while the session's own agents are still at work is not a finished
/// thread: the session carries on when they report back.
struct TurnEndTests {
    private func stop(_ tasks: [[String: Any]]?) -> [String: Any] {
        var event: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1"]
        if let tasks { event["background_tasks"] = tasks }
        return event
    }

    @Test func aTurnWithNothingRunningIsFinished() {
        #expect(!ClaudeBridge.hasAgentsRunning(stop(nil)))
        #expect(!ClaudeBridge.hasAgentsRunning(stop([])))
    }

    @Test func aTurnWithAnAgentStillRunningIsNotFinished() {
        let agent: [String: Any] = ["id": "a1", "type": "subagent", "status": "running", "agent_type": "general-purpose"]
        #expect(ClaudeBridge.hasAgentsRunning(stop([agent])))
        #expect(ClaudeBridge.hasAgentsRunning(stop([["id": "w1", "type": "workflow", "status": "running"]])))
    }

    @Test func anAgentThatHasReportedBackDoesNotHoldTheTurnOpen() {
        #expect(!ClaudeBridge.hasAgentsRunning(stop([["id": "a1", "type": "subagent", "status": "completed"]])))
    }

    @Test func aServerLeftRunningDoesNotHoldTheTurnOpen() {
        // A shell command or a monitor can run for as long as the session does.
        let shell: [String: Any] = ["id": "b1", "type": "shell", "status": "running"]
        let monitor: [String: Any] = ["id": "m1", "type": "monitor", "status": "running"]
        #expect(!ClaudeBridge.hasAgentsRunning(stop([shell, monitor])))
    }

    @Test func runsTopLayerStartsForItselfAreNotYourThreads() {
        #expect(ClaudeBridge.isOwnRun(cwd: ClaudeUsage.folder))
        #expect(ClaudeBridge.isOwnRun(cwd: "/private/var/folders/ab/T/toplayer-check.x1Y2z3/project"))
        #expect(!ClaudeBridge.isOwnRun(cwd: "/Users/someone/work/toplayer-checkout"))
        #expect(!ClaudeBridge.isOwnRun(cwd: "/Users/someone/work/api"))
    }
}
