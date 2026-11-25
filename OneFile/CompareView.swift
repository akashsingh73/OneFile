import SwiftUI
import AppKit

/// Comparing two folders: a copy against its original, or any two (File › Compare Two Folders…).
@MainActor
final class CompareModel: ObservableObject {
    static let shared = CompareModel()

    @Published private(set) var first: URL?
    @Published private(set) var second: URL?
    @Published var showing = false
    /// Read every file on both sides, not only sizes and dates.
    @Published var contents = false
    @Published private(set) var progress = Comparer.Progress()
    @Published private(set) var summary: Comparer.Summary?
    @Published private(set) var failure: String?

    private var comparer: Comparer?
    private var timer: Timer?

    var isComparing: Bool { comparer != nil }

    /// Picks two folders, then compares them.
    func chooseAndCompare() {
        guard !isComparing else { return }
        guard let a = Self.pick("Choose the First Folder", "Compare", nil),
              let b = Self.pick("Choose the Folder to Compare It With", "Compare", a.deletingLastPathComponent()) else { return }
        compare(a, b)
    }

    private static func pick(_ title: String, _ prompt: String, _ start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    func compare(_ a: URL, _ b: URL) {
        guard !isComparing else { return }
        first = a
        second = b
        showing = true
        again()
    }

    /// Compares (again), with the contents setting as it is now.
    func again() {
        guard let first, let second, !isComparing else { return }
        summary = nil
        failure = nil
        let comparer = Comparer(first: first, second: second,
                                options: Comparer.Options(contents: contents,
                                                          leaveOut: WalkRules.parse(PackModel.shared.leaveOut)))
        self.comparer = comparer
        progress = comparer.progress()
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let comparer = CompareModel.shared.comparer { CompareModel.shared.progress = comparer.progress() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        comparer.start { outcome in
            onMain { CompareModel.shared.finish(outcome) }
        }
    }

    func stop() {
        comparer?.cancel()
    }

    func close() {
        stop()
        showing = false
    }

    private func finish(_ outcome: Comparer.Outcome) {
        timer?.invalidate()
        timer = nil
        if let comparer { progress = comparer.progress() }
        comparer = nil
        switch outcome {
        case .finished(let result): summary = result
        case .stopped: failure = "Stopped."
        case .failed(let message): failure = message
        }
    }

    func label(_ difference: Comparer.Difference) -> String {
        let a = first?.lastPathComponent ?? "the first"
        let b = second?.lastPathComponent ?? "the second"
        switch difference {
        case .onlyFirst: return "only in “\(a)”"
        case .onlySecond: return "only in “\(b)”"
        case .kind: return "a file on one side, a folder on the other"
        case .size: return "different size"
        case .date: return "different date"
        case .contents: return "different contents"
        case .link: return "the link points elsewhere"
        }
    }
}

struct CompareSheet: View {
    @ObservedObject var model: CompareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Brand.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comparing “\(model.first?.lastPathComponent ?? "")” and “\(model.second?.lastPathComponent ?? "")”")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(model.first.map { Format.path($0) } ?? "")  ↔  \(model.second.map { Format.path($0) } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if model.isComparing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(Format.count(model.progress.compared)) compared" + (model.contents ? ", \(Format.bytes(model.progress.bytesRead)) read" : ""))
                        .monospacedDigit()
                    Spacer()
                    Button("Stop") { model.stop() }
                }
                Text(model.progress.current)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let summary = model.summary {
                CompareResult(model: model, summary: summary)
            } else if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Toggle("Compare contents too (reads every file on both sides)", isOn: $model.contents)
                    .toggleStyle(.checkbox)
                    .disabled(model.isComparing)
                Spacer()
                Button("Compare Again") { model.again() }
                    .disabled(model.isComparing)
                Button("Done") { model.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440, alignment: .top)
    }
}

private struct CompareResult: View {
    @ObservedObject var model: CompareModel
    let summary: Comparer.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if summary.identical {
                Label(summary.contents ? "The same, file for file and byte for byte." : "The same: names, sizes and dates all match.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
            }
            HighlightRow(items: [
                .init(value: Format.count(summary.same), label: "the same"),
                .init(value: Format.count(summary.different), label: "different"),
                .init(value: Format.count(summary.onlyFirst), label: "only in “\(summary.first.lastPathComponent)”"),
                .init(value: Format.count(summary.onlySecond), label: "only in “\(summary.second.lastPathComponent)”"),
            ])
            if !summary.items.isEmpty || !summary.problems.isEmpty {
                List {
                    ForEach(summary.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isFolder ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(item.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(model.label(item.difference))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(summary.problems) { problem in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(problem.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(problem.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .listStyle(.bordered)
            }
        }
    }
}

/// What a copy has that its original no longer does: to move to the Trash, or keep.
struct ExtrasSheet: View {
    @ObservedObject var model: CopyModel
    let extras: [Copier.Extra]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Format.items(Int64(extras.count))) in the copy aren't in the original any more")
                .font(.headline)
            Text("They were there from an earlier copy. Move them to the Trash to make the copy match the original, or keep them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(extras) { extra in
                HStack(spacing: 8) {
                    Image(systemName: extra.isFolder ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    Text(extra.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if !extra.isFolder {
                        Text(Format.bytes(extra.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.bordered)
            HStack {
                if model.trashing {
                    ProgressView().controlSize(.small)
                    Text("Moving them to the Trash…")
                }
                Spacer()
                Button("Keep Them") { model.showingExtras = false }
                    .disabled(model.trashing)
                Button("Move to Trash") { model.trashExtras() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.trashing)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}
