import SwiftUI

/// Big number stat card (top row of the Overview). All cards share one uniform
/// height; set `emphasized` to make one stand out as the hero metric.
struct StatCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    var valueColor: Color = Theme.textPrimary
    var subtitle: String? = nil
    var subtitleColor: Color = Theme.textSecondary
    var emphasized: Bool = false
    var help: String? = nil
    @ViewBuilder var accessory: () -> AnyView

    init(icon: String, iconColor: Color, title: String, value: String,
         valueColor: Color = Theme.textPrimary, subtitle: String? = nil,
         subtitleColor: Color = Theme.textSecondary, emphasized: Bool = false,
         help: String? = nil,
         @ViewBuilder accessory: @escaping () -> AnyView = { AnyView(EmptyView()) }) {
        self.icon = icon; self.iconColor = iconColor; self.title = title
        self.value = value; self.valueColor = valueColor; self.subtitle = subtitle
        self.subtitleColor = subtitleColor; self.emphasized = emphasized
        self.help = help; self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 30, height: 30)
                    .background(iconColor.opacity(emphasized ? 0.22 : 0.14),
                                in: RoundedRectangle(cornerRadius: 9))
                Text(title.uppercased())
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(emphasized ? iconColor : Theme.textSecondary)
                Spacer(minLength: 0)
                if emphasized {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(iconColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(iconColor.opacity(0.16), in: Capsule())
                }
            }
            Text(value)
                .font(.system(size: emphasized ? 42 : 29, weight: .bold, design: .rounded))
                .foregroundStyle(emphasized ? iconColor : valueColor)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            accessory()
            Spacer(minLength: 0)
        }
        .padding(emphasized ? 18 : 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(emphasized ? iconColor.opacity(0.10) : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(emphasized ? iconColor.opacity(0.55) : Theme.cardStroke,
                              lineWidth: emphasized ? 1.5 : 1)
        )
        .help(help ?? "")
    }
}

/// A row of "label ........ value" used in the Health / detail tables.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary
    var icon: String? = nil
    var iconColor: Color = Theme.textSecondary
    var help: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            if help != nil {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted.opacity(0.7))
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

/// Small metric card (bottom row: temperature / voltage / current / condition).
struct MetricCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let status: String
    var statusColor: Color = Theme.green
    var help: String? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 28, height: 28)
                        .background(iconColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(status)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .help(help ?? "")
    }
}

/// One labeled row of data for a DetailCard.
struct DetailRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary
    var icon: String? = nil
    var iconColor: Color = Theme.textSecondary
    var help: String? = nil
}

/// A card whose rows spread to fill its full height (no empty gap at the bottom).
struct DetailCard: View {
    let title: String
    let titleIcon: String
    var titleColor: Color = Theme.textPrimary
    let rows: [DetailRow]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: titleIcon)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .padding(.bottom, 4)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    InfoRow(label: r.label, value: r.value, valueColor: r.valueColor,
                            icon: r.icon, iconColor: r.iconColor, help: r.help)
                    if i < rows.count - 1 {
                        Divider().overlay(Theme.separator)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Header shown at the top of every section.
struct SectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin horizontal battery gauge.
struct BatteryBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(6, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }
}
