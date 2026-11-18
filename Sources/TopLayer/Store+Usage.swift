import Foundation

/// How much of each plan is used: read from Codex's service and from the claude command.
extension Store {
    /// How old a reading may get before it is taken again. Claude's costs a short-lived
    /// process each time, so it is left longer.
    static func usageAge(_ source: AgentSource) -> TimeInterval { source == .codex ? 90 : 300 }

    /// Reads again whatever has gone stale. Called from the timer.
    func refreshUsageIfStale() {
        for source in [AgentSource.codex, .claude] { refreshUsage(source) }
    }

    /// Reads one tool's limits. Without `force`, only when the last reading is old; a
    /// failed reading is retried at the same pace, not on every tick.
    func refreshUsage(_ source: AgentSource, force: Bool = false) {
        if usageLoading.contains(source) { return }
        let last = max(usage[source]?.fetched ?? .distantPast, usageTried[source] ?? .distantPast)
        if !force, Date().timeIntervalSince(last) < Self.usageAge(source) { return }
        if source == .codex && !codexConnected {
            if usageProblem[source] == nil, usage[source] == nil { usageProblem[source] = "Codex is not connected." }
            return
        }
        usageLoading.insert(source)
        usageTried[source] = Date()
        switch source {
        case .codex:
            codex.request("account/rateLimits/read", [:]) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.took(UsageReport.codex(from: result), from: source)
                } else {
                    self.failed(error ?? "Codex did not answer.", from: source)
                }
            }
        case .claude:
            ClaudeUsage.fetch { [weak self] result in
                switch result {
                case .success(let report): self?.took(report, from: source)
                case .failure(let failure): self?.failed(failure.message, from: source)
                }
            }
        }
    }

    private func took(_ report: UsageReport, from source: AgentSource) {
        usageLoading.remove(source)
        usageProblem[source] = nil
        usage[source] = report
    }

    /// A failed reading keeps the last good one on show, with the reason beside it.
    private func failed(_ reason: String, from source: AgentSource) {
        usageLoading.remove(source)
        usageProblem[source] = reason
    }
}
