import AppKit
import SwiftUI

// The visual system in one place.
//
// Layers:
//   glass   small pieces that float alone: the squircle, the pills beside it, the TopLayer bar
//   frost   large surfaces: sidebar sections and the conversation pane (see `Frost`)
//   fills   everything drawn on top of those: headers, rows, bubbles, buttons, badges
//
// Shape language: everything is a squircle (a continuous-corner rounded rectangle), and
// nested shapes use the outer radius minus their inset so corners stay concentric.

enum Brand {
    static func color(_ source: AgentSource) -> Color { source == .claude ? .orange : .blue }

    private static var icons: [AgentSource: NSImage] = [:]

    /// The environment's own app icon, read once from the installed app.
    static func icon(_ source: AgentSource) -> NSImage? {
        if let cached = icons[source] { return cached }
        let path = source == .claude ? "/Applications/Claude.app" : "/Applications/ChatGPT.app"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[source] = image
        return image
    }
}

enum Radius {
    static let surface: CGFloat = 20        // every top-level piece
    static let squircle: CGFloat = 17       // the 56pt squircle and the pills beside it
    static let row: CGFloat = 14            // surface − the 6pt row inset
    static let bubble: CGFloat = 10         // surface − the 10pt content inset
    static let control: CGFloat = 8         // icon and action buttons
}

/// The one shape everything uses.
func squircle(_ radius: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

enum Metrics {
    static let squircle: CGFloat = 56
    static let inset: CGFloat = 10          // room around the pieces for their shadows
    static let peekWidth: CGFloat = 340
    static let permissionWidth: CGFloat = 540
    static let sidebarWidth: CGFloat = 264
    static let readingWidth: CGFloat = 760
    static let gap: CGFloat = 8             // between top-level pieces

    static let barHeight: CGFloat = 40      // the TopLayer bar
    static let headerHeight: CGFloat = 48
    static let rowHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 2
    static let rowInset: CGFloat = 6
    static let searchHeight: CGFloat = 34   // a section's search field with the space above it
    static let contentInset: CGFloat = 10

    /// Height a section's thread list wants when nothing is cut off.
    static func rowsHeight(_ count: Int) -> CGFloat {
        count == 0 ? 36 : CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing + rowInset * 2
    }
}

// MARK: Sizes: one source of truth for SwiftUI and the window

enum PanelLayout {
    static let margin: CGFloat = 8          // between the overlay and the screen edge

    /// The overlay's size in its current state.
    static func size(_ store: Store) -> CGSize {
        let visible = store.visibleSize
        let maxWidth = visible.width - margin * 2
        let maxHeight = visible.height - margin * 2
        var size: CGSize
        switch store.drawnMode {
        case .collapsed:
            let side = Metrics.squircle + Metrics.inset * 2
            var width = side
            if !store.permissions.isEmpty {
                width += Metrics.gap + Metrics.permissionWidth
            } else if store.peek != nil {
                width += Metrics.gap + Metrics.peekWidth
            }
            return CGSize(width: width, height: side)
        case .open:
            // As tall as the sidebar needs to show every thread. With a thread open it
            // never gets shorter than a comfortable reading height, and folding a section
            // away does not count: the conversation keeps its height while you tidy the
            // sidebar beside it.
            let ideal = idealSidebarHeight(store, unfolded: store.hasConversation)
                + Metrics.inset * 2 + CGFloat(store.permissions.count) * 118
            size = CGSize(width: store.preferences.openWidth, height: store.hasConversation ? max(660, ideal) : ideal)
        case .expanded:
            // The chosen share of the screen, a little taller than it is wide.
            let share = store.preferences.expandedFraction
            size = CGSize(width: max(900, visible.width * share), height: max(660, visible.height * min(0.94, share + 0.1)))
        }
        if !store.hasConversation { size.width = Metrics.sidebarWidth + Metrics.inset * 2 }
        if let cap = ProcessInfo.processInfo.environment["TOPLAYER_DEBUG_MAXHEIGHT"].flatMap(Double.init) {
            size.height = min(size.height, cap)             // debug: pretend the screen is short
        }
        return CGSize(width: min(size.width, maxWidth), height: min(size.height, maxHeight))
    }

    /// Height of everything in the sidebar that never scrolls. With `unfolded`, sections
    /// that are folded away are counted as if they were showing.
    static func fixedSidebarHeight(_ store: Store, unfolded: Bool = false) -> CGFloat {
        var height = Metrics.barHeight + Metrics.gap
        let chats = store.groupChats.chats.count
        if chats > 0 {
            height += Metrics.headerHeight + Metrics.gap
            if unfolded || !store.collapsedSections.contains("group") { height += Metrics.rowsHeight(chats) }
        }
        // An open search field takes room from the lists. It is left out of the unfolded
        // height, so opening one does not resize an open conversation.
        if !unfolded {
            for source in store.searches.keys where !store.collapsedSections.contains(source.rawValue) {
                height += Metrics.searchHeight
            }
        }
        return height + Metrics.headerHeight * 2 + Metrics.gap
    }

    private static func wanted(_ source: AgentSource, _ store: Store, unfolded: Bool = false) -> CGFloat {
        if !unfolded && store.collapsedSections.contains(source.rawValue) { return 0 }
        return Metrics.rowsHeight(source == .claude ? store.claudeRows.count : store.codexRows.count)
    }

    /// Height the sidebar needs to show every thread without scrolling.
    static func idealSidebarHeight(_ store: Store, unfolded: Bool = false) -> CGFloat {
        fixedSidebarHeight(store, unfolded: unfolded)
            + wanted(.claude, store, unfolded: unfolded) + wanted(.codex, store, unfolded: unfolded)
    }

    /// Shares the room between the two thread lists. Each takes what it needs; when they
    /// don't both fit, neither is squeezed below half unless the other needs less, and
    /// the longer one scrolls inside its own section.
    static func split(_ store: Store, available: CGFloat) -> (claude: CGFloat, codex: CGFloat) {
        let claude = wanted(.claude, store)
        let codex = wanted(.codex, store)
        let room = max(0, available - fixedSidebarHeight(store))
        if claude + codex <= room { return (claude, codex) }
        let claudeShare = min(claude, max(room / 2, room - codex))
        return (claudeShare, min(codex, room - claudeShare))
    }
}

extension Corner {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
    var anchor: UnitPoint {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

// MARK: Frost

/// The dark frosted backing for the large surfaces.
///
/// Liquid Glass renders differently depending on whether its window has focus: clearer
/// and more colourful with focus, darker and frostier without. This backing is pinned to
/// one state, so the overlay looks the same while you type in it and while you work in
/// the app behind it.
struct Frost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active            // never follow the window's focus
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Clips to a squircle and gives it the frosted backing and a hairline edge.
    func surface(_ radius: CGFloat = Radius.surface) -> some View {
        clipShape(squircle(radius))
            .background { Frost().clipShape(squircle(radius)) }
            .overlay { squircle(radius).strokeBorder(.white.opacity(0.13)) }
    }
}

// MARK: Arriving pieces

/// Brings a piece in from where the piece before it sits: it starts that far back,
/// invisible, and fades in as it travels to its own place. A section comes down from the
/// one above it, and the conversation comes out sideways from the sidebar.
struct Arrival: ViewModifier, Animatable {
    var edge: Edge
    var distance: CGFloat
    /// 1 is at the starting point and invisible, 0 is in place.
    var away: Double

    var animatableData: Double {
        get { away }
        set { away = newValue }
    }

    func body(content: Content) -> some View {
        let travel = distance * away
        content
            .offset(x: edge == .leading ? -travel : edge == .trailing ? travel : 0,
                    y: edge == .top ? -travel : edge == .bottom ? travel : 0)
            .opacity(1 - away)
    }
}

extension AnyTransition {
    static func arrival(from edge: Edge, distance: CGFloat) -> AnyTransition {
        .modifier(active: Arrival(edge: edge, distance: distance, away: 1),
                  identity: Arrival(edge: edge, distance: distance, away: 0))
    }
}

// MARK: Buttons

/// Press feedback shared by every custom button.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// An icon-only button: a 28pt squircle hit area with a hover fill.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                squircle(Radius.control).fill(.white.opacity(hovering ? 0.18 : 0))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)       // one box for every glyph, so all sit centred
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small text button drawn with explicit fills. System button tints dim while the
/// panel is not the key window, which is most of the time for an overlay.
struct ActionButton: View {
    let title: String
    var prominent = false
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, prominent: Bool = false, tint: Color = .accentColor, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(prominent ? tint.opacity(hovering ? 1 : 0.88) : Color.white.opacity(hovering ? 0.26 : 0.16),
                            in: squircle(Radius.control))
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: The layers glyph

/// The app's three layers, as on its icon. The middle layer turns orange when Claude
/// has something new and the bottom layer turns blue for Codex.
struct LayersGlyph: View {
    var claudeActive: Bool
    var codexActive: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                layer(codexActive ? Brand.color(.codex) : .white.opacity(0.36), width: w).offset(y: w * 0.24)
                layer(claudeActive ? Brand.color(.claude) : .white.opacity(0.62), width: w)
                layer(.white, width: w).offset(y: -w * 0.24)
            }
            .frame(width: w, height: geo.size.height)
        }
        .animation(Motion.panel, value: claudeActive)
        .animation(Motion.panel, value: codexActive)
        .accessibilityHidden(true)
    }

    private func layer(_ color: Color, width: CGFloat) -> some View {
        squircle(width * 0.13)
            .fill(color)
            .frame(width: width * 0.62, height: width * 0.62)
            .rotationEffect(.degrees(45))
            .scaleEffect(x: 1, y: 0.5)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

// MARK: Click, drag and right-click on a non-activating panel

/// Distinguishes a click from a window drag, which SwiftUI gestures can't do for a
/// panel that must not take focus. Dragging moves the whole overlay.
struct ClickDragArea: NSViewRepresentable {
    var onClick: () -> Void = {}
    var onRightClick: ((NSEvent, NSView) -> Void)? = nil

    func makeNSView(context: Context) -> Area { Area() }

    func updateNSView(_ view: Area, context: Context) {
        view.onClick = onClick
        view.onRightClick = onRightClick
    }

    final class Area: NSView {
        var onClick: () -> Void = {}
        var onRightClick: ((NSEvent, NSView) -> Void)?
        private var down: NSPoint?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            down = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let down else { return }
            let now = event.locationInWindow
            if hypot(now.x - down.x, now.y - down.y) > 4 {
                dragging = true
                window?.performDrag(with: event)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if !dragging { onClick() }
            down = nil
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }
    }
}
