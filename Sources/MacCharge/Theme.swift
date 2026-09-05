import SwiftUI

/// Palette + reusable styling tuned to the reference mockup (dark, card-based).
enum Theme {
    static let bg          = Color(hex: 0x0B0E11)
    static let sidebar     = Color(hex: 0x0E1216)
    static let card        = Color(hex: 0x141A20)
    static let cardStroke  = Color.white.opacity(0.06)
    static let separator   = Color.white.opacity(0.05)

    static let textPrimary   = Color(hex: 0xF3F5F7)
    static let textSecondary = Color(hex: 0x8B96A2)
    static let textMuted     = Color(hex: 0x5B6672)

    static let green  = Color(hex: 0x3FD07E)
    static let blue   = Color(hex: 0x4FA8FF)
    static let purple = Color(hex: 0x9B7BFF)
    static let orange = Color(hex: 0xFF9F45)
    static let red    = Color(hex: 0xFF5A5A)
    static let yellow = Color(hex: 0xF7C948)
}

extension Theme {
    /// Smoothly interpolates green → yellow → orange → red as the battery drains.
    static func batteryColor(_ fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        // (fraction, r, g, b) stops from empty (red) to full (green).
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 255, 90, 90),    // red
            (0.15, 255, 90, 90),    // hold red at critical
            (0.35, 255, 159, 69),   // orange
            (0.60, 247, 201, 72),   // yellow
            (1.00, 63, 208, 126)    // green
        ]
        for i in 1..<stops.count {
            let (f1, r1, g1, b1) = stops[i - 1]
            let (f2, r2, g2, b2) = stops[i]
            if f <= f2 {
                let t = f2 == f1 ? 0 : (f - f1) / (f2 - f1)
                return Color(.sRGB,
                             red: (r1 + (r2 - r1) * t) / 255,
                             green: (g1 + (g2 - g1) * t) / 255,
                             blue: (b1 + (b2 - b1) * t) / 255)
            }
        }
        return green
    }
}

extension PowerSnapshot {
    /// Battery colour: green while on power, otherwise graded by remaining %.
    var batteryTint: Color {
        externalConnected ? Theme.green : Theme.batteryColor(Double(currentCapacity) / 100)
    }
    /// Battery glyph: bolt only while connected to power; level-based otherwise.
    var batterySymbol: String {
        if externalConnected { return "battery.100percent.bolt" }
        switch currentCapacity {
        case 88...:    return "battery.100percent"
        case 63..<88:  return "battery.75percent"
        case 38..<63:  return "battery.50percent"
        case 13..<38:  return "battery.25percent"
        default:       return "battery.0percent"
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Rounded card container used across every panel.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}
