import Foundation

// MARK: - What gets packed

/// One entry of the tar file.
struct PackItem: Sendable {
    var header: Tar.Header
    /// Where it is on disk.
    var diskPath: String
}

/// A file's identity on disk, to recognise one file under several names (hard links).
struct FileID: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// What to leave out of the tar file.
struct WalkRules: Sendable {
    private let names: Set<String>
    private let patterns: [String]
    /// The disk the folder is on. Folders of other disks mounted inside it are left out.
    let device: UInt64
    /// The tar file being written, in case it's inside the folder being packed.
    var output: FileID?
    /// Kinds of rebuildable folders (`Rebuildable` rule ids) to leave out, like `node_modules`.
    let skipRebuildable: Set<Int16>

    init(leaveOut: [String], device: UInt64, skipRebuildable: Set<Int16> = []) {
        var names = Set<String>()
        var patterns: [String] = []
        for item in leaveOut {
            if item.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                patterns.append(item)
            } else {
                names.insert(item)
            }
        }
        self.names = names
        self.patterns = patterns
        self.device = device
        self.skipRebuildable = skipRebuildable
    }

    func leavesOut(_ name: String) -> Bool {
        if names.contains(name) { return true }
        for pattern in patterns where fnmatch(pattern, name, 0) == 0 { return true }
        return false
    }

    /// The names and patterns typed in the window, separated by commas or new lines.
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Goes through a folder depth-first: each folder, then what's directly in it, then its subfolders.
enum TreeWalk {
    struct Folder: Sendable {
        let diskPath: String
        /// Its path inside the tar file, ending in "/".
        let archivePath: String
        let entry: FolderEntry
        /// The rebuildable kind (a `Rebuildable` rule id) it's in, or -1.
        var tag: Int16 = -1
        /// It's the folder that matched the rule (a `node_modules` itself, not one inside it).
        var tagRoot = false
    }

    enum Skip { case leftOut, rebuildable, cloudOnly, otherDisk, unsupported }

    /// `folder` and `entry` return false to stop the walk. Folders are classified as rebuildable
    /// (`Rebuildable.classify`) when `classify` is on.
    static func run(_ root: Folder, rules: WalkRules, classify: Bool = true, stopped: () -> Bool,
                    folder: (Folder) -> Bool,
                    entry: (FolderEntry, Folder) -> Bool,
                    skip: (Skip) -> Void,
                    problem: (String, Int32) -> Void) {
        // A drive that can't keep Mac attributes itself (exFAT, FAT) keeps them in a "._" file
        // beside each file that has some. Those aren't files of their own: they're left out, and
        // the file they belong to is marked (copying reads them for its attributes).
        let pairs = !Drive.keepsAttributes(root.diskPath)
        var stack = [root]
        while let current = stack.popLast() {
            if stopped() || !folder(current) { return }
            var subfolders: [Folder] = []
            var keepGoing = true
            var gathered: [FolderEntry] = []
            func take(_ entries: [FolderEntry]) -> Bool {
                for item in entries {
                    if rules.leavesOut(item.name) { skip(.leftOut); continue }
                    if let output = rules.output, output.inode == item.inode, output.device == item.device { continue }
                    // Reading it would download it, perhaps a lot of it.
                    if item.isDataless { skip(.cloudOnly); continue }
                    switch item.kind {
                    case .directory:
                        guard item.device == rules.device else { skip(.otherDisk); continue }
                        var tag = current.tag
                        var tagRoot = false
                        if tag < 0 && classify {
                            let found = Rebuildable.classify(parent: current.diskPath, name: item.name)
                            if found >= 0 {
                                if rules.skipRebuildable.contains(found) { skip(.rebuildable); continue }
                                tag = found
                                tagRoot = true
                            }
                        }
                        subfolders.append(Folder(diskPath: current.diskPath + "/" + item.name,
                                                 archivePath: current.archivePath + item.name + "/", entry: item,
                                                 tag: tag, tagRoot: tagRoot))
                    case .other:
                        skip(.unsupported)
                    case .file, .symlink, .fifo:
                        if !entry(item, current) {
                            keepGoing = false
                            return false
                        }
                    }
                }
                return true
            }
            let code = FolderReader.read(current.diskPath) { entries in
                // "._" files can come before or after their file: pair them once all are listed.
                if pairs {
                    gathered.append(contentsOf: entries)
                    return true
                }
                return take(entries)
            }
            if pairs && !gathered.isEmpty { _ = take(AppleDouble.pair(gathered)) }
            if !keepGoing { return }
            if code != 0 { problem(current.diskPath, code) }
            // Reversed, so they come off the stack in the order the folder lists them.
            stack.append(contentsOf: subfolders.reversed())
        }
    }
}

/// Something that couldn't be packed or unpacked, and why.
struct Problem: Sendable, Identifiable, Hashable {
    let id: Int
    let path: String
    let message: String
}

/// Where a tar stream goes other than a file: to another Mac, say. Blocks of the stream
/// (compressed as the method says) are framed on compression threads, then sent in order.
protocol PackStream: AnyObject, Sendable {
    /// Turns block number `index`, holding `count` bytes of the tar stream, into what's sent
    /// (encrypted, say). On compression threads, several at once.
    func frame(_ block: Data, holding count: Int, index: Int) -> Data?
    /// Sends a framed block. In order, one at a time. False if it can't (the connection dropped).
    func send(_ frame: Data) -> Bool
    /// Why sending failed, if it did.
    var failureMessage: String? { get }
}

/// Where packing puts the tar stream.
enum PackTarget: Sendable {
    /// A file. Replace one that's there only if the person said so (in the Save panel).
    case file(URL, replaceExisting: Bool)
    case stream(any PackStream)
}

// MARK: - Packing

/// Packs a folder into one uncompressed tar file, as fast as the disks allow.
///
/// Four things happen at once. A walker lists the folder (in bulk, see `FolderReader`) and hands
/// out batches of up to a thousand entries. For each batch, the packer works out where every header
/// and file goes in the tar file, then reads all the batch's files at the same time, one per CPU
/// core, straight into their places in memory. A writer writes the finished stretch to disk while
/// the packer fills the next one. And a counter, running ahead, adds up the whole folder for the
/// progress bar. Files over 8 MB skip the memory stretch and are copied a piece at a time, in order.
///
/// Nothing is compressed, and Mac-only metadata (extended attributes, Finder tags) isn't packed:
/// both would make it slower. The file is written as NAME.tar.part and renamed when it's complete.
final class Packer: @unchecked Sendable {
    struct Options: Sendable {
        /// Names (or patterns like `*.tmp`) of files and folders to leave out.
        var leaveOut: [String]
        /// How the tar file is compressed, if at all.
        var method: PackMethod = .plain
        /// Kinds of rebuildable folders to leave out (`Rebuildable` rule ids).
        var skipRebuildable: Set<Int16> = []
    }

    /// What a folder holds, as packing it sees it.
    struct Totals: Sendable, Equatable {
        /// Everything but folders: files, links and named pipes.
        var files: Int64 = 0
        var folders: Int64 = 0
        /// File data, counting a file with several names (hard links) once.
        var bytes: Int64 = 0
        /// About how big the tar file will be.
        var archiveBytes: Int64 = 0
    }

    struct Progress: Sendable {
        var started = Date()
        var files: Int64 = 0
        var folders: Int64 = 0
        var bytes: Int64 = 0
        /// Bytes of the tar stream so far, before any compression.
        var written: Int64 = 0
        /// Bytes of the file on the disk so far: fewer than `written` when compressing.
        var outputBytes: Int64 = 0
        /// Bytes of the tar stream that have reached the file, compressed or not: what the progress
        /// bar shows. (Compressing, `written` runs ahead by what's still being compressed.)
        var processed: Int64 = 0
        var current = ""
        /// What counting has found so far.
        var counted = Totals()
        /// Everything, once counting is done.
        var totals: Totals?
        var problemCount = 0
        /// Everything is packed; it's making sure it's all on the disk.
        var finishing = false
    }

    struct Summary: Sendable {
        /// The tar file (none for a stream).
        var output: URL?
        var method: PackMethod
        var files: Int64
        var folders: Int64
        var bytes: Int64
        /// The tar stream before compression, and the file it made.
        var tarBytes: Int64
        var archiveBytes: Int64
        var seconds: Double
        var leftOut: Int64
        /// Rebuildable folders left out (each with everything in it).
        var rebuildable: Int64
        var cloudOnly: Int64
        var otherDisks: Int64
        var unsupported: Int64
        var changed: Int64
        var problems: [Problem]
        var problemCount: Int
    }

    enum Outcome: Sendable {
        case finished(Summary)
        case stopped
        case failed(String)
    }

    struct PackError: Error, Sendable {
        let message: String
    }

    /// Files bigger than this are copied a piece at a time, in pieces this big.
    static let streamAbove: Int64 = 8 << 20
    static let streamChunk = 8 << 20
    /// A batch ends after this many entries, or this many bytes of file data.
    static let batchItems = 1_024
    static let batchBytes: Int64 = 32 << 20
    /// How many files are read at the same time: one per CPU core, up to 16.
    ///
    /// macOS keeps about 263,000 files open-able without going back to the disk (kern.maxvnodes);
    /// a folder of millions is always past that, so its files are read from the disk, and reading
    /// many at once hides the wait. On an M4 Max (16 cores), 300,000 small files took 13.3 s with 2
    /// readers, 9.3 s with 4, 6.2 s with 8 and 4.7 s with 16; 32 and 64 plain threads were slower
    /// again. (Re-packing a small folder that was just read, whose files are all still in memory,
    /// is fastest with about 4, but that takes under a second either way.)
    static let readers = min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 16)
    /// The most problems kept to show; all of them are counted.
    static let problemsKept = 1_000

    let source: URL
    let target: PackTarget
    let options: Options
    private let knownTotals: Totals?

    /// The tar file, when packing to one.
    var destination: URL? {
        if case .file(let url, _) = target { return url }
        return nil
    }

    /// Whether to replace a file already at `destination` (the person said Replace in the Save
    /// panel). If not, the tar file gets the next free name: "Folder 2.tar", and so on.
    private var replaceExisting: Bool {
        if case .file(_, let replace) = target { return replace }
        return false
    }

    private struct State {
        var progress = Progress()
        var stopped = false
        var done = false
        var failure: String?
        var leftOut: Int64 = 0
        var rebuildable: Int64 = 0
        var cloudOnly: Int64 = 0
        var otherDisks: Int64 = 0
        var unsupported: Int64 = 0
        var changed: Int64 = 0
        var problems: [Problem] = []
    }

    private let state = Locked(State())
    private let queue = BatchQueue(limit: 4)
    private let writer = DispatchQueue(label: "OneFile.writer", qos: .userInitiated)
    private let arenas = [Arena(), Arena()]
    /// For files copied a piece at a time, and the end of the tar file. Writer queue only.
    private let streamBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Packer.streamChunk)
    private var output: Int32 = -1
    /// Compresses the tar stream on its way to the file, unless the method is `.plain`.
    private var compressor: BlockCompressor?

    convenience init(source: URL, destination: URL, replaceExisting: Bool, options: Options, knownTotals: Totals? = nil) {
        self.init(source: source, target: .file(destination, replaceExisting: replaceExisting), options: options,
                  knownTotals: knownTotals)
    }

    init(source: URL, target: PackTarget, options: Options, knownTotals: Totals? = nil) {
        self.source = source
        self.target = target
        self.options = options
        self.knownTotals = knownTotals
    }

    deinit {
        streamBuffer.deallocate()
    }

    /// Starts packing on threads of its own; `completion` is called on one of them.
    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in
            completion(run())
        }
        thread.name = "OneFile packer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops packing. The unfinished file is deleted, and `start`'s completion gets `.stopped`.
    func cancel() {
        state.withLock { $0.stopped = true }
        queue.stop()
    }

    func progress() -> Progress {
        state.withLock { $0.progress }
    }

    /// The unfinished file, named NAME.tar.part, next to where the finished one goes.
    var partPath: String? { destination.map { $0.path + ".part" } }

    /// Makes sure reading a file that's only in iCloud fails rather than downloading it. For the
    /// whole app: OneFile never wants to download anything.
    static func stopDownloadingCloudFiles() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    // MARK: The packing thread

    private func run() -> Outcome {
        let started = Date()
        let root: TreeWalk.Folder
        switch Self.root(for: source) {
        case .success(let folder): root = folder
        case .failure(let error): return .failed(error.message)
        }

        var rules = WalkRules(leaveOut: options.leaveOut, device: root.entry.device,
                              skipRebuildable: options.skipRebuildable)
        var folderPath: String?
        switch target {
        case .file(let destination, _):
            folderPath = destination.deletingLastPathComponent().path
            output = open(destination.path + ".part", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard output >= 0 else {
                let place = destination.deletingLastPathComponent().lastPathComponent
                return .failed("Couldn't save in “\(place)”: \(Self.message(errno)).")
            }
            var outputInfo = stat()
            fstat(output, &outputInfo)
            rules.output = FileID(device: FolderEntry.device(outputInfo.st_dev), inode: UInt64(outputInfo.st_ino))
            if options.method != .plain {
                compressor = BlockCompressor(method: options.method) { [unowned self] bytes, input in
                    guard writeOut(bytes) else { return false }
                    state.withLock { $0.progress.processed += Int64(input) }
                    return true
                }
            }
        case .stream(let stream):
            // Even uncompressed, a stream goes in blocks: each is encrypted on its own, on every core.
            compressor = BlockCompressor(method: options.method,
                                         blockSize: options.method == .plain ? 4 << 20 : options.method.blockSize,
                                         frame: { stream.frame($0, holding: $1, index: $2) }) { [unowned self] frame, input in
                guard stream.send(frame) else {
                    fail(stream.failureMessage ?? "The connection was lost.")
                    return false
                }
                state.withLock {
                    $0.progress.processed += Int64(input)
                    $0.progress.outputBytes += Int64(frame.count)
                }
                return true
            }
        }
        let part = partPath
        let roomFolder = folderPath

        if let knownTotals {
            state.withLock { $0.progress.counted = knownTotals; $0.progress.totals = knownTotals }
            if let roomFolder { checkRoom(for: knownTotals, in: roomFolder) }
        } else {
            let walkRules = rules
            let counter = Thread { [self] in
                let counted = Self.count(root, rules: walkRules, stopped: { self.isOver }, progress: { partial in
                    self.state.withLock { $0.progress.counted = partial }
                })
                guard let totals = counted?.totals else { return }
                state.withLock { $0.progress.counted = totals; $0.progress.totals = totals }
                if let roomFolder { checkRoom(for: totals, in: roomFolder) }
            }
            counter.name = "OneFile counter"
            counter.qualityOfService = .utility
            counter.start()
        }

        let walkRules = rules
        let walker = Thread { [self] in walk(root, walkRules) }
        walker.name = "OneFile walker"
        walker.qualityOfService = .userInitiated
        walker.start()

        packBatches()
        writer.sync {}

        if state.withLock({ $0.stopped || $0.failure != nil }) {
            return giveUp(part)
        }

        // The end of the tar file, then make sure it's all on the disk before calling it done.
        state.withLock { $0.progress.finishing = true }
        let trailer = Int(Tar.trailerBytes(after: state.withLock { $0.progress.written }))
        let buffer = SharedPointer(streamBuffer)
        let ended = writer.sync { () -> Bool in
            buffer.pointer.initialize(repeating: 0, count: trailer)
            guard write(buffer.pointer, trailer) else { return false }
            if let compressor, !compressor.finish() {
                fail(compressor.failureMessage ?? "Couldn't write the file.")
                return false
            }
            return true
        }
        if ended && output >= 0 && fsync(output) != 0 {
            fail("Couldn't save the file: \(Self.message(errno)).")
        }
        if state.withLock({ $0.failure != nil }) {
            return giveUp(part)
        }
        var saved: URL?
        if let part, let destination {
            close(output)
            output = -1
            saved = moveIntoPlace(part, destination)
            guard saved != nil else {
                let code = errno
                unlink(part)
                finish()
                return .failed("Couldn't name the file “\(destination.lastPathComponent)”: \(Self.message(code)).")
            }
        }
        finish()
        let seconds = Date().timeIntervalSince(started)
        return state.withLock { s in
            .finished(Summary(
                output: saved, method: options.method, files: s.progress.files, folders: s.progress.folders,
                bytes: s.progress.bytes, tarBytes: s.progress.written, archiveBytes: s.progress.outputBytes,
                seconds: seconds, leftOut: s.leftOut, rebuildable: s.rebuildable, cloudOnly: s.cloudOnly,
                otherDisks: s.otherDisks, unsupported: s.unsupported, changed: s.changed, problems: s.problems,
                problemCount: s.progress.problemCount))
        }
    }

    /// After stopping or failing: deletes the unfinished file.
    private func giveUp(_ part: String?) -> Outcome {
        // Nothing may write to the file once it's closed: let compression threads finish first.
        compressor?.abandon()
        if output >= 0 {
            close(output)
            output = -1
        }
        if let part { unlink(part) }
        let failure = state.withLock { $0.failure }
        finish()
        return failure.map { .failed($0) } ?? .stopped
    }

    /// Ends the threads still going (the counter, say) once the outcome is decided.
    private func finish() {
        state.withLock { $0.done = true }
        queue.stop()
    }

    private func moveIntoPlace(_ part: String, _ destination: URL) -> URL? {
        if replaceExisting {
            return rename(part, destination.path) == 0 ? destination : nil
        }
        var candidate = destination
        var number = 2
        // RENAME_EXCL: never replace a file that turned up there in the meantime.
        while renamex_np(part, candidate.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { return nil }
            candidate = ArchiveName.numbered(destination, number)
            number += 1
        }
        return candidate
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
        if first { queue.stop() }
    }

    private func problem(_ path: String, _ message: String) {
        state.withLock { s in
            s.progress.problemCount += 1
            if s.problems.count < Self.problemsKept {
                s.problems.append(Problem(id: s.problems.count, path: path, message: message))
            }
        }
    }

    // MARK: The walker thread

    private func walk(_ root: TreeWalk.Folder, _ rules: WalkRules) {
        var batch: [PackItem] = []
        batch.reserveCapacity(Self.batchItems)
        var batchBytes: Int64 = 0
        var firstNames: [FileID: String] = [:]
        var leftOut: Int64 = 0, rebuildable: Int64 = 0, cloudOnly: Int64 = 0, otherDisks: Int64 = 0, unsupported: Int64 = 0

        func add(_ item: PackItem) -> Bool {
            batch.append(item)
            if item.header.type == .file { batchBytes += item.header.size }
            guard batch.count >= Self.batchItems || batchBytes >= Self.batchBytes else { return true }
            let full = batch
            batch = []
            batch.reserveCapacity(Self.batchItems)
            batchBytes = 0
            return queue.push(full)
        }

        TreeWalk.run(root, rules: rules, stopped: { isStopped },
            folder: { folder in
                let entry = folder.entry
                return add(PackItem(
                    header: Tar.Header(path: folder.archivePath, type: .directory, size: 0, mode: entry.permissions,
                                       owner: entry.owner, group: entry.group, modified: entry.modified, linkTarget: ""),
                    diskPath: folder.diskPath))
            },
            entry: { entry, folder in
                let diskPath = folder.diskPath + "/" + entry.name
                var header = Tar.Header(path: folder.archivePath + entry.name, type: .file, size: 0,
                                        mode: entry.permissions, owner: entry.owner, group: entry.group,
                                        modified: entry.modified, linkTarget: "")
                switch entry.kind {
                case .file:
                    if entry.links > 1 {
                        // A file with several names: its data goes in once, under the first name met.
                        let id = FileID(device: entry.device, inode: entry.inode)
                        if let first = firstNames[id] {
                            header.type = .hardLink
                            header.linkTarget = first
                            return add(PackItem(header: header, diskPath: diskPath))
                        }
                        firstNames[id] = header.path
                    }
                    header.size = entry.size
                case .symlink:
                    guard let target = Self.linkTarget(diskPath) else {
                        problem(diskPath, "Couldn't read where this link points: \(Self.message(errno)).")
                        return true
                    }
                    header.type = .symbolicLink
                    header.linkTarget = target
                case .fifo:
                    header.type = .fifo
                case .directory, .other:
                    return true
                }
                return add(PackItem(header: header, diskPath: diskPath))
            },
            skip: { reason in
                switch reason {
                case .leftOut: leftOut += 1
                case .rebuildable: rebuildable += 1
                case .cloudOnly: cloudOnly += 1
                case .otherDisk: otherDisks += 1
                case .unsupported: unsupported += 1
                }
            },
            problem: { path, code in
                problem(path, "Couldn't read this folder: \(Self.message(code)).")
            })
        if !batch.isEmpty, !isStopped { _ = queue.push(batch) }
        state.withLock { s in
            s.leftOut = leftOut
            s.rebuildable = rebuildable
            s.cloudOnly = cloudOnly
            s.otherDisks = otherDisks
            s.unsupported = unsupported
        }
        queue.finish()
    }

    static func linkTarget(_ path: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                readlink(path, $0, buffer.count - 1)
            }
        }
        guard count >= 0 else { return nil }
        return String(decoding: bytes[0..<count], as: UTF8.self)
    }

    // MARK: The packing thread: batches

    private func packBatches() {
        var failedFiles = Set<String>()
        var turn = 0
        while let batch = queue.pop() {
            if isStopped { break }
            var start = batch.startIndex
            for index in batch.indices {
                let header = batch[index].header
                guard header.type == .file, header.size > Self.streamAbove else { continue }
                if start < index {
                    fill(batch[start..<index], arena: arenas[turn], failedFiles: &failedFiles)
                    turn ^= 1
                }
                stream(batch[index], failedFiles: &failedFiles)
                start = index + 1
            }
            if start < batch.endIndex {
                fill(batch[start...], arena: arenas[turn], failedFiles: &failedFiles)
                turn ^= 1
            }
        }
    }

    enum ReadOutcome: Sendable {
        case ok
        /// It's a different size than when the folder was listed (zeros fill in for a shorter file).
        case changed
        case failed(Int32)
    }

    private struct BatchCounts: Sendable {
        var files: Int64 = 0
        var folders: Int64 = 0
        var bytes: Int64 = 0
        var changed: Int64 = 0
        var current = ""
    }

    /// Lays out the items' stretch of the tar file in `arena`, reads their files into it all at
    /// once, and has the writer write it.
    private func fill(_ items: ArraySlice<PackItem>, arena: Arena, failedFiles: inout Set<String>) {
        let count = items.count
        var offsets: [Int] = []
        offsets.reserveCapacity(count + 1)
        var extended: [[UInt8]?] = []
        extended.reserveCapacity(count)
        var total = 0
        for item in items {
            offsets.append(total)
            let records = Tar.extendedRecords(for: item.header)
            extended.append(records)
            total += Tar.headerBytes(extended: records)
            if item.header.type == .file { total += Int(Tar.padded(item.header.size)) }
        }
        offsets.append(total)

        // Wait until the writer is done with what this arena held before.
        arena.free.wait()
        guard !isStopped else {
            arena.free.signal()
            return
        }
        arena.reserve(total)
        let base = SharedPointer(arena.pointer)
        let results = SharedPointer(UnsafeMutablePointer<ReadOutcome>.allocate(capacity: count))
        results.pointer.initialize(repeating: .ok, count: count)
        defer {
            results.pointer.deinitialize(count: count)
            results.pointer.deallocate()
        }
        let first = items.startIndex
        let layout = offsets
        let records = extended
        let workers = min(Self.readers, count)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var index = worker
            while index < count {
                let item = items[first + index]
                let at = base.pointer + layout[index]
                let headerLength = Tar.write(item.header, extended: records[index], to: at)
                if item.header.type == .file {
                    results.pointer[index] = Packer.read(item.diskPath, size: item.header.size, into: at + headerLength)
                }
                index += workers
            }
        }

        // In order: what goes out, and what went wrong.
        var runs: [Range<Int>] = []
        var counts = BatchCounts()
        for index in 0..<count {
            let item = items[first + index]
            switch results.pointer[index] {
            case .failed(let code):
                failedFiles.insert(item.header.path)
                problem(item.diskPath, "Couldn't read this file: \(Self.message(code)).")
                continue
            case .changed:
                counts.changed += 1
            case .ok:
                break
            }
            if item.header.type == .hardLink, failedFiles.contains(item.header.linkTarget) {
                problem(item.diskPath, "Left out: it's another name for a file that couldn't be read.")
                continue
            }
            let range = layout[index]..<layout[index + 1]
            if let last = runs.last, last.upperBound == range.lowerBound {
                runs[runs.count - 1] = last.lowerBound..<range.upperBound
            } else {
                runs.append(range)
            }
            switch item.header.type {
            case .directory: counts.folders += 1
            case .file: counts.files += 1; counts.bytes += item.header.size
            default: counts.files += 1
            }
            counts.current = item.header.path
        }

        let stretches = runs
        let done = counts
        writer.async { [self] in
            defer { arena.free.signal() }
            for run in stretches {
                guard write(base.pointer + run.lowerBound, run.count) else { return }
            }
            state.withLock { s in
                s.progress.files += done.files
                s.progress.folders += done.folders
                s.progress.bytes += done.bytes
                s.changed += done.changed
                if !done.current.isEmpty { s.progress.current = done.current }
            }
        }
    }

    /// Reads a whole file into `buffer`, followed by the zeros that pad it to whole blocks.
    static func read(_ path: String, size: Int64, into buffer: UnsafeMutablePointer<UInt8>) -> ReadOutcome {
        let wanted = Int(size)
        guard wanted > 0 else { return .ok }
        let room = Int(Tar.padded(size))
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return .failed(errno) }
        defer { close(file) }
        // Ask for a byte more than expected when the padding has room for it, to notice a file
        // that grew since the folder was listed.
        let ask = min(wanted + 1, room)
        var done = 0
        while done < wanted {
            let count = Darwin.read(file, buffer + done, ask - done)
            if count > 0 { done += count; continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return .failed(errno)
        }
        if done < wanted {
            (buffer + done).initialize(repeating: 0, count: wanted - done)
        }
        (buffer + wanted).initialize(repeating: 0, count: room - wanted)
        return done == wanted ? .ok : .changed
    }

    /// Has the writer copy a big file into the tar file a piece at a time.
    private func stream(_ item: PackItem, failedFiles: inout Set<String>) {
        let file = open(item.diskPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            failedFiles.insert(item.header.path)
            problem(item.diskPath, "Couldn't read this file: \(Self.message(errno)).")
            return
        }
        let header = item.header
        let records = Tar.extendedRecords(for: header)
        let buffer = SharedPointer(streamBuffer)
        let diskPath = item.diskPath
        writer.async { [self] in
            defer { close(file) }
            guard !isStopped else { return }
            let headerLength = Tar.write(header, extended: records, to: buffer.pointer)
            guard write(buffer.pointer, headerLength) else { return }
            var remaining = header.size
            var ended = false
            var readError: Int32 = 0
            while remaining > 0 {
                guard !isStopped else { return }
                let chunk = Int(min(remaining, Int64(Self.streamChunk)))
                var got = 0
                while !ended && got < chunk {
                    let count = Darwin.read(file, buffer.pointer + got, chunk - got)
                    if count > 0 {
                        got += count
                    } else if count == 0 {
                        ended = true
                    } else if errno != EINTR {
                        readError = errno
                        ended = true
                    }
                }
                // A file that got shorter, or couldn't be read to the end: zeros fill in.
                if got < chunk { (buffer.pointer + got).initialize(repeating: 0, count: chunk - got) }
                guard write(buffer.pointer, chunk) else { return }
                remaining -= Int64(chunk)
                state.withLock { $0.progress.bytes += Int64(chunk) }
            }
            let padding = Int(Tar.padded(header.size) - header.size)
            if padding > 0 {
                buffer.pointer.initialize(repeating: 0, count: padding)
                guard write(buffer.pointer, padding) else { return }
            }
            state.withLock { s in
                s.progress.files += 1
                s.progress.current = header.path
                if ended && readError == 0 { s.changed += 1 }
            }
            if readError != 0 {
                problem(diskPath, "Couldn't read all of this file (\(Self.message(readError))); zeros fill in for the rest.")
            }
        }
    }

    /// Adds bytes to the tar stream: through the compressor when there is one, else straight to
    /// the file. Writer queue only.
    private func write(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        if let compressor {
            guard compressor.append(bytes, count) else {
                fail(compressor.failureMessage ?? "Couldn't write the file.")
                return false
            }
            state.withLock { $0.progress.written += Int64(count) }
        } else {
            guard writeOut(UnsafeRawBufferPointer(start: bytes, count: count)) else { return false }
            state.withLock { $0.progress.written += Int64(count); $0.progress.processed += Int64(count) }
        }
        return true
    }

    private func writeOut(_ data: Data) -> Bool {
        data.withUnsafeBytes { writeOut($0) }
    }

    /// Writes bytes to the file itself. On the writer queue, or a compression thread (one at a time).
    private func writeOut(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var done = 0
        while done < bytes.count {
            let written = Darwin.write(output, base + done, bytes.count - done)
            if written > 0 { done += written; continue }
            if written < 0 && errno == EINTR { continue }
            let code = errno
            switch code {
            case ENOSPC:
                fail("The disk is full: there's no room for the rest of the file.")
            case EFBIG:
                fail("The file grew past the biggest this disk can hold (4 GB on a FAT32 drive). Pick another place, or format the drive as exFAT.")
            default:
                fail("Couldn't write the file: \(Self.message(code)).")
            }
            return false
        }
        state.withLock { $0.progress.outputBytes += Int64(bytes.count) }
        return true
    }

    // MARK: Counting

    /// What counting a folder finds.
    struct CountResult: Sendable {
        var totals: Totals
        /// A few dozen files picked at random, bigger ones more often (every byte of data equally
        /// likely), to see how well the folder compresses.
        var samples: [SampleFile]
        /// What kinds of files, and how much of it could be rebuilt.
        var insights: FolderInsights
    }

    struct SampleFile: Sendable {
        let path: String
        let size: Int64
    }

    /// Adds up what packing `root` puts in the tar file. Calls `progress` now and then with the
    /// count so far. Nil if stopped.
    static func count(_ root: TreeWalk.Folder, rules: WalkRules, stopped: () -> Bool,
                      progress: (Totals) -> Void) -> CountResult? {
        var totals = Totals()
        var insights = FolderInsights()
        var seen = Set<FileID>()
        var sinceReport = 0
        var sampler = Sampler(capacity: 48)
        TreeWalk.run(root, rules: rules, stopped: stopped,
            folder: { folder in
                totals.folders += 1
                totals.archiveBytes += headerEstimate(folder.archivePath.utf8.count, ascii: isASCII(folder.entry.name))
                if folder.tagRoot { insights.rebuildable[Int(folder.tag)].folders += 1 }
                return true
            },
            entry: { entry, folder in
                totals.files += 1
                totals.archiveBytes += headerEstimate(folder.archivePath.utf8.count + entry.name.utf8.count,
                                                      ascii: isASCII(entry.name))
                if folder.tag >= 0 { insights.rebuildable[Int(folder.tag)].files += 1 }
                if entry.kind == .file {
                    let anotherName = entry.links > 1
                        && !seen.insert(FileID(device: entry.device, inode: entry.inode)).inserted
                    if !anotherName {
                        totals.bytes += entry.size
                        totals.archiveBytes += Tar.padded(entry.size)
                        insights.kinds.add(entry.name, size: entry.size)
                        insights.allocate(entry.size)
                        insights.largest = max(insights.largest, entry.size)
                        if folder.tag >= 0 { insights.rebuildable[Int(folder.tag)].bytes += entry.size }
                        if entry.size > 0 {
                            let key = sampler.key(for: entry.size)
                            if key < sampler.threshold {
                                sampler.insert(key, SampleFile(path: folder.diskPath + "/" + entry.name, size: entry.size))
                            }
                        }
                    }
                }
                sinceReport += 1
                if sinceReport == 10_000 {
                    sinceReport = 0
                    progress(totals)
                }
                return true
            },
            skip: { _ in },
            problem: { _, _ in })
        if stopped() { return nil }
        totals.archiveBytes += Tar.trailerBytes(after: totals.archiveBytes)
        return CountResult(totals: totals, samples: sampler.files, insights: insights)
    }

    private static func headerEstimate(_ pathLength: Int, ascii: Bool) -> Int64 {
        ascii && pathLength <= 100 ? 512 : 1_536
    }

    private static func isASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }

    /// Stops early, with a reason, when the tar file can't fit where it's going.
    private func checkRoom(for totals: Totals, in folder: String) {
        // Compressed, the size isn't known until it's done: a full disk is reported when it happens.
        guard options.method == .plain, !state.withLock({ $0.progress.finishing }) else { return }
        let volume = Self.volumeName(folder)
        if Self.isFAT(folder) && totals.archiveBytes >= 4 << 30 {
            fail("“\(volume)” is formatted as FAT32, which can't hold a file of 4 GB or more, and this one will be about \(Format.bytes(totals.archiveBytes)). Pick another place, or reformat the drive as exFAT.")
            return
        }
        guard let free = Self.freeSpace(folder) else { return }
        let needed = totals.archiveBytes - state.withLock { $0.progress.written }
        if needed > free {
            fail("There isn't room on “\(volume)”: the file needs about \(Format.bytes(needed)) more, and \(Format.bytes(free)) is free.")
        }
    }

    // MARK: Helpers

    /// The folder to pack, checked: it's there, it's a folder, it can be read, and it's on this Mac.
    static func root(for url: URL) -> Result<TreeWalk.Folder, PackError> {
        let path = url.path
        let name = url.lastPathComponent
        guard path != "/" else {
            return .failure(PackError(message: "Pick a folder rather than the whole startup disk."))
        }
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .failure(PackError(message: "Couldn't find “\(name)”: \(message(errno))."))
        }
        let entry = FolderEntry(name: name, info)
        guard entry.kind == .directory else {
            return .failure(PackError(message: "“\(name)” isn't a folder."))
        }
        guard !entry.isDataless else {
            return .failure(PackError(message: "“\(name)” is only in iCloud. Download it first (in Finder, Control-click it and choose Download Now)."))
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == EPERM {
                return .failure(PackError(message: "macOS didn't let OneFile read “\(name)”. To allow it, turn on OneFile in System Settings › Privacy & Security › Full Disk Access."))
            }
            return .failure(PackError(message: "Couldn't read “\(name)”: \(message(code))."))
        }
        close(fd)
        return .success(TreeWalk.Folder(diskPath: path, archivePath: name + "/", entry: entry))
    }

    static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    static func isFAT(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return type == "msdos"
    }

    static func freeSpace(_ path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free > 0 {
            return free
        }
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    static func volumeName(_ path: String) -> String {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? path
    }
}

// MARK: - Plumbing

/// Memory a stretch of the tar file is put together in. Two take turns: one is filled while the
/// other is written.
private final class Arena: @unchecked Sendable {
    private(set) var pointer: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    /// Signalled when the writer is done with what the arena holds.
    let free = DispatchSemaphore(value: 1)

    init(capacity: Int = 48 << 20) {
        self.capacity = capacity
        pointer = .allocate(capacity: capacity)
    }

    func reserve(_ count: Int) {
        guard count > capacity else { return }
        pointer.deallocate()
        capacity = max(count, capacity * 2)
        pointer = .allocate(capacity: capacity)
    }

    deinit {
        pointer.deallocate()
    }
}

/// A pointer handed to other threads, each using its own part of the memory.
struct SharedPointer<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
    init(_ pointer: UnsafeMutablePointer<T>) { self.pointer = pointer }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Hands batches from the walker to the packer, holding only a few, so the walker can't run far
/// ahead and fill memory.
final class BatchQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var batches: [[PackItem]] = []
    private var finished = false
    private var stopped = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Waits while the queue is full. False once everything has stopped.
    func push(_ batch: [PackItem]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while batches.count >= limit && !stopped { condition.wait() }
        guard !stopped else { return false }
        batches.append(batch)
        condition.broadcast()
        return true
    }

    /// The next batch, waiting for it if need be. Nil once the walker is done, or everything stopped.
    func pop() -> [PackItem]? {
        condition.lock()
        defer { condition.unlock() }
        while batches.isEmpty && !finished && !stopped { condition.wait() }
        guard !stopped, !batches.isEmpty else { return nil }
        let batch = batches.removeFirst()
        condition.broadcast()
        return batch
    }

    /// The walker has handed out everything.
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

/// Keeps a fixed number of files, picked at random as the folder is walked, a file's chance
/// growing with its size: each keeps the smallest of the random keys -ln(u) / size (the
/// Efraimidis–Spirakis method), so every byte of data is equally likely to be in the sample.
struct Sampler {
    let capacity: Int
    private var items: [(key: Double, file: Packer.SampleFile)] = []
    private var worst = 0
    private var random = SplitMix64(state: 0x5EED_0F0E_F11E_0001)

    init(capacity: Int) { self.capacity = capacity }

    mutating func key(for size: Int64) -> Double {
        let unit = Double(random.next() >> 11) * 0x1.0p-53
        return -log(1 - unit) / Double(size)
    }

    /// Keys at or above this lose.
    var threshold: Double { items.count < capacity ? .infinity : items[worst].key }

    mutating func insert(_ key: Double, _ file: Packer.SampleFile) {
        if items.count < capacity {
            items.append((key, file))
        } else {
            items[worst] = (key, file)
        }
        if items.count == capacity {
            worst = items.indices.max { items[$0].key < items[$1].key } ?? 0
        }
    }

    var files: [Packer.SampleFile] { items.map(\.file) }
}

/// A small, fast random number generator (SplitMix64), good enough for sampling.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Set once, read from any thread.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
