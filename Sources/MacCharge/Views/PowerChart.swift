import SwiftUI

/// Live area chart of battery power draw over the sampled window. Drawn with
/// paths rather than Swift Charts, which macOS 12 does not have.
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
                PathChart(samples: samples, tint: tint)
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

/// Area + line plot with a leading watt axis and a few time labels.
private struct PathChart: View {
    let samples: [PowerMonitor.PowerSample]
    let tint: Color

    private let axisWidth: CGFloat = 38
    private let labelHeight: CGFloat = 16

    /// Top of the y axis rounded up to a tidy step, and the step itself.
    private var scale: (top: Double, step: Double) {
        let peak = max(1, samples.map(\.watts).max() ?? 1)
        let raw = peak / 4
        let mag = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? raw
        return (step * ceil(peak / step), step)
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: axisWidth, y: 4,
                              width: max(1, geo.size.width - axisWidth),
                              height: max(1, geo.size.height - labelHeight - 8))
            let (top, step) = scale
            let ticks = Array(stride(from: 0, through: top, by: step))
            let points = self.points(in: plot, top: top)

            ZStack(alignment: .topLeading) {
                // Grid lines + watt labels
                ForEach(ticks, id: \.self) { t in
                    let y = plot.maxY - CGFloat(t / top) * plot.height
                    Path { p in
                        p.move(to: CGPoint(x: plot.minX, y: y))
                        p.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    .stroke(Theme.separator, lineWidth: 1)
                    Text("\(Int(t))W")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .position(x: (axisWidth - 6) / 2, y: y)
                }

                // Area under the line
                Path { p in
                    guard let first = points.first, let last = points.last else { return }
                    p.move(to: CGPoint(x: first.x, y: plot.maxY))
                    p.addLine(to: first)
                    addCurve(through: points, to: &p)
                    p.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))

                // The line
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    addCurve(through: points, to: &p)
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // Time labels
                ForEach(timeLabels(), id: \.self) { i in
                    Text(samples[i].time, style: .time)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize()
                        .position(x: points[i].x, y: plot.maxY + 4 + labelHeight / 2)
                }
            }
        }
    }

    private func points(in rect: CGRect, top: Double) -> [CGPoint] {
        guard let t0 = samples.first?.time, let t1 = samples.last?.time else { return [] }
        let span = max(1, t1.timeIntervalSince(t0))
        return samples.map { s in
            CGPoint(x: rect.minX + CGFloat(s.time.timeIntervalSince(t0) / span) * rect.width,
                    y: rect.maxY - CGFloat(min(s.watts, top) / top) * rect.height)
        }
    }

    /// Smooth curve (Catmull-Rom as cubic Béziers) from points[0] onward.
    private func addCurve(through pts: [CGPoint], to p: inout Path) {
        guard pts.count > 1 else { return }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    /// Indices of about four evenly spread samples to label, inset from the edges.
    private func timeLabels() -> [Int] {
        let n = samples.count
        guard n >= 2 else { return [] }
        return [0.1, 0.37, 0.63, 0.9].map { Int(Double(n - 1) * $0) }.reduce(into: []) { acc, i in
            if !acc.contains(i) { acc.append(i) }
        }
    }
}
