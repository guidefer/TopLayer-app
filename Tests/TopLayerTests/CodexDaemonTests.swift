import Testing
@testable import TopLayer

struct CodexDaemonTests {
    @Test func theFirstAttemptWaitsLongEnoughForAPlainReconnect() {
        #expect(CodexDaemon.wait(beforeAttempt: 1) >= 3)
        #expect(CodexDaemon.wait(beforeAttempt: 1) <= 10)
    }

    @Test func laterAttemptsAreFurtherApartAndThenSteady() {
        let waits = (1...6).map { CodexDaemon.wait(beforeAttempt: $0) }
        #expect(waits == waits.sorted())
        #expect(waits[1] > waits[0])
        #expect(waits[4] == waits[5])
        #expect(waits.last! <= 600)
    }
}
