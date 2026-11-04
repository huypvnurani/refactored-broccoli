import SwiftUI
import AppKit

/// Stand-ins for SwiftUI modifiers newer than macOS 12, so the macOS 12 build
/// keeps the newer animations where the system has them and skips them where
/// it doesn't.
extension View {
    /// Rolling-digit animation for changing numbers (macOS 13+).
    @ViewBuilder func numericTransition() -> some View {
        if #available(macOS 13, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    /// Cross-fade between SF Symbols when the image changes (macOS 14+).
    @ViewBuilder func symbolReplaceTransition() -> some View {
        if #available(macOS 14, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// Letter spacing for every Text inside (macOS 13+).
    @ViewBuilder func compatTracking(_ value: CGFloat) -> some View {
        if #available(macOS 13, *) {
            tracking(value)
        } else {
            self
        }
    }

    /// Pointer position while it is over the view (local coordinates), nil once
    /// it leaves. Native on macOS 13+, an AppKit tracking area on macOS 12.
    @ViewBuilder func compatContinuousHover(_ perform: @escaping (CGPoint?) -> Void) -> some View {
        if #available(macOS 13, *) {
            onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { perform(p) } else { perform(nil) }
            }
        } else {
            background(HoverTracker(perform: perform))
        }
    }
}

/// Reports mouse moves over its frame without taking clicks: it sits behind the
/// content and tracking areas fire no matter which view gets hit-tested.
private struct HoverTracker: NSViewRepresentable {
    let perform: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.perform = perform
        return v
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.perform = perform
    }

    final class TrackingView: NSView {
        var perform: ((CGPoint?) -> Void)?

        override var isFlipped: Bool { true }   // match SwiftUI's top-left origin

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                           owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            perform?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            perform?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            perform?(nil)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
