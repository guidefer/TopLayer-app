import AppKit
import Carbon.HIToolbox
import Testing
@testable import TopLayer

struct ShortcutTests {
    @Test func shortcutsAreWrittenTheWayMacOSWritesThem() {
        #expect(Shortcut.toggleDefault.display == "⌃⌥Space")
        #expect(Shortcut.expandDefault.display == "⌃⌥⇧Space")
        #expect(Shortcut(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)).display == "⌘↩")
        #expect(Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey)).display == "⇧⌘F5")
    }

    @Test func aShortcutSurvivesSavingAndLoading() throws {
        let saved = try JSONEncoder().encode(Shortcut.expandDefault)
        #expect(try JSONDecoder().decode(Shortcut.self, from: saved) == .expandDefault)
    }
}
