import SwiftUI
import AppKit

/// Drives: the drives connected now, along the top; below, the one picked: what it is, how fast
/// it is with many files, and tools for it.
struct DrivesScreen: View {
    @ObservedObject var model: DrivesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.drives) { drive in
                        DriveTile(drive: drive, free: model.free[drive.id], selected: drive.id == model.selectedID,
                                  busy: model.testing == drive.id) {
                            model.selectedID = drive.id
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(height: 118)
            if let drive = model.selected {
                DriveDetail(model: model, drive: drive)
                    .frame(minHeight: 430, alignment: .top)
            } else {
                MessagePanel(symbol: "externaldrive.badge.questionmark", tint: .secondary, title: "No drives",
                             message: "Connect a drive to see what it can do.", done: { model.refresh() })
                    .frame(minHeight: 430, alignment: .top)
            }
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $model.showingDeleteProblems) {
            if case .done(let summary) = model.deleteStage {
                ProblemsSheet(title: "Not deleted", problems: summary.problems, count: summary.problemCount) {
                    model.showingDeleteProblems = false
                }
            }
        }
    }
}

struct DriveTile: View {
    let drive: Drive
    let free: Int64?
    let selected: Bool
    let busy: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: drive.mountPath))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                    if busy { ProgressView().controlSize(.mini) }
                }
                Text(drive.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(drive.kindText) · \(drive.formatName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let free, let capacity = drive.capacity, capacity > 0 {
                    ProgressView(value: Double(capacity - free), total: Double(capacity))
                        .progressViewStyle(.linear)
                        .tint(Brand.teal)
                    Text("\(Format.bytes(free)) free of \(Format.bytes(capacity))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(width: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)),
                              lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DriveDetail: View {
    @ObservedObject var model: DrivesModel
    let drive: Drive

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: drive.mountPath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(drive.name)
                        .font(.system(size: 17, weight: .semibold))
                    Text([drive.kindText, drive.formatName, drive.product].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(model.blockText(drive) + (drive.nativeAttributes ? "" : ". Mac details go in “._” files beside each file."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            SpeedSection(model: model, drive: drive)
            if !drive.isStartup {
                BackupSection(model: BackupsModel.shared, drive: drive)
            }
            CleanUpSection(model: model, drive: drive)
            Spacer(minLength: 0)
        }
    }
}

/// How fast the drive is with many files, measured.
struct SpeedSection: View {
    @ObservedObject var model: DrivesModel
    let drive: Drive

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speed with many files")
                    .font(.callout.weight(.semibold))
                Spacer()
                if model.testing == drive.id {
                    Button("Stop") { model.stopTest() }
                        .controlSize(.small)
                } else {
                    Button(model.results[drive.id] == nil ? "Test Speed" : "Test Again") { model.testSpeed() }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }
            if model.testing == drive.id {
                VStack(alignment: .leading, spacing: 6) {
                    BrandProgressBar(fraction: model.testProgress.fraction)
                    Text(model.testProgress.step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let result = model.results[drive.id] {
                HStack(spacing: 10) {
                    StatTile(label: "Small files in", value: Format.count(Int64(result.smallWrite)), detail: "a second")
                    StatTile(label: "Small files out", value: Format.count(Int64(result.smallRead)), detail: "a second")
                    StatTile(label: "Big file in", value: "\(Format.bytes(Int64(result.bigWrite)))/s", detail: "written")
                    StatTile(label: "Big file out", value: "\(Format.bytes(Int64(result.bigRead)))/s", detail: "read")
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SpeedTest.advice(result, drive: drive), id: \.self) { line in
                        Label(line, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let failure = model.testFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("Writes \(Format.count(Int64(SpeedTest.smallCount))) small files and one big file (about 1 GB) in a hidden folder, reads them back from the drive, then deletes them. Takes under a minute on most drives.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// Deleting a folder of many files, or the drive's Trash, for good and fast.
struct CleanUpSection: View {
    @ObservedObject var model: DrivesModel
    let drive: Drive

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Delete fast")
                    .font(.callout.weight(.semibold))
                Text("many files at once, with progress: for good, not to the Trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            switch model.deleteStage {
            case .none:
                HStack(spacing: 10) {
                    Button("Delete a Folder…") { model.chooseFolderToDelete() }
                    Button("Empty the Trash on “\(drive.name)”…") { model.emptyTrash() }
                        .disabled(model.trashFolder == nil)
                }
                .controlSize(.small)
                .disabled(model.isBusy)
            case .counting(let url):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Counting what's in “\(url.lastPathComponent)”…")
                    Spacer()
                    Button("Cancel") { model.cancelDelete() }.controlSize(.small)
                }
            case .confirm(let url, let count, let keepFolder):
                VStack(alignment: .leading, spacing: 8) {
                    Text(keepFolder ? "Empty the Trash for good? \(Format.items(count.items)), \(Format.bytes(count.bytes))."
                                    : "Delete “\(url.lastPathComponent)” for good? \(Format.items(count.items)), \(Format.bytes(count.bytes)).")
                        .font(.callout.weight(.semibold))
                    Text("\(Format.path(url)). This can't be undone: nothing goes to the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 10) {
                        Button(keepFolder ? "Empty Trash" : "Delete") { model.confirmDelete() }
                            .tint(.red)
                        Button("Cancel") { model.cancelDelete() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.07)))
            case .deleting(let url):
                VStack(alignment: .leading, spacing: 6) {
                    BrandProgressBar(fraction: model.deleteFraction)
                    HStack {
                        Text("Deleting “\(url.lastPathComponent)”: \(Format.count(model.deleteProgress.deleted)) deleted"
                             + (model.deleteProgress.finishing ? ", now the folders…" : ""))
                            .font(.caption)
                            .monospacedDigit()
                        Spacer()
                        Button("Stop") { model.cancelDelete() }.controlSize(.small)
                    }
                }
            case .done(let summary):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
                    Text("Deleted \(Format.items(summary.deleted)) (\(Format.bytes(summary.bytes))) in \(Format.duration(summary.seconds)).")
                        .font(.callout)
                    if summary.problemCount > 0 {
                        Button("\(Format.items(Int64(summary.problemCount))) weren't…") { model.showingDeleteProblems = true }
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("OK") { model.doneDeleting() }.controlSize(.small)
                }
            case .stopped(let count):
                HStack {
                    Text("Stopped after deleting \(Format.items(count)).").font(.callout)
                    Spacer()
                    Button("OK") { model.doneDeleting() }.controlSize(.small)
                }
            case .failed(let message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("OK") { model.doneDeleting() }.controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// Folders backed up to this drive each time it's plugged in.
struct BackupSection: View {
    @ObservedObject var model: BackupsModel
    let drive: Drive

    var body: some View {
        let rules = model.rules(for: drive)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Back up when plugged in")
                    .font(.callout.weight(.semibold))
                Text(model.background ? "even when OneFile isn't open" : "while OneFile is open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Add a Folder…") { model.add(to: drive) }
                    .controlSize(.small)
            }
            if rules.isEmpty {
                Text("Pick folders to copy here each time “\(drive.name)” is plugged in. Only what's new or changed is copied, so it's quick, and nothing on the drive is deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rules) { rule in
                    BackupRow(model: model, rule: rule)
                }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct BackupRow: View {
    @ObservedObject var model: BackupsModel
    let rule: BackupRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: rule.source))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.sourceName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(Format.path(URL(fileURLWithPath: rule.source))) → \(rule.placeText) · \(rule.every.title)"
                         + (rule.enabled ? "" : " · off"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if model.running == rule.id {
                    Button(model.isPaused ? "Resume" : "Pause") { model.isPaused ? model.resume() : model.pause() }
                    Button("Stop") { model.stop() }
                } else if model.elsewhere.contains(rule.id) {
                    ProgressView().controlSize(.small)
                    Text("Backing up in the background…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Back Up Now") { model.backUpNow(rule) }
                        .disabled(model.isRunning)
                }
                Menu {
                    Picker("Back Up", selection: Binding(get: { rule.every },
                                                         set: { every in model.update(rule) { $0.every = every } })) {
                        ForEach(BackupRule.Every.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Back Up Automatically", isOn: Binding(get: { rule.enabled },
                                                                  set: { on in model.update(rule) { $0.enabled = on } }))
                    Toggle("Read Each Copy Back to Check It", isOn: Binding(get: { rule.verify },
                                                                            set: { on in model.update(rule) { $0.verify = on } }))
                    Toggle("Leave Out What Git Ignores", isOn: Binding(get: { rule.gitIgnore },
                                                                       set: { on in model.update(rule) { $0.gitIgnore = on } }))
                    Divider()
                    Button("Choose Another Folder on the Drive…") { model.chooseFolder(for: rule) }
                    Button("Show the Backup in Finder") { model.reveal(rule) }
                    Divider()
                    Button("Stop Backing Up “\(rule.sourceName)” (What's on the Drive Stays)") { model.remove(rule) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
            if model.running == rule.id {
                BrandProgressBar(fraction: model.fraction)
                Text(model.isPaused ? "Paused" : model.progressText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if let result = rule.lastResult, let last = rule.lastRun {
                Label("\(BackupsModel.when(last)): \(result)",
                      systemImage: rule.lastFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(rule.lastFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
