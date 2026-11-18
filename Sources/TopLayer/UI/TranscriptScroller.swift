import Combine
import SwiftUI

/// Lets the keyboard scroll the conversation that is showing.
///
/// The panel's key handling calls `scroll`, and the conversation's scroll view, which
/// carries the `keyboardScrolling()` modifier, performs it. It has to go through
/// SwiftUI's own scroll position: moving the underlying AppKit scroll view directly
/// works for a moment, then SwiftUI puts it back where it believes it should be.
enum TranscriptScroller {
    enum Move { case lines(CGFloat), pages(CGFloat), top, bottom }

    fileprivate static let moves = PassthroughSubject<Move, Never>()
    fileprivate static var listeners = 0

    /// Returns false when no conversation is showing, so the key is not swallowed.
    @discardableResult
    static func scroll(_ move: Move) -> Bool {
        guard listeners > 0 else { return false }
        moves.send(move)
        return true
    }
}

private struct KeyboardScrolling: ViewModifier {
    /// Where the scroll view is, kept outside SwiftUI's state so that scrolling does not
    /// redraw anything.
    private final class Geometry {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
    }
    private struct Snapshot: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var container: CGFloat
    }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var geometry = Geometry()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)       // open at, and stay on, the latest message
            .onScrollGeometryChange(for: Snapshot.self) { scroll in
                Snapshot(offset: scroll.contentOffset.y, content: scroll.contentSize.height, container: scroll.containerSize.height)
            } action: { _, new in
                geometry.offset = new.offset
                geometry.content = new.content
                geometry.container = new.container
            }
            .onReceive(TranscriptScroller.moves, perform: apply)
            .onAppear { TranscriptScroller.listeners += 1 }
            .onDisappear { TranscriptScroller.listeners -= 1 }
    }

    private func apply(_ move: TranscriptScroller.Move) {
        let range = max(0, geometry.content - geometry.container)
        var target = geometry.offset
        switch move {
        case .lines(let count): target += count * 48
        case .pages(let count): target += count * max(80, geometry.container - 56)    // keep a little overlap
        case .top: target = 0
        case .bottom: target = range
        }
        target = min(max(0, target), range).rounded()
        if ProcessInfo.processInfo.environment["TOPLAYER_DEBUG_CLIPS"] == "1" {
            log("scroll \(Int(geometry.offset)) -> \(Int(target)) of \(Int(range))")
        }
        withAnimation(.easeOut(duration: 0.16)) {
            // Going to an edge by name keeps the view pinned there as new messages arrive.
            if target >= range { position.scrollTo(edge: .bottom) } else { position.scrollTo(y: target) }
        }
    }
}

extension View {
    /// Makes this scroll view the one the keyboard scrolls, and keeps it on its newest
    /// content until you scroll away.
    func keyboardScrolling() -> some View { modifier(KeyboardScrolling()) }
}
