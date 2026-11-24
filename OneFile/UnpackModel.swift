import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Unpack side: a tar file, where it unpacks, and unpacking it.
@MainActor
final class UnpackModel: ObservableObject {
    static let shared = UnpackModel()

    enum Stage {
        case ready
        case unpacking
        case finished(Unpacker.Summary)
        case failed(String)
        case stopped
    }

    /// What's inside, found by reading it through once it's chosen.
    enum Look {
        case none
        case looking
        case seen(Unpacker.Summary)
        case failed(String)
    }

    @Published private(set) var archive: URL?
    @Published private(set) var archiveSize: Int64 = 0
    @Published private(set) var destination: URL?
    @Published private(set) var look: Look = .none
    @Published private(set) var lookProgress = Unpacker.Progress()
    @Published private(set) var stage: Stage = .ready
    @Published private(set) var progress = Unpacker.Progress()
    @Published private(set) var meter = RateMeter()
    @Published private(set) var room: PackModel.Room?
    @Published private(set) var finishedAt: Date?
    @Published var isDropTarget = false
    @Published var showingProblems = false

    private var chosenFolder: URL?
    private var inspector: Unpacker?
    private var unpacker: Unpacker?
    private var timer: Timer?
    private var lookTimer: Timer?
    private var activity: NSObjectProtocol?
    private var inputMeter = RateMeter()

    var isUnpacking: Bool {
        if case .unpacking = stage { return true }
        return false
    }

    var isLooking: Bool {
        if case .looking = look { return true }
        return false
    }

    var seen: Unpacker.Summary? {
        if case .seen(let summary) = look { return summary }
        return nil
    }

    var summary: Unpacker.Summary? {
        if case .finished(let summary) = stage { return summary }
        return nil
    }

    var canUnpack: Bool {
        guard archive != nil, destination != nil, !isUnpacking else { return false }
        if case .failed = look { return false }
        return !notEnoughRoom
    }

    // MARK: Choosing

    func chooseArchive() {
        guard !isUnpacking else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a File to Unpack"
        panel.prompt = "Choose"
        panel.message = "A .tar, .tar.gz or .tar.xz file (from OneFile or anything else)."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AppModel.archiveTypes
        panel.directoryURL = archive?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setArchive(url)
    }

    /// Takes a file chosen or dropped on the window. False if it isn't a file.
    @discardableResult
    func setArchive(_ url: URL) -> Bool {
        guard !isUnpacking else { return false }
        var isFolder: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              !isFolder.boolValue else { return false }
        let file = url.standardizedFileURL
        archive = file
        archiveSize = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        stage = .ready
        destination = chosenFolder ?? defaultFolder(for: file)
        refreshRoom()
        startLooking()
        return true
    }

    /// Next to the file, if that's a place OneFile can write; else Downloads.
    private func defaultFolder(for file: URL) -> URL {
        let folder = file.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: folder.path) { return folder }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func chooseDestination() {
        guard !isUnpacking else { return }
        let panel = NSOpenPanel()
        panel.title = "Unpack Where?"
        panel.prompt = "Unpack Here"
        panel.message = "A new folder is made here; nothing already here is replaced."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenFolder = url
        destination = url
        refreshRoom()
    }

    private func refreshRoom() {
        room = destination.map { PackModel.Room(folder: $0) }
    }

    // MARK: Looking inside

    private func startLooking() {
        inspector?.cancel()
        lookTimer?.invalidate()
        guard let archive else { return }
        let inspector = Unpacker(source: .file(archive), destination: nil)
        self.inspector = inspector
        look = .looking
        lookProgress = Unpacker.Progress()
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { UnpackModel.shared.lookTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lookTimer = timer
        inspector.start { outcome in
            onMain { UnpackModel.shared.looked(outcome, by: inspector) }
        }
    }

    private func lookTick() {
        guard let inspector else { return }
        lookProgress = inspector.progress()
    }

    private func looked(_ outcome: Unpacker.Outcome, by inspector: Unpacker) {
        guard inspector === self.inspector else { return }
        lookTimer?.invalidate()
        lookTimer = nil
        lookProgress = inspector.progress()
        self.inspector = nil
        switch outcome {
        case .finished(let summary): look = .seen(summary)
        case .failed(let message): look = .failed(message)
        case .stopped: look = .none
        }
    }

    // MARK: Unpacking

    func unpack() {
        guard canUnpack, let archive, let destination else { return }
        // Unpacking reads it all anyway: stop looking.
        if isLooking {
            inspector?.cancel()
            inspector = nil
            lookTimer?.invalidate()
            look = .none
        }
        let unpacker = Unpacker(source: .file(archive), destination: destination)
        self.unpacker = unpacker
        progress = unpacker.progress()
        meter.reset()
        inputMeter.reset()
        finishedAt = nil
        stage = .unpacking
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Unpacking a file into a folder")
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { UnpackModel.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        AppModel.shared.activityChanged()
        unpacker.start { outcome in
            onMain { UnpackModel.shared.finish(outcome) }
        }
    }

    func stop() {
        unpacker?.cancel()
    }

    func stopForQuit() {
        unpacker?.cancel()
    }

    private func tick() {
        guard let unpacker else { return }
        progress = unpacker.progress()
        meter.add(bytes: progress.bytes, files: progress.files)
        inputMeter.add(bytes: progress.processed, files: progress.files)
    }

    private func finish(_ outcome: Unpacker.Outcome) {
        timer?.invalidate()
        timer = nil
        if let unpacker { progress = unpacker.progress() }
        unpacker = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        switch outcome {
        case .finished(let summary):
            stage = .finished(summary)
            finishedAt = Date()
        case .stopped: stage = .stopped
        case .failed(let message): stage = .failed(message)
        }
        refreshRoom()
        AppModel.shared.activityChanged()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func done() {
        stage = .ready
        refreshRoom()
    }

    func showInFinder() {
        guard let output = summary?.output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    func open() {
        guard let output = summary?.output else { return }
        NSWorkspace.shared.open(output)
    }

    // MARK: What the window says

    var stageKey: Int {
        switch stage {
        case .ready: 0
        case .unpacking: 1
        case .finished: 2
        case .failed: 3
        case .stopped: 4
        }
    }

    var archiveFolderLine: String {
        archive.map { "in " + Format.path($0.deletingLastPathComponent()) } ?? ""
    }

    var archiveKindText: String {
        let name = archive?.lastPathComponent.lowercased() ?? ""
        let kind: String
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { kind = "gzip" }
        else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { kind = "xz" }
        else if name.hasSuffix(".gz") { kind = "gzip" }
        else if name.hasSuffix(".xz") { kind = "xz" }
        else { kind = "tar" }
        return "\(Format.bytes(archiveSize)) · \(kind)"
    }

    var lookText: String {
        switch look {
        case .none: return ""
        case .looking:
            let files = lookProgress.files
            return files > 0 ? "Looking inside… \(Format.count(files)) files" : "Looking inside…"
        case .seen(let seen):
            if seen.single { return "One file · \(Format.bytes(seen.bytes))" }
            return "\(Format.count(seen.files)) files · \(Format.bytes(seen.bytes))"
        case .failed(let message): return message
        }
    }

    /// What reading it through showed about it.
    var checkText: String? {
        guard let seen else { return nil }
        switch seen.format {
        case .gzip, .xz: return seen.parallel ? "Intact · unpacks on every core" : "Intact: it all decompresses"
        default: return "Every entry reads back in order"
        }
    }

    /// What it'll be called once unpacked (with a number if that name's taken there).
    var outputName: String {
        guard let archive else { return "" }
        let base = ArchiveName.unpackedName(archive.lastPathComponent)
        var name = base
        var isFolder = true
        if let seen, seen.topCount == 1, let only = seen.topNames.first {
            name = only
            isFolder = seen.topIsFolder
        }
        guard let destination else { return name }
        var candidate = name
        var number = 2
        while FileManager.default.fileExists(atPath: destination.appendingPathComponent(candidate).path) && number < 1000 {
            candidate = Unpacker.numbered(name, number, isFolder: isFolder)
            number += 1
        }
        return candidate
    }

    var outputIsFolder: Bool {
        guard let seen else { return true }
        return seen.topCount != 1 || seen.topIsFolder
    }

    var shownOutput: URL? {
        summary?.output ?? destination?.appendingPathComponent(outputName)
    }

    var topText: String? {
        guard let seen, !seen.single else { return nil }
        if seen.topCount == 1, let only = seen.topNames.first {
            return seen.topIsFolder ? "One folder, “\(only)”, with \(Format.count(seen.files)) files and \(Format.count(max(seen.folders - 1, 0))) folders in it."
                                    : "One file, “\(only)”."
        }
        let names = seen.topNames.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        let more = seen.topCount > 3 ? " and \(seen.topCount - 3) more" : ""
        return "\(seen.topCount) things at the top (\(names)\(more)): they go together into a new folder, “\(outputName)”."
    }

    var needText: String? {
        guard summary == nil, let room else { return nil }
        let free = room.free.map { "\(Format.bytes($0)) free on “\(room.volume)”" } ?? "on “\(room.volume)”"
        guard let seen else { return free }
        return "Needs \(Format.bytes(seen.bytes)) · \(free)"
    }

    var notEnoughRoom: Bool {
        guard let seen, let free = room?.free else { return false }
        return seen.bytes > free
    }

    var warningText: String? {
        if notEnoughRoom, let seen, let free = room?.free {
            return "Not enough room here: it needs \(Format.bytes(seen.bytes)), and \(Format.bytes(free)) is free."
        }
        return nil
    }

    var unpackButtonTitle: String {
        if let seen, seen.files > 0, !seen.single {
            return "Unpack \(Format.count(seen.files)) \(seen.files == 1 ? "File" : "Files")"
        }
        return "Unpack"
    }

    var fraction: Double? {
        guard let total = progress.total, total > 0 else { return nil }
        if progress.finishing { return 1 }
        return min(1, Double(progress.processed) / Double(total))
    }

    var percentText: String {
        if progress.cleaning { return "Stopping…" }
        guard let fraction else { return "Unpacking…" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var etaText: String {
        if progress.cleaning { return "Deleting what was unpacked…" }
        if progress.finishing { return "Setting dates and links…" }
        guard let total = progress.total, let fraction, fraction > 0.01, inputMeter.bytesPerSecond > 0 else {
            return "Working out the time left…"
        }
        let left = Double(total - progress.processed) / inputMeter.bytesPerSecond
        return "About \(Format.duration(left)) left"
    }

    var filesDetail: String {
        seen.map { "of \(Format.count($0.files))" } ?? "\(Format.count(progress.folders)) folders"
    }

    var dataDetail: String {
        seen.map { "of \(Format.bytes($0.bytes))" } ?? ""
    }

    var timeValue: String {
        Format.clock(Date().timeIntervalSince(progress.started))
    }
}
