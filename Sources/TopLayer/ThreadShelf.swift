import Foundation

/// A thread the overlay keeps in its list when it would otherwise not be there.
struct KeptThread: Codable, Equatable {
    var id: String          // the thread or session id, without the "codex:" or "claude:" prefix
    var title: String
    var cwd: String
    /// Codex: its rollout file, so it can be followed like any other thread.
    var path: String?
    /// Pinned threads stay until unpinned. The one unpinned thread is whatever was last
    /// opened from a search: it stays until another search result takes its place.
    var pinned: Bool
}

/// Which threads an environment shows besides the ones it lists by itself, and in what order.
///
/// Codex is only asked for its most recently updated threads, and Claude only has its
/// running sessions, so anything older or ended is not on the list. Two things bring a
/// thread back: pinning it, and opening it from a search. This type holds those threads
/// and merges them with the listed ones ("recent" below). It knows nothing about the
/// daemon or the disk, so it can be tested on its own.
struct ThreadShelf: Codable, Equatable {
    private(set) var kept: [KeptThread] = []

    func isPinned(_ id: String) -> Bool { kept.contains { $0.id == id && $0.pinned } }

    /// Pins a thread to the top, after the ones already pinned.
    mutating func pin(_ thread: KeptThread) {
        kept.removeAll { $0.id == thread.id }
        var pinned = thread
        pinned.pinned = true
        let end = kept.lastIndex(where: \.pinned).map { $0 + 1 } ?? 0
        kept.insert(pinned, at: end)
    }

    /// Unpins a thread. With `stillOpen`, it stays in the list as the thread last opened
    /// from a search would, so it does not vanish from under an open conversation.
    mutating func unpin(_ id: String, stillOpen: Bool) {
        guard let index = kept.firstIndex(where: { $0.id == id && $0.pinned }) else { return }
        var thread = kept.remove(at: index)
        guard stillOpen else { return }
        thread.pinned = false
        visit(thread)
    }

    /// Keeps a thread opened from a search. It replaces the previous one; a pinned
    /// thread is already kept and is left as it is.
    mutating func visit(_ thread: KeptThread) {
        guard !isPinned(thread.id) else { return }
        kept.removeAll { !$0.pinned }
        var visited = thread
        visited.pinned = false
        kept.append(visited)
    }

    /// Takes in a fresh list of recent threads: kept threads pick up new titles and
    /// paths, and a thread that was only kept because it was opened from a search is
    /// let go once it is recent again.
    mutating func absorb(recent: [SessionRow], paths: [String: String]) {
        let fresh = Dictionary(recent.map { ($0.rawId, $0) }, uniquingKeysWith: { first, _ in first })
        kept.removeAll { !$0.pinned && fresh[$0.id] != nil }
        for index in kept.indices {
            guard let row = fresh[kept[index].id] else { continue }
            kept[index].title = row.title
            kept[index].cwd = row.cwd
            if let path = paths[row.rawId] { kept[index].path = path }
        }
    }

    /// The list to show: pinned threads in the order they were pinned, then the thread
    /// last opened from a search, then the recent ones. `make` builds a row for a kept
    /// thread that is not among the recent ones.
    func rows(recent: [SessionRow], make: (KeptThread) -> SessionRow) -> [SessionRow] {
        let fresh = Dictionary(recent.map { ($0.rawId, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = [SessionRow]()
        var placed = Set<String>()
        for thread in kept.filter(\.pinned) + kept.filter({ !$0.pinned }) {
            rows.append(fresh[thread.id] ?? make(thread))
            placed.insert(thread.id)
        }
        return rows + recent.filter { !placed.contains($0.rawId) }
    }
}
