import Foundation
import Testing
@testable import TopLayer

struct UsageTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func codexWeeklyLimitCreditsAndResetsAreRead() {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex", "planType": "pro",
                "primary": ["usedPercent": 76, "windowDurationMins": 10080, "resetsAt": 1_795_352_477],
                "secondary": NSNull(),
                "credits": ["hasCredits": true, "unlimited": false, "balance": "3650.6969635000"],
            ],
            "rateLimitsByLimitId": ["codex": ["limitId": "codex"]],
            "rateLimitResetCredits": ["availableCount": 1],
        ]
        let report = UsageReport.codex(from: result, now: now)
        #expect(report.limits.count == 1)
        #expect(report.limits[0].name == "This week")
        #expect(report.limits[0].used == 76)
        #expect(report.limits[0].left == 24)
        #expect(report.limits[0].resets == Date(timeIntervalSince1970: 1_795_352_477))
        #expect(report.plan == "Pro")
        #expect(report.credits == "3,651")
        #expect(report.freeResets == 1)
    }

    @Test func codexShortWindowAndModelLimitsAreNamed() {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 12.4, "windowDurationMins": 300, "resetsAt": 1_795_010_000],
                "secondary": ["usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1_795_352_477],
            ],
            "rateLimitsByLimitId": [
                "codex": ["limitId": "codex"],
                "spark": ["limitId": "spark", "limitName": "Spark",
                          "primary": ["usedPercent": 91, "windowDurationMins": 10080, "resetsAt": 1_795_352_477]],
            ],
        ]
        let report = UsageReport.codex(from: result, now: now)
        #expect(report.limits.map(\.name) == ["5-hour window", "This week", "This week (Spark)"])
        #expect(report.limits.map(\.used) == [12, 40, 91])
        #expect(report.tightest?.name == "This week (Spark)")
        #expect(report.credits == nil)
    }

    @Test func anEmptyCodexAnswerHasNoLimits() {
        let report = UsageReport.codex(from: [:], now: now)
        #expect(report.limits.isEmpty)
        #expect(report.summary(now: now) == "No limits reported")
    }

    private let claudeOutput = """
    {"type":"system","subtype":"init","cwd":"/tmp"}
    {"type":"assistant","usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":9,"resets_at":"2026-11-17T23:00:00.120000+00:00","scope":null,"severity":"normal","is_active":true},{"kind":"weekly_all","group":"weekly","percent":32,"resets_at":"2026-11-23T00:00:00.775078+00:00","scope":null,"severity":"normal","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":36,"resets_at":"2026-11-23T00:00:00.775307+00:00","scope":{"model":{"display_name":"Fable"},"surface":null},"severity":"normal","is_active":true}],"extra_usage":{"is_enabled":false}}}}
    {"type":"result","subtype":"success","is_error":false,"result":"You are currently using your subscription"}
    """

    @Test func claudeLimitsAreReadFromTheUsageReport() throws {
        let report = try #require(UsageReport.claude(fromOutput: claudeOutput, now: now))
        #expect(report.limits.map(\.name) == ["Current session", "This week", "This week (Fable)"])
        #expect(report.limits.map(\.used) == [9, 32, 36])
        #expect(report.tightest?.name == "This week (Fable)")
        let expected = ISO8601DateFormatter().date(from: "2026-11-23T00:00:00+00:00")
        #expect(report.limits[2].resets == expected)
    }

    @Test func aClaudeReportWithoutLimitsIsStillAReport() throws {
        let output = #"{"type":"assistant","usage_report":{"session":{},"rate_limits":null}}"#
        let report = try #require(UsageReport.claude(fromOutput: output, now: now))
        #expect(report.limits.isEmpty)
    }

    @Test func outputWithoutAReportGivesNothingButSaysWhy() {
        let output = """
        {"type":"system","subtype":"init"}
        {"type":"result","is_error":true,"result":"Not logged in · Please run /login\\nmore"}
        """
        #expect(UsageReport.claude(fromOutput: output) == nil)
        #expect(ClaudeUsage.said(in: output) == "Not logged in · Please run /login")
        #expect(ClaudeUsage.Failure.noReport("").message == "Claude Code gave no usage report.")
    }

    @Test func theSummaryNamesTheTightestLimit() {
        var report = UsageReport(fetched: now)
        report.limits = [UsageLimit(id: "a", name: "This week", used: 32, resets: now.addingTimeInterval(5 * 86400)),
                         UsageLimit(id: "b", name: "This week (Fable)", used: 36, resets: now.addingTimeInterval(5 * 86400))]
        #expect(report.summary(now: now) == "36% of this week (Fable) used, 64% left. Resets in 5 days.")
    }

    @Test func timeUntilAResetIsSaidInTheLargestUnitThatFits() {
        #expect(UsageReport.until(now.addingTimeInterval(20), now: now) == "now")
        #expect(UsageReport.until(now.addingTimeInterval(60), now: now) == "in 1 minute")
        #expect(UsageReport.until(now.addingTimeInterval(45 * 60), now: now) == "in 45 minutes")
        #expect(UsageReport.until(now.addingTimeInterval(3 * 3600), now: now) == "in 3 hours")
        #expect(UsageReport.until(now.addingTimeInterval(4.6 * 86400), now: now) == "in 5 days")
    }

    @Test func theProbeSwitchesHooksOffAndSavesNoSession() {
        #expect(ClaudeUsage.arguments.contains("--no-session-persistence"))
        #expect(ClaudeUsage.arguments.contains("--strict-mcp-config"))
        #expect(ClaudeUsage.arguments.contains { $0.contains(#""disableAllHooks":true"#) })
        #expect(Array(ClaudeUsage.arguments.prefix(2)) == ["-p", "/usage"])
    }
}
