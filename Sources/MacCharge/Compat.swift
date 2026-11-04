import SwiftUI

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
}
