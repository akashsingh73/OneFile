import SwiftUI
import AppKit

// MARK: - Method

/// Fastest, Balanced or Smallest, each with what it would make of this folder.
struct MethodPicker: View {
    @ObservedObject var model: PackModel
    /// "smaller files take longer to make", or for sending, "…to send".
    var subtitle = "smaller files take longer to make"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Method")
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(PackMethod.allCases) { method in
                    // (The Recommended badge sits on a tile's top edge, in the padding above.)
                    MethodTile(method: method,
                               selected: model.method == method,
                               recommended: model.isRecommended(method),
                               reason: model.recommendationReason,
                               size: model.methodSizeText(method),
                               detail: model.methodDetailText(method)) {
                        model.choose(method)
                    }
                }
            }
            .padding(.top, 6)
            Text(model.method.advice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isLocked)
    }
}

struct MethodTile: View {
    let method: PackMethod
    let selected: Bool
    let recommended: Bool
    let reason: String?
    let size: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: method.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary))
                        .frame(width: 16)
                    Text(method.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                Text("\(method.format) · .\(method.fileExtension)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(size)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .padding(.top, 2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.teal.opacity(0.10))
                                   : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Brand.teal : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if recommended {
                    Text("Recommended")
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Brand.gradient))
                        .offset(x: -10, y: -9)
                        .help(reason ?? "")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(recommended ? "Recommended for this folder" : "")
    }
}

// MARK: - Leaving things out

/// The names to leave out, as tags, with a field to add more.
struct LeaveOutRow: View {
    @ObservedObject var model: PackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Leave out")
                    .font(.callout.weight(.semibold))
                Text("files and folders with these names")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(model.leaveOutItems, id: \.self) { item in
                    Chip(text: item) { model.removeLeaveOut(item) }
                }
                TextField("Add a name, or a pattern like *.tmp", text: $model.leaveOutDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                    .onSubmit { model.addLeaveOut() }
            }
        }
        .disabled(model.isLocked)
    }
}

/// Folders a tool can make again (node_modules and the like), with a button to leave each out.
struct SuggestionsBox: View {
    @ObservedObject var model: PackModel

    var body: some View {
        let all = model.suggestions
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Brand.gradient)
                Text(model.suggestionHeadline)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            ForEach(Array(all.prefix(2))) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(item.rule.title)
                                .font(.system(size: 12.5, weight: .semibold, design: item.rule.title.contains("_") ? .monospaced : .default))
                            if item.totals.folders > 1 {
                                Text("· \(Format.count(item.totals.folders)) folders")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            if item.leftOut {
                                Text("Left out")
                                    .font(.system(size: 9, weight: .bold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Brand.gradient))
                            }
                        }
                        Text("\(Format.count(item.totals.files)) files · \(Format.bytes(item.totals.bytes)) · \(item.rule.hint)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Button(item.leftOut ? "Include" : "Leave Out") { model.toggleRebuildable(item.id) }
                        .controlSize(.small)
                        .help(item.leftOut ? "Pack these folders after all" : "Don't pack these: they can be made again on the other side")
                }
            }
            if all.count > 2 {
                Menu("\(all.count - 2) more kinds") {
                    ForEach(Array(all.dropFirst(2))) { item in
                        Button("\(item.leftOut ? "Include" : "Leave out") \(item.rule.title) (\(Format.count(item.totals.files)) files)") {
                            model.toggleRebuildable(item.id)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.teal.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.teal.opacity(0.25)))
        .disabled(model.isLocked)
    }
}

// MARK: - Work in progress

/// How a job's going: percent, bars, numbers, a speed chart, and a Stop button.
struct WorkPanel: View {
    struct Bar {
        var label: String?
        var fraction: Double?
    }

    struct Tile {
        let label: String
        let value: String
        let detail: String
    }

    let percent: String
    var chip: (text: String, symbol: String)?
    let eta: String
    let bars: [Bar]
    let tiles: [Tile]
    let history: [Double]
    var lineIcon: NSImage?
    var lineSymbol: String?
    let line: String
    let current: String
    var warning: String?
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(percent)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let chip {
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Text(eta)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    if let label = bar.label {
                        HStack {
                            Text(label)
                            Spacer()
                            if let fraction = bar.fraction {
                                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    BrandProgressBar(fraction: bar.fraction)
                }
            }
            HStack(spacing: 10) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    StatTile(label: tile.label, value: tile.value, detail: tile.detail)
                }
            }
            SpeedChart(samples: history)
            HStack(spacing: 8) {
                if let lineIcon {
                    Image(nsImage: lineIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                } else if let lineSymbol {
                    Image(systemName: lineSymbol)
                        .foregroundStyle(Brand.gradient)
                        .frame(width: 18)
                }
                Text(line)
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Text(current)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Button("Stop", action: stop)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

// MARK: - Done

struct DoneHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white, .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Big numbers after a job: how many files a second, and the like.
struct HighlightRow: View {
    struct Item {
        let value: String
        let label: String
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.value)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Brand.gradient)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
        }
    }
}

/// Notes after a job (left out, skipped), and the problems, with a button to see them.
struct NotesList: View {
    let notes: [String]
    var problemCount = 0
    var problemText = ""
    var showProblems: () -> Void = {}

    var body: some View {
        if !notes.isEmpty || problemCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if problemCount > 0 {
                    HStack(spacing: 8) {
                        Label(problemText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Show…", action: showProblems)
                            .controlSize(.small)
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// Before and after, as bars.
struct SizeBars: View {
    let before: Int64
    let after: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar("Before", before, 1, AnyShapeStyle(Color.primary.opacity(0.16)))
            bar("After", after, Double(after) / Double(max(before, 1)), AnyShapeStyle(Brand.gradient))
        }
    }

    private func bar(_ label: String, _ bytes: Int64, _ fraction: Double, _ style: AnyShapeStyle) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(style)
                    .frame(width: max(6, geometry.size.width * min(fraction, 1)))
            }
            .frame(height: 8)
            Text(Format.bytes(bytes))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }
}

/// A command to copy, in a box.
struct CommandBox: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Stopped, failed, declined.
struct MessagePanel: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var button = "OK"
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.09)))
            Spacer(minLength: 0)
            Button(button, action: done)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// What couldn't be done, item by item.
struct ProblemsSheet: View {
    let title: String
    let problems: [Problem]
    let count: Int
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.headline)
            }
            if count > problems.count {
                Text("The first \(Format.count(Int64(problems.count))) of \(Format.count(Int64(count))):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(problems) { problem in
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Button("Copy List") { Problems.copy(problems) }
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}

/// A line of small print with a symbol.
struct InfoLine: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(tint))
                .frame(width: 14)
            Text(text)
                .font(.callout)
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
