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
    /// Where an archive on the internet is: "in “Work R2”", "at example.com". Nil for a file.
    @Published private(set) var remoteLabel: String?
    /// Opening an archive on the internet (asking for its size, whether it's locked).
    @Published private(set) var openingRemote = false
    @Published private(set) var remoteProblem: String?
    /// How many files the archive is in: more than one when it was split into parts.
    @Published private(set) var partCount = 1
    /// Locked with a password (age): it has to be unlocked before anything else.
    @Published private(set) var locked = false
    @Published var password = ""
    @Published private(set) var unlocking = false
    @Published private(set) var unlockProblem: String?
    /// The password that opened it (kept while it's chosen, for unpacking).
    private var openPassword: String?
    /// OneFile's index, when the archive is one of OneFile's: listing, taking files out, checking.
    @Published private(set) var index: ArchiveIndex?
    @Published private(set) var indexFormat: ArchiveFormat?
    @Published var showingBrowser = false
    @Published var browserQuery = ""
    @Published var browserSelection = Set<Int>()
    @Published private(set) var extracting = false
    @Published private(set) var extractProgress = Extractor.Progress()
    @Published private(set) var extractResult: String?
    @Published private(set) var checking = false
    @Published private(set) var checkFraction: Double = 0
    @Published private(set) var checkResult: (ok: Bool, text: String)?
    private var extractor: Extractor?
    private var checker: ArchiveChecker?
    private var indexTimer: Timer?
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
        guard archive != nil, destination != nil, !isUnpacking, !locked else { return false }
        if case .failed = look { return false }
        return !notEnoughRoom
    }

    // MARK: Choosing

    func chooseArchive() {
        guard !isUnpacking else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a File to Unpack"
        panel.prompt = "Choose"
        panel.message = "A .tar, .tar.gz, .tar.zst or .tar.xz file (from OneFile or anything else)."
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
        remoteLabel = nil
        remoteProblem = nil
        // A split file is all its parts, from the first.
        let parts = SplitParts.parts(of: file) ?? [file]
        partCount = parts.count
        archiveSize = parts.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        stage = .ready
        destination = chosenFolder ?? defaultFolder(for: file)
        refreshRoom()
        openPassword = nil
        password = ""
        unlockProblem = nil
        locked = InputFile(paths: parts.map(\.path))?.isLocked ?? false
        if locked {
            inspector?.cancel()
            look = .none
            index = nil
        } else {
            startLooking()
            readIndex(file, parts)
        }
        return true
    }

    // MARK: On the internet

    var isRemote: Bool { remoteLabel != nil }

    /// Opens an archive on the internet: at a link, or in the cloud (registered by `Cloud.open`).
    /// It's read from there as it's needed; nothing is downloaded first.
    func openRemote(_ url: URL, label: String) {
        guard !isUnpacking else { return }
        openingRemote = true
        remoteProblem = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Remote.objects(for: url).map { objects -> (Int64, Int, Bool) in
                let file = InputFile(remote: RemoteFile(objects))
                return (file.rawSize, objects.count, file.isLocked)
            }
            onMain {
                let model = UnpackModel.shared
                model.openingRemote = false
                switch result {
                case .success(let (size, parts, locked)): model.setRemote(url, label: label, size: size, parts: parts, locked: locked)
                case .failure(let error): model.remoteProblem = error.message
                }
            }
        }
    }

    private func setRemote(_ url: URL, label: String, size: Int64, parts: Int, locked: Bool) {
        guard !isUnpacking else { return }
        inspector?.cancel()
        inspector = nil
        lookTimer?.invalidate()
        look = .none
        archive = url
        remoteLabel = label
        partCount = parts
        archiveSize = size
        stage = .ready
        destination = chosenFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        refreshRoom()
        openPassword = nil
        password = ""
        unlockProblem = nil
        self.locked = locked
        index = nil
        // Looking inside would read all of it: only the index (a few pieces) is read.
        if !locked { readIndex(url, [url]) }
    }

    // MARK: Locked files

    /// Tries the password (scrypt takes about a second), then carries on as with any archive.
    func unlock() {
        guard let archive, locked, !unlocking, !password.isEmpty else { return }
        unlocking = true
        unlockProblem = nil
        let attempt = password
        DispatchQueue.global(qos: .userInitiated).async {
            let result = InputFile.open(archive, password: attempt)
            onMain {
                let model = UnpackModel.shared
                guard model.archive == archive else { return }
                model.unlocking = false
                switch result {
                case .success:
                    model.openPassword = attempt
                    model.locked = false
                    model.password = ""
                    model.startLooking()
                    model.readIndex(archive, SplitParts.parts(of: archive) ?? [archive])
                case .failure(let error):
                    model.unlockProblem = error.message
                }
            }
        }
    }

    // MARK: OneFile's index

    private func readIndex(_ file: URL, _ parts: [URL]) {
        index = nil
        indexFormat = nil
        checkResult = nil
        extractResult = nil
        browserSelection = []
        browserQuery = ""
        let password = openPassword
        DispatchQueue.global(qos: .userInitiated).async {
            guard case .success(let input) = InputFile.open(file, password: password),
                  case .success(let format) = ArchiveFormat.detect(input, name: file.lastPathComponent),
                  let found = ArchiveIndex.read(input, format: format) else { return }
            onMain {
                let model = UnpackModel.shared
                guard model.archive == file else { return }
                model.index = found
                model.indexFormat = format
            }
        }
    }

    /// What the browser lists: everything, or what matches what's typed (at most a few thousand).
    var browserEntries: [ArchiveIndex.Entry] {
        guard let index else { return [] }
        let query = browserQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty ? index.entries : index.entries.filter { $0.path.lowercased().contains(query) }
        return Array(matching.prefix(5_000))
    }

    /// Takes the chosen files and folders out, into a folder picked now.
    func extractSelected() {
        guard let index, let indexFormat, let archive, !extracting, !browserSelection.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Take Out to Where?"
        panel.prompt = "Take Out Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let chosen = index.entries.filter { browserSelection.contains($0.id) }
        let extractor = Extractor(archive: archive, index: index, format: indexFormat, chosen: chosen, destination: folder,
                                  password: openPassword)
        self.extractor = extractor
        extracting = true
        extractResult = nil
        extractProgress = Extractor.Progress()
        startIndexTimer()
        extractor.start { outcome in
            onMain { UnpackModel.shared.extracted(outcome) }
        }
    }

    private func extracted(_ outcome: Extractor.Outcome) {
        if let extractor { extractProgress = extractor.progress() }
        extractor = nil
        extracting = false
        stopIndexTimer()
        switch outcome {
        case .finished(let summary):
            var text = "Took out \(Format.items(summary.files)) (\(Format.bytes(summary.bytes)))"
            text += summary.mismatched == 0 ? ", each matching its SHA-256." : "; \(summary.mismatched) didn't match: the archive is damaged there."
            if summary.problems.count > summary.mismatched { text += " \(Format.items(Int64(summary.problems.count))) couldn't be taken out." }
            extractResult = text
            if let first = summary.made.first { NSWorkspace.shared.activateFileViewerSelecting(summary.made.isEmpty ? [first] : summary.made) }
        case .stopped:
            extractResult = "Stopped."
        case .failed(let message):
            extractResult = message
        }
    }

    func stopExtracting() { extractor?.cancel() }

    /// Reads the whole archive and checks every file against its SHA-256.
    func checkEveryFile() {
        guard let index, let indexFormat, let archive, !checking else { return }
        let checker = ArchiveChecker(archive: archive, index: index, format: indexFormat, password: openPassword)
        self.checker = checker
        checking = true
        checkResult = nil
        checkFraction = 0
        startIndexTimer()
        checker.start { outcome in
            onMain { UnpackModel.shared.checked(outcome) }
        }
    }

    private func checked(_ outcome: ArchiveChecker.Outcome) {
        checker = nil
        checking = false
        stopIndexTimer()
        switch outcome {
        case .finished(let summary):
            if summary.mismatched.isEmpty {
                checkResult = (true, "All \(Format.count(summary.checked)) files match the SHA-256 recorded when they were packed (checked in \(Format.duration(summary.seconds))).")
            } else {
                checkResult = (false, "\(Format.items(Int64(summary.mismatched.count))) don't match: \(summary.mismatched.prefix(3).joined(separator: ", "))\(summary.mismatched.count > 3 ? "…" : ""). The archive is damaged there.")
            }
        case .stopped:
            checkResult = nil
        case .failed(let message):
            checkResult = (false, message)
        }
    }

    func stopChecking() { checker?.cancel() }

    private func startIndexTimer() {
        guard indexTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = UnpackModel.shared
                if let extractor = model.extractor { model.extractProgress = extractor.progress() }
                if let checker = model.checker { model.checkFraction = checker.fraction }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        indexTimer = timer
    }

    private func stopIndexTimer() {
        guard extractor == nil, checker == nil else { return }
        indexTimer?.invalidate()
        indexTimer = nil
    }

    /// "12,345 files listed": what the index holds, for the panel.
    var indexText: String? {
        guard let index else { return nil }
        let files = index.entries.filter { $0.kind == .file }.count
        return "OneFile's index lists \(Format.count(Int64(files))) files with their SHA-256: look inside, take out just what you need, or check every file."
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
        setDestination(url)
    }

    /// Unpacks into `folder` (picked, or from a link).
    func setDestination(_ folder: URL) {
        guard !isUnpacking else { return }
        chosenFolder = folder
        destination = folder
        refreshRoom()
    }

    private func refreshRoom() {
        room = destination.map { PackModel.Room(folder: $0) }
    }

    // MARK: Looking inside

    private func startLooking() {
        inspector?.cancel()
        lookTimer?.invalidate()
        guard let archive, !isRemote else { return }
        let inspector = Unpacker(source: .file(archive), destination: nil, password: openPassword)
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
        let unpacker = Unpacker(source: .file(archive), destination: destination, password: openPassword)
        self.unpacker = unpacker
        progress = unpacker.progress()
        meter.reset()
        inputMeter.reset()
        finishedAt = nil
        stage = .unpacking
        Work.jobStarted()
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

    // MARK: Pausing

    @Published private(set) var isPaused = false
    /// Paused because the Mac went onto its battery: it carries on when it's back on power.
    private(set) var pausedForBattery = false

    func togglePause() {
        guard let unpacker else { return }
        if isPaused {
            unpacker.resume()
            isPaused = false
            pausedForBattery = false
        } else {
            unpacker.pause()
            isPaused = true
        }
    }

    func pauseForBattery() {
        guard let unpacker, !isPaused else { return }
        unpacker.pause()
        isPaused = true
        pausedForBattery = true
    }

    func resumeAfterBattery() {
        guard let unpacker, pausedForBattery else { return }
        unpacker.resume()
        isPaused = false
        pausedForBattery = false
    }

    var pausedText: String {
        pausedForBattery ? "Paused while the Mac is on its battery" : "Paused"
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
        isPaused = false
        pausedForBattery = false
        if let activity { ProcessInfo.processInfo.endActivity(activity); Work.jobEnded() }
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
        if let remoteLabel { return remoteLabel }
        return archive.map { "in " + Format.path($0.deletingLastPathComponent()) } ?? ""
    }

    var archiveKindText: String {
        let name = SplitParts.wholeName(archive?.lastPathComponent ?? "").lowercased()
        let kind: String
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { kind = "gzip" }
        else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { kind = "xz" }
        else if name.hasSuffix(".tar.zst") || name.hasSuffix(".tzst") { kind = "zstd" }
        else if name.hasSuffix(".gz") { kind = "gzip" }
        else if name.hasSuffix(".xz") { kind = "xz" }
        else if name.hasSuffix(".zst") { kind = "zstd" }
        else { kind = "tar" }
        return "\(Format.bytes(archiveSize)) · \(kind)" + (partCount > 1 ? " · in \(partCount) parts" : "")
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
        case .gzip, .zstd, .xz: return seen.parallel ? "Intact · unpacks on every core" : "Intact: it all decompresses"
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
        if isPaused { return pausedText }
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
