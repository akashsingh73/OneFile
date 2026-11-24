import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Unpack: a tar file on the left, the folder it becomes on the right.
struct UnpackScreen: View {
    @ObservedObject var model: UnpackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                ArchiveCard(model: model)
                FlowStream(mode: flowMode)
                UnpackFolderCard(model: model)
            }
            .frame(height: 214)
            UnpackPanel(model: model)
                .id(model.stageKey)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .frame(minHeight: 330, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: model.stageKey)
        .sheet(isPresented: $model.showingProblems) {
            ProblemsSheet(title: "Not unpacked", problems: model.summary?.problems ?? [],
                          count: model.summary?.problemCount ?? 0) { model.showingProblems = false }
        }
    }

    private var flowMode: FlowStream.Mode {
        switch model.stage {
        case .unpacking: .flowing(FlowStream.intensity(filesPerSecond: model.meter.filesPerSecond))
        case .finished: .done
        default: model.archive == nil ? .faint : .ready
        }
    }
}

/// The tar file. Empty, a place to drop one.
struct ArchiveCard: View {
    @ObservedObject var model: UnpackModel

    var body: some View {
        if let archive = model.archive {
            VStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: archive.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 50, height: 50)
                Text(archive.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.archiveFolderLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(archive.path)
                Text(model.archiveKindText)
                    .font(.callout)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    if model.isLooking { ProgressView().controlSize(.mini) }
                    Text(model.lookText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(lookFailed ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                if let check = model.checkText {
                    Label(check, systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Button("Change…") { model.chooseArchive() }
                    .controlSize(.small)
                    .disabled(model.isUnpacking)
            }
            .cardStyle(highlighted: model.isDropTarget)
        } else {
            Button {
                model.chooseArchive()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Brand.gradient)
                    Text("Drop a tar file here")
                        .font(.system(size: 15, weight: .semibold))
                    Text(".tar, .tar.gz or .tar.xz, or click to choose one")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle(highlighted: model.isDropTarget, dashed: true)
        }
    }

    private var lookFailed: Bool {
        if case .failed = model.look { return true }
        return false
    }
}

/// The folder it becomes, and where.
struct UnpackFolderCard: View {
    @ObservedObject var model: UnpackModel

    var body: some View {
        if model.archive != nil, let destination = model.destination {
            let output = model.shownOutput
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 50, height: 50)
                    if model.summary != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white, .green)
                            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(1))
                            .offset(x: 6, y: 4)
                    }
                }
                Text(output?.lastPathComponent ?? model.outputName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("in " + Format.path(model.summary?.output?.deletingLastPathComponent() ?? destination))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination.path)
                if let summary = model.summary {
                    Text("\(Format.count(summary.files)) files · \(Format.bytes(summary.bytes))")
                        .font(.callout)
                        .monospacedDigit()
                } else if model.summary == nil {
                    Text("A new folder: nothing is replaced")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let warning = model.warningText {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let need = model.needText {
                    Text(need)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if model.summary != nil {
                    Button("Open") { model.open() }
                        .controlSize(.small)
                } else {
                    Button("Change…") { model.chooseDestination() }
                        .controlSize(.small)
                        .disabled(model.isUnpacking)
                }
            }
            .cardStyle()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("A folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("comes out here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardStyle(dashed: true)
        }
    }

    private var icon: NSImage {
        if let output = model.summary?.output, FileManager.default.fileExists(atPath: output.path) {
            return NSWorkspace.shared.icon(forFile: output.path)
        }
        return model.outputIsFolder ? NSWorkspace.shared.icon(for: .folder)
                                    : NSWorkspace.shared.icon(for: UTType(filenameExtension: (model.outputName as NSString).pathExtension) ?? .data)
    }
}

struct UnpackPanel: View {
    @ObservedObject var model: UnpackModel

    var body: some View {
        switch model.stage {
        case .ready:
            UnpackReady(model: model)
        case .unpacking:
            WorkPanel(
                percent: model.percentText,
                chip: ("\(Unpacker.writers) writers at once", "square.stack.3d.up.fill"),
                eta: model.etaText,
                bars: [.init(label: nil, fraction: model.fraction)],
                tiles: [
                    .init(label: "Files", value: Format.count(model.progress.files), detail: model.filesDetail),
                    .init(label: "Data", value: Format.bytes(model.progress.bytes), detail: model.dataDetail),
                    .init(label: "Speed", value: model.meter.speedText, detail: model.meter.filesText),
                    .init(label: "Time", value: model.timeValue, detail: "elapsed"),
                ],
                history: model.meter.history,
                lineSymbol: "folder.fill",
                line: "\(model.outputName) · \(Format.count(model.progress.folders)) folders made",
                current: model.progress.current,
                warning: model.progress.problemCount > 0
                    ? "\(Format.items(Int64(model.progress.problemCount))) couldn't be unpacked" : nil,
                stop: model.stop)
        case .finished(let summary):
            UnpackFinished(model: model, summary: summary)
        case .failed(let message):
            MessagePanel(symbol: "xmark.octagon.fill", tint: .red, title: "Couldn't unpack it", message: message,
                         done: model.done)
        case .stopped:
            MessagePanel(symbol: "stop.circle.fill", tint: .gray, title: "Stopped",
                         message: "What was unpacked has been deleted. The file wasn't touched.", done: model.done)
        }
    }
}

struct UnpackReady: View {
    @ObservedObject var model: UnpackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's inside")
                    .font(.callout.weight(.semibold))
                if let seen = model.seen {
                    if seen.kinds.totalFiles > 0 {
                        CompositionBar(kinds: seen.kinds, legendCount: 5)
                    }
                    if let top = model.topText {
                        InfoLine(symbol: "folder.fill", text: top)
                    }
                    if seen.single {
                        InfoLine(symbol: "doc.fill", text: "It isn't a tar file: it's one compressed file, “\(model.outputName)”. It unpacks as that file.")
                    }
                    if seen.links > 0 {
                        InfoLine(symbol: "link", text: "\(Format.count(seen.links)) links, made last, inside the new folder only.")
                    }
                    if seen.refused > 0 {
                        InfoLine(symbol: "exclamationmark.shield.fill",
                                 text: "\(Format.items(seen.refused)) would land outside the folder (their paths have “..”): \(seen.refused == 1 ? "it's" : "they're") left out.",
                                 tint: .orange)
                    }
                    if seen.macMetadata > 0 {
                        InfoLine(symbol: "info.circle", text: "\(Format.count(seen.macMetadata)) Mac metadata files (“._” files from macOS's tar) are left out.")
                    }
                } else if case .failed(let message) = model.look {
                    InfoLine(symbol: "xmark.octagon.fill", text: message, tint: .red)
                } else if model.archive == nil {
                    InfoLine(symbol: "sparkles", text: "Choose a tar file: OneFile reads it through first, so you see what's inside and that it's intact before anything is written.")
                } else {
                    InfoLine(symbol: "magnifyingglass", text: "Reading it through, to show what's inside and check it's intact. You can unpack right away.")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
            VStack(alignment: .leading, spacing: 7) {
                InfoLine(symbol: "bolt.fill", text: "\(Unpacker.writers) files are written at once, and OneFile's own files decompress on every core: about 3× as fast as tar on small files.")
                InfoLine(symbol: "lock.shield.fill", text: "Nothing is replaced, and nothing can be written outside the new folder. Stopping deletes what was unpacked.")
            }
            .padding(.top, 14)
            Spacer(minLength: 18)
            Button(model.unpackButtonTitle) { model.unpack() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canUnpack)
        }
    }
}

struct UnpackFinished: View {
    @ObservedObject var model: UnpackModel
    let summary: Unpacker.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DoneHeader(title: "Unpacked in \(Format.duration(summary.seconds))",
                       detail: "\(Format.count(summary.files)) files and \(Format.count(summary.folders)) folders · \(Format.bytes(summary.bytes)), as “\(summary.output?.lastPathComponent ?? "")”")
            HighlightRow(items: [
                .init(value: Format.count(Int64(Double(summary.files) / max(summary.seconds, 0.001))), label: "files a second"),
                .init(value: "\(Format.bytes(Int64(Double(summary.bytes) / max(summary.seconds, 0.001))))/s", label: "written"),
                .init(value: summary.parallel ? "every core" : "one core", label: "decompressing"),
            ])
            NotesList(notes: notes, problemCount: summary.problemCount,
                      problemText: "\(Format.items(Int64(summary.problemCount))) couldn't be unpacked.") {
                model.showingProblems = true
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Show in Finder") { model.showInFinder() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Unpack Another") { model.done() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if summary.links > 0 { notes.append("\(Format.count(summary.links)) links made, all inside the folder.") }
        if summary.macMetadata > 0 {
            notes.append("\(Format.count(summary.macMetadata)) Mac metadata files (“._”) left out.")
        }
        if summary.refused > 0 {
            notes.append("\(Format.items(summary.refused)) left out: \(summary.refused == 1 ? "its path leads" : "their paths lead") outside the folder.")
        }
        return notes
    }
}
