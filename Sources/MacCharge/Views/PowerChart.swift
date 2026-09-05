import SwiftUI
import Charts

/// Live area chart of battery power draw over the sampled window.
struct PowerChart: View {
    let samples: [PowerMonitor.PowerSample]
    var tint: Color = Theme.green

    private var stats: (avg: Double, min: Double, max: Double) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        let w = samples.map(\.watts)
        return (w.reduce(0, +) / Double(w.count), w.min() ?? 0, w.max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if samples.count < 2 {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.03))
                    .frame(minHeight: 130, maxHeight: .infinity)
                    .overlay(
                        Text("Collecting samples…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    )
            } else {
                Chart(samples) { s in
                    AreaMark(x: .value("Time", s.time), y: .value("Watts", s.watts))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            .linearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom)
                        )
                    LineMark(x: .value("Time", s.time), y: .value("Watts", s.watts))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.separator)
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text("\(Int(d))W").foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Theme.separator)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .frame(minHeight: 130, maxHeight: .infinity)
            }

            HStack {
                chartStat("Average", stats.avg, Theme.green)
                Spacer()
                chartStat("Min", stats.min, Theme.blue)
                Spacer()
                chartStat("Max", stats.max, Theme.orange)
            }
            .padding(.top, 2)
        }
    }

    private func chartStat(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
            Text(String(format: "%.1f W", value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}
