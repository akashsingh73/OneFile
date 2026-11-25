import Foundation
import DiskArbitration
import IOKit

/// A folder backed up to a drive when the drive is plugged in. A backup is a copy kept up to date
/// the way Copy updates one: only what's new or changed is copied, and nothing on the drive is
/// deleted (what the original no longer has stays in the backup).
struct BackupRule: Codable, Identifiable, Sendable, Equatable {
    enum Every: String, Codable, Sendable, CaseIterable, Identifiable {
        case plugIn, day, week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plugIn: "Every time it's plugged in"
            case .day: "Once a day"
            case .week: "Once a week"
            }
        }

        /// How long after one backup the next is due (a little under a day or a week, so a drive
        /// plugged in at about the same time each day isn't missed by minutes).
        var interval: TimeInterval? {
            switch self {
            case .plugIn: nil
            case .day: 20 * 3_600
            case .week: 6.5 * 86_400
            }
        }
    }

    var id = UUID()
    /// The folder backed up.
    var source: String
    /// The drive it goes to: its volume UUID, and its name when the backup was set up (to show
    /// while it isn't plugged in).
    var driveID: String
    var driveName: String
    /// The folder on the drive the backup goes in, from the drive's top ("" for the top itself).
    var folder: String
    var leaveOut = ".DS_Store"
    var gitIgnore = false
    var verify = false
    var every = Every.plugIn
    var enabled = true

    // How the last one went.
    var lastRun: Date?
    var lastResult: String?
    var lastFailed = false
    /// Which plugging-in of the drive the last backup was for (see `BackupDrive.plugIn`): "every
    /// time it's plugged in" runs once each time, however many other drives come and go meanwhile.
    var lastPlugIn: String?

    var sourceName: String { (source as NSString).lastPathComponent }

    /// "Backups/Documents" on the drive.
    var placeText: String { folder.isEmpty ? sourceName : folder + "/" + sourceName }
}

/// A drive plugged in now, as backups know drives.
struct BackupDrive: Sendable, Equatable {
    let mountPath: String
    let name: String
    /// Its volume UUID (exFAT and FAT drives have one too, made from their serial number).
    let id: String
    /// Different each time it's plugged in: when the Mac started up, and the number macOS gave the
    /// drive's volume when it appeared (a new one each time). Nil for a network drive.
    let plugIn: String?
}

/// The backups set up on this Mac, kept in a file the app and the onefile command share.
enum BackupStore {
    /// ~/Library/Application Support/OneFile (ONEFILE_SUPPORT_FOLDER for the tests).
    static var folder: URL {
        if let given = ProcessInfo.processInfo.environment["ONEFILE_SUPPORT_FOLDER"] {
            return URL(fileURLWithPath: given)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OneFile")
    }

    static var file: URL { folder.appendingPathComponent("Backups.json") }

    static func load() -> [BackupRule] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BackupRule].self, from: data)) ?? []
    }

    /// Changes the backups and saves them, under a lock: the app and a backup running in the
    /// background may both be changing them. Returns them as they are after.
    @discardableResult
    static func change(_ body: (inout [BackupRule]) -> Void) -> [BackupRule] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent("Backups.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        var rules = load()
        body(&rules)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(rules) { try? data.write(to: file, options: .atomic) }
        return rules
    }
}

/// A lock held while something runs: a file lock, so it's let go when the process ends, however
/// it ends.
final class FileLock: @unchecked Sendable {
    private let fd: Int32

    /// Nil if someone else holds it.
    init?(_ name: String) {
        try? FileManager.default.createDirectory(at: BackupStore.folder, withIntermediateDirectories: true)
        let fd = open(BackupStore.folder.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Whether someone holds it now.
    static func isHeld(_ name: String) -> Bool { FileLock(name) == nil }
}

enum Backups {
    /// Held by the app while it runs: then the app backs drives up as they're plugged in, and the
    /// background backup leaves them to it.
    static let appLockName = "App.lock"

    static func lockName(_ rule: BackupRule) -> String { "Backup-\(rule.id.uuidString).lock" }

    // MARK: Drives

    /// The drives plugged in now that a backup could go to (not the startup disk or its system
    /// volumes), hidden ones included.
    static func drives() -> [BackupDrive] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: []) ?? []
        return urls.compactMap { url in
            let path = url.path
            guard path != "/", !path.hasPrefix("/System/Volumes/"), !path.hasPrefix("/private/var/vm"),
                  !path.hasPrefix("/dev") else { return nil }
            return drive(at: path)
        }
    }

    /// The drive mounted at `mountPath`, as backups know it.
    static func drive(at mountPath: String) -> BackupDrive? {
        let url = URL(fileURLWithPath: mountPath)
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
        var id: String?
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
           let description = DADiskCopyDescription(disk) as? [String: Any],
           let raw = description[kDADiskDescriptionVolumeUUIDKey as String] {
            let object = raw as CFTypeRef
            if CFGetTypeID(object) == CFUUIDGetTypeID() {
                id = CFUUIDCreateString(kCFAllocatorDefault, unsafeDowncast(object, to: CFUUID.self)) as String
            }
        }
        if id == nil { id = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
        // A network drive may have no UUID: it's known by its name.
        return BackupDrive(mountPath: mountPath, name: name, id: id ?? "name:" + name, plugIn: plugIn(mountPath))
    }

    /// What tells this plugging-in of the drive from the last: its volume's I/O Registry number is
    /// new each time it appears; with the time the Mac started up, it's never the same twice.
    static func plugIn(_ mountPath: String) -> String? {
        var info = statfs()
        guard statfs(mountPath, &info) == 0 else { return nil }
        let from = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard from.hasPrefix("/dev/") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, String(from.dropFirst(5))))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var entry: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entry) == KERN_SUCCESS else { return nil }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return "\(boot.tv_sec)-\(entry)"
    }

    // MARK: What's due

    /// The backups to run now: each one that's on, whose drive is plugged in, and that hasn't run
    /// since the drive was plugged in (every time) or for about a day or a week.
    static func due(_ rules: [BackupRule], drives: [BackupDrive], now: Date = Date()) -> [(rule: BackupRule, drive: BackupDrive)] {
        rules.compactMap { rule in
            guard rule.enabled, let drive = drives.first(where: { $0.id == rule.driveID }) else { return nil }
            if let interval = rule.every.interval {
                if let last = rule.lastRun, now.timeIntervalSince(last) < interval { return nil }
            } else if let plugIn = drive.plugIn {
                if rule.lastPlugIn == plugIn { return nil }
            } else if let last = rule.lastRun, now.timeIntervalSince(last) < 3_600 {
                // A network drive, which isn't plugged in as such: at most once an hour.
                return nil
            }
            return (rule, drive)
        }
    }

    /// Makes a backup of `source` to the folder `destination` on a drive (one plugged in now).
    static func rule(backingUp source: URL, to destination: URL) -> Result<BackupRule, Packer.PackError> {
        // The folder is made at the first backup. Until then its nearest folder that's there says
        // which drive it's on, and whether it can be written to.
        var existing = destination.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let existingPath = Copier.realPath(existing.path)
        guard let mounted = Drive.of(existingPath) else {
            return .failure(Packer.PackError(message: "Couldn't find the drive “\(destination.lastPathComponent)” is on."))
        }
        guard !mounted.isStartup else {
            return .failure(Packer.PackError(message: "That's on the Mac's own disk. Pick a folder on the drive the backup goes to."))
        }
        if let problem = Copier.problem(copying: source, into: URL(fileURLWithPath: existingPath)) {
            return .failure(Packer.PackError(message: problem))
        }
        let destinationPath = ([existingPath] + rest).joined(separator: "/")
        let from = Copier.realPath(source.path)
        if destinationPath == from || destinationPath.hasPrefix(from + "/") {
            return .failure(Packer.PackError(message: "That's inside the folder being backed up. Pick a place outside it."))
        }
        guard let drive = drive(at: mounted.mountPath) else {
            return .failure(Packer.PackError(message: "Couldn't tell which drive “\(mounted.name)” is."))
        }
        let top = Copier.realPath(mounted.mountPath)
        let folder = destinationPath == top ? "" : String(destinationPath.dropFirst(top.count + 1))
        return .success(BackupRule(source: from, driveID: drive.id, driveName: mounted.name, folder: folder))
    }

    // MARK: Running one

    /// The copier for a backup, ready to start; or why it can't run (the folder's gone, say).
    static func copier(for rule: BackupRule, on drive: BackupDrive) -> Result<Copier, Packer.PackError> {
        let source = URL(fileURLWithPath: rule.source)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rule.source, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(Packer.PackError(message: "“\(rule.sourceName)” isn't where it was (\(rule.source))."))
        }
        let into = URL(fileURLWithPath: drive.mountPath).appendingPathComponent(rule.folder)
        do {
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        } catch {
            return .failure(Packer.PackError(message: "Couldn't make the folder “\(rule.folder)” on “\(drive.name)”."))
        }
        if let problem = Copier.problem(copying: source, into: into) { return .failure(Packer.PackError(message: problem)) }
        var options = Copier.Options(leaveOut: WalkRules.parse(rule.leaveOut))
        options.verify = rule.verify
        if rule.gitIgnore { options.excluded = Set(GitIgnore.ignored(in: rule.source) ?? []) }
        let target: Copier.Target
        if case .folder(let existing) = Copier.existing(for: source, name: source.lastPathComponent, in: into) {
            target = .update(existing)
        } else {
            target = .new(folder: into, name: source.lastPathComponent)
        }
        return .success(Copier(source: source, target: target, options: options))
    }

    /// Notes how a backup went, in the backups file.
    static func record(_ rule: BackupRule, on drive: BackupDrive, _ outcome: Copier.Outcome, at date: Date = Date()) {
        let (text, failed) = describe(outcome)
        BackupStore.change { rules in
            guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index].lastRun = date
            rules[index].lastResult = text
            rules[index].lastFailed = failed
            rules[index].lastPlugIn = drive.plugIn
        }
    }

    /// A backup that couldn't start: noted once for this plug-in, not again at every check.
    static func record(_ rule: BackupRule, on drive: BackupDrive, failure: String, at date: Date = Date()) {
        BackupStore.change { rules in
            guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index].lastRun = date
            rules[index].lastResult = failure
            rules[index].lastFailed = true
            rules[index].lastPlugIn = drive.plugIn
        }
    }

    /// How a backup went, in a sentence, and whether it failed.
    static func describe(_ outcome: Copier.Outcome) -> (String, Bool) {
        switch outcome {
        case .finished(let summary):
            var text: String
            if summary.files == 0 {
                text = "Up to date: nothing new or changed"
                if summary.unchanged > 0 { text += " (\(Format.count(summary.unchanged)) files)" }
            } else {
                text = "Copied \(Format.count(summary.files)) \(summary.files == 1 ? "file" : "files") (\(Format.bytes(summary.bytes)))"
                if summary.unchanged > 0 { text += "; \(Format.count(summary.unchanged)) were there already" }
            }
            if summary.problemCount > 0 { text += "; \(Format.count(Int64(summary.problemCount))) couldn't be copied" }
            if summary.mismatched > 0 { text += "; \(Format.count(summary.mismatched)) didn't match when read back" }
            return (text + ".", summary.problemCount > 0 || summary.mismatched > 0)
        case .stopped:
            return ("Stopped before it was done: the next backup picks up there.", true)
        case .failed(let message, _):
            return (message, true)
        }
    }

    /// Runs a backup to the end, here (for the onefile command and the tests): nil if it's
    /// running already, elsewhere.
    static func runHere(_ rule: BackupRule, on drive: BackupDrive, progress: ((Copier) -> Void)? = nil) -> Copier.Outcome? {
        guard let lock = FileLock(lockName(rule)) else { return nil }
        defer { withExtendedLifetime(lock) {} }
        let copier: Copier
        switch Backups.copier(for: rule, on: drive) {
        case .success(let made): copier = made
        case .failure(let error):
            record(rule, on: drive, failure: error.message)
            return .failed(error.message, nil)
        }
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Copier.Outcome?>(nil)
        copier.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        progress?(copier)
        done.wait()
        let outcome = result.withLock { $0 }!
        record(rule, on: drive, outcome)
        return outcome
    }
}

/// Backing up when OneFile isn't open: a launchd agent that runs `onefile backup --due` whenever a
/// drive is mounted (and every hour, for daily and weekly backups to a drive that stays plugged in).
enum BackupAgent {
    static let label = "local.onefile.backups"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OneFile/Backups.log")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The onefile command the agent runs, if it's installed.
    static var installedCommand: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    static func plist(command: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [command, "backup", "--due"],
            "StartOnMount": true,
            "StartInterval": 3_600,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
    }

    /// Installs (or moves) the agent to run `command`. Nil if it went well, or what went wrong.
    static func install(command: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(command: command), format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return "Couldn't set it up: \(error.localizedDescription)"
        }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let loaded = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return loaded == 0 ? nil : "macOS didn't start it (launchctl said \(loaded)). It starts when you next log in."
    }

    static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
