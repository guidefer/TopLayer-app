import Foundation
import SwiftUI

/// A search that is open in one environment's section.
struct ThreadSearch: Equatable {
    var text = ""
    var results: [SessionRow] = []
    /// True while the list of everything that can be found is still being put together.
    var pending = true
}

// Reaching threads that are not on the list: search, and pinning.
//
// Each environment's section lists only part of what exists: Codex its most recently
// updated threads, Claude its running sessions. Search looks through all of them, and a
// pin keeps one on the list. What is kept, and in what order, is `ThreadShelf`'s job.
extension Store {
    // MARK: Search

    func isSearching(_ source: AgentSource) -> Bool { searches[source] != nil }

    private func listed(_ source: AgentSource) -> [SessionRow] { source == .codex ? codexRows : claudeRows }

    /// What a section lists: the search results while something is typed, otherwise the usual list.
    func shown(_ source: AgentSource) -> [SessionRow] {
        guard let search = searches[source], !search.text.trimmingCharacters(in: .whitespaces).isEmpty else { return listed(source) }
        return search.results
    }

    /// Opens a section's search and starts collecting everything it can find. The
    /// matching is done here, not by the environment: Codex's own title search is
    /// case-sensitive ("frigg" does not find "Frigg"), and Claude has none.
    func beginSearch(_ source: AgentSource) {
        guard searches[source] == nil else { return }
        animate {
            collapsedSections.remove(source.rawValue)
            searches[source] = ThreadSearch()
        }
        let run = (searchRun[source] ?? 0) + 1
        searchRun[source] = run
        searchIndex[source] = []
        switch source {
        case .codex: loadCodexIndex(run: run, cursor: nil, pages: 0, collected: [])
        case .claude: loadClaudeIndex(run: run)
        }
    }

    func endSearch(_ source: AgentSource) {
        guard searches[source] != nil else { return }
        searchRun[source, default: 0] += 1
        searchIndex[source] = nil
        animate { searches[source] = nil }
    }

    /// Closes whatever search is open. Returns false if none was.
    @discardableResult
    func endSearches() -> Bool {
        let open = Array(searches.keys)
        open.forEach(endSearch)
        return !open.isEmpty
    }

    func setSearch(_ source: AgentSource, _ text: String) {
        guard searches[source] != nil, searches[source]?.text != text else { return }
        searches[source]?.text = text
        applySearch(source)
    }

    /// Called when everything searchable in an environment has been collected.
    func finishIndex(_ source: AgentSource, run: Int, rows: [SessionRow]) {
        guard searchRun[source] == run, searches[source] != nil else { return }     // closed meanwhile
        log("search: \(rows.count) \(source.rawValue) threads indexed")
        searchIndex[source] = rows
        searches[source]?.pending = false
        applySearch(source)
    }

    /// Threads whose title or folder contains every word typed, in the order given.
    static func matches(_ text: String, in rows: [SessionRow]) -> [SessionRow] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return rows.filter { row in
            let folder = (row.cwd as NSString).lastPathComponent
            return words.allSatisfy { row.title.localizedStandardContains($0) || folder.localizedStandardContains($0) }
        }
    }

    private func applySearch(_ source: AgentSource) {
        guard let search = searches[source] else { return }
        var rows = Array(Self.matches(search.text, in: searchIndex[source] ?? []).prefix(60))
        // A thread that is also on the list is shown as it is there (unread, working).
        let live = Dictionary(listed(source).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in rows.indices {
            if let current = live[rows[index].id] { rows[index] = current }
        }
        if rows != search.results { searches[source]?.results = rows }
    }

    /// Opens a search result. A thread that is not on the usual list is kept there, so it
    /// is still reachable once the search is closed.
    func openSearchResult(_ row: SessionRow) {
        let source = row.source
        if !listed(source).contains(where: { $0.id == row.id }) {
            if source == .codex { codexShelf.visit(kept(row)) } else { claudeShelf.visit(kept(row)) }
        }
        searchRun[source, default: 0] += 1
        searchIndex[source] = nil
        animate {
            compose(source)
            searches[source] = nil
        }
        select(row)
    }

    // MARK: Pinning

    func isPinned(_ row: SessionRow) -> Bool {
        row.source == .codex ? codexShelf.isPinned(row.rawId) : claudeShelf.isPinned(row.rawId)
    }

    private func kept(_ row: SessionRow) -> KeptThread {
        KeptThread(id: row.rawId, title: row.title, cwd: row.cwd,
                   path: row.source == .codex ? codexPaths[row.rawId] : nil, pinned: false)
    }

    private func compose(_ source: AgentSource) {
        if source == .codex { composeCodexRows() } else { composeClaudeRows() }
    }

    /// Pins a thread to the top of its section, or lets it go again. A thread that is
    /// unpinned while it is open stays until you open another one from a search.
    func togglePin(_ row: SessionRow) {
        animate {
            let stillOpen = selectedId == row.id
            switch row.source {
            case .codex:
                if codexShelf.isPinned(row.rawId) { codexShelf.unpin(row.rawId, stillOpen: stillOpen) } else { codexShelf.pin(kept(row)) }
            case .claude:
                if claudeShelf.isPinned(row.rawId) { claudeShelf.unpin(row.rawId, stillOpen: stillOpen) } else { claudeShelf.pin(kept(row)) }
            }
            compose(row.source)
        }
    }
}
