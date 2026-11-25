import AppKit
import Combine
import SwiftUI

/// Copy: the folder (shared with Pack and Send) to a folder on another drive, many files at once.
@MainActor
final class CopyModel: ObservableObject {
    static let shared = CopyModel()

    enum Stage {
        case ready
        case copying
        case finished(Copier.Summary)
        /// Why, and what was copied so far (to pick up later).
        case failed(String, URL?)
        case stopped(URL?)
    }

    /// The folder the copy goes in.
    @Published private(set) var destination: URL?
    @Published private(set) var destinationDrive: Drive?
    /// Free space where the copy goes (asking takes a moment on APFS, so it's kept).
    @Published private(set) var destinationFree: Int64?
    /// The cloud service that syncs the destination, if one does (Google Drive, iCloud Drive…).
    @Published private(set) var cloudService: String?
    @Published private(set) var sourceDrive: Drive?
    /// The drives connected now, for picking one.
    @Published private(set) var drives: [Drive] = []
    /// What's at the destination already by the folder's name.
    @Published private(set) var existing: Copier.Existing = .nothing
    /// With a folder of that name there: make a new copy beside it, rather than update it.
    @Published var makeNewCopy = false
    @Published private(set) var stage: Stage = .ready
    @Published private(set) var progress = Copier.Progress()
    @Published private(set) var meter = RateMeter()
    @Published var showingProblems = false
    @Published private(set) var ejecting = false
    @Published private(set) var ejectMessage: String?
    /// Read each copied file back from the drive, and check it against the original.
    @Published var verify: Bool {
        didSet { UserDefaults.standard.set(verify, forKey: "copyVerify") }
    }
    /// Updating a copy: offer to move to the Trash what the original no longer has.
    @Published var mirror: Bool {
        didSet { UserDefaults.standard.set(mirror, forKey: "copyMirror") }
    }
    @Published var showingExtras = false
    @Published private(set) var trashing = false
    @Published private(set) var trashMessage: String?

    private var copier: Copier?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var watchers: [NSObjectProtocol] = []
    private var sourceWatch: AnyCancellable?

    private static let destinationKey = "copyDestination"

    init() {
        verify = UserDefaults.standard.bool(forKey: "copyVerify")
        mirror = UserDefaults.standard.bool(forKey: "copyMirror")
        if let saved = UserDefaults.standard.string(forKey: Self.destinationKey),
           FileManager.default.fileExists(atPath: saved) {
            destination = URL(fileURLWithPath: saved)
        }
        refreshDrives()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            watchers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CopyModel.shared.drivesChanged() }
            })
        }
        sourceWatch = PackModel.shared.$source.sink { source in
            // (Called before the source changes: look at the new one.)
            onMain { CopyModel.shared.sourceChanged(source) }
        }
    }

    var source: URL? { PackModel.shared.source }

    var isCopying: Bool {
        if case .copying = stage { return true }
        return false
    }

    // MARK: Where it goes

    func chooseDestination() {
        guard !isCopying else { return }
        let panel = NSOpenPanel()
        panel.title = "Copy Into"
        panel.prompt = "Copy Here"
        panel.message = "Choose a folder to copy into: on another drive, say."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination ?? drives.first { !$0.isStartup }.map { URL(fileURLWithPath: $0.mountPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestination(url)
    }

    /// A drive picked from the list: its top folder (the Desktop, for the Mac's own disk).
    func choose(_ drive: Drive) {
        if drive.isStartup {
            setDestination(FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                           ?? URL(fileURLWithPath: NSHomeDirectory()))
        } else {
            setDestination(URL(fileURLWithPath: drive.mountPath))
        }
    }

    func setDestination(_ url: URL) {
        guard !isCopying else { return }
        destination = url.standardizedFileURL
        UserDefaults.standard.set(destination?.path, forKey: Self.destinationKey)
        stage = .ready
        refresh()
    }

    private func sourceChanged(_ source: URL?) {
        guard !isCopying else { return }
        if case .finished = stage { stage = .ready }
        sourceDrive = source.flatMap { Drive.of($0.path) }
        refresh()
    }

    private func drivesChanged() {
        refreshDrives()
        // The destination's drive went away.
        if let destination, !FileManager.default.fileExists(atPath: destination.path), !isCopying {
            self.destination = nil
            destinationDrive = nil
        }
        refresh()
    }

    private func refreshDrives() {
        drives = Drive.mounted()
    }

    /// Looks again at both drives, and at what's at the destination already.
    func refresh() {
        guard !isCopying else { return }
        sourceDrive = source.flatMap { Drive.of($0.path) }
        destinationDrive = destination.flatMap { Drive.of($0.path) }
        destinationFree = destinationDrive?.free
        cloudService = destination.flatMap { CloudSync.service(for: $0.path) }
        if let source, let destination {
            existing = Copier.existing(for: source, name: source.lastPathComponent, in: destination)
        } else {
            existing = .nothing
        }
    }

    // MARK: Copying

    var plan: CopyPlan { CopyPlan(from: sourceDrive, to: destinationDrive) }

    /// Where the copy will go: new, picked up, or updating one that's there.
    var target: Copier.Target? {
        guard let source, let destination else { return nil }
        switch existing {
        case .folder(let url) where !makeNewCopy: return .update(url)
        default: return .new(folder: destination, name: source.lastPathComponent)
        }
    }

    /// Why it can't be copied there, if it can't.
    var blocker: String? {
        guard let source, let destination else { return nil }
        if let problem = Copier.problem(copying: source, into: destination) { return problem }
        if case .folder(let url) = existing, !makeNewCopy, Copier.realPath(url.path) == Copier.realPath(source.path) {
            return "That's the folder itself. Pick another place."
        }
        return nil
    }

    var canCopy: Bool {
        source != nil && destination != nil && blocker == nil && !isCopying && !PackModel.shared.isLocked
            && !PackModel.shared.countFailed && roomWarning?.stops != true
    }

    func copy() {
        guard canCopy, let source, let target else { return }
        let pack = PackModel.shared
        var options = Copier.Options(leaveOut: WalkRules.parse(pack.leaveOut), skipRebuildable: pack.skipRebuildable,
                                     excluded: pack.excludedPaths)
        options.verify = verify
        if case .update = target { options.mirror = mirror }
        trashMessage = nil
        let copier = Copier(source: source, target: target, options: options, knownTotals: pack.knownTotals)
        self.copier = copier
        progress = copier.progress()
        meter.reset()
        ejectMessage = nil
        stage = .copying
        pack.objectWillChange.send()
        Work.jobStarted()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Copying a folder")
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { CopyModel.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        AppModel.shared.activityChanged()
        copier.start { outcome in
            onMain { CopyModel.shared.finish(outcome) }
        }
    }

    func stop() {
        copier?.cancel()
    }

    /// Quitting: stops. What's copied stays, to pick up next time.
    func stopForQuit() {
        copier?.cancel()
    }

    // MARK: Pausing

    @Published private(set) var isPaused = false
    /// Paused because the Mac went onto its battery: it carries on when it's back on power.
    private(set) var pausedForBattery = false

    func togglePause() {
        guard let copier else { return }
        if isPaused {
            copier.resume()
            isPaused = false
            pausedForBattery = false
        } else {
            copier.pause()
            isPaused = true
        }
    }

    func pauseForBattery() {
        guard let copier, !isPaused else { return }
        copier.pause()
        isPaused = true
        pausedForBattery = true
    }

    func resumeAfterBattery() {
        guard let copier, pausedForBattery else { return }
        copier.resume()
        isPaused = false
        pausedForBattery = false
    }

    var pausedText: String {
        pausedForBattery ? "Paused while the Mac is on its battery" : "Paused"
    }


    private func tick() {
        guard let copier else { return }
        progress = copier.progress()
        meter.add(bytes: progress.bytes, files: progress.files)
    }

    private func finish(_ outcome: Copier.Outcome) {
        timer?.invalidate()
        timer = nil
        if let copier { progress = copier.progress() }
        copier = nil
        isPaused = false
        pausedForBattery = false
        if let activity { ProcessInfo.processInfo.endActivity(activity); Work.jobEnded() }
        activity = nil
        switch outcome {
        case .finished(let summary): stage = .finished(summary)
        case .stopped(let partial): stage = .stopped(partial)
        case .failed(let message, let partial): stage = .failed(message, partial)
        }
        makeNewCopy = false
        PackModel.shared.objectWillChange.send()
        AppModel.shared.activityChanged()
        refreshDrives()
        destinationDrive = destination.flatMap { Drive.of($0.path) }
        destinationFree = destinationDrive?.free
        if let source, let destination {
            existing = Copier.existing(for: source, name: source.lastPathComponent, in: destination)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Whether updating will offer to remove what the original no longer has.
    var isUpdating: Bool {
        if case .folder = existing, !makeNewCopy { return true }
        return false
    }

    /// Compares the folder with the copy that's there (or was just made).
    func compareWithCopy() {
        guard let source else { return }
        let copy: URL?
        if let summary { copy = summary.destination } else if case .folder(let url) = existing { copy = url } else { copy = nil }
        guard let copy else { return }
        CompareModel.shared.compare(source, copy)
    }

    /// Moves what the copy has and the original doesn't to the Trash (asked for, after the list).
    func trashExtras() {
        guard let summary, !trashing else { return }
        trashing = true
        let root = summary.destination
        let extras = summary.extras
        DispatchQueue.global(qos: .userInitiated).async {
            var moved = 0, failed = 0
            for extra in extras {
                do {
                    try FileManager.default.trashItem(at: root.appendingPathComponent(extra.path), resultingItemURL: nil)
                    moved += 1
                } catch {
                    failed += 1
                }
            }
            let message = failed == 0
                ? "Moved \(Format.items(Int64(moved))) to the Trash: the copy matches the original."
                : "Moved \(Format.items(Int64(moved))) to the Trash; \(Format.items(Int64(failed))) couldn't be (a network drive may have no Trash)."
            onMain {
                let model = CopyModel.shared
                model.trashing = false
                model.showingExtras = false
                model.trashMessage = message
            }
        }
    }

    /// Back to the start, ready to copy again (or update the copy).
    func done() {
        stage = .ready
        ejectMessage = nil
        refresh()
    }

    func showInFinder() {
        var shown: URL?
        switch stage {
        case .finished(let summary): shown = summary.destination
        case .stopped(let partial), .failed(_, let partial): shown = partial
        default: shown = nil
        }
        guard let shown, FileManager.default.fileExists(atPath: shown.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([shown])
    }

    func copyProblems() {
        guard case .finished(let summary) = stage else { return }
        Problems.copy(summary.problems)
    }

    /// The destination's drive can be ejected (it's not the Mac's own).
    var canEject: Bool {
        guard let drive = destinationDrive else { return false }
        return !drive.isInternal && !drive.isStartup && drive.medium != .network
    }

    func eject() {
        guard let drive = destinationDrive, canEject, !ejecting else { return }
        ejecting = true
        ejectMessage = nil
        let url = URL(fileURLWithPath: drive.mountPath)
        let name = drive.name
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                message = "“\(name)” is ejected: you can unplug it."
            } catch {
                message = "Couldn't eject “\(name)”: something is still using it."
            }
            let result = message
            onMain {
                let model = CopyModel.shared
                model.ejecting = false
                model.ejectMessage = result
            }
        }
    }

    // MARK: What the window says

    var stageKey: Int {
        switch stage {
        case .ready: 0
        case .copying: 1
        case .finished: 2
        case .failed: 3
        case .stopped: 4
        }
    }

    var summary: Copier.Summary? {
        if case .finished(let summary) = stage { return summary }
        return nil
    }

    var destinationName: String {
        guard let destination else { return "" }
        if let drive = destinationDrive, Copier.realPath(destination.path) == Copier.realPath(drive.mountPath) {
            return drive.name
        }
        return destination.lastPathComponent
    }

    /// "on “Travel SSD”", "in ~/Desktop".
    var destinationLine: String {
        guard let destination else { return "" }
        if let drive = destinationDrive, Copier.realPath(destination.path) == Copier.realPath(drive.mountPath) {
            return "at the top of the drive"
        }
        if let drive = destinationDrive, !drive.isStartup {
            return "on “\(drive.name)”"
        }
        return "in " + Format.path(destination.deletingLastPathComponent())
    }

    /// "USB SSD · exFAT".
    func driveText(_ drive: Drive?) -> String {
        guard let drive else { return "" }
        return "\(drive.kindText) · \(drive.formatName)"
    }

    /// How much room the copy needs there, and whether that's a problem.
    struct RoomWarning {
        let text: String
        /// It can't fit at all (rather than might not).
        let stops: Bool
    }

    /// The space the copy will take on the destination (whole blocks per file).
    var expectedSpace: Int64? {
        guard case .counted(let totals) = PackModel.shared.count, let drive = destinationDrive else { return nil }
        if plan.clone { return 0 }
        if let space = PackModel.shared.insights?.space(withBlocks: drive.blockSize) { return space }
        return totals.bytes + totals.files * drive.blockSize / 2
    }

    var roomWarning: RoomWarning? {
        guard summary == nil, let drive = destinationDrive, let space = expectedSpace, let free = destinationFree else { return nil }
        if drive.isFAT, let insights = PackModel.shared.insights, insights.largest >= 4 << 30 {
            return RoomWarning(text: "“\(drive.name)” is FAT32, which can't hold files of 4 GB or more, and some here are bigger.",
                               stops: false)
        }
        // Updating, only what's changed is copied: the space needed isn't known.
        if case .folder = existing, !makeNewCopy { return nil }
        if space > free {
            return RoomWarning(text: "Needs about \(Format.bytes(space)) on “\(drive.name)”, and \(Format.bytes(free)) is free.",
                               stops: true)
        }
        return nil
    }

    var roomText: String? {
        destinationFree.map { "\(Format.bytes($0)) free" }
    }

    /// Lots of small files going to a drive that's slow with them (exFAT, FAT, a hard drive, a
    /// network drive), where one packed file would go far faster and take far less room.
    struct PackHint {
        let headline: String
        let detail: String
    }

    var packHint: PackHint? {
        // Updating a copy that's there: only what changed goes, so it's quick anyway.
        if case .folder = existing, !makeNewCopy { return nil }
        guard summary == nil, !plan.clone, let drive = destinationDrive,
              case .counted(let totals) = PackModel.shared.count else { return nil }
        let packed = PackModel.shared.expectedSize(.plain) ?? totals.archiveBytes
        // A folder a cloud service syncs: each file is an upload of its own.
        if let cloudService, totals.files >= 500 {
            return PackHint(headline: "Faster as one file",
                            detail: "\(cloudService) uploads every file on its own, so these \(Format.count(totals.files)) files would be \(Format.count(totals.files)) uploads, which can take hours. As one packed file: one upload of \(Format.bytes(packed)). Unpack it on the Mac it goes to.")
        }
        guard totals.files >= 2_000 else { return nil }
        let average = totals.bytes / max(totals.files, 1)
        let slowForSmall = drive.isWindowsFormat || drive.medium == .hdd || drive.isNetwork
        guard slowForSmall, average < 512 << 10 else { return nil }
        var detail: String
        if let space = expectedSpace, drive.blockSize >= 32 << 10, space > totals.bytes * 2 {
            detail = "“\(drive.name)” gives every file at least \(Format.block(drive.blockSize)), so these \(Format.count(totals.files)) files (\(Format.bytes(totals.bytes))) would take about \(Format.bytes(space)) there. As one packed file: \(Format.bytes(packed))."
        } else {
            detail = "\(drive.formatName == "exFAT" || drive.formatName == "FAT32" ? "\(drive.formatName) drives are" : drive.medium == .hdd ? "Hard drives are" : "Network drives are") slow with many small files: \(Format.count(totals.files)) of them, \(Format.bytes(average)) on average. As one packed file they go in one long write (\(Format.bytes(packed)))."
        }
        detail += " Unpack it on the Mac it goes to."
        return PackHint(headline: "Faster as one file", detail: detail)
    }

    /// Packing instead, into the copy's destination.
    func packInstead() {
        guard let destination, !isCopying else { return }
        PackModel.shared.saveIn(destination)
        AppModel.shared.mode = .pack
    }

    /// How OneFile will copy, given the two drives.
    var planText: String {
        let plan = plan
        if plan.clone {
            return "Same drive: each file is cloned, which takes no time and no extra space until one of them changes."
        }
        var parts = ["\(plan.workers) small files at a time", "big files one after another"]
        if plan.diskOrder { parts.append("read in the order they are on the disk") }
        if plan.appleDoubleSource { parts.append("Mac details read from the drive's ._ files") }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
    }

    var copyButtonTitle: String {
        let name = destinationDrive.map { !$0.isStartup ? " to “\($0.name)”" : "" } ?? ""
        if case .folder(let url) = existing, !makeNewCopy {
            let on = destinationDrive.map { !$0.isStartup ? " on “\($0.name)”" : "" } ?? ""
            return "Update “\(url.lastPathComponent)”\(on)"
        }
        if case .stopped = existing { return "Pick Up the Copy\(name)" }
        if case .counted(let totals) = PackModel.shared.count, totals.files > 0 {
            return "Copy \(Format.count(totals.files)) \(totals.files == 1 ? "File" : "Files")\(name)"
        }
        return "Copy\(name)"
    }

    var buttonNote: String {
        switch existing {
        case .folder where !makeNewCopy:
            return "Only what's new or changed is copied. Nothing there is deleted."
        case .stopped(let url):
            return "Picks up where it stopped, in “\(url.lastPathComponent)”."
        default:
            guard let source else { return "" }
            return "Made as “\(source.lastPathComponent) (copying)”, and named “\(source.lastPathComponent)” once it's complete."
        }
    }

    // MARK: While copying

    /// Each file costs about this much time, in bytes' worth: copying many small files is about the
    /// number of files more than their size.
    private var fileWeight: Double {
        if plan.clone { return 1_048_576 }
        if let drive = destinationDrive, drive.isWindowsFormat || drive.medium == .hdd || drive.isNetwork { return 262_144 }
        return 32_768
    }

    var fraction: Double? {
        guard let totals = progress.totals else { return nil }
        let weight = fileWeight
        let whole = Double(totals.bytes) + Double(totals.files) * weight
        guard whole > 0 else { return nil }
        let done = Double(progress.bytes + progress.unchangedBytes) + Double(progress.files + progress.unchanged) * weight
        return min(1, done / whole)
    }

    var percentText: String {
        if progress.verifying, progress.toVerify > 0 {
            return (Double(progress.verified) / Double(progress.toVerify)).formatted(.percent.precision(.fractionLength(0)))
        }
        if progress.saving { return "100%" }
        guard let fraction else { return "Copying…" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var etaText: String {
        if isPaused { return pausedText }
        if progress.verifying {
            return "Checking each file on “\(destinationDrive?.name ?? "the drive")”: \(Format.count(progress.verified)) of \(Format.count(progress.toVerify))"
        }
        if progress.saving { return "Making sure it's all on “\(destinationDrive?.name ?? "the drive")”…" }
        if progress.finishing { return "Folders' dates and links…" }
        guard progress.totals != nil else { return "Counting what's left…" }
        guard let fraction, fraction > 0.02 else { return "Working out the time left…" }
        let elapsed = Date().timeIntervalSince(progress.started)
        let left = elapsed / fraction - elapsed
        return "About \(Format.duration(left)) left"
    }

    var filesDetail: String {
        var detail = progress.totals.map { "of \(Format.count($0.files))" } ?? "\(Format.count(progress.counted.files)) counted"
        if progress.unchanged > 0 { detail += ", \(Format.count(progress.unchanged)) there already" }
        return detail
    }

    var dataDetail: String {
        progress.totals.map { "of \(Format.bytes($0.bytes))" } ?? ""
    }

    /// The big file being copied, or where it's all going.
    var workLine: String {
        if let name = progress.bigName, progress.bigSize > 0 {
            let share = Double(progress.bigDone) / Double(progress.bigSize)
            return "\((name as NSString).lastPathComponent) · \(Format.bytes(progress.bigDone)) of \(Format.bytes(progress.bigSize)) (\(share.formatted(.percent.precision(.fractionLength(0)))))"
        }
        let into = destinationDrive.map { $0.isStartup ? Format.path(destination ?? URL(fileURLWithPath: "/")) : "“\($0.name)”" } ?? ""
        return "Into \(into) · \(plan.clone ? "cloning" : "\(plan.workers) at a time")"
    }

    var timeValue: String {
        Format.clock(Date().timeIntervalSince(progress.started))
    }
}
