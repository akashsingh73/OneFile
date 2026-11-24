import SwiftUI
import AppKit

/// OneFile's look: the icon's teal-to-blue, rounded cards, and a few controls drawn to match.
/// (No `@State` anywhere: it's a macro, and the Command Line Tools don't ship the plugin it needs.)
enum Brand {
    static let teal = Color(.sRGB, red: 0.17, green: 0.70, blue: 0.88, opacity: 1)
    static let blue = Color(.sRGB, red: 0.10, green: 0.30, blue: 0.72, opacity: 1)
    static let gradient = LinearGradient(colors: [teal, blue], startPoint: .leading, endPoint: .trailing)
}

/// The big button that does the main thing: full width, in the icon's colours.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PrimaryButton(configuration: configuration)
    }

    private struct PrimaryButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isEnabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// A quieter button the same size as `PrimaryButtonStyle`'s, for the other choice.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A rounded card. `dashed` for an empty one waiting to be filled; `highlighted` while something
/// is being dragged over it.
struct CardStyle: ViewModifier {
    var highlighted = false
    var dashed = false

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 188)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Brand.teal.opacity(0.10))
                                      : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                    .shadow(color: .black.opacity(dashed ? 0 : 0.07), radius: 10, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(highlighted ? Brand.teal : Color(nsColor: .separatorColor),
                                  style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: dashed ? [6, 5] : []))
            )
    }
}

extension View {
    func cardStyle(highlighted: Bool = false, dashed: Bool = false) -> some View {
        modifier(CardStyle(highlighted: highlighted, dashed: dashed))
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        // Line each row's items up on their centres.
        var rows: [[(Subviews.Element, CGSize)]] = [[]]
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                rows.append([])
            }
            rows[rows.count - 1].append((view, size))
            x += size.width + spacing
        }
        for row in rows {
            rowHeight = row.map(\.1.height).max() ?? 0
            x = bounds.minX
            for (view, size) in row {
                view.place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

/// A name in the Leave out list, with a button to take it off.
struct Chip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Pack “\(text)” after all")
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Brand.teal.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Brand.teal.opacity(0.30)))
    }
}

/// A progress bar in the icon's colours. With no fraction (the folder is still being counted), a
/// stretch of it glides back and forth.
struct BrandProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let fraction {
                    Capsule()
                        .fill(Brand.gradient)
                        .frame(width: max(10, geometry.size.width * fraction))
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    TimelineView(.animation) { context in
                        let time = context.date.timeIntervalSinceReferenceDate
                        let width = geometry.size.width * 0.28
                        Capsule()
                            .fill(Brand.gradient)
                            .frame(width: width)
                            .offset(x: (geometry.size.width - width) * (sin(time * 2.2) + 1) / 2)
                    }
                }
            }
        }
        .frame(height: 10)
    }
}

/// The arrow between the folder and the file. While packing, dots run along it.
struct FlowArrow: View {
    enum Mode { case faint, ready, flowing, done }
    let mode: Mode

    var body: some View {
        ZStack {
            Circle()
                .fill(mode == .done ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: mode == .done ? 0 : 1))
                .frame(width: 40, height: 40)
            if mode == .flowing {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Brand.gradient)
                                .frame(width: 6, height: 6)
                                .opacity(0.25 + 0.75 * max(0, sin(time * 5 - Double(index) * 0.9)))
                        }
                    }
                }
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mode == .done ? Color.white
                                     : Color.secondary.opacity(mode == .faint ? 0.45 : 1))
            }
        }
        .frame(width: 60)
        .accessibilityHidden(true)
    }
}

/// One number while packing: what it is, the number, and something about it.
struct StatTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail.isEmpty ? " " : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}
