import AppKit
import SwiftUI

/// Backups to drives: set up per drive (in Drives), run when the drive is plugged in. While the app
/// is open it runs them itself, with progress; when it isn't, the background agent does (if it's
/// on, in Settings), and the app shows how they went.
@MainActor
final class BackupsModel: ObservableObject {
    static let shared = BackupsModel()

    @Published private(set) var rules: [BackupRule] = []
    /// The drives plugged in now.
    @Published private(set) var drives: [BackupDrive] = []
    /// The backup running here, and how far it's got.
    @Published private(set) var running: UUID?
    @Published private(set) var progress = Copier.Progress()
    @Published private(set) var isPaused = false
    /// Backups running in the background agent (it started before the app opened).
    @Published private(set) var elsewhere: Set<UUID> = []
    @Published private(set) var background = BackupAgent.isInstalled
    @Published var problem: String?

    private var copier: Copier?
    private var ruleLock: FileLock?
    private var appLock: FileLock?
    private var queue: [UUID] = []
    private var pausedForBattery = false
    private var ticker: Timer?
    private var hourly: Timer?
    private var activity: NSObjectProtocol?
    private var watchers: [NSObjectProtocol] = []

    var isRunning: Bool { running != nil }

    /// Called once, when the app starts.
    func start() {
        appLock = FileLock(Backups.appLockName)
        repairAgent()
        let workspace = NSWorkspace.shared.notificationCenter
        watchers.append(workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            // A moment for Disk Arbitration to describe the new drive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { BackupsModel.shared.runDue() }
            }
        })
        watchers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackupsModel.shared.reload() }
        })
        watchers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackupsModel.shared.reload() }
        })
        // Daily and weekly backups to a drive that stays plugged in.
        let hourly = Timer(timeInterval: 3_600, repeats: true) { _ in
            MainActor.assumeIsolated { BackupsModel.shared.runDue() }
        }
        RunLoop.main.add(hourly, forMode: .common)
        self.hourly = hourly
        // Drives plugged in while the app was closed (and the agent off) are backed up now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { BackupsModel.shared.runDue() }
        }
        reload()
    }

    /// The backups as they are on the disk (the agent may have run some), and the drives now.
    func reload() {
        rules = BackupStore.load()
        drives = Backups.drives()
        elsewhere = Set(rules.filter { $0.id != running && FileLock.isHeld(Backups.lockName($0)) }.map(\.id))
        if !elsewhere.isEmpty { startTicking() }
    }

    func rules(for drive: Drive) -> [BackupRule] {
        guard let id = drives.first(where: { $0.mountPath == drive.mountPath })?.id else { return [] }
        return rules.filter { $0.driveID == id }
    }

    func isPluggedIn(_ rule: BackupRule) -> Bool { drives.contains { $0.id == rule.driveID } }

    // MARK: Running

    func runDue() {
        reload()
        for (rule, _) in Backups.due(rules, drives: drives) where rule.id != running && !queue.contains(rule.id) {
            queue.append(rule.id)
        }
        next()
    }

    func backUpNow(_ rule: BackupRule) {
        problem = nil
        if rule.id != running && !queue.contains(rule.id) { queue.append(rule.id) }
        next()
    }

    func stop() {
        queue.removeAll()
        copier?.cancel()
    }

    func stopForQuit() { stop() }

    private func next() {
        guard running == nil else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let rule = rules.first(where: { $0.id == id }),
                  let drive = drives.first(where: { $0.id == rule.driveID }) else { continue }
            // Running in the background already.
            guard let lock = FileLock(Backups.lockName(rule)) else { continue }
            switch Backups.copier(for: rule, on: drive) {
            case .failure(let error):
                Backups.record(rule, on: drive, failure: error.message)
                continue
            case .success(let copier):
                ruleLock = lock
                self.copier = copier
                running = id
                progress = copier.progress()
                isPaused = false
                Work.jobStarted()
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Backing up a folder")
                startTicking()
                AppModel.shared.activityChanged()
                if Work.pauseOnBattery && PowerWatcher.shared.onBattery { pauseForBattery() }
                copier.start { outcome in
                    onMain { BackupsModel.shared.finished(rule, drive, outcome) }
                }
                return
            }
        }
        reload()
    }

    private func finished(_ rule: BackupRule, _ drive: BackupDrive, _ outcome: Copier.Outcome) {
        if let copier { progress = copier.progress() }
        Backups.record(rule, on: drive, outcome)
        copier = nil
        ruleLock = nil
        running = nil
        isPaused = false
        pausedForBattery = false
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            Work.jobEnded()
        }
        activity = nil
        AppModel.shared.activityChanged()
        reload()
        next()
    }

    var fraction: Double? {
        guard let totals = progress.totals, totals.bytes + totals.files > 0 else { return nil }
        let whole = Double(totals.bytes) + Double(totals.files) * 64_000
        let done = Double(progress.bytes + progress.unchangedBytes) + Double(progress.files + progress.unchanged) * 64_000
        return min(1, done / whole)
    }

    var progressText: String {
        if progress.verifying { return "Checking on the drive: \(Format.count(progress.verified)) of \(Format.count(progress.toVerify))" }
        if progress.saving { return "Making sure it's all on the drive…" }
        if progress.finishing { return "Finishing…" }
        let done = progress.files + progress.unchanged
        let of = progress.totals.map { " of \(Format.count($0.files))" } ?? ""
        return "\(Format.count(done))\(of) files looked at, \(Format.count(progress.files)) copied"
    }

    // MARK: Pausing

    func pause() {
        guard let copier, !isPaused else { return }
        copier.pause()
        isPaused = true
    }

    func resume() {
        guard let copier, isPaused else { return }
        copier.resume()
        isPaused = false
        pausedForBattery = false
    }

    func pauseForBattery() {
        guard !isPaused, copier != nil else { return }
        pause()
        pausedForBattery = true
    }

    func resumeAfterBattery() {
        guard pausedForBattery else { return }
        resume()
    }

    // MARK: Setting up

    /// Picks a folder to back up to `drive`, into a folder called Backups at its top.
    func add(to drive: Drive) {
        problem = nil
        let panel = NSOpenPanel()
        panel.title = "Back Up a Folder to “\(drive.name)”"
        panel.message = "Choose a folder. Each time “\(drive.name)” is plugged in, what's new or changed in it is copied to Backups on the drive."
        panel.prompt = "Back Up"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let destination = URL(fileURLWithPath: drive.mountPath).appendingPathComponent("Backups")
        switch Backups.rule(backingUp: source, to: destination) {
        case .success(let rule):
            if rules.contains(where: { $0.source == rule.source && $0.driveID == rule.driveID }) {
                problem = "“\(rule.sourceName)” is backed up to “\(drive.name)” already."
                return
            }
            BackupStore.change { $0.append(rule) }
            reload()
            backUpNow(rule)
        case .failure(let error):
            problem = error.message
        }
    }

    /// Picks another folder on the drive for a backup to go in.
    func chooseFolder(for rule: BackupRule) {
        guard let drive = drives.first(where: { $0.id == rule.driveID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Where “\(rule.sourceName)” Is Backed Up"
        panel.message = "Choose a folder on “\(drive.name)”. The backup goes inside it, as “\(rule.sourceName)”."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: drive.mountPath).appendingPathComponent(rule.folder)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        switch Backups.rule(backingUp: URL(fileURLWithPath: rule.source), to: folder) {
        case .success(let made):
            guard made.driveID == rule.driveID else {
                problem = "That's on another drive. To back up there, add the folder in that drive's Backups."
                return
            }
            update(rule) { $0.folder = made.folder }
        case .failure(let error):
            problem = error.message
        }
    }

    func update(_ rule: BackupRule, _ change: @escaping (inout BackupRule) -> Void) {
        BackupStore.change { rules in
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { change(&rules[index]) }
        }
        reload()
    }

    func remove(_ rule: BackupRule) {
        queue.removeAll { $0 == rule.id }
        if running == rule.id { copier?.cancel() }
        BackupStore.change { $0.removeAll { $0.id == rule.id } }
        reload()
    }

    /// The backup's folder on the drive, in Finder.
    func reveal(_ rule: BackupRule) {
        guard let drive = drives.first(where: { $0.id == rule.driveID }) else { return }
        let url = URL(fileURLWithPath: drive.mountPath).appendingPathComponent(rule.folder).appendingPathComponent(rule.sourceName)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    // MARK: In the background

    /// Turns the background agent on (it runs the onefile command inside the app) or off.
    func setBackground(_ on: Bool) {
        problem = nil
        if on {
            guard let command = SettingsModel.shared.commandPath else {
                problem = "This copy of OneFile has no onefile command inside: build it with build.sh."
                return
            }
            if let failure = BackupAgent.install(command: command) { problem = failure }
        } else {
            BackupAgent.uninstall()
        }
        background = BackupAgent.isInstalled
    }

    /// The app moved (or was updated in another place): the agent follows it.
    private func repairAgent() {
        guard BackupAgent.isInstalled, let command = SettingsModel.shared.commandPath,
              BackupAgent.installedCommand != command else { return }
        _ = BackupAgent.install(command: command)
    }

    // MARK: Ticking

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { BackupsModel.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private var tickCount = 0

    private func tick() {
        if let copier { progress = copier.progress() }
        tickCount += 1
        // A backup running in the background: look every few seconds for whether it's done.
        if !elsewhere.isEmpty && tickCount % 12 == 0 {
            let still = Set(elsewhere.filter { id in rules.first { $0.id == id }.map { FileLock.isHeld(Backups.lockName($0)) } ?? false })
            if still != elsewhere { reload() }
        }
        if copier == nil && elsewhere.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: Words

    /// "Today at 10:02", "Yesterday at 18:40", "3 Nov at 09:15".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " at \(time)"
    }
}
