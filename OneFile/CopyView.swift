import SwiftUI
import AppKit

/// Copy: the folder on the left, where it's going (a folder on a drive) on the right.
struct CopyScreen: View {
    @ObservedObject var pack: PackModel
    @ObservedObject var model: CopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                FolderCard(model: pack)
                FlowStream(mode: flowMode)
                DestinationCard(model: model)
            }
            .frame(height: 214)
            CopyPanel(pack: pack, model: model)
                .id(model.stageKey)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .frame(minHeight: 330, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: model.stageKey)
        .onAppear { model.refresh() }
        .sheet(isPresented: $model.showingProblems) {
            ProblemsSheet(title: "Not copied", problems: model.summary?.problems ?? [],
                          count: model.summary?.problemCount ?? 0) { model.showingProblems = false }
        }
        .sheet(isPresented: $model.showingExtras) {
            ExtrasSheet(model: model, extras: model.summary?.extras ?? [])
        }
    }

    private var flowMode: FlowStream.Mode {
        switch model.stage {
        case .copying: .flowing(FlowStream.intensity(filesPerSecond: model.meter.filesPerSecond))
        case .finished: .done
        default: pack.source == nil || model.destination == nil ? .faint : .ready
        }
    }
}

/// Where the copy goes: a folder, and the drive it's on (what kind, how it's connected, how
/// much room). Empty, the drives connected now, to pick one.
struct DestinationCard: View {
    @ObservedObject var model: CopyModel

    var body: some View {
        if let destination = model.destination {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: model.summary?.destination.path ?? destination.path))
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
                Text(model.summary?.destination.lastPathComponent ?? model.destinationName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.summary.map { _ in "in " + model.destinationName } ?? model.destinationLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination.path)
                if let drive = model.destinationDrive {
                    DriveBadge(drive: drive)
                        .padding(.top, 2)
                }
                if let warning = model.roomWarning {
                    Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let blocker = model.blocker {
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let room = model.roomText {
                    Text(room)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                HStack(spacing: 6) {
                    Button("Change…") { model.chooseDestination() }
                        .controlSize(.small)
                    DriveMenu(model: model)
                }
                .disabled(model.isCopying)
            }
            .cardStyle()
        } else {
            VStack(spacing: 9) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Brand.gradient)
                Text("Copy to…")
                    .font(.system(size: 15, weight: .semibold))
                let drives = model.drives.filter { !$0.isStartup }
                if drives.isEmpty {
                    Text("Connect a drive, or choose a folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(drives.prefix(3)) { drive in
                            Button {
                                model.choose(drive)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: drive.symbol)
                                        .foregroundStyle(Brand.gradient)
                                    Text(drive.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(drive.formatName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                Button("Choose a Folder…") { model.chooseDestination() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardStyle(dashed: true)
        }
    }
}

/// "USB SSD · exFAT", with the drive's symbol.
struct DriveBadge: View {
    let drive: Drive

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: drive.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text("\(drive.kindText) · \(drive.formatName)")
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(drive.product.map { "\(drive.name): \($0)" } ?? drive.name)
    }
}

/// The drives connected now, to copy to one of them.
struct DriveMenu: View {
    @ObservedObject var model: CopyModel

    var body: some View {
        Menu {
            ForEach(model.drives) { drive in
                Button {
                    model.choose(drive)
                } label: {
                    Label(drive.isStartup ? "\(drive.name) (Desktop)" : "\(drive.name) — \(drive.kindText), \(drive.formatName)",
                          systemImage: drive.symbol)
                }
            }
        } label: {
            Image(systemName: "externaldrive")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Copy to a drive")
    }
}

struct CopyPanel: View {
    @ObservedObject var pack: PackModel
    @ObservedObject var model: CopyModel

    var body: some View {
        switch model.stage {
        case .ready:
            CopyReady(pack: pack, model: model)
        case .copying:
            WorkPanel(
                percent: model.percentText,
                chip: (model.plan.clone ? "Cloning" : "\(model.plan.workers) at a time", model.plan.clone ? "plus.square.on.square" : "square.stack.3d.up.fill"),
                eta: model.etaText,
                bars: [.init(label: nil, fraction: model.progress.verifying
                             ? Double(model.progress.verified) / Double(max(model.progress.toVerify, 1))
                             : model.progress.saving ? 1 : model.fraction)],
                tiles: [
                    .init(label: "Files", value: Format.count(model.progress.files + model.progress.unchanged), detail: model.filesDetail),
                    .init(label: "Data", value: Format.bytes(model.progress.bytes + model.progress.unchangedBytes), detail: model.dataDetail),
                    .init(label: "Speed", value: model.meter.speedText, detail: model.meter.filesText),
                    .init(label: "Time", value: model.timeValue, detail: "elapsed"),
                ],
                history: model.meter.history,
                lineSymbol: model.progress.bigName != nil ? "film" : model.destinationDrive?.symbol ?? "externaldrive",
                line: model.workLine,
                current: model.progress.current,
                warning: model.progress.problemCount > 0
                    ? "\(Format.items(Int64(model.progress.problemCount))) couldn't be copied" : nil,
                paused: model.isPaused,
                pauseToggle: model.togglePause,
                stop: model.stop)
        case .finished(let summary):
            CopyFinished(model: model, summary: summary)
        case .failed(let message, let partial):
            MessagePanel(symbol: "xmark.octagon.fill", tint: .red, title: "Couldn't finish copying",
                         message: message + partialNote(partial), done: model.done)
        case .stopped(let partial):
            MessagePanel(symbol: "stop.circle.fill", tint: .gray, title: "Stopped",
                         message: "Nothing was deleted." + partialNote(partial), done: model.done)
        }
    }

    private func partialNote(_ partial: URL?) -> String {
        guard let partial, FileManager.default.fileExists(atPath: partial.path) else { return "" }
        return " What's copied so far is in “\(partial.lastPathComponent)”: copy again to pick up where it stopped."
    }
}

/// Before copying: how it'll go, what's there already, a faster way if there is one, and what to
/// leave out.
struct CopyReady: View {
    @ObservedObject var pack: PackModel
    @ObservedObject var model: CopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pack.source != nil && model.destination != nil {
                PlanBox(model: model)
                Spacer(minLength: 12)
                if case .folder(let url) = model.existing {
                    ExistingChoice(model: model, name: url.lastPathComponent)
                    Spacer(minLength: 12)
                }
                if let hint = model.packHint {
                    PackHintBox(hint: hint, model: model)
                    Spacer(minLength: 12)
                } else if pack.showsSuggestions {
                    SuggestionsBox(model: pack)
                    Spacer(minLength: 12)
                }
            } else {
                InfoLine(symbol: "bolt.fill",
                         text: "Many files at once, big files one after another: far faster than one at a time with many small files. A copy that's stopped picks up where it stopped, and copying again copies only what changed.")
                Spacer(minLength: 16)
            }
            LeaveOutRow(model: pack)
            Spacer(minLength: 14)
            CopyOptionsRow(model: model)
            Spacer(minLength: 18)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button(model.copyButtonTitle) { model.copy() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canCopy)
                    if case .folder = model.existing {
                        Button("Compare") { model.compareWithCopy() }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(width: 130)
                            .help("Compare the folder with the copy that's there: what's only on one side, and what's different")
                    }
                }
                if pack.source != nil && model.destination != nil {
                    Text(model.buttonNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// From which drive to which, and how OneFile will copy between them.
struct PlanBox: View {
    @ObservedObject var model: CopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                DriveChip(drive: model.sourceDrive)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Brand.gradient)
                DriveChip(drive: model.destinationDrive)
                Spacer(minLength: 0)
            }
            Label(model.planText, systemImage: model.plan.clone ? "plus.square.on.square" : "bolt.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct DriveChip: View {
    let drive: Drive?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: drive?.symbol ?? "externaldrive")
                .foregroundStyle(Brand.gradient)
            Text(drive?.name ?? "–")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let drive {
                Text("\(drive.kindText), \(drive.formatName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(drive?.product ?? "")
    }
}

/// A folder of that name is there already: update it, or make a new copy beside it.
struct ExistingChoice: View {
    @ObservedObject var model: CopyModel
    let name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("“\(name)” is there already.")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Picker("", selection: $model.makeNewCopy) {
                Text("Update It").tag(false)
                Text("Make Another Copy").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

/// Many small files going to a drive that's slow with them: packing would be much faster.
struct PackHintBox: View {
    let hint: CopyModel.PackHint
    @ObservedObject var model: CopyModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 16))
                .foregroundStyle(Brand.gradient)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(hint.headline)
                    .font(.callout.weight(.semibold))
                Text(hint.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Pack Instead") { model.packInstead() }
                .controlSize(.small)
                .help("Pack it into one file there (the Pack tab)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.teal.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.teal.opacity(0.25)))
    }
}

struct CopyFinished: View {
    @ObservedObject var model: CopyModel
    let summary: Copier.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DoneHeader(title: title, detail: stats)
            HighlightRow(items: highlights)
            if !summary.extras.isEmpty && model.trashMessage == nil {
                HStack(spacing: 10) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Brand.gradient)
                    Text("\(Format.items(Int64(summary.extras.count))) in the copy aren't in the original any more.")
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button("Review…") { model.showingExtras = true }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.teal.opacity(0.07)))
            }
            if let message = model.trashMessage {
                Label(message, systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            NotesList(notes: notes, problemCount: summary.problemCount,
                      problemText: "\(Format.items(Int64(summary.problemCount))) couldn't be copied.") {
                model.showingProblems = true
            }
            if let message = model.ejectMessage {
                Label(message, systemImage: "eject.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Show in Finder") { model.showInFinder() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Compare") { model.compareWithCopy() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Compare the copy with the original, file by file")
                if model.canEject && model.ejectMessage == nil {
                    Button(model.ejecting ? "Ejecting…" : "Eject “\(model.destinationDrive?.name ?? "")”") { model.eject() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.ejecting)
                }
                Button("Done") { model.done() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var copying: Double { max(summary.seconds - summary.savingSeconds, 0.001) }

    private var title: String {
        if summary.updated && summary.files == 0 { return "Already up to date" }
        return "\(summary.updated ? "Updated" : "Copied") in \(Format.duration(summary.seconds))"
    }

    private var stats: String {
        var text = "\(Format.count(summary.files)) \(summary.files == 1 ? "file" : "files") · \(Format.bytes(summary.bytes))"
        if summary.unchanged > 0 { text += " · \(Format.count(summary.unchanged)) already there" }
        if summary.savingSeconds >= 0.5 {
            text += " · \(Format.duration(summary.savingSeconds)) of it making sure it's all on “\(model.destinationDrive?.name ?? "the drive")”"
        }
        return text
    }

    private var highlights: [HighlightRow.Item] {
        var items: [HighlightRow.Item] = []
        if summary.plan.clone {
            items.append(.init(value: Format.count(summary.files), label: "cloned: no extra space"))
        } else {
            items.append(.init(value: Format.count(Int64(Double(summary.files) / copying)), label: "files a second"))
            items.append(.init(value: "\(Format.bytes(Int64(Double(summary.bytes) / copying)))/s", label: "copied"))
        }
        if summary.verified > 0 || summary.mismatched > 0 {
            items.append(.init(value: Format.count(summary.verified), label: summary.mismatched > 0
                               ? "checked on the drive, \(Format.count(summary.mismatched)) didn't match" : "checked on the drive: all match"))
        } else if summary.unchanged > 0 {
            items.append(.init(value: Format.count(summary.unchanged), label: "there already, skipped"))
        } else if !summary.plan.clone {
            items.append(.init(value: "\(summary.plan.workers)", label: "files at a time"))
        }
        return items
    }

    private var notes: [String] {
        var notes: [String] = []
        if summary.resumed { notes.append("Picked up a copy that had been stopped.") }
        if summary.savingSeconds > 0, let drive = model.destinationDrive {
            notes.append("Everything is on “\(drive.name)”: it's safe to unplug.")
        }
        if summary.rebuildable > 0 {
            notes.append("\(Format.count(summary.rebuildable)) rebuildable \(summary.rebuildable == 1 ? "folder" : "folders") (like node_modules) left out.")
        }
        if summary.gitIgnored > 0 {
            notes.append("\(Format.items(summary.gitIgnored)) that Git ignores left out.")
        }
        if summary.leftOut > 0 {
            notes.append("\(Format.items(summary.leftOut)) matched Leave out, so \(summary.leftOut == 1 ? "it wasn't" : "they weren't") copied.")
        }
        if summary.cloudOnly > 0 {
            notes.append("\(Format.items(summary.cloudOnly)) only in iCloud, so not copied. Download \(summary.cloudOnly == 1 ? "it" : "them") first to include \(summary.cloudOnly == 1 ? "it" : "them").")
        }
        if summary.otherDisks > 0 {
            notes.append("\(Format.count(summary.otherDisks)) other \(summary.otherDisks == 1 ? "disk" : "disks") mounted inside the folder left out.")
        }
        if summary.unsupported > 0 {
            notes.append("\(Format.items(summary.unsupported)) left out (sockets or devices).")
        }
        if summary.changed > 0 {
            notes.append("\(Format.count(summary.changed)) \(summary.changed == 1 ? "file" : "files") changed while being copied.")
        }
        return notes
    }
}

/// Checking the copy on the drive, and (updating) mirroring the original.
struct CopyOptionsRow: View {
    @ObservedObject var model: CopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: $model.verify) {
                HStack(spacing: 6) {
                    Text("Check each file on the drive")
                        .font(.callout.weight(.semibold))
                    Text("reads every copy back and compares it with the original (SHA-256)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            if model.isUpdating {
                Toggle(isOn: $model.mirror) {
                    HStack(spacing: 6) {
                        Text("Offer to remove what's gone")
                            .font(.callout.weight(.semibold))
                        Text("lists what the original no longer has, to move to the Trash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .disabled(model.isCopying)
    }
}
