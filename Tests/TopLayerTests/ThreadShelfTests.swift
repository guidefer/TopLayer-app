import Foundation
import Testing
@testable import TopLayer

struct ThreadShelfTests {
    private func row(_ id: String, _ title: String = "") -> SessionRow {
        SessionRow(id: "codex:\(id)", source: .codex, rawId: id, title: title.isEmpty ? "Thread \(id)" : title,
                   cwd: "/work", status: "idle", updatedAt: 0)
    }

    private func kept(_ id: String, pinned: Bool = false) -> KeptThread {
        KeptThread(id: id, title: "Thread \(id)", cwd: "/work", path: "/rollouts/\(id).jsonl", pinned: pinned)
    }

    private func ids(_ shelf: ThreadShelf, recent: [SessionRow]) -> [String] {
        shelf.rows(recent: recent) { self.row($0.id, $0.title) }.map(\.rawId)
    }

    @Test func withNothingKeptTheListIsTheRecentThreads() {
        #expect(ids(ThreadShelf(), recent: [row("a"), row("b")]) == ["a", "b"])
    }

    @Test func pinnedThreadsComeFirstInTheOrderTheyWerePinned() {
        var shelf = ThreadShelf()
        shelf.pin(kept("old"))
        shelf.pin(kept("b"))
        #expect(ids(shelf, recent: [row("a"), row("b"), row("c")]) == ["old", "b", "a", "c"])
    }

    @Test func aPinnedThreadThatIsAlsoRecentIsShownOnce() {
        var shelf = ThreadShelf()
        shelf.pin(kept("b"))
        #expect(ids(shelf, recent: [row("a"), row("b")]) == ["b", "a"])
    }

    @Test func aThreadOpenedFromASearchStaysUntilAnotherTakesItsPlace() {
        var shelf = ThreadShelf()
        shelf.pin(kept("pinned"))
        shelf.visit(kept("found"))
        #expect(ids(shelf, recent: [row("a")]) == ["pinned", "found", "a"])
        shelf.visit(kept("other"))
        #expect(ids(shelf, recent: [row("a")]) == ["pinned", "other", "a"])
    }

    @Test func openingAPinnedThreadFromASearchChangesNothing() {
        var shelf = ThreadShelf()
        shelf.pin(kept("pinned"))
        shelf.visit(kept("found"))
        shelf.visit(kept("pinned"))
        #expect(ids(shelf, recent: []) == ["pinned", "found"])
        #expect(shelf.isPinned("pinned"))
    }

    @Test func aSearchedThreadIsLetGoOnceItIsRecentAgain() {
        var shelf = ThreadShelf()
        shelf.visit(kept("found"))
        shelf.absorb(recent: [row("found"), row("a")], paths: [:])
        #expect(shelf.kept.isEmpty)
        #expect(ids(shelf, recent: [row("found"), row("a")]) == ["found", "a"])
    }

    @Test func aPinnedThreadPicksUpItsNewTitleAndKeepsItWhenItIsNoLongerRecent() {
        var shelf = ThreadShelf()
        shelf.pin(kept("p"))
        shelf.absorb(recent: [row("p", "Renamed")], paths: ["p": "/new/path.jsonl"])
        let rows = shelf.rows(recent: []) { self.row($0.id, $0.title) }
        #expect(rows.map(\.title) == ["Renamed"])
        #expect(shelf.kept.first?.path == "/new/path.jsonl")
    }

    @Test func unpinningRemovesAThreadUnlessItIsStillOpen() {
        var shelf = ThreadShelf()
        shelf.pin(kept("a"))
        shelf.pin(kept("b"))
        shelf.unpin("a", stillOpen: false)
        #expect(ids(shelf, recent: []) == ["b"])
        shelf.unpin("b", stillOpen: true)
        #expect(ids(shelf, recent: []) == ["b"])
        #expect(!shelf.isPinned("b"))
    }

    @Test func itSurvivesBeingSavedAndLoaded() throws {
        var shelf = ThreadShelf()
        shelf.pin(kept("a"))
        shelf.visit(kept("b"))
        let loaded = try JSONDecoder().decode(ThreadShelf.self, from: JSONEncoder().encode(shelf))
        #expect(loaded == shelf)
    }

    // MARK: Search

    private func thread(_ title: String, in folder: String = "/work/app") -> SessionRow {
        SessionRow(id: "codex:\(title)", source: .codex, rawId: title, title: title, cwd: folder, status: "idle", updatedAt: 0)
    }

    @Test func searchIgnoresCaseAndAccents() {
        let rows = [thread("Frigg"), thread("Configure OpenAI API key"), thread("Résumé review")]
        #expect(Store.matches("frigg", in: rows).map(\.title) == ["Frigg"])
        #expect(Store.matches("OPENAI", in: rows).map(\.title) == ["Configure OpenAI API key"])
        #expect(Store.matches("resume", in: rows).map(\.title) == ["Résumé review"])
    }

    @Test func everyWordHasToMatchInAnyOrder() {
        let rows = [thread("Configure OpenAI API key"), thread("OpenAI pricing notes")]
        #expect(Store.matches("key openai", in: rows).map(\.title) == ["Configure OpenAI API key"])
        #expect(Store.matches("openai", in: rows).count == 2)
    }

    @Test func aThreadIsAlsoFoundByItsFolder() {
        let rows = [thread("Fix the build", in: "/work/rootweave"), thread("Fix the docs", in: "/work/site")]
        #expect(Store.matches("rootweave", in: rows).map(\.title) == ["Fix the build"])
        #expect(Store.matches("fix rootweave", in: rows).map(\.title) == ["Fix the build"])
    }

    @Test func nothingTypedFindsNothing() {
        #expect(Store.matches("   ", in: [thread("Frigg")]).isEmpty)
    }
}
