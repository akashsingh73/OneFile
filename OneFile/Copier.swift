import Foundation
import CryptoKit

/// Copies a folder to another place, usually another drive, as fast as the two drives allow.
///
/// Finder and `cp` copy one file at a time, and each file waits for the drive twice (read, then
/// write): with many small files, the drives sit idle most of the time. OneFile copies 8 small files
/// at a time while one lane copies big files, one at a time in 8 MB pieces, reading the next piece
/// while writing the last. Measured with 20,000 small files on a USB SSD (exFAT): to the drive
/// 10.5 s (cp: 68 s), from it 1.1 s (ditto: 10 s, cp: 21 s).
///
/// Big files go one at a time because exFAT drives are very slow at growing several files at
/// once: four 64 MB files written together took 51 s, one after another under half a second.
///
/// What it keeps: contents, permissions, modification and creation dates, the hidden flag, extended
/// attributes (Finder tags and the like; on exFAT and FAT drives they're in "._" files, which are
/// read as files, much faster than asking for each attribute), hard links (where the drive can
/// hold them), symbolic links and named pipes. On one APFS drive, files are cloned instead: no
/// time, and no extra space until one of them changes.
///
/// A new copy is made as "NAME (copying)" and gets its name when it's complete. Stopped (or if a
/// drive is unplugged), that folder stays: copying again picks up where it stopped, skipping the
/// files already there (same size and date), and so does updating a copy made earlier.
final class Copier: @unchecked Sendable {
    struct Options: Sendable {
        /// Names (or patterns like `*.tmp`) of files and folders to leave out.
        var leaveOut: [String]
        /// Kinds of rebuildable folders to leave out (`Rebuildable` rule ids).
        var skipRebuildable: Set<Int16> = []
        /// Exact paths to leave out (what Git ignores, when asked).
        var excluded: Set<String> = []
        /// Once it's all on the drive, read each copied file back and check it matches the
        /// original (SHA-256, worked out while copying).
        var verify = false
        /// Updating a copy: note what's there that the original no longer has, to offer to move
        /// it to the Trash afterwards. (The copier itself never deletes anything.)
        var mirror = false
    }

    /// Something in the copy that the original no longer has.
    struct Extra: Sendable, Identifiable, Hashable {
        var id: String { path }
        let path: String
        let isFolder: Bool
        let size: Int64
    }

    enum Target: Sendable, Equatable {
        /// A new folder called `name` in `folder`.
        case new(folder: URL, name: String)
        /// A folder that's there already: what's missing or changed is copied into it. Nothing in
        /// it is deleted.
        case update(URL)
    }

    struct Progress: Sendable {
        var started = Date()
        /// Files, links and pipes copied.
        var files: Int64 = 0
        var folders: Int64 = 0
        /// Data copied.
        var bytes: Int64 = 0
        /// Files already there (same size and date), so not copied again.
        var unchanged: Int64 = 0
        var unchangedBytes: Int64 = 0
        var current = ""
        var counted = Packer.Totals()
        var totals: Packer.Totals?
        var problemCount = 0
        /// Everything's copied; folders get their dates, links are made.
        var finishing = false
        /// Then it's made sure of on the drive (an external one), so it's safe to unplug.
        var saving = false
        /// Then each file copied is read back and checked against the original.
        var verifying = false
        var verified: Int64 = 0
        var toVerify: Int64 = 0
        /// The big file being copied, if any, and how far along.
        var bigName: String?
        var bigDone: Int64 = 0
        var bigSize: Int64 = 0
    }

    struct Summary: Sendable {
        /// The copy.
        var destination: URL
        var files: Int64
        var folders: Int64
        var bytes: Int64
        var unchanged: Int64
        var unchangedBytes: Int64
        /// Start to end, saving included.
        var seconds: Double
        /// Of those, making sure it's all on the drive, once it was all copied.
        var savingSeconds: Double
        var plan: CopyPlan
        /// It picked up a copy that had been stopped.
        var resumed: Bool
        var updated: Bool
        var leftOut: Int64
        var gitIgnored: Int64 = 0
        var rebuildable: Int64
        var cloudOnly: Int64
        var otherDisks: Int64
        var unsupported: Int64
        var changed: Int64
        var problems: [Problem]
        var problemCount: Int
        /// Files read back from the drive that matched their originals, and those that didn't.
        var verified: Int64 = 0
        var mismatched: Int64 = 0
        /// What's in the copy that the original no longer has (when mirroring).
        var extras: [Extra] = []
    }

    enum Outcome: Sendable {
        case finished(Summary)
        /// Stopped: what's copied so far is in the folder (if any), and copying again picks up there.
        case stopped(URL?)
        case failed(String, URL?)
    }

    struct CopyError: Error, Sendable {
        let message: String
    }

    /// What's at the destination already, for a folder of this name.
    enum Existing: Sendable, Equatable {
        case nothing
        /// A folder of that name: it can be updated, or a new copy made beside it.
        case folder(URL)
        /// A copy of this same folder that was stopped: copying picks it up.
        case stopped(URL)
    }

    /// The extended attribute on a "(copying)" folder that says what it's a copy of.
    static let markerName = "local.onefile.copy-of"
    /// Small files go to the copying threads in groups of up to this many (or this much data).
    static let chunkFiles = 64
    static let chunkBytes: Int64 = 16 << 20
    static let problemsKept = 1_000
    /// Each thread's buffer, for a whole small file or a piece of a big one.
    static let bufferSize = 8 << 20

    let source: URL
    let target: Target
    let options: Options
    private let knownTotals: Packer.Totals?

    private(set) var plan = CopyPlan(from: nil, to: nil)
    /// Reads in disk order whatever the drive (tests, as no hard drive is at hand).
    var forceDiskOrder = false
    private var sourceDrive: Drive?
    private var destinationDrive: Drive?

    private struct State {
        var progress = Progress()
        var stopped = false
        var done = false
        var failure: String?
        var leftOut: Int64 = 0
        var gitIgnored: Int64 = 0
        var rebuildable: Int64 = 0
        var cloudOnly: Int64 = 0
        var otherDisks: Int64 = 0
        var unsupported: Int64 = 0
        var changed: Int64 = 0
        var problems: [Problem] = []
    }

    private let state = Locked(State())
    private let small = WorkQueue<[CopyJob]>(limit: 256)
    /// Big files waiting (any number: the walker mustn't wait for them, or the small files would).
    private let big = WorkQueue<CopyJob>(limit: 1_000_000)
    /// Folders made at the destination (paths inside the copy).
    private let madeFolders = Locked(Set<String>())
    /// Where the first name of each file with several names went, for the others (hard links).
    private let firstNames = Locked([FileID: String]())
    /// Each copied file's SHA-256, worked out while copying, to check the copy against (verifying).
    private let digests = Locked([String: [UInt8]]())
    /// What the copy has that the original doesn't (mirroring). Walker only, then the end.
    private var extras: [Extra] = []
    private let readAhead = DispatchQueue(label: "OneFile.readAhead", qos: Work.dispatchQoS)
    /// Pausing waits here, between files and between pieces of a big one.
    private let gate = PauseGate()

    /// The copy's folder at the destination, open, and its path.
    private var root: Int32 = -1
    private var rootPath = ""
    private var sourceRoot = ""
    /// Seconds two dates may differ by and still be the same (FAT keeps them to 2 s).
    private var dateSlack: Int64 = 1
    private var windowsFormat = false

    // Handed from the walker to the end.
    private var links: [LinkJob] = []
    private var symbolicLinks: [SymlinkJob] = []
    private var pipes: [PipeJob] = []
    private var folders: [FolderJob] = []

    init(source: URL, target: Target, options: Options, knownTotals: Packer.Totals? = nil) {
        self.source = source
        self.target = target
        self.options = options
        self.knownTotals = knownTotals
    }

    /// Starts copying on threads of its own; `completion` is called on one of them.
    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in
            completion(run())
        }
        thread.name = "OneFile copier"
        thread.qualityOfService = Work.qos
        thread.start()
    }

    /// Stops copying. What's copied stays (in the "(copying)" folder), to pick up later.
    func cancel() {
        state.withLock { $0.stopped = true }
        small.stop()
        big.stop()
        gate.release()
    }

    /// Pauses between files (and between pieces of a big one), or carries on.
    func pause() { gate.pause() }
    func resume() { gate.resume() }
    var isPaused: Bool { gate.isPaused }

    func progress() -> Progress {
        state.withLock { $0.progress }
    }

    // MARK: Before starting

    /// What's at `folder` already for a copy of `source` called `name`.
    static func existing(for source: URL, name: String, in folder: URL) -> Existing {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        for candidate in stagingCandidates(name, in: folder) {
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isFolder) else { break }
            if isFolder.boolValue, marker(candidate.path) == source.path { return .stopped(candidate) }
        }
        let plain = folder.appendingPathComponent(name)
        if fm.fileExists(atPath: plain.path, isDirectory: &isFolder), isFolder.boolValue { return .folder(plain) }
        return .nothing
    }

    /// "Photos (copying)", "Photos (copying 2)"…
    private static func stagingCandidates(_ name: String, in folder: URL) -> [URL] {
        (1...20).map { number in
            folder.appendingPathComponent(number == 1 ? "\(name) (copying)" : "\(name) (copying \(number))")
        }
    }

    private static func marker(_ path: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = getxattr(path, markerName, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard count > 0 else { return nil }
        return String(decoding: bytes[0..<count], as: UTF8.self)
    }

    /// Why copying `source` to `folder` can't work, if it can't: a folder into itself, say.
    static func problem(copying source: URL, into folder: URL) -> String? {
        let from = realPath(source.path)
        let into = realPath(folder.path)
        if into == from || into.hasPrefix(from + "/") {
            return "That's inside the folder being copied. Pick a place outside it."
        }
        var info = statfs()
        if statfs(folder.path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0 {
            let name = Packer.volumeName(folder.path)
            let ntfs = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "ntfs"
            return ntfs ? "“\(name)” is an NTFS drive, which a Mac can only read. Pick another place, or format the drive as exFAT."
                        : "“\(name)” can only be read, not written to."
        }
        if access(folder.path, W_OK) != 0 {
            return "OneFile can't write to “\(folder.lastPathComponent)”."
        }
        return nil
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: The copying thread

    private func run() -> Outcome {
        let started = Date()
        let walkRoot: TreeWalk.Folder
        switch Packer.root(for: source) {
        case .success(let folder): walkRoot = folder
        case .failure(let error): return .failed(error.message, nil)
        }
        sourceRoot = walkRoot.diskPath

        let prepared: (path: String, resumed: Bool)
        switch prepare() {
        case .success(let value): prepared = value
        case .failure(let error): return .failed(error.message, nil)
        }
        rootPath = prepared.path
        root = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            return .failed("Couldn't open the copy at “\(rootPath)”: \(Packer.message(errno)).", nil)
        }
        defer {
            close(root)
            root = -1
        }
        sourceDrive = Drive.of(sourceRoot)
        destinationDrive = Drive.of(rootPath)
        plan = CopyPlan(from: sourceDrive, to: destinationDrive)
        if forceDiskOrder {
            plan.diskOrder = true
            plan.workers = 4
        }
        windowsFormat = destinationDrive?.isWindowsFormat ?? false
        dateSlack = destinationDrive?.isFAT == true || sourceDrive?.isFAT == true ? 2 : 1
        let existing = prepared.resumed || isUpdate

        var walkRules = WalkRules(leaveOut: options.leaveOut, device: walkRoot.entry.device,
                                  skipRebuildable: options.skipRebuildable)
        walkRules.excluded = options.excluded
        let rules = walkRules
        if let knownTotals {
            state.withLock { $0.progress.counted = knownTotals; $0.progress.totals = knownTotals }
        } else {
            let counter = Thread { [self] in
                let counted = Packer.count(walkRoot, rules: rules, stopped: { self.isOver }, progress: { partial in
                    self.state.withLock { $0.progress.counted = partial }
                })
                guard let totals = counted?.totals else { return }
                state.withLock { $0.progress.counted = totals; $0.progress.totals = totals }
            }
            counter.name = "OneFile counter"
            counter.qualityOfService = .utility
            counter.start()
        }

        let finished = DispatchGroup()
        for index in 0..<plan.workers {
            finished.enter()
            let worker = Thread { [self] in
                copySmallFiles()
                finished.leave()
            }
            worker.name = "OneFile copy \(index + 1)"
            worker.qualityOfService = Work.qos
            worker.start()
        }
        finished.enter()
        let bigLane = Thread { [self] in
            copyBigFiles()
            finished.leave()
        }
        bigLane.name = "OneFile big files"
        bigLane.qualityOfService = Work.qos
        bigLane.start()

        walk(walkRoot, rules, existing: existing)
        finished.wait()

        if isStopped { return endEarly(started) }
        state.withLock { $0.progress.finishing = true; $0.progress.bigName = nil }
        finishTree()
        if isStopped { return endEarly(started) }

        // Make sure it's all on the drive before calling it done, so it's safe to unplug: macOS
        // holds on to some of what's written (on a USB exFAT drive, 7 s more for 20,000 files,
        // which Finder leaves for when the drive is ejected).
        let copied = Date()
        if destinationDrive?.isInternal != true {
            state.withLock { $0.progress.saving = true }
            fsync_volume_np(root, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)
        }
        let savingSeconds = Date().timeIntervalSince(copied)
        var verified: Int64 = 0, mismatched: Int64 = 0
        if options.verify && !plan.clone {
            (verified, mismatched) = verifyCopies()
            if isStopped { return endEarly(started) }
        }

        var destination = URL(fileURLWithPath: rootPath)
        if case .new(let folder, let name) = target {
            removexattr(rootPath, Self.markerName, XATTR_NOFOLLOW)
            guard let placed = Self.place(rootPath, in: folder, name: name) else {
                let code = errno
                finish()
                return .failed("Everything is copied, in “\(destination.lastPathComponent)”, but it couldn't be renamed “\(name)”: \(Packer.message(code)).", destination)
            }
            destination = placed
        }
        finish()
        let seconds = Date().timeIntervalSince(started)
        let updated = isUpdate
        let plan = plan
        return state.withLock { s in
            .finished(Summary(
                destination: destination, files: s.progress.files, folders: s.progress.folders,
                bytes: s.progress.bytes, unchanged: s.progress.unchanged, unchangedBytes: s.progress.unchangedBytes,
                seconds: seconds, savingSeconds: savingSeconds, plan: plan, resumed: prepared.resumed, updated: updated, leftOut: s.leftOut, gitIgnored: s.gitIgnored,
                rebuildable: s.rebuildable, cloudOnly: s.cloudOnly, otherDisks: s.otherDisks,
                unsupported: s.unsupported, changed: s.changed, problems: s.problems,
                problemCount: s.progress.problemCount, verified: verified, mismatched: mismatched, extras: extras))
        }
    }

    private var isUpdate: Bool {
        if case .update = target { return true }
        return false
    }

    /// Stopped, or failed: what's copied stays where it is.
    private func endEarly(_ started: Date) -> Outcome {
        let failure = state.withLock { $0.failure }
        finish()
        let partial = URL(fileURLWithPath: rootPath)
        return failure.map { .failed($0, partial) } ?? .stopped(partial)
    }

    /// Ends what's still going (the counter) once the outcome is decided.
    private func finish() {
        state.withLock { $0.done = true }
        small.stop()
        big.stop()
        gate.release()
    }

    /// Makes (or finds) the folder the copy goes in.
    private func prepare() -> Result<(path: String, resumed: Bool), CopyError> {
        switch target {
        case .update(let folder):
            if let problem = Self.problem(copying: source, into: folder.deletingLastPathComponent()) {
                return .failure(CopyError(message: problem))
            }
            let into = Self.realPath(folder.path)
            let from = Self.realPath(source.path)
            if into == from || from.hasPrefix(into + "/") {
                return .failure(CopyError(message: "That's the folder being copied, or holds it. Pick another place."))
            }
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return .failure(CopyError(message: "“\(folder.lastPathComponent)” isn't a folder any more."))
            }
            return .success((folder.path, false))
        case .new(let folder, let name):
            if let problem = Self.problem(copying: source, into: folder) {
                return .failure(CopyError(message: problem))
            }
            for candidate in Self.stagingCandidates(name, in: folder) {
                if mkdir(candidate.path, 0o700) == 0 {
                    let mark = source.path
                    _ = mark.withCString { setxattr(candidate.path, Self.markerName, $0, strlen($0), 0, XATTR_NOFOLLOW) }
                    return .success((candidate.path, false))
                }
                let code = errno
                guard code == EEXIST else {
                    return .failure(CopyError(message: Self.writeMessage(code, in: folder)))
                }
                if Self.marker(candidate.path) == source.path { return .success((candidate.path, true)) }
            }
            return .failure(CopyError(message: "There are too many unfinished copies of “\(name)” here."))
        }
    }

    /// Renames the finished copy to `name`, or "NAME 2" (and so on) if that's taken, never
    /// replacing anything. Drives that can't rename exclusively (some exFAT and network drives)
    /// get a check first.
    static func place(_ path: String, in folder: URL, name: String) -> URL? {
        for number in 1...9_999 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : Unpacker.numbered(name, number, isFolder: true))
            if renamex_np(path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            if code == EEXIST { continue }
            guard code == ENOTSUP || code == EINVAL else { return nil }
            var info = stat()
            if lstat(candidate.path, &info) == 0 { continue }
            return rename(path, candidate.path) == 0 ? candidate : nil
        }
        return nil
    }

    static func writeMessage(_ code: Int32, in folder: URL) -> String {
        let drive = Packer.volumeName(folder.path)
        switch code {
        case ENOSPC, EDQUOT: return "“\(drive)” is full."
        case EROFS: return "“\(drive)” can only be read, not written to."
        case EACCES, EPERM: return "OneFile isn't allowed to write in “\(folder.lastPathComponent)”."
        default: return "Couldn't make a folder in “\(folder.lastPathComponent)”: \(Packer.message(code))."
        }
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }
    private var isOver: Bool { state.withLock { $0.stopped || $0.done } }

    private func fail(_ message: String) {
        let first = state.withLock { s -> Bool in
            guard !s.done, s.failure == nil else { return false }
            s.failure = message
            s.stopped = true
            return true
        }
        if first {
            small.stop()
            big.stop()
        }
    }

    private func problem(_ path: String, _ message: String) {
        state.withLock { s in
            s.progress.problemCount += 1
            if s.problems.count < Self.problemsKept {
                s.problems.append(Problem(id: s.problems.count, path: path, message: message))
            }
        }
    }

    // MARK: The walker

    /// Goes through the folder, hands out the files, and keeps the rest (links, pipes, folders)
    /// for the end. Copying a folder that's partly there (picking up a stopped copy, or updating
    /// one), each folder at the destination is listed too, to skip files already there.
    private func walk(_ walkRoot: TreeWalk.Folder, _ rules: WalkRules, existing: Bool) {
        var chunk: [CopyJob] = []
        var chunkBytes: Int64 = 0
        /// Waiting to go out in disk order (a spinning disk's files).
        var window: [CopyJob] = []
        var seen: [FileID: String] = [:]
        var there: [String: FolderEntry] = [:]
        let insensitive = !(destinationDrive?.caseSensitive ?? false)
        var leftOut: Int64 = 0, gitIgnored: Int64 = 0, rebuildable: Int64 = 0, cloudOnly: Int64 = 0, otherDisks: Int64 = 0
        var unsupported: Int64 = 0
        let rootLength = walkRoot.diskPath.utf8.count
        let plan = plan

        func relative(_ diskPath: String) -> String {
            diskPath.utf8.count <= rootLength ? "" : String(diskPath.dropFirst(walkRoot.diskPath.count + 1))
        }
        func key(_ name: String) -> String {
            let composed = name.precomposedStringWithCanonicalMapping
            return insensitive ? composed.lowercased() : composed
        }
        func send(_ jobs: [CopyJob]) -> Bool {
            var start = 0
            while start < jobs.count {
                var end = start
                var bytes: Int64 = 0
                while end < jobs.count && end - start < Self.chunkFiles && bytes < Self.chunkBytes {
                    bytes += jobs[end].size
                    end += 1
                }
                guard small.push(Array(jobs[start..<end])) else { return false }
                start = end
            }
            return true
        }
        func flush() -> Bool {
            if plan.diskOrder {
                window.append(contentsOf: chunk)
                chunk = []
                chunkBytes = 0
                guard window.count >= 2_048 else { return true }
                // In the order they were made, which on a spinning disk is roughly the order
                // they are on it: the heads sweep across instead of jumping back and forth.
                window.sort { $0.inode < $1.inode }
                defer { window = [] }
                return send(window)
            }
            defer {
                chunk = []
                chunkBytes = 0
            }
            return chunk.isEmpty || small.push(chunk)
        }

        TreeWalk.run(walkRoot, rules: rules, stopped: { isStopped },
            folder: { folder in
                let path = relative(folder.diskPath)
                var entry = folder.entry
                if path.isEmpty { entry.hasAppleDouble = plan.appleDoubleSource && Self.hasAppleDouble(folder.diskPath) }
                folders.append(FolderJob(path: path, source: folder.diskPath, mode: entry.permissions,
                                         modified: entry.modified, created: entry.created, flags: entry.flags,
                                         appleDouble: entry.hasAppleDouble))
                there = [:]
                if existing {
                    // What's at the destination for this folder (if it's there, and not by way of
                    // a link: then nothing is "there", and copying it will say why).
                    let fd = path.isEmpty ? dup(root) : openat(root, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                    if fd >= 0 {
                        close(fd)
                        FolderReader.read(path.isEmpty ? rootPath : rootPath + "/" + path) { entries in
                            for item in entries { there[key(item.name)] = item }
                            return true
                        }
                    }
                    if options.mirror && !there.isEmpty { noteExtras(in: folder.diskPath, at: path, there, rules, key) }
                }
                return true
            },
            entry: { entry, folder in
                let folderPath = relative(folder.diskPath)
                let path = folderPath.isEmpty ? entry.name : folderPath + "/" + entry.name
                let diskPath = folder.diskPath + "/" + entry.name
                var replace = false
                if existing, let found = there[key(entry.name)] {
                    if found.kind == .directory {
                        problem(path, "Not copied: there's a folder of that name where the copy goes.")
                        return true
                    }
                    if entry.kind == .file, found.kind == .file, found.size == entry.size,
                       abs(found.modified - entry.modified) <= dateSlack {
                        state.withLock { s in
                            s.progress.unchanged += 1
                            s.progress.unchangedBytes += entry.size
                        }
                        if entry.links > 1 {
                            let id = FileID(device: entry.device, inode: entry.inode)
                            if seen[id] == nil { seen[id] = path }
                            firstNames.withLock { $0[id] = $0[id] ?? path }
                        }
                        return true
                    }
                    if (entry.kind == .symlink && found.kind == .symlink
                        && Packer.linkTarget(rootPath + "/" + path) == Packer.linkTarget(diskPath))
                        || (entry.kind == .fifo && found.kind == .fifo) {
                        state.withLock { $0.progress.unchanged += 1 }
                        return true
                    }
                    replace = true
                }
                switch entry.kind {
                case .file:
                    var job = CopyJob(source: diskPath, path: path, size: entry.size, mode: entry.permissions,
                                      modified: entry.modified, created: entry.created, flags: entry.flags,
                                      inode: entry.inode, appleDouble: entry.hasAppleDouble, replace: replace)
                    if entry.links > 1 {
                        let id = FileID(device: entry.device, inode: entry.inode)
                        if seen[id] != nil {
                            links.append(LinkJob(job: job, first: id))
                            return true
                        }
                        seen[id] = path
                        job.linkGroup = id
                    }
                    if entry.size > plan.bigFile && !plan.clone {
                        return big.push(job)
                    }
                    chunk.append(job)
                    chunkBytes += entry.size
                    if chunk.count >= Self.chunkFiles || chunkBytes >= Self.chunkBytes { return flush() }
                case .symlink:
                    guard let target = Packer.linkTarget(diskPath) else {
                        problem(path, "Couldn't read where this link points: \(Packer.message(errno)).")
                        return true
                    }
                    symbolicLinks.append(SymlinkJob(path: path, target: target, modified: entry.modified, replace: replace))
                case .fifo:
                    pipes.append(PipeJob(path: path, mode: entry.permissions, modified: entry.modified, replace: replace))
                case .directory, .other:
                    break
                }
                return true
            },
            skip: { reason in
                switch reason {
                case .leftOut: leftOut += 1
                case .gitIgnored: gitIgnored += 1
                case .rebuildable: rebuildable += 1
                case .cloudOnly: cloudOnly += 1
                case .otherDisk: otherDisks += 1
                case .unsupported: unsupported += 1
                }
            },
            problem: { path, code in
                problem(path, "Couldn't read this folder: \(Packer.message(code)).")
            })
        if !isStopped {
            _ = flush()
            if !window.isEmpty {
                window.sort { $0.inode < $1.inode }
                _ = send(window)
            }
        }
        state.withLock { s in
            s.leftOut = leftOut
            s.gitIgnored = gitIgnored
            s.rebuildable = rebuildable
            s.cloudOnly = cloudOnly
            s.otherDisks = otherDisks
            s.unsupported = unsupported
        }
        small.finish()
        big.finish()
    }

    /// What's in the copy's folder at `path` that the original's folder doesn't have at all (left
    /// out isn't missing: it stays). On an exFAT or FAT drive, "._" files are attributes, not extras.
    private func noteExtras(in source: String, at path: String, _ there: [String: FolderEntry], _ rules: WalkRules,
                            _ key: (String) -> String) {
        var names = Set<String>()
        FolderReader.read(source) { entries in
            for entry in entries { names.insert(key(entry.name)) }
            return true
        }
        let sidecars = !(destinationDrive?.nativeAttributes ?? true)
        for (name, item) in there where !names.contains(name) {
            if rules.leavesOut(item.name) || (sidecars && item.name.hasPrefix("._")) { continue }
            extras.append(Extra(path: path.isEmpty ? item.name : path + "/" + item.name,
                                isFolder: item.kind == .directory, size: item.size))
        }
    }

    /// Whether the "._" file of the item at `path` is there (beside it, in its folder).
    private static func hasAppleDouble(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var info = stat()
        return lstat(url.deletingLastPathComponent().path + "/._" + url.lastPathComponent, &info) == 0
    }

    // MARK: Copying threads

    private func copySmallFiles() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize + 1, alignment: 16_384)
        defer { buffer.deallocate() }
        while let jobs = small.pop() {
            var files: Int64 = 0, bytes: Int64 = 0, changed: Int64 = 0
            var last = ""
            for job in jobs {
                gate.wait()
                if isStopped { return }
                switch copy(job, buffer: buffer) {
                case .copied(let size, let sizeChanged):
                    files += 1
                    bytes += size
                    if sizeChanged { changed += 1 }
                    last = job.path
                case .skipped:
                    break
                }
            }
            state.withLock { s in
                s.progress.files += files
                s.progress.bytes += bytes
                s.changed += changed
                if !last.isEmpty { s.progress.current = last }
            }
        }
    }

    private func copyBigFiles() {
        let buffers = [UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16_384),
                       UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16_384)]
        defer { buffers.forEach { $0.deallocate() } }
        while let job = big.pop() {
            if isStopped { return }
            state.withLock { s in
                s.progress.bigName = job.path
                s.progress.bigDone = 0
                s.progress.bigSize = job.size
            }
            let result = copy(job, buffers: buffers)
            state.withLock { s in
                s.progress.bigName = nil
                if case .copied(_, let sizeChanged) = result {
                    s.progress.files += 1
                    s.progress.current = job.path
                    if sizeChanged { s.changed += 1 }
                }
            }
        }
    }

    private enum CopyResult {
        /// Copied, with this much data; and whether its size changed while it was being copied.
        case copied(Int64, Bool)
        /// Not copied (and the problem is noted), or stopped.
        case skipped
    }

    /// Copies one file: a small one into `buffer` whole, a big one through `buffers` in pieces.
    private func copy(_ job: CopyJob, buffer: UnsafeMutableRawPointer? = nil,
                      buffers: [UnsafeMutableRawPointer] = []) -> CopyResult {
        guard ensureFolder(parent(job.path)) else { return .skipped }
        if plan.clone {
            if let cloned = clone(job) { return cloned }
        }
        let input = open(job.source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            let code = errno
            if code == ENOENT {
                problem(job.path, "Not copied: it was deleted before it could be.")
            } else if !sourceGone() {
                problem(job.path, "Couldn't read this file: \(Packer.message(code)).")
            }
            return .skipped
        }
        defer { close(input) }
        guard let output = create(job) else { return .skipped }
        defer { close(output) }

        var copied: Int64
        var hasher: SHA256? = options.verify ? SHA256() : nil
        if let buffer, job.size < Int64(Self.bufferSize) {
            // Small: read it whole (and a byte more, to notice one that grew), then write it in one go.
            var done = 0
            let wanted = Int(job.size) + 1
            var readError: Int32 = 0
            while done < wanted {
                let count = read(input, buffer + done, wanted - done)
                if count > 0 { done += count; continue }
                if count == 0 { break }
                if errno == EINTR { continue }
                readError = errno
                break
            }
            if readError != 0 {
                unlinkPartial(job)
                if !sourceGone() { problem(job.path, "Couldn't read this file: \(Packer.message(readError)).") }
                return .skipped
            }
            guard writeOut(output, buffer, done, job) else { return .skipped }
            hasher?.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: done))
            copied = Int64(done)
            // It grew since the folder was listed: the rest goes too.
            if done == wanted {
                guard let rest = stream(input, output, job, [buffer], counting: false, hasher: &hasher) else { return .skipped }
                copied += rest
            }
        } else if let buffer {
            // A big file on a small file's thread (it couldn't be cloned): in pieces, one buffer.
            guard let result = stream(input, output, job, [buffer], counting: false, hasher: &hasher) else { return .skipped }
            copied = result
        } else {
            guard let result = stream(input, output, job, buffers, counting: true, hasher: &hasher) else { return .skipped }
            copied = result
        }
        let sizeChanged = copied != job.size
        if let hasher { digests.withLock { $0[job.path] = Array(hasher.finalize()) } }
        copyAttributes(job, from: input, to: output)
        finishFile(output, job)
        if let id = job.linkGroup { firstNames.withLock { $0[id] = job.path } }
        return .copied(copied, sizeChanged)
    }

    /// Copies a file a piece at a time, to its end: with two buffers, the next piece is read while
    /// one is written. What it copied, or nil if it couldn't (the problem is noted). `counting`, it
    /// adds to the progress as it goes (the big-file lane).
    private func stream(_ input: Int32, _ output: Int32, _ job: CopyJob,
                        _ buffers: [UnsafeMutableRawPointer], counting: Bool, hasher: inout SHA256?) -> Int64? {
        let pointers = buffers.map { SharedPointer($0.assumingMemoryBound(to: UInt8.self)) }
        let ahead = buffers.count > 1
        var current = 0
        var piece = Self.fill(input, pointers[0])
        var total: Int64 = 0
        while piece.count > 0 && piece.error == 0 {
            gate.wait()
            if isStopped {
                unlinkPartial(job)
                return nil
            }
            let next = ahead ? 1 - current : current
            var wrote: Bool
            if ahead {
                let nextPiece = Locked<(count: Int, error: Int32)>((0, 0))
                let group = DispatchGroup()
                let into = pointers[next]
                readAhead.async(group: group) { nextPiece.withLock { $0 = Self.fill(input, into) } }
                wrote = writeOut(output, buffers[current], piece.count, job)
                hasher?.update(bufferPointer: UnsafeRawBufferPointer(start: buffers[current], count: piece.count))
                group.wait()
                guard wrote else { return nil }
                total += Int64(piece.count)
                if counting {
                    let done = total, count = piece.count
                    state.withLock { s in
                        s.progress.bytes += Int64(count)
                        s.progress.bigDone = done
                    }
                }
                piece = nextPiece.withLock { $0 }
            } else {
                wrote = writeOut(output, buffers[current], piece.count, job)
                guard wrote else { return nil }
                hasher?.update(bufferPointer: UnsafeRawBufferPointer(start: buffers[current], count: piece.count))
                total += Int64(piece.count)
                piece = Self.fill(input, pointers[current])
            }
            current = next
        }
        if piece.error != 0 {
            unlinkPartial(job)
            if !sourceGone() { problem(job.path, "Couldn't read all of this file: \(Packer.message(piece.error)).") }
            return nil
        }
        return total
    }

    /// Reads every copied file back from the drive (not from memory) and checks it against the
    /// SHA-256 of the original worked out while copying. How many matched, and didn't.
    private func verifyCopies() -> (Int64, Int64) {
        let list = digests.withLock { Array($0) }
        state.withLock { s in
            s.progress.verifying = true
            s.progress.toVerify = Int64(list.count)
        }
        let next = Locked(0)
        let counts = Locked((matched: Int64(0), mismatched: Int64(0)))
        let group = DispatchGroup()
        let drive = destinationDrive?.name ?? "the drive"
        for _ in 0..<min(8, max(list.count, 1)) {
            group.enter()
            let thread = Thread { [self] in
                defer { group.leave() }
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16_384)
                defer { buffer.deallocate() }
                while !isStopped {
                    let index = next.withLock { value -> Int in
                        defer { value += 1 }
                        return value
                    }
                    guard index < list.count else { return }
                    gate.wait()
                    let (path, digest) = list[index]
                    let fd = openat(root, path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
                    var matched = false
                    if fd >= 0 {
                        Comparer.forgetCached(fd)
                        var hasher = SHA256()
                        var failed = false
                        while true {
                            let got = Comparer.readFull(fd, buffer, Self.bufferSize)
                            if got < 0 { failed = true; break }
                            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: got))
                            if got < Self.bufferSize { break }
                        }
                        close(fd)
                        matched = !failed && Array(hasher.finalize()) == digest
                    }
                    if !matched {
                        problem(path, "Read back from “\(drive)”, it doesn't match the original. Copy it again.")
                    }
                    counts.withLock { c in
                        if matched { c.matched += 1 } else { c.mismatched += 1 }
                    }
                    state.withLock { $0.progress.verified += 1 }
                }
            }
            thread.qualityOfService = Work.qos
            thread.start()
        }
        group.wait()
        return counts.withLock { ($0.matched, $0.mismatched) }
    }

    /// Reads up to a buffer's worth of a file: what it got, and the error that stopped it, if any.
    private static func fill(_ input: Int32, _ buffer: SharedPointer<UInt8>) -> (count: Int, error: Int32) {
        var got = 0
        while got < bufferSize {
            let count = read(input, buffer.pointer + got, bufferSize - got)
            if count > 0 { got += count; continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return (got, errno)
        }
        return (got, 0)
    }

    /// On one APFS drive: a clone, which takes no time and no space. Nil if it can't be cloned
    /// (then it's copied).
    private func clone(_ job: CopyJob) -> CopyResult? {
        var result = clonefileat(AT_FDCWD, job.source, root, job.path, UInt32(CLONE_NOFOLLOW | CLONE_NOFOLLOW_ANY))
        if result != 0 && errno == EEXIST && job.replace {
            removeExisting(job.path)
            result = clonefileat(AT_FDCWD, job.source, root, job.path, UInt32(CLONE_NOFOLLOW | CLONE_NOFOLLOW_ANY))
        }
        if result == 0 {
            // A clone keeps the dates, permissions and attributes already.
            if let id = job.linkGroup { firstNames.withLock { $0[id] = job.path } }
            return .copied(job.size, false)
        }
        let code = errno
        switch code {
        case ENOTSUP, EXDEV, ENOTTY, EINVAL:
            return nil
        case ENOENT:
            problem(job.path, "Not copied: it was deleted before it could be.")
            return .skipped
        default:
            report(code, job)
            return .skipped
        }
    }

    /// The new file at the destination, open for writing; nil if it can't be made (and the problem
    /// is noted). Never through a symbolic link.
    private func create(_ job: CopyJob) -> Int32? {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC
        let permissions = mode_t(job.mode & 0o777 | 0o200)
        var fd = openat(root, job.path, flags, permissions)
        if fd < 0 && errno == EEXIST && job.replace {
            removeExisting(job.path)
            fd = openat(root, job.path, flags, permissions)
        }
        guard fd >= 0 else {
            report(errno, job)
            return nil
        }
        return fd
    }

    /// Deletes what's at `path` in the copy to make way for a newer version: a file or a link,
    /// never a folder.
    private func removeExisting(_ path: String) {
        let (folder, leaf) = split(path)
        let fd = folder.isEmpty ? dup(root) : openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return }
        unlinkat(fd, leaf, 0)
        close(fd)
    }

    /// A file that couldn't be copied to the end: no half-copied file is left with its name.
    private func unlinkPartial(_ job: CopyJob) {
        removeExisting(job.path)
    }

    private func writeOut(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ job: CopyJob) -> Bool {
        var done = 0
        while done < count {
            let written = write(fd, bytes + done, count - done)
            if written > 0 { done += written; continue }
            if written < 0 && errno == EINTR { continue }
            let code = written == 0 ? EIO : errno
            unlinkPartial(job)
            report(code, job)
            return false
        }
        return true
    }

    /// What went wrong making or writing a file: some things stop the whole copy (a full drive,
    /// one that went away), the rest are noted against the file.
    private func report(_ code: Int32, _ job: CopyJob) {
        let drive = destinationDrive?.name ?? "the drive"
        switch code {
        case ENOSPC, EDQUOT:
            fail("“\(drive)” is full. Make room on it, then copy again: it picks up where it stopped.")
        case EROFS:
            fail("“\(drive)” can only be read, not written to.")
        case EFBIG:
            problem(job.path, "Too big for “\(drive)”: FAT32 drives hold files of up to 4 GB.")
        case EEXIST:
            problem(job.path, "Not copied: something else here has the same name, apart from upper and lower case, which “\(drive)” doesn't tell apart.")
        case ENAMETOOLONG:
            problem(job.path, "Not copied: the name is too long for “\(drive)”.")
        case EINVAL, EILSEQ:
            problem(job.path, "Not copied: “\(drive)” (\(destinationDrive?.formatName ?? "its format")) doesn't allow this name.")
        case ELOOP, ENOTDIR:
            problem(job.path, "Not copied: at the destination, a link or a file is where its folder should be.")
        default:
            if !destinationGone() {
                problem(job.path, "Couldn't copy this file: \(Packer.message(code)).")
            }
        }
    }

    /// The source drive went away (unplugged): stops the copy, saying so. False if it's there.
    private func sourceGone() -> Bool {
        var info = stat()
        guard stat(sourceRoot, &info) != 0 else { return false }
        fail("The drive with “\(source.lastPathComponent)” went away. Connect it again, then copy again: it picks up where it stopped.")
        return true
    }

    private func destinationGone() -> Bool {
        var info = stat()
        guard fstat(root, &info) != 0 || stat(rootPath, &info) != 0 else { return false }
        let drive = destinationDrive?.name ?? "The drive"
        fail("“\(drive)” went away. Connect it again, then copy again: it picks up where it stopped.")
        return true
    }

    /// The source file's extended attributes (Finder tags and the like) onto the copy.
    private func copyAttributes(_ job: CopyJob, from input: Int32, to output: Int32) {
        if plan.appleDoubleSource {
            guard job.appleDouble else { return }
            applyAppleDouble(of: job.source, to: output)
        } else {
            Self.copyAttributes(input, output)
        }
    }

    /// Copies the extended attributes worth copying (as Finder decides) from one open file to
    /// another. By hand rather than with `fcopyfile`, which first clears the copy's own: on an
    /// exFAT drive that rewrites its "._" file, which made copying small files there 3× slower.
    static func copyAttributes(_ input: Int32, _ output: Int32) {
        let size = flistxattr(input, nil, 0, 0)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        let got = flistxattr(input, &names, size, 0)
        guard got > 0 else { return }
        var value: [UInt8] = []
        var start = 0
        for index in 0..<min(got, names.count) where names[index] == 0 {
            let name = names[start..<index].withUnsafeBufferPointer { String(decoding: UnsafeRawBufferPointer($0), as: UTF8.self) }
            start = index + 1
            guard !name.isEmpty, AppleDouble.copies(name) else { continue }
            let length = fgetxattr(input, name, nil, 0, 0, 0)
            guard length >= 0 else { continue }
            if value.count < max(length, 1) { value = [UInt8](repeating: 0, count: max(length, 1)) }
            let read = fgetxattr(input, name, &value, length, 0, 0)
            guard read >= 0 else { continue }
            fsetxattr(output, name, value, read, 0, 0)
        }
    }

    /// Reads the "._" file beside `path` and gives `fd` the attributes it holds.
    private func applyAppleDouble(of path: String, to fd: Int32) {
        let url = URL(fileURLWithPath: path)
        let sidecar = url.deletingLastPathComponent().path + "/._" + url.lastPathComponent
        let input = open(sidecar, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { return }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_size > 0, info.st_size <= 64 << 20 else { return }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
        guard count == bytes.count else { return }
        let attributes = bytes.withUnsafeBytes { AppleDouble.attributes($0) }
        if let attributes { AppleDouble.apply(attributes, to: fd) }
    }

    /// Permissions, the hidden flag, and the dates: last, as writing changed the date. (Files are
    /// made writable by their owner, to give them their attributes; exFAT and FAT drives have no
    /// permissions to set.)
    private func finishFile(_ fd: Int32, _ job: CopyJob) {
        let wanted = job.mode & 0o777
        if !windowsFormat, (wanted | 0o200) & ~Unpacker.umaskBits != wanted {
            fchmod(fd, mode_t(wanted))
        }
        if job.flags & UInt32(UF_HIDDEN) != 0 { fchflags(fd, UInt32(UF_HIDDEN)) }
        Self.setDates(fd, modified: job.modified, created: job.created)
    }

    /// Sets the modification date, and the creation date when there is one.
    static func setDates(_ fd: Int32, modified: Int64, created: Int64) {
        guard created > 0 || modified != 0 else { return }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        var times: [timespec] = []
        // In attribute order: the creation date comes first.
        if created > 0 {
            request.commonattr |= attrgroup_t(ATTR_CMN_CRTIME)
            times.append(timespec(tv_sec: Int(created), tv_nsec: 0))
        }
        request.commonattr |= attrgroup_t(ATTR_CMN_MODTIME)
        times.append(timespec(tv_sec: Int(modified), tv_nsec: 0))
        let result = times.withUnsafeMutableBytes { raw in
            fsetattrlist(fd, &request, raw.baseAddress, raw.count, 0)
        }
        if result != 0 {
            var both = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(modified), tv_nsec: 0)]
            futimens(fd, &both)
        }
    }

    // MARK: Folders

    /// Makes the folder at `path` in the copy (and any it's in), unless it's there. False if it
    /// can't be made, with the problem noted. Never through a symbolic link.
    private func ensureFolder(_ path: String) -> Bool {
        if path.isEmpty || madeFolders.withLock({ $0.contains(path) }) { return true }
        let (folder, leaf) = split(path)
        guard ensureFolder(folder) else { return false }
        let parent = folder.isEmpty ? dup(root) : openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else {
            problem(path, "Couldn't make this folder: \(Packer.message(errno)).")
            return false
        }
        defer { close(parent) }
        if mkdirat(parent, leaf, 0o700) != 0 {
            let code = errno
            var info = stat()
            guard code == EEXIST, fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if code == ENOSPC || code == EDQUOT || code == EROFS {
                    fail(Self.writeMessage(code, in: URL(fileURLWithPath: rootPath)))
                } else if !destinationGone() {
                    problem(path, "Couldn't make this folder: \(Packer.message(code)).")
                }
                return false
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                problem(path, "Not copied: there's a file or a link of that name where this folder goes.")
                return false
            }
        } else {
            state.withLock { $0.progress.folders += 1 }
        }
        madeFolders.withLock { _ = $0.insert(path) }
        return true
    }

    private func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private func split(_ path: String) -> (folder: String, leaf: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// Opens the folder `path` of the copy, for making something in it.
    private func openFolder(_ path: String) -> Int32 {
        path.isEmpty ? dup(root) : openat(root, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    }

    // MARK: The end

    /// Other names for files (hard links), named pipes, symbolic links, then the folders'
    /// permissions, attributes and dates, deepest first.
    private func finishTree() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize + 1, alignment: 16_384)
        let pieces = [UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16_384),
                      UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16_384)]
        defer {
            buffer.deallocate()
            pieces.forEach { $0.deallocate() }
        }
        // Hard links first, while there are no symbolic links in the copy for a path to run
        // through. Where the drive can't hold them (exFAT), each name gets a copy of its own.
        for link in links {
            guard !isStopped else { return }
            let job = link.job
            guard ensureFolder(parent(job.path)) else { continue }
            guard let first = firstNames.withLock({ $0[link.first] }) else {
                problem(job.path, "Not copied: it's another name for a file that couldn't be copied.")
                continue
            }
            let (folder, leaf) = split(job.path)
            let fd = openFolder(folder)
            guard fd >= 0 else { continue }
            var result = linkat(root, first, fd, leaf, 0)
            if result != 0 && errno == EEXIST && job.replace {
                unlinkat(fd, leaf, 0)
                result = linkat(root, first, fd, leaf, 0)
            }
            let code = errno
            close(fd)
            if result == 0 {
                state.withLock { s in
                    s.progress.files += 1
                    s.progress.current = job.path
                }
                continue
            }
            if code == ENOSPC { report(code, job); return }
            // No hard links here: copy it again under this name.
            let isBig = job.size > plan.bigFile && !plan.clone
            let copied = isBig ? copy(job, buffers: pieces) : copy(job, buffer: buffer)
            if case .copied(let size, _) = copied {
                state.withLock { s in
                    s.progress.files += 1
                    // (A big file's data is counted as it goes.)
                    if !isBig { s.progress.bytes += size }
                }
            }
        }
        for pipe in pipes {
            guard !isStopped, ensureFolder(parent(pipe.path)) else { continue }
            let (folder, leaf) = split(pipe.path)
            let fd = openFolder(folder)
            guard fd >= 0 else { continue }
            if pipe.replace { unlinkat(fd, leaf, 0) }
            if mkfifoat(fd, leaf, mode_t(pipe.mode & 0o777)) == 0 {
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(pipe.modified), tv_nsec: 0)]
                utimensat(fd, leaf, &times, AT_SYMLINK_NOFOLLOW)
                state.withLock { $0.progress.files += 1 }
            } else {
                let code = errno
                let drive = destinationDrive?.name ?? "this drive"
                problem(pipe.path, code == ENOTSUP || code == EPERM
                        ? "Not copied: “\(drive)” (\(destinationDrive?.formatName ?? "")) can't hold named pipes."
                        : "Couldn't make this named pipe: \(Packer.message(code)).")
            }
            close(fd)
        }
        for link in symbolicLinks {
            guard !isStopped, ensureFolder(parent(link.path)) else { continue }
            let (folder, leaf) = split(link.path)
            let fd = openFolder(folder)
            guard fd >= 0 else {
                problem(link.path, "Not copied: at the destination, a link is where its folder should be.")
                continue
            }
            var result = symlinkat(link.target, fd, leaf)
            if result != 0 && errno == EEXIST && link.replace {
                var info = stat()
                if fstatat(fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFDIR {
                    unlinkat(fd, leaf, 0)
                    result = symlinkat(link.target, fd, leaf)
                }
            }
            if result == 0 {
                var times = [timespec(tv_sec: Int(link.modified), tv_nsec: 0), timespec(tv_sec: Int(link.modified), tv_nsec: 0)]
                utimensat(fd, leaf, &times, AT_SYMLINK_NOFOLLOW)
                state.withLock { s in
                    s.progress.files += 1
                    s.progress.current = link.path
                }
            } else {
                let code = errno
                let drive = destinationDrive?.name ?? "this drive"
                problem(link.path, code == ENOTSUP || code == EPERM
                        ? "Not copied: “\(drive)” (\(destinationDrive?.formatName ?? "")) can't hold symbolic links."
                        : "Couldn't make this link: \(Packer.message(code)).")
            }
            close(fd)
        }
        // Folders: empty ones are made now; then each gets its own permissions, attributes and
        // dates, deepest first (making things in a folder changed its date).
        for folder in folders where !isStopped { _ = ensureFolder(folder.path) }
        let ordered = folders.enumerated().sorted { a, b in
            let depthA = a.element.path.isEmpty ? 0 : a.element.path.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            let depthB = b.element.path.isEmpty ? 0 : b.element.path.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            return depthA != depthB ? depthA > depthB : a.offset < b.offset
        }
        for (_, folder) in ordered {
            guard !isStopped else { return }
            let fd = openFolder(folder.path)
            guard fd >= 0 else { continue }
            if plan.appleDoubleSource {
                if folder.appleDouble { applyAppleDouble(of: folder.source, to: fd) }
            } else {
                let input = open(folder.source, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if input >= 0 {
                    Self.copyAttributes(input, fd)
                    close(input)
                }
            }
            if folder.flags & UInt32(UF_HIDDEN) != 0 { fchflags(fd, UInt32(UF_HIDDEN)) }
            if !windowsFormat { fchmod(fd, mode_t(folder.mode & 0o1777)) }
            Self.setDates(fd, modified: folder.modified, created: folder.created)
            close(fd)
        }
    }
}

// MARK: - Jobs

/// One file to copy.
struct CopyJob: Sendable {
    /// Where it is.
    let source: String
    /// Where it goes, inside the copy.
    let path: String
    let size: Int64
    let mode: UInt32
    let modified: Int64
    let created: Int64
    let flags: UInt32
    let inode: UInt64
    /// A "._" file beside it holds its attributes (on an exFAT or FAT source).
    let appleDouble: Bool
    /// Something else is there by its name (an older version): replace it.
    let replace: Bool
    /// It's the first name met of a file with several: say where it went, for the others.
    var linkGroup: FileID?
}

/// Another name for a file already copied.
struct LinkJob: Sendable {
    let job: CopyJob
    let first: FileID
}

struct SymlinkJob: Sendable {
    let path: String
    let target: String
    let modified: Int64
    let replace: Bool
}

struct PipeJob: Sendable {
    let path: String
    let mode: UInt32
    let modified: Int64
    let replace: Bool
}

/// A folder's permissions, attributes and dates, set once everything is in it.
struct FolderJob: Sendable {
    let path: String
    let source: String
    let mode: UInt32
    let modified: Int64
    let created: Int64
    let flags: UInt32
    let appleDouble: Bool
}

/// Hands work from one thread to others, holding only so much at a time.
final class WorkQueue<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [Element] = []
    private var head = 0
    private var finished = false
    private var stopped = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Waits while the queue is full. False once everything has stopped.
    func push(_ item: Element) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while items.count - head >= limit && !stopped { condition.wait() }
        guard !stopped else { return false }
        items.append(item)
        condition.broadcast()
        return true
    }

    /// The next item, waiting for one if need be. Nil once all are handed out, or everything stopped.
    func pop() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while head == items.count && !finished && !stopped { condition.wait() }
        guard !stopped, head < items.count else { return nil }
        let item = items[head]
        head += 1
        if head > 1_024 && head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        condition.broadcast()
        return item
    }

    /// Everything has been handed in.
    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}
