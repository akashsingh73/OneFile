import AppKit
import SwiftUI

/// Drives: what each connected drive is and can do (a speed test for many files), and tools for
/// them (deleting a folder of many files fast, emptying a drive's Trash).
@MainActor
final class DrivesModel: ObservableObject {
    static let shared = DrivesModel()

    @Published private(set) var drives: [Drive] = []
    @Published var selectedID: String?
    @Published private(set) var free: [String: Int64] = [:]

    // Speed test
    @Published private(set) var testing: String?
    @Published private(set) var testProgress = SpeedTest.Progress()
    /// Results this session, by drive (mount path).
    @Published private(set) var results: [String: SpeedTest.Result] = [:]
    @Published private(set) var testFailure: String?
    private var test: SpeedTest?

    // Deleting
    enum DeleteStage {
        case none
        case counting(URL)
        case confirm(URL, Deleter.Count, keepFolder: Bool)
        case deleting(URL)
        case done(Deleter.Summary)
        case stopped(Int64)
        case failed(String)
    }

    @Published private(set) var deleteStage: DeleteStage = .none
    @Published private(set) var deleteProgress = Deleter.Progress()
    @Published var showingDeleteProblems = false
    private var deleter: Deleter?
    private var countFlag: StopFlag?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var watchers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            watchers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DrivesModel.shared.refresh() }
            })
        }
    }

    func refresh() {
        drives = Drive.mounted()
        var free: [String: Int64] = [:]
        for drive in drives { free[drive.mountPath] = drive.free }
        self.free = free
        if selectedID == nil || !drives.contains(where: { $0.id == selectedID }) {
            selectedID = drives.first { !$0.isStartup }?.id ?? drives.first?.id
        }
    }

    var selected: Drive? { drives.first { $0.id == selectedID } }

    var isBusy: Bool {
        if testing != nil { return true }
        switch deleteStage {
        case .counting, .deleting: return true
        default: return false
        }
    }

    // MARK: Speed test

    func testSpeed() {
        guard let drive = selected, testing == nil else { return }
        testFailure = nil
        let test = SpeedTest(place: SpeedTest.place(for: drive))
        self.test = test
        testing = drive.id
        testProgress = SpeedTest.Progress()
        startTicking()
        let id = drive.id
        test.start { outcome in
            onMain { DrivesModel.shared.tested(id, outcome) }
        }
    }

    func stopTest() {
        test?.cancel()
    }

    private func tested(_ id: String, _ outcome: SpeedTest.Outcome) {
        test = nil
        testing = nil
        stopTicking()
        switch outcome {
        case .finished(let result): results[id] = result
        case .stopped: break
        case .failed(let message): testFailure = message
        }
        refresh()
    }

    // MARK: Deleting

    /// Picks a folder to delete for good (counted, then asked about).
    func chooseFolderToDelete() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Delete a Folder for Good"
        panel.message = "Choose a folder of many files to delete: an old node_modules, a cache, a backup. Next, OneFile counts it and asks."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = selected.map { URL(fileURLWithPath: $0.isStartup ? NSHomeDirectory() : $0.mountPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareDelete(url, keepFolder: false)
    }

    /// The Trash for the selected drive: yours on the Mac's own disk, the drive's own on another.
    var trashFolder: URL? {
        guard let drive = selected else { return nil }
        if drive.isStartup { return URL(fileURLWithPath: NSHomeDirectory() + "/.Trash") }
        let url = URL(fileURLWithPath: drive.mountPath + "/.Trashes/\(getuid())")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func emptyTrash() {
        guard let trash = trashFolder, !isBusy else { return }
        prepareDelete(trash, keepFolder: true)
    }

    private func prepareDelete(_ url: URL, keepFolder: Bool) {
        if !keepFolder, let refusal = Deleter.refusal(url) {
            deleteStage = .failed(refusal)
            return
        }
        deleteStage = .counting(url)
        let flag = StopFlag()
        countFlag = flag
        DispatchQueue.global(qos: .userInitiated).async {
            let count = Deleter.count(url, stopped: { flag.isSet })
            onMain {
                let model = DrivesModel.shared
                guard model.countFlag === flag, let count else { return }
                if count.items == 0 && keepFolder {
                    model.deleteStage = .failed("The Trash on “\(model.selected?.name ?? "this drive")” is already empty.")
                } else {
                    model.deleteStage = .confirm(url, count, keepFolder: keepFolder)
                }
            }
        }
    }

    func cancelDelete() {
        countFlag?.set()
        deleter?.cancel()
        if case .confirm = deleteStage { deleteStage = .none }
        if case .counting = deleteStage { deleteStage = .none }
    }

    /// Deletes for good, after the person said so.
    func confirmDelete() {
        guard case .confirm(let url, let count, let keepFolder) = deleteStage else { return }
        confirmedCount = count.items
        let deleter = Deleter(folder: url, keepFolder: keepFolder)
        self.deleter = deleter
        deleteProgress = deleter.progress()
        deleteStage = .deleting(url)
        Work.jobStarted()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Deleting a folder")
        startTicking()
        AppModel.shared.activityChanged()
        deleter.start { outcome in
            onMain { DrivesModel.shared.deleted(outcome) }
        }
    }

    private func deleted(_ outcome: Deleter.Outcome) {
        if let deleter { deleteProgress = deleter.progress() }
        deleter = nil
        stopTicking()
        if let activity { ProcessInfo.processInfo.endActivity(activity); Work.jobEnded() }
        activity = nil
        switch outcome {
        case .finished(let summary): deleteStage = .done(summary)
        case .stopped(let count): deleteStage = .stopped(count)
        case .failed(let message): deleteStage = .failed(message)
        }
        AppModel.shared.activityChanged()
        refresh()
    }

    func doneDeleting() {
        deleteStage = .none
    }

    var deleteFraction: Double? {
        guard case .deleting = deleteStage, let total = confirmedCount, total > 0 else { return nil }
        return min(1, Double(deleteProgress.deleted) / Double(total))
    }

    private var confirmedCount: Int64?

    // MARK: Ticking

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { DrivesModel.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        guard testing == nil, deleter == nil else { return }
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let test { testProgress = test.progress() }
        if let deleter { deleteProgress = deleter.progress() }
    }

    /// "Each small file takes at least 128 KB": what the drive's blocks mean for small files.
    func blockText(_ drive: Drive) -> String {
        "Hands out room \(Format.block(drive.blockSize)) at a time" + (drive.blockSize >= 64 << 10 ? ": a 2 KB file takes \(Format.block(drive.blockSize))" : "")
    }
}
