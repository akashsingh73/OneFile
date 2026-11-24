import SwiftUI
import AppKit

/// Between the two cards: a hub, and while work goes on, files streaming through it, more and
/// faster the more files a second go through.
struct FlowStream: View {
    enum Mode: Equatable {
        case faint
        case ready
        /// 0 (a trickle) to 1 (a flood).
        case flowing(Double)
        case done
    }

    let mode: Mode

    var body: some View {
        ZStack {
            if case .flowing(let intensity) = mode {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { context, size in
                        Self.particles(&context, size, time: timeline.date.timeIntervalSinceReferenceDate,
                                       intensity: intensity)
                    }
                }
                .allowsHitTesting(false)
            }
            Hub(mode: mode)
        }
        .frame(width: 78)
        .accessibilityHidden(true)
    }

    /// How busy the stream looks for this many files a second.
    static func intensity(filesPerSecond: Double) -> Double {
        guard filesPerSecond > 1 else { return 0.15 }
        return min(1, max(0.15, log10(filesPerSecond) / 5))
    }

    private static func fract(_ value: Double) -> Double { value - floor(value) }

    private static func particles(_ context: inout GraphicsContext, _ size: CGSize, time: Double, intensity: Double) {
        let count = 6 + Int(intensity * 16)
        let middle = size.height / 2
        for index in 0..<count {
            let seed = Double(index) * 0.618_033_988_7
            let speed = 0.5 + intensity * 1.1 + fract(seed * 5.3) * 0.4
            let phase = fract(time * speed * 0.8 + fract(seed * 3.1))
            let x = -6 + phase * (size.width + 12)
            let lane = (fract(seed * 11.7) - 0.5) * 34
            let y = middle + lane * sin(phase * .pi)
            var particle = context
            particle.opacity = pow(sin(phase * .pi), 0.7) * 0.95
            let rect = CGRect(x: x - 2.5, y: y - 3, width: 5, height: 6)
            particle.fill(Path(roundedRect: rect, cornerRadius: 1.4),
                          with: .color(index % 3 == 0 ? Brand.blue : Brand.teal))
        }
    }
}

/// The circle in the middle: an arrow, a spinning ring while it works, a tick when it's done.
private struct Hub: View {
    let mode: FlowStream.Mode

    var body: some View {
        ZStack {
            Circle()
                .fill(mode == .done ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: mode == .done ? 0 : 1))
                .shadow(color: mode == .done ? Brand.blue.opacity(0.35) : .black.opacity(0.08), radius: mode == .done ? 8 : 3, y: 1)
                .frame(width: 42, height: 42)
            switch mode {
            case .flowing:
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 42, height: 42)
                        .rotationEffect(.degrees(turn * 360))
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.gradient)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            case .faint, .ready:
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(mode == .faint ? 0.45 : 1))
            }
        }
    }
}

/// Speed over time, as a filled line.
struct SpeedChart: View {
    let samples: [Double]
    var label = "Speed"

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let peak = max(samples.max() ?? 0, 1)
            let moving = (samples.max() ?? 0) >= 1
            let points: [CGPoint] = samples.enumerated().map { index, value in
                CGPoint(x: samples.count < 2 ? 0 : size.width * CGFloat(index) / CGFloat(samples.count - 1),
                        y: size.height - 3 - (size.height - 24) * CGFloat(value / peak))
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                if points.count >= 2 && moving {
                    Self.area(points, size)
                        .fill(LinearGradient(colors: [Brand.teal.opacity(0.30), Brand.teal.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Self.line(points)
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        Circle()
                            .fill(Brand.blue)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .position(last)
                    }
                }
                HStack {
                    Text(label.uppercased())
                        .tracking(0.6)
                    Spacer()
                    if samples.count >= 2 && moving {
                        Text("peak \(Format.bytes(Int64(peak)))/s")
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 5)
            }
        }
        .frame(height: 58)
        .accessibilityHidden(true)
    }

    private static func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: middle, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func area(_ points: [CGPoint], _ size: CGSize) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
        path.addLine(to: CGPoint(x: points[0].x, y: size.height))
        path.closeSubpath()
        return path
    }
}

/// Rings spreading out from a Mac: looking for, or waiting for, another Mac.
struct Radar: View {
    let symbol: String
    var active = true
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            if active {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { ring in
                            let phase = (time / 2.6 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(Brand.teal.opacity(0.6 * (1 - phase)), lineWidth: 1.5)
                                .frame(width: 44 + (size - 44) * phase, height: 44 + (size - 44) * phase)
                        }
                    }
                }
            } else {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    .frame(width: size * 0.7, height: size * 0.7)
            }
            Circle()
                .fill(active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: 46, height: 46)
                .shadow(color: Brand.blue.opacity(active ? 0.35 : 0), radius: 8, y: 3)
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The 6-digit code both Macs show, big.
struct CodeView: View {
    let code: String
    var digitSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                if character == " " {
                    Color.clear.frame(width: 8, height: 1)
                } else {
                    Text(String(character))
                        .font(.system(size: digitSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Brand.gradient)
                        .frame(width: digitSize * 1.02, height: digitSize * 1.4)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(code)")
    }
}

/// What kinds of files, as a bar split by data, and the biggest few named below it.
struct CompositionBar: View {
    let kinds: KindTotals
    var legendCount = 3

    var body: some View {
        let ranked = kinds.ranked
        let total = Double(max(kinds.totalBytes, 1))
        VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in
                let gap: CGFloat = ranked.count > 1 ? 1.5 : 0
                let usable = size.width - gap * CGFloat(max(ranked.count - 1, 0))
                let widths = ranked.map { max(3, usable * CGFloat(Double($0.bytes) / total)) }
                let scale = min(1, usable / max(widths.reduce(0, +), 1))
                var x: CGFloat = 0
                for (index, item) in ranked.enumerated() {
                    let width = widths[index] * scale
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(item.kind.color))
                    x += width + gap
                }
            }
            .frame(height: 7)
            .clipShape(Capsule())
            HStack(spacing: 9) {
                ForEach(Array(ranked.prefix(legendCount)), id: \.kind) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.kind.color).frame(width: 6, height: 6)
                        Text("\(item.kind.title) \(Self.share(item.bytes, of: total))")
                            .lineLimit(1)
                    }
                }
                if ranked.count > legendCount {
                    Text("+\(ranked.count - legendCount)")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .help(ranked.map { "\($0.kind.title): \(Format.count($0.files)) files, \(Format.bytes($0.bytes))" }.joined(separator: "\n"))
    }

    static func share(_ bytes: Int64, of total: Double) -> String {
        let share = Double(bytes) / total
        if share > 0 && share < 0.01 { return "<1%" }
        return share.formatted(.percent.precision(.fractionLength(0)))
    }
}

extension FileKind {
    var color: Color {
        switch self {
        case .video: Color(.sRGB, red: 0.56, green: 0.38, blue: 0.95, opacity: 1)
        case .images: Color(.sRGB, red: 0.98, green: 0.58, blue: 0.22, opacity: 1)
        case .audio: Color(.sRGB, red: 0.93, green: 0.34, blue: 0.55, opacity: 1)
        case .documents: Color(.sRGB, red: 0.24, green: 0.54, blue: 0.96, opacity: 1)
        case .code: Color(.sRGB, red: 0.18, green: 0.74, blue: 0.50, opacity: 1)
        case .archives: Color(.sRGB, red: 0.86, green: 0.70, blue: 0.20, opacity: 1)
        case .apps: Color(.sRGB, red: 0.45, green: 0.53, blue: 0.66, opacity: 1)
        case .other: Color(.sRGB, red: 0.62, green: 0.62, blue: 0.66, opacity: 1)
        }
    }
}
