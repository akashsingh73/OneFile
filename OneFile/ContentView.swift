import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The window: OneFile's five parts (Pack, Unpack, Copy, Send, Receive), each laid out the same way: what
/// goes in on the left, where it ends up on the right, and below, the choices, then the progress,
/// then what happened.
struct ContentView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var pack: PackModel
    @ObservedObject var unpack: UnpackModel
    @ObservedObject var copy: CopyModel
    @ObservedObject var send: SendModel
    @ObservedObject var receive: ReceiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(app: app, busy: Set(AppModel.Mode.allCases.filter { app.isBusy($0) }))
            Group {
                switch app.mode {
                case .pack: PackScreen(model: pack)
                case .unpack: UnpackScreen(model: unpack)
                case .copy: CopyScreen(pack: pack, model: copy)
                case .send: SendScreen(pack: pack, model: send)
                case .receive: ReceiveScreen(model: receive)
                }
            }
            .transition(.opacity)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 720)
        .background(WindowBackground())
        // A folder or a tar file dropped anywhere on the window.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return false }
            if isFolder.boolValue {
                guard pack.setSource(url) else { return false }
                if app.mode != .send && app.mode != .copy { app.mode = .pack }
                return true
            }
            guard unpack.setArchive(url) else { return false }
            app.mode = .unpack
            return true
        } isTargeted: { targeted in
            pack.isDropTarget = targeted && !pack.isLocked
            unpack.isDropTarget = targeted && !unpack.isUnpacking
        }
        .animation(.easeInOut(duration: 0.18), value: app.mode)
    }
}

/// The window's background: plain, with a faint wash of the icon's teal at the top.
struct WindowBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Brand.teal.opacity(0.11), Brand.teal.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
        }
        .ignoresSafeArea()
    }
}

struct Header: View {
    @ObservedObject var app: AppModel
    let busy: Set<AppModel.Mode>

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("OneFile")
                    .font(.system(size: 21, weight: .bold))
                Text(app.mode.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 10)
            ModeSwitcher(selection: $app.mode, busy: busy)
        }
    }
}

/// Pack · Unpack · Copy · Send · Receive, with a dot on any that's busy.
struct ModeSwitcher: View {
    @Binding var selection: AppModel.Mode
    let busy: Set<AppModel.Mode>
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Mode.allCases) { mode in
                let selected = selection == mode
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { selection = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary))
                        Text(mode.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.13), radius: 2.5, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if busy.contains(mode) {
                            Circle()
                                .fill(Brand.gradient)
                                .frame(width: 6, height: 6)
                                .offset(x: -3, y: 3)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(mode.title) (⌘\(String(mode.shortcut.character)))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

// MARK: - Pack

struct PackScreen: View {
    @ObservedObject var model: PackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                FolderCard(model: model)
                FlowStream(mode: flowMode)
                FileCard(model: model)
            }
            .frame(height: 214)
            // The old panel goes at once and the new one fades in, rather than the two showing
            // through each other.
            PackPanel(model: model)
                .id(model.stageKey)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .frame(minHeight: 330, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: model.stageKey)
        .sheet(isPresented: $model.showingProblems) {
            ProblemsSheet(title: "Not in the file", problems: model.summary?.problems ?? [],
                          count: model.summary?.problemCount ?? 0) { model.showingProblems = false }
        }
    }

    private var flowMode: FlowStream.Mode {
        switch model.stage {
        case .packing: .flowing(FlowStream.intensity(filesPerSecond: model.meter.filesPerSecond))
        case .finished: .done
        default: model.source == nil ? .faint : .ready
        }
    }
}

/// The folder to pack or send. Empty, it's one big place to drop a folder or click to choose one.
struct FolderCard: View {
    @ObservedObject var model: PackModel

    var body: some View {
        if let source = model.source {
            VStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 50, height: 50)
                Text(source.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.sourceFolderLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.path)
                HStack(spacing: 6) {
                    if model.isCounting {
                        ProgressView().controlSize(.mini)
                    }
                    Text(model.sourceCountText)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(model.countFailed ? Color.orange : Color.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                if let insights = model.insights, insights.kinds.totalFiles > 0, !model.countFailed {
                    CompositionBar(kinds: insights.kinds)
                        .padding(.horizontal, 4)
                        .padding(.top, 3)
                }
                Spacer(minLength: 2)
                Button("Change…") { model.chooseSource() }
                    .controlSize(.small)
                    .disabled(model.isLocked)
            }
            .cardStyle(highlighted: model.isDropTarget)
        } else {
            Button {
                model.chooseSource()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Brand.gradient)
                    Text("Drop a folder here")
                        .font(.system(size: 15, weight: .semibold))
                    Text("or click to choose one")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle(highlighted: model.isDropTarget, dashed: true)
        }
    }
}

/// The tar file: where it will go, then where it went (draggable, and shareable).
struct FileCard: View {
    @ObservedObject var model: PackModel

    static let tarIcon = NSWorkspace.shared.icon(for: UTType(filenameExtension: "tar") ?? .data)

    var body: some View {
        if let file = model.shownDestination {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: model.summary != nil ? NSWorkspace.shared.icon(forFile: file.path) : Self.tarIcon)
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
                .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                .help(model.summary != nil ? "Drag it anywhere: a drive, AirDrop, a message" : "")
                Text(file.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("in " + Format.path(file.deletingLastPathComponent()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                if let size = model.destinationSizeText {
                    Text(size)
                        .font(.callout)
                        .monospacedDigit()
                }
                if let warning = model.destinationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let room = model.destinationRoomText {
                    Text(room)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if let output = model.summary?.output {
                    ShareLink(item: output) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                } else {
                    Button("Change…") { model.chooseDestination() }
                        .controlSize(.small)
                        .disabled(model.isLocked)
                }
            }
            .cardStyle()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("One .tar file")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("goes here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardStyle(dashed: true)
        }
    }
}

struct PackPanel: View {
    @ObservedObject var model: PackModel

    var body: some View {
        switch model.stage {
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                if model.showsSuggestions {
                    SuggestionsBox(model: model)
                    Spacer(minLength: 14)
                }
                MethodPicker(model: model)
                Spacer(minLength: 16)
                LeaveOutRow(model: model)
                Spacer(minLength: 18)
                VStack(spacing: 8) {
                    Button(model.packButtonTitle) { model.pack() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canPack)
                    Text(model.method.opensWith)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        case .packing:
            WorkPanel(
                percent: model.percentText,
                chip: ("\(model.method.title) · \(model.method.format)", model.method.symbol),
                eta: model.etaText,
                bars: model.method == .plain ? [.init(label: nil, fraction: model.fraction)]
                    : [.init(label: "Read", fraction: model.readFraction),
                       .init(label: "Compressed and saved", fraction: model.fraction)],
                tiles: [
                    .init(label: "Files", value: Format.count(model.progress.files), detail: model.filesDetail),
                    .init(label: "Data", value: Format.bytes(model.progress.bytes), detail: model.dataDetail),
                    .init(label: "Speed", value: model.meter.speedText, detail: model.meter.filesText),
                    .init(label: "Time", value: model.timeValue, detail: "elapsed"),
                ],
                history: model.meter.history,
                lineIcon: FileCard.tarIcon,
                line: model.outputText,
                current: model.progress.current,
                warning: model.progress.problemCount > 0
                    ? "\(Format.items(Int64(model.progress.problemCount))) couldn't be read" : nil,
                stop: model.stop)
        case .finished(let summary):
            PackFinished(model: model, summary: summary)
        case .failed(let message):
            MessagePanel(symbol: "xmark.octagon.fill", tint: .red, title: "Couldn't pack it", message: message,
                         done: model.done)
        case .stopped:
            MessagePanel(symbol: "stop.circle.fill", tint: .gray, title: "Stopped",
                         message: "The unfinished file was deleted. The folder wasn't touched.", done: model.done)
        }
    }
}

struct PackFinished: View {
    @ObservedObject var model: PackModel
    let summary: Packer.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DoneHeader(title: "Done in \(Format.duration(summary.seconds))", detail: stats)
            HighlightRow(items: [
                .init(value: Format.count(Int64(Double(summary.files) / max(summary.seconds, 0.001))), label: "files a second"),
                .init(value: "\(Format.bytes(Int64(Double(summary.tarBytes) / max(summary.seconds, 0.001))))/s", label: "packed"),
                .init(value: Format.bytes(summary.archiveBytes), label: "one file, \(summary.method.title.lowercased())"),
            ])
            if summary.method != .plain {
                SizeBars(before: summary.tarBytes, after: summary.archiveBytes)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("To unpack it: OneFile (Unpack, on every core), a double-click on a Mac, or on Windows and Linux:",
                      systemImage: "shippingbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CommandBox(command: "tar -xf \"\(summary.output?.lastPathComponent ?? "")\"")
            }
            NotesList(notes: notes, problemCount: summary.problemCount,
                      problemText: "\(Format.items(Int64(summary.problemCount))) couldn't be read, so \(summary.problemCount == 1 ? "it isn't" : "they aren't") in the file.") {
                model.showingProblems = true
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Show in Finder") { model.showInFinder() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Pack Another") { model.done() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var stats: String {
        let things = "\(Format.count(summary.files)) files and \(Format.count(summary.folders)) folders"
        if summary.method == .plain {
            return things + " · \(Format.bytes(summary.archiveBytes))"
        }
        let times = Double(summary.tarBytes) / Double(max(summary.archiveBytes, 1))
        let smaller = times < 1.05 ? "barely smaller" : String(format: "%.1f× smaller", times)
        return things + " · \(Format.bytes(summary.tarBytes)) → \(Format.bytes(summary.archiveBytes)), \(smaller)"
    }

    private var notes: [String] {
        var notes: [String] = []
        if summary.rebuildable > 0 {
            notes.append("\(Format.count(summary.rebuildable)) rebuildable \(summary.rebuildable == 1 ? "folder" : "folders") (like node_modules) left out.")
        }
        if summary.leftOut > 0 {
            notes.append("\(Format.items(summary.leftOut)) matched Leave out, so \(summary.leftOut == 1 ? "it isn't" : "they aren't") in the file.")
        }
        if summary.cloudOnly > 0 {
            notes.append("\(Format.items(summary.cloudOnly)) only in iCloud, so not in the file. Download \(summary.cloudOnly == 1 ? "it" : "them") first to include \(summary.cloudOnly == 1 ? "it" : "them").")
        }
        if summary.otherDisks > 0 {
            notes.append("\(Format.count(summary.otherDisks)) other \(summary.otherDisks == 1 ? "disk" : "disks") mounted inside the folder left out.")
        }
        if summary.unsupported > 0 {
            notes.append("\(Format.items(summary.unsupported)) left out (sockets or devices, which a tar file can't hold).")
        }
        if summary.changed > 0 {
            notes.append("\(Format.count(summary.changed)) \(summary.changed == 1 ? "file" : "files") changed while being packed.")
        }
        return notes
    }
}
