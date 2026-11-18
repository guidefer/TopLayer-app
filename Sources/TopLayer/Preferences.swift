import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A global keyboard shortcut: a key plus modifiers, in the form Carbon's hot-key API takes.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    static let expandDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press. Nil unless it includes ⌘, ⌥ or ⌃: a global shortcut on a bare
    /// key (or Shift alone) would swallow ordinary typing in every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        guard carbon != 0 else { return nil }
        if flags.contains(.shift) { carbon |= shiftKey }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon))
    }

    /// As macOS writes shortcuts: modifiers in the order ⌃⌥⇧⌘, then the key.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ keyCode: UInt32) -> String {
        if let name = named[Int(keyCode)] { return name }
        // Ask the current keyboard layout what this key types.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// What you choose in the settings window. Everything is saved as it changes.
final class Preferences: ObservableObject {
    static let widthChoices: [(label: String, value: Double)] = [("Compact", 860), ("Regular", 980), ("Wide", 1120)]

    private static let defaults = UserDefaults.standard

    /// Width of the open panel when a thread is showing.
    @Published var openWidth: Double { didSet { Self.defaults.set(openWidth, forKey: "openWidth") } }
    /// Share of the screen the expanded layout takes, 0.55 to 0.9.
    @Published var expandedFraction: Double { didSet { Self.defaults.set(expandedFraction, forKey: "expandedFraction") } }
    /// Keep the overlay out of screen recordings and shared screens.
    @Published var hideFromScreenSharing: Bool { didSet { Self.defaults.set(hideFromScreenSharing, forKey: "hideFromScreenSharing") } }
    @Published var playSound: Bool { didSet { Self.defaults.set(playSound, forKey: "playSound") } }
    @Published var toggleShortcut: Shortcut { didSet { Self.save(toggleShortcut, "shortcut.toggle") } }
    @Published var expandShortcut: Shortcut { didSet { Self.save(expandShortcut, "shortcut.expand") } }

    /// True while a shortcut field is listening, so the global shortcuts step aside and
    /// the keys reach the field.
    @Published var recording = false
    /// Set when macOS refuses a shortcut, usually because something else already has it.
    @Published var shortcutProblem: String?
    @Published var loginProblem: String?

    init() {
        let d = Self.defaults
        openWidth = d.object(forKey: "openWidth") as? Double ?? 980
        expandedFraction = d.object(forKey: "expandedFraction") as? Double ?? 0.72
        hideFromScreenSharing = d.bool(forKey: "hideFromScreenSharing")
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        toggleShortcut = Self.load("shortcut.toggle") ?? .toggleDefault
        expandShortcut = Self.load("shortcut.expand") ?? .expandDefault
    }

    private static func load(_ key: String) -> Shortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private static func save(_ shortcut: Shortcut, _ key: String) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }

    func resetShortcuts() {
        toggleShortcut = .toggleDefault
        expandShortcut = .expandDefault
    }

    // MARK: Open at login

    /// Only an installed app bundle can be a login item.
    var canOpenAtLogin: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = "macOS would not change that: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}
