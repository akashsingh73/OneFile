import Foundation

// MARK: - Reading tar headers

enum TarHeader {
    static func checksumOK(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 512 else { return false }
        return bytes.withUnsafeBufferPointer { checksumOK($0.baseAddress!) }
    }

    /// The header's checksum adds up (as unsigned bytes, or as signed, which some old tars used).
    static func checksumOK(_ h: UnsafePointer<UInt8>) -> Bool {
        guard let stored = number(h + 148, 8) else { return false }
        var unsigned: Int64 = 0
        var signed: Int64 = 0
        for index in 0..<512 {
            let byte = index >= 148 && index < 156 ? 0x20 : h[index]
            unsigned += Int64(byte)
            signed += Int64(Int8(bitPattern: byte))
        }
        return stored == unsigned || stored == signed
    }

    static func isZero(_ h: UnsafePointer<UInt8>) -> Bool {
        let raw = UnsafeRawPointer(h)
        for word in 0..<64 where raw.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) != 0 { return false }
        return true
    }

    /// A numeric field: octal digits (with spaces or NULs around them), or for big numbers GNU's
    /// base-256, flagged by the first byte's top bit.
    static func number(_ field: UnsafePointer<UInt8>, _ length: Int) -> Int64? {
        if field[0] & 0x80 != 0 {
            var value: Int64 = field[0] == 0xFF ? -1 : Int64(field[0] & 0x7F)
            for index in 1..<length {
                guard value >> 55 == 0 || value >> 55 == -1 else { return nil }
                value = value << 8 | Int64(field[index])
            }
            return value
        }
        var index = 0
        while index < length && (field[index] == 0x20 || field[index] == 0) { index += 1 }
        var value: Int64 = 0
        while index < length, field[index] >= 0x30, field[index] <= 0x37 {
            guard value <= Int64.max >> 3 else { return nil }
            value = value << 3 | Int64(field[index] - 0x30)
            index += 1
        }
        if index < length && field[index] != 0x20 && field[index] != 0 { return nil }
        return value
    }

    /// A text field, up to its first NUL.
    static func string(_ field: UnsafePointer<UInt8>, _ length: Int) -> String {
        var end = 0
        while end < length && field[end] != 0 { end += 1 }
        return String(decoding: UnsafeBufferPointer(start: field, count: end), as: UTF8.self)
    }

    /// The entry's path: the name, after the prefix field in POSIX ustar headers.
    static func path(_ h: UnsafePointer<UInt8>) -> String {
        let name = string(h, 100)
        // "ustar\0": POSIX, with a prefix field. (GNU's "ustar  " uses that space for other things.)
        if h[257] == 0x75, h[258] == 0x73, h[259] == 0x74, h[260] == 0x61, h[261] == 0x72, h[262] == 0, h[345] != 0 {
            return string(h + 345, 155) + "/" + name
        }
        return name
    }
}

// MARK: - Unpacking

/// Unpacks a tar file (plain, gzip or xz), or a tar stream arriving from another Mac, into a new
/// folder, as fast as the disk allows; or, with no destination, only looks inside (counts what's
/// there and checks every byte decompresses).
///
/// Decompressing runs ahead on other threads (on every core for OneFile's own files: see
/// `ArchiveDecoder`) while the entries are worked through. Folders are made as they come. Files
/// are collected into batches of up to a thousand, straight from the decompressed data, and each
/// batch is written by four threads at once while the next one is read: APFS makes files fastest
/// from about four threads (on an M4 Max, 54,000 small files a second, against 20,000 from one, and
/// slower again from eight). Files over 8 MB are written as they arrive. Links, and folders'
/// permissions and dates, come last, once everything else is there.
///
/// It all goes into a new folder, "NAME (unpacking)", made next to where it ends up. Only once it's
/// complete does it get its real name: the archive's one top folder, or a folder named after the
/// archive, under a name that isn't taken. So nothing on the disk is ever replaced, and stopping
/// deletes the unfinished folder. Nothing is written outside it either: paths with "..", and links
/// pointing elsewhere, can't lead out (every file is opened with `O_NOFOLLOW_ANY`, and symbolic
/// links are made last).
final class Unpacker: @unchecked Sendable {
    enum Source: Sendable {
        case file(URL)
        /// A tar stream, already decompressed (from another Mac), with the name it goes by.
        case stream(OrderedPipeline, name: String)
    }

    struct Progress: Sendable {
        var started = Date()
        /// Entries read from the tar stream.
        var entries: Int64 = 0
        /// Files, links and pipes made (counted, when only looking).
        var files: Int64 = 0
        var folders: Int64 = 0
        /// File data written.
        var bytes: Int64 = 0
        /// Of the input: the archive file, or the stream.
        var processed: Int64 = 0
        var total: Int64?
        var current = ""
        var problemCount = 0
        /// Everything's unpacked: making links and setting folders' dates.
        var finishing = false
        /// Stopped: deleting the unfinished folder.
        var cleaning = false
    }

    struct Summary: Sendable {
        /// Where it went (none when only looking).
        var output: URL?
        var format: ArchiveFormat?
        /// It decompressed on several cores.
        var parallel: Bool
        var files: Int64
        var folders: Int64
        var links: Int64
        var bytes: Int64
        var tarBytes: Int64
        var seconds: Double
        /// The first few names at the top of the tar file, how many there are, and whether there's
        /// one and it's a folder.
        var topNames: [String]
        var topCount: Int
        var topIsFolder: Bool
        /// What kinds of files (only when looking).
        var kinds: KindTotals
        /// Mac metadata files ("._name", from macOS's own tar) left out.
        var macMetadata: Int64
        /// Entries refused: their paths led outside the folder.
        var refused: Int64
        var problems: [Problem]
        var problemCount: Int
        /// Not a tar file: one compressed file (notes.txt.gz), unpacked as itself.
        var single: Bool
    }

    enum Outcome: Sendable {
        case finished(Summary)
        case stopped
        case failed(String)
    }

    /// Threads writing files at once.
    static let writers = 4
    /// Files bigger than this are written as they arrive, rather than in a batch.
    static let bigFile: Int64 = 8 << 20
    static let batchItems = 1_024
    static let batchBytes = 32 << 20
    static let problemsKept = 1_000
    /// The process's umask, read once (reading it means setting it, briefly).
    static let umaskBits: UInt32 = {
        let mask = umask(0o022)
        umask(mask)
        return UInt32(mask)
    }()

    static let diskFull = "The disk is full: there's no room for the rest. What was unpacked has been deleted."

    let source: Source
    /// The folder the new folder goes in; nil only looks inside.
    let destination: URL?
    /// What the new folder is called if the tar file has several things at its top.
    let baseName: String
    private var looking: Bool { destination == nil }

    private struct State {
        var progress = Progress()
        var stopped = false
        var done = false
        var failure: String?
        var problems: [Problem] = []
        var pipeline: OrderedPipeline?
    }

    private let state = Locked(State())
    /// Batches are written one after another, each by `writers` threads.
    private let creator = DispatchQueue(label: "OneFile.creator", qos: Work.dispatchQoS)
    /// Pausing waits here, between pieces of the stream and between batches of files.
    private let gate = PauseGate()
    /// Batches handed to the creator and not yet written: one being written, one waiting.
    private let batchSlots = DispatchSemaphore(value: 2)

    // The unpacking thread's own.
    private var root: Int32 = -1
    private var staging: String?
    private var compressed = false
    private var phase = Phase.header
    private var header = [UInt8](repeating: 0, count: 512)
    private var headerFill = 0
    private var meta: [UInt8] = []
    private var pendingPath: String?
    private var pendingLink: String?
    private var pendingSize: Int64?
    private var pendingTime: timespec?
    private var pendingSparse = false
    private var job: FileJob?
    private var big: (path: String, mode: UInt32, mtime: timespec, ok: Bool)?
    private var batch = Batch()
    private var knownFolders: Set<String> = [""]
    private var folderAttributes: [FolderAttributes] = []
    private var hardLinks: [(path: String, target: String)] = []
    private var symbolicLinks: [(path: String, target: String, mtime: timespec)] = []
    private var pipes: [(path: String, mode: UInt32, mtime: timespec)] = []
    private var entriesSeen: Int64 = 0
    private var position: Int64 = 0
    private var topNames: [String] = []
    private var topSet = Set<String>()
    private var lastTop = ""
    private var topIsFolder = false
    private var counted = (files: Int64(0), folders: Int64(0), links: Int64(0), bytes: Int64(0))
    private var madeFolders: Int64 = 0
    private var madeLinks: Int64 = 0
    private var kinds = KindTotals()
    private var macMetadata: Int64 = 0
    private var refused: Int64 = 0
    private var singleBytes: Int64 = 0
    private var single = false

    private enum Phase {
        case header
        case meta(MetaKind, remaining: Int64, padding: Int64)
        case file(remaining: Int64, padding: Int64)
        case big(fd: Int32, remaining: Int64, padding: Int64)
        case skip(Int64)
        case single(fd: Int32)
        case ended
    }

    private enum MetaKind { case pax, globalPax, longName, longLink }

    private struct FolderAttributes {
        let path: String
        let depth: Int
        let mode: UInt32
        let mtime: timespec
    }

    /// For an archive locked with a password.
    let password: String?

    init(source: Source, destination: URL?, password: String? = nil) {
        self.source = source
        self.destination = destination
        self.password = password
        switch source {
        case .file(let url): baseName = ArchiveName.unpackedName(url.lastPathComponent)
        case .stream(_, let name): baseName = name
        }
    }

    /// Starts on threads of its own; `completion` is called on one of them.
    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in
            completion(run())
        }
        thread.name = looking ? "OneFile inspector" : "OneFile unpacker"
        thread.qualityOfService = looking ? .utility : Work.qos
        thread.start()
    }

    /// Stops. What was unpacked is deleted, and `start`'s completion gets `.stopped`.
    func cancel() {
        let pipeline = state.withLock { s -> OrderedPipeline? in
            s.stopped = true
            return s.pipeline
        }
        pipeline?.stop()
        gate.release()
    }

    /// Pauses between pieces of the stream (and batches of files), or carries on.
    func pause() { gate.pause() }
    func resume() { gate.resume() }
    var isPaused: Bool { gate.isPaused }

    func progress() -> Progress {
        state.withLock { $0.progress }
    }

    /// For a stream: how big it's expected to be, once known.
    func setTotal(_ total: Int64?) {
        state.withLock { $0.progress.total = total }
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func fail(_ message: String) {
        let pipeline = state.withLock { s -> OrderedPipeline? in
            guard s.failure == nil, !s.done else { return nil }
            s.failure = message
            s.stopped = true
            return s.pipeline
        }
        pipeline?.stop()
    }

    private func problem(_ path: String, _ message: String) {
        state.withLock { s in
            s.progress.problemCount += 1
            if s.problems.count < Self.problemsKept {
                s.problems.append(Problem(id: s.problems.count, path: path, message: message))
            }
        }
    }

    // MARK: The unpacking thread

    private func run() -> Outcome {
        let started = Date()
        var format: ArchiveFormat?
        var parallel = false
        let pipeline: OrderedPipeline
        switch source {
        case .file(let url):
            // A split file's parts are read one after another, as one; a locked one, unlocked.
            let name = SplitParts.wholeName(url.lastPathComponent)
            let file: InputFile
            switch InputFile.open(url, password: password) {
            case .success(let opened): file = opened
            case .failure(let error): return .failed(error.message)
            }
            switch ArchiveFormat.detect(file, name: name) {
            case .failure(let error): return .failed(error.message)
            case .success(let detected): format = detected
            }
            let decoding = ArchiveDecoder.start(file, format: format!)
            pipeline = decoding.pipeline
            parallel = decoding.parallel
            compressed = format != .tar
            state.withLock { $0.progress.total = file.size }
        case .stream(let stream, _):
            pipeline = stream
            parallel = true
        }
        let alreadyStopped = state.withLock { s -> Bool in
            s.pipeline = pipeline
            return s.stopped
        }
        if alreadyStopped { pipeline.stop() }

        if let destination, !alreadyStopped {
            guard makeStaging(in: destination) else {
                pipeline.stop()
                return .failed(state.withLock { $0.failure } ?? "Couldn't make a folder in “\(destination.lastPathComponent)”.")
            }
        }

        // Work through the tar stream.
        while let result = pipeline.next() {
            gate.wait()
            if isStopped { break }
            switch result {
            case .failure(let error):
                fail(error.message)
            case .success(let chunk):
                if consume(chunk) {
                    position += Int64(chunk.count)
                    let snapshot = (counted, singleBytes, entriesSeen)
                    let looking = self.looking
                    state.withLock { s in
                        s.progress.processed = chunk.inputEnd
                        s.progress.entries = snapshot.2
                        if looking {
                            s.progress.files = snapshot.0.files + snapshot.0.links
                            s.progress.folders = snapshot.0.folders
                            s.progress.bytes = snapshot.0.bytes + snapshot.1
                        }
                    }
                }
            }
            if isStopped { break }
        }
        if !isStopped { endOfStream() }
        if !batch.jobs.isEmpty && !isStopped { dispatch() }
        creator.sync {}

        if isStopped {
            pipeline.stop()
            return giveUp()
        }
        var output: URL?
        if !looking {
            finishTree()
            if isStopped { return giveUp() }
            output = place()
            if output == nil {
                // Everything's unpacked, in the "(unpacking)" folder: leave it there and say so.
                let left = staging.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                closeRoot()
                return finish(.failed("Everything was unpacked, but the folder couldn't be given its name: it's “\(left)” in \(Format.path(destination!)), \(Packer.message(errno))."))
            }
            closeRoot()
        }

        let seconds = Date().timeIntervalSince(started)
        let summary = state.withLock { s in
            Summary(output: output, format: format, parallel: parallel,
                    files: looking ? counted.files + counted.links : s.progress.files + madeLinks,
                    folders: looking ? counted.folders : madeFolders,
                    links: looking ? counted.links : madeLinks,
                    bytes: looking ? counted.bytes + singleBytes : s.progress.bytes,
                    tarBytes: position, seconds: seconds, topNames: topNames, topCount: topSet.count,
                    topIsFolder: topSet.count == 1 && topIsFolder, kinds: kinds, macMetadata: macMetadata,
                    refused: refused, problems: s.problems, problemCount: s.progress.problemCount, single: single)
        }
        return finish(.finished(summary))
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        state.withLock { $0.done = true }
        gate.release()
        return outcome
    }

    /// After stopping or failing: deletes what was unpacked.
    private func giveUp() -> Outcome {
        switch phase {
        case .big(let fd, _, _): close(fd)
        case .single(let fd) where fd >= 0: close(fd)
        default: break
        }
        phase = .ended
        closeRoot()
        if let staging {
            state.withLock { $0.progress.cleaning = true }
            if removefile(staging, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) != 0 {
                // A folder without write permission stops removefile: open them all up and try again.
                Self.openUp(staging)
                removefile(staging, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
            }
        }
        let failure = state.withLock { $0.failure }
        return finish(failure.map { .failed($0) } ?? .stopped)
    }

    private func closeRoot() {
        if root >= 0 {
            close(root)
            root = -1
        }
    }

    private static func openUp(_ path: String) {
        chmod(path, 0o755)
        guard let items = FileManager.default.enumerator(atPath: path) else { return }
        for case let item as String in items {
            fchmodat(AT_FDCWD, path + "/" + item, 0o755, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// Makes the "NAME (unpacking)" folder everything goes into first.
    private func makeStaging(in folder: URL) -> Bool {
        for number in 1...999 {
            let name = number == 1 ? "\(baseName) (unpacking)" : "\(baseName) (unpacking \(number))"
            let path = folder.appendingPathComponent(name).path
            if mkdir(path, 0o755) == 0 {
                staging = path
                root = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                if root < 0 {
                    rmdir(path)
                    break
                }
                return true
            }
            let code = errno
            guard code == EEXIST else {
                fail(code == ENOSPC ? Self.diskFull
                     : "Couldn't make a folder in “\(folder.lastPathComponent)”: \(Packer.message(code)).")
                return false
            }
        }
        fail("Couldn't make a folder in “\(folder.lastPathComponent)”.")
        return false
    }

    // MARK: Working through the tar stream

    /// Works through a chunk of the tar stream. False if it can't go on (it has failed).
    private func consume(_ chunk: Chunk) -> Bool {
        let base = UnsafeRawPointer(chunk.base).assumingMemoryBound(to: UInt8.self)
        let count = chunk.count
        var at = 0
        while at < count {
            switch phase {
            case .ended:
                return true

            case .header:
                if headerFill == 0 && count - at >= 512 {
                    let ok = handleHeader(base + at, at: position + Int64(at))
                    at += 512
                    guard ok else { return false }
                } else {
                    let take = min(512 - headerFill, count - at)
                    let fill = headerFill
                    header.withUnsafeMutableBufferPointer { ($0.baseAddress! + fill).update(from: base + at, count: take) }
                    headerFill += take
                    at += take
                    if headerFill == 512 {
                        headerFill = 0
                        let where_ = position + Int64(at) - 512
                        let ok = header.withUnsafeBufferPointer { handleHeader($0.baseAddress!, at: where_) }
                        guard ok else { return false }
                    }
                }

            case .meta(let kind, let remaining, let padding):
                let take = Int(min(remaining, Int64(count - at)))
                meta.append(contentsOf: UnsafeBufferPointer(start: base + at, count: take))
                at += take
                if remaining == Int64(take) {
                    applyMeta(kind)
                    phase = padding > 0 ? .skip(padding) : .header
                } else {
                    phase = .meta(kind, remaining: remaining - Int64(take), padding: padding)
                }

            case .file(let remaining, let padding):
                let take = Int(min(remaining, Int64(count - at)))
                job?.pieces.append(UnsafeRawBufferPointer(start: base + at, count: take))
                batch.retain(chunk)
                at += take
                if remaining == Int64(take) {
                    finishJob()
                    phase = padding > 0 ? .skip(padding) : .header
                } else {
                    phase = .file(remaining: remaining - Int64(take), padding: padding)
                }

            case .big(let fd, let remaining, let padding):
                let take = Int(min(remaining, Int64(count - at)))
                if big?.ok == true && !Self.writeAll(fd, base + at, take) {
                    let code = errno
                    big?.ok = false
                    if code == ENOSPC {
                        fail(Self.diskFull)
                        return false
                    }
                    problem(big?.path ?? "", "Couldn't write this file: \(Packer.message(code)).")
                }
                at += take
                state.withLock { $0.progress.bytes += Int64(take) }
                if remaining == Int64(take) {
                    finishBig(fd)
                    phase = padding > 0 ? .skip(padding) : .header
                } else {
                    phase = .big(fd: fd, remaining: remaining - Int64(take), padding: padding)
                }

            case .skip(let remaining):
                let take = Int(min(remaining, Int64(count - at)))
                at += take
                phase = remaining == Int64(take) ? .header : .skip(remaining - Int64(take))

            case .single(let fd):
                let take = count - at
                if fd >= 0 && !Self.writeAll(fd, base + at, take) {
                    let code = errno
                    fail(code == ENOSPC ? Self.diskFull : "Couldn't write the file: \(Packer.message(code)).")
                    return false
                }
                singleBytes += Int64(take)
                if fd >= 0 { state.withLock { $0.progress.bytes += Int64(take) } }
                at = count
            }
        }
        return true
    }

    /// The tar stream is over: it must not stop part-way through an entry.
    private func endOfStream() {
        switch phase {
        case .header:
            if headerFill > 0 {
                if entriesSeen == 0 && compressed {
                    // A small compressed file that isn't a tar file: it's the file itself.
                    let bytes = Array(header.prefix(headerFill))
                    let ok = bytes.withUnsafeBufferPointer { startSingle($0.baseAddress!, count: $0.count) }
                    if ok, case .single(let fd) = phase { finishSingle(fd) }
                } else {
                    fail(ArchiveDecoder.endsEarly)
                }
            } else if entriesSeen == 0 && !single {
                if case .file = source { fail("There's nothing in this tar file.") }
            }
        case .single(let fd):
            finishSingle(fd)
        case .ended:
            break
        case .skip(let remaining):
            // Only the padding at the very end missing is fine.
            if remaining >= 512 { fail(ArchiveDecoder.endsEarly) }
        case .file, .big, .meta:
            fail(ArchiveDecoder.endsEarly)
        }
    }

    /// Handles one 512-byte header. False if it can't go on.
    private func handleHeader(_ h: UnsafePointer<UInt8>, at offset: Int64) -> Bool {
        if TarHeader.isZero(h) {
            phase = .ended
            return true
        }
        guard TarHeader.checksumOK(h) else {
            if entriesSeen == 0 && compressed && pendingPath == nil {
                // Not a tar file inside: a single compressed file (notes.txt.gz).
                return startSingle(h, count: 512)
            }
            fail(entriesSeen == 0 ? "This isn't a tar file, or it's damaged at the start."
                 : "The file is damaged: a header doesn't add up \(Format.bytes(offset)) into the tar stream.")
            return false
        }
        entriesSeen += 1
        let type = h[156]
        guard var size = TarHeader.number(h + 124, 12), size >= 0 else {
            fail("The file is damaged: a header's size doesn't make sense \(Format.bytes(offset)) in.")
            return false
        }

        switch type {
        case 0x78, 0x67, 0x4C, 0x4B: // x, g: pax extended headers; L, K: GNU long names
            guard size <= 16 << 20 else {
                fail("The file is damaged: a header is \(Format.bytes(size)) long.")
                return false
            }
            let kind: MetaKind = type == 0x78 ? .pax : type == 0x67 ? .globalPax : type == 0x4C ? .longName : .longLink
            meta.removeAll(keepingCapacity: true)
            if size == 0 {
                applyMeta(kind)
            } else {
                phase = .meta(kind, remaining: size, padding: Tar.padded(size) - size)
            }
            return true
        default:
            break
        }

        if let pendingSize { size = pendingSize }
        let path = pendingPath ?? TarHeader.path(h)
        let link = pendingLink ?? TarHeader.string(h + 157, 100)
        let mtime = pendingTime ?? timespec(tv_sec: Int(TarHeader.number(h + 136, 12) ?? 0), tv_nsec: 0)
        let mode = UInt32(truncatingIfNeeded: TarHeader.number(h + 100, 8) ?? 0o644) & 0o7777
        let sparse = pendingSparse
        pendingPath = nil
        pendingLink = nil
        pendingSize = nil
        pendingTime = nil
        pendingSparse = false

        // Data that follows the header, whatever happens to the entry.
        let data = size
        let padding = Tar.padded(size) - size
        var kind = type
        if kind == 0 || kind == 0x37 { kind = 0x30 }            // "\0" and "7" are files too
        if kind == 0x30 && path.hasSuffix("/") { kind = 0x35 }  // old tars mark folders this way
        if kind == 0x44 { kind = 0x35 }                         // GNU's "dumpdir" folders
        if kind == 0x53 && h[482] != 0 {
            fail("This tar file holds GNU sparse files, which OneFile can't unpack. Use tar -xf in Terminal.")
            return false
        }

        guard let relative = Self.sanitize(path) else {
            refused += 1
            problem(path, "Left out: its path leads outside the folder.")
            phase = skipping(data + padding)
            return true
        }
        guard !relative.isEmpty else {
            phase = skipping(data + padding)
            return true
        }

        switch kind {
        case 0x35:
            noteTop(relative, isFolder: true)
            folder(relative, mode: mode, mtime: mtime)
            phase = skipping(data + padding)
        case 0x30:
            // "._" files may be Mac metadata, not files: they count once they're known to be files.
            if !Self.maybeAppleDouble(relative) { noteTop(relative, isFolder: false) }
            if sparse {
                problem(relative, "Left out: it's a sparse file, which OneFile can't unpack.")
                phase = skipping(data + padding)
            } else {
                file(relative, size: size, padding: padding, mode: mode, mtime: mtime)
            }
        case 0x31:
            noteTop(relative, isFolder: false)
            if let target = Self.sanitize(link), !target.isEmpty {
                counted.links += 1
                if !looking { hardLinks.append((relative, target)) }
            } else {
                refused += 1
                problem(relative, "Left out: it's a link to something outside the folder.")
            }
            phase = skipping(data + padding)
        case 0x32:
            noteTop(relative, isFolder: false)
            counted.links += 1
            if !looking { symbolicLinks.append((relative, link, mtime)) }
            phase = skipping(data + padding)
        case 0x36:
            noteTop(relative, isFolder: false)
            counted.files += 1
            if !looking { pipes.append((relative, mode, mtime)) }
            phase = skipping(data + padding)
        case 0x33, 0x34:
            problem(relative, "Left out: devices can't be unpacked.")
            phase = skipping(data + padding)
        case 0x53:
            problem(relative, "Left out: it's a sparse file, which OneFile can't unpack.")
            phase = skipping(data + padding)
        case 0x41...0x5A:
            // Other letters are extensions (volume labels and the like), not entries.
            phase = skipping(data + padding)
        default:
            // POSIX: an entry of a type not known is unpacked as a file.
            if !Self.maybeAppleDouble(relative) { noteTop(relative, isFolder: false) }
            file(relative, size: size, padding: padding, mode: mode, mtime: mtime)
        }
        return true
    }

    private func skipping(_ count: Int64) -> Phase {
        count > 0 ? .skip(count) : .header
    }

    private func applyMeta(_ kind: MetaKind) {
        switch kind {
        case .longName:
            pendingPath = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
        case .longLink:
            pendingLink = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
        case .pax:
            parsePax()
        case .globalPax:
            break
        }
    }

    /// pax records: "LENGTH key=value\n", where LENGTH counts the whole record.
    private func parsePax() {
        let bytes = meta
        var start = 0
        while start < bytes.count {
            var index = start
            var length = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39, length < 1 << 24 {
                length = length * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            guard index < bytes.count, bytes[index] == 0x20, length > index - start + 1,
                  start + length <= bytes.count else { return }
            let record = bytes[(index + 1)..<(start + length - 1)]
            if let equals = record.firstIndex(of: 0x3D) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)...], as: UTF8.self)
                switch key {
                case "path": pendingPath = value
                case "linkpath": pendingLink = value
                case "size": pendingSize = Int64(value)
                case "mtime": pendingTime = Self.time(value)
                default: if key.hasPrefix("GNU.sparse.") { pendingSparse = true }
                }
            }
            start += length
        }
    }

    /// "1700000000.123456789" as seconds and nanoseconds.
    static func time(_ text: String) -> timespec? {
        let parts = text.split(separator: ".", maxSplits: 1)
        guard let first = parts.first, let seconds = Int(first) else { return nil }
        var nanoseconds = 0
        if parts.count == 2 {
            let digits = String(parts[1].prefix(9))
            nanoseconds = (Int(digits) ?? 0) * Int(pow(10, Double(9 - digits.count)))
            if text.hasPrefix("-") && nanoseconds > 0 {
                return timespec(tv_sec: seconds - 1, tv_nsec: 1_000_000_000 - nanoseconds)
            }
        }
        return timespec(tv_sec: seconds, tv_nsec: nanoseconds)
    }

    /// A tar path as a path inside the new folder: leading "/" and "." parts dropped, and nil if it
    /// has a ".." part (it could lead outside).
    static func sanitize(_ path: String) -> String? {
        var needsWork = false
        var startOfPart = true
        var dots = 0
        var onlyDots = true
        for byte in path.utf8 {
            if byte == 0x2F {
                if startOfPart || (onlyDots && dots <= 2) { needsWork = true }
                startOfPart = true
                dots = 0
                onlyDots = true
            } else {
                startOfPart = false
                if byte == 0x2E { dots += 1 } else { onlyDots = false }
            }
        }
        if !startOfPart && onlyDots && dots <= 2 { needsWork = true }
        if !needsWork {
            return path.utf8.last == 0x2F ? String(path.dropLast()) : path
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// Remembers what's at the top of the tar file.
    private func noteTop(_ relative: String, isFolder: Bool) {
        let first: Substring
        let folderish: Bool
        if let slash = relative.firstIndex(of: "/") {
            first = relative[..<slash]
            folderish = true
        } else {
            first = relative[...]
            folderish = isFolder
        }
        if first == lastTop {
            if folderish { topIsFolder = true }
            return
        }
        let name = String(first)
        lastTop = name
        if topSet.count < 10_000, topSet.insert(name).inserted {
            if topNames.count < 20 { topNames.append(name) }
            if topSet.count == 1 { topIsFolder = folderish }
        }
        if topSet.count == 1 && folderish { topIsFolder = true }
    }

    // MARK: Entries

    private func folder(_ relative: String, mode: UInt32, mtime: timespec) {
        counted.folders += 1
        if looking {
            state.withLock { $0.progress.current = relative }
            return
        }
        guard ensureFolder(relative) else { return }
        folderAttributes.append(FolderAttributes(path: relative, depth: relative.utf8.reduce(0) { $0 + ($1 == 0x2F ? 1 : 0) },
                                                 mode: mode, mtime: mtime))
    }

    private func file(_ relative: String, size: Int64, padding: Int64, mode: UInt32, mtime: timespec) {
        if looking {
            let name = relative.lastIndex(of: "/").map { String(relative[relative.index(after: $0)...]) } ?? relative
            if name.hasPrefix("._") {
                macMetadata += 1
            } else {
                counted.files += 1
                counted.bytes += size
                kinds.add(name, size: size)
            }
            phase = skipping(size + padding)
            return
        }
        guard ensureParent(relative) else {
            phase = skipping(size + padding)
            return
        }
        if size > Self.bigFile {
            if Self.maybeAppleDouble(relative) { noteTop(relative, isFolder: false) }
            let fd = Self.openNew(root, relative, mode)
            guard fd >= 0 else {
                let code = errno
                if code == ENOSPC { fail(Self.diskFull) }
                problem(relative, "Couldn't make this file: \(Packer.message(code)).")
                phase = skipping(size + padding)
                return
            }
            big = (relative, mode, mtime, true)
            phase = .big(fd: fd, remaining: size, padding: padding)
            return
        }
        job = FileJob(path: relative, mode: mode, mtime: mtime, size: Int(size), pieces: [])
        if size == 0 {
            finishJob()
            phase = skipping(padding)
        } else {
            phase = .file(remaining: size, padding: padding)
        }
    }

    private func finishJob() {
        guard let job else { return }
        self.job = nil
        if Self.isAppleDouble(job) {
            macMetadata += 1
            return
        }
        if Self.maybeAppleDouble(job.path) { noteTop(job.path, isFolder: false) }
        batch.jobs.append(job)
        batch.bytes += job.size
        if batch.jobs.count >= Self.batchItems || batch.bytes >= Self.batchBytes { dispatch() }
    }

    private func finishBig(_ fd: Int32) {
        guard let big else {
            close(fd)
            return
        }
        self.big = nil
        if big.ok {
            Self.finishFile(fd, mode: big.mode, mtime: big.mtime)
            close(fd)
            state.withLock { s in
                s.progress.files += 1
                s.progress.current = big.path
            }
        } else {
            close(fd)
            _ = big.path.withCString { unlinkat(root, $0, 0) }
        }
    }

    /// Named "._something", as the Mac metadata files macOS's own tar adds are.
    static func maybeAppleDouble(_ path: String) -> Bool {
        let name = path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
        return name.hasPrefix("._")
    }

    /// "._name" files that macOS's own tar adds for each file's Mac metadata (AppleDouble).
    private static func isAppleDouble(_ job: FileJob) -> Bool {
        guard job.size >= 8 else { return false }
        let name = job.path.lastIndex(of: "/").map { job.path[job.path.index(after: $0)...] } ?? job.path[...]
        guard name.hasPrefix("._") else { return false }
        var magic: [UInt8] = []
        for piece in job.pieces where magic.count < 4 {
            magic += UnsafeRawBufferPointer(rebasing: piece.prefix(4 - magic.count))
        }
        return magic == [0x00, 0x05, 0x16, 0x07]
    }

    private func startSingle(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        single = true
        let name = baseName
        noteTop(name, isFolder: false)
        if looking {
            singleBytes += Int64(count)
            phase = .single(fd: -1)
            return true
        }
        let fd = Self.openNew(root, name, 0o644)
        guard fd >= 0 else {
            fail("Couldn't make “\(name)”: \(Packer.message(errno)).")
            return false
        }
        phase = .single(fd: fd)
        guard Self.writeAll(fd, bytes, count) else {
            fail("Couldn't write “\(name)”: \(Packer.message(errno)).")
            return false
        }
        singleBytes += Int64(count)
        state.withLock { $0.progress.bytes += Int64(count) }
        return true
    }

    private func finishSingle(_ fd: Int32) {
        counted.files += 1
        counted.bytes += singleBytes
        kinds.add(baseName, size: singleBytes)
        if fd >= 0 {
            close(fd)
            state.withLock { s in
                s.progress.files += 1
                s.progress.current = baseName
            }
        }
        phase = .ended
    }

    // MARK: Folders

    /// Makes the folder, and any it's in, if they aren't there yet.
    private func ensureFolder(_ relative: String) -> Bool {
        if knownFolders.contains(relative) { return true }
        if let slash = relative.lastIndex(of: "/") {
            guard ensureFolder(String(relative[..<slash])) else { return false }
        }
        if relative.withCString({ mkdirat(root, $0, 0o755) }) == 0 {
            madeFolders += 1
            state.withLock { $0.progress.folders += 1 }
        } else {
            let code = errno
            var info = stat()
            guard code == EEXIST, relative.withCString({ fstatat(root, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else {
                if code == ENOSPC { fail(Self.diskFull) }
                problem(relative, code == EEXIST ? "Couldn't make this folder: a file with its name is in the way."
                                                 : "Couldn't make this folder: \(Packer.message(code)).")
                return false
            }
        }
        knownFolders.insert(relative)
        return true
    }

    private func ensureParent(_ relative: String) -> Bool {
        guard let slash = relative.lastIndex(of: "/") else { return true }
        return ensureFolder(String(relative[..<slash]))
    }

    // MARK: Writing files

    private func dispatch() {
        let full = batch
        batch = Batch()
        batchSlots.wait()
        creator.async { [self] in
            defer { batchSlots.signal() }
            write(full)
        }
    }

    /// Writes a batch's files, `writers` at a time. On the creator queue.
    private func write(_ batch: Batch) {
        gate.wait()
        guard !isStopped else { return }
        let jobs = batch.jobs
        let count = jobs.count
        guard count > 0 else { return }
        let results = SharedPointer(UnsafeMutablePointer<Int32>.allocate(capacity: count))
        results.pointer.initialize(repeating: 0, count: count)
        defer { results.pointer.deallocate() }
        let root = self.root
        let workers = min(Self.writers, count)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var index = worker
            while index < count {
                results.pointer[index] = Unpacker.create(root, jobs[index])
                index += workers
            }
        }
        var files: Int64 = 0
        var bytes: Int64 = 0
        var last = ""
        for index in 0..<count {
            let code = results.pointer[index]
            if code == 0 {
                files += 1
                bytes += Int64(jobs[index].size)
                last = jobs[index].path
            } else if code == ENOSPC {
                fail(Self.diskFull)
                break
            } else {
                problem(jobs[index].path, "Couldn't make this file: \(Packer.message(code)).")
            }
        }
        state.withLock { s in
            s.progress.files += files
            s.progress.bytes += bytes
            if !last.isEmpty { s.progress.current = last }
        }
    }

    /// Makes one file and writes its data. 0, or what went wrong.
    static func create(_ root: Int32, _ job: FileJob) -> Int32 {
        let fd = openNew(root, job.path, job.mode)
        guard fd >= 0 else { return errno }
        var code: Int32 = 0
        for piece in job.pieces where code == 0 {
            if !writeAll(fd, piece.baseAddress!, piece.count) { code = errno == 0 ? EIO : errno }
        }
        if code == 0 { finishFile(fd, mode: job.mode, mtime: job.mtime) }
        close(fd)
        return code
    }

    /// Opens a new file for writing, never through a symbolic link. If one with that name is there
    /// already (the tar file had the same path twice), the later one wins, unless it's a folder.
    static func openNew(_ root: Int32, _ path: String, _ mode: UInt32) -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC
        let permissions = mode_t(mode & 0o777)
        var fd = path.withCString { openat(root, $0, flags, permissions) }
        if fd < 0 && errno == EEXIST {
            _ = path.withCString { unlinkat(root, $0, 0) }
            fd = path.withCString { openat(root, $0, flags, permissions) }
        }
        return fd
    }

    /// Gives a file its exact permissions (where the umask took some away) and its date.
    static func finishFile(_ fd: Int32, mode: UInt32, mtime: timespec) {
        let permissions = mode & 0o777
        if permissions & umaskBits != 0 { fchmod(fd, mode_t(permissions)) }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), mtime]
        futimens(fd, &times)
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let written = Darwin.write(fd, bytes + done, count - done)
            if written > 0 { done += written; continue }
            if written < 0 && errno == EINTR { continue }
            if written == 0 { errno = EIO }
            return false
        }
        return true
    }

    // MARK: Finishing

    /// Links and pipes, then folders' permissions and dates, deepest first.
    private func finishTree() {
        state.withLock { $0.progress.finishing = true }
        // Hard links, now that every file they point to is there. (No symbolic links are there
        // yet, so neither name can lead outside the folder.)
        for link in hardLinks {
            guard !isStopped else { return }
            guard ensureParent(link.path) else { continue }
            var result = linkat(root, link.target, root, link.path, 0)
            if result != 0 && errno == EEXIST {
                unlinkat(root, link.path, 0)
                result = linkat(root, link.target, root, link.path, 0)
            }
            if result == 0 {
                madeLinks += 1
            } else {
                problem(link.path, "Couldn't make this link to “\(link.target)”: \(Packer.message(errno)).")
            }
        }
        for pipe in pipes {
            guard ensureParent(pipe.path) else { continue }
            if mkfifoat(root, pipe.path, mode_t(pipe.mode & 0o777)) == 0 {
                if pipe.mode & 0o777 & Self.umaskBits != 0 {
                    fchmodat(root, pipe.path, mode_t(pipe.mode & 0o777), AT_SYMLINK_NOFOLLOW)
                }
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), pipe.mtime]
                utimensat(root, pipe.path, &times, AT_SYMLINK_NOFOLLOW)
                state.withLock { $0.progress.files += 1 }
            } else {
                problem(pipe.path, "Couldn't make this named pipe: \(Packer.message(errno)).")
            }
        }
        // Symbolic links, each in a folder reached without following any link.
        for link in symbolicLinks {
            guard ensureParent(link.path) else { continue }
            let parent: String
            let leaf: String
            if let slash = link.path.lastIndex(of: "/") {
                parent = String(link.path[..<slash])
                leaf = String(link.path[link.path.index(after: slash)...])
            } else {
                parent = ""
                leaf = link.path
            }
            let folder = parent.isEmpty ? dup(root)
                                        : openat(root, parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard folder >= 0 else {
                refused += 1
                problem(link.path, "Left out: it would be made inside another link.")
                continue
            }
            var result = symlinkat(link.target, folder, leaf)
            if result != 0 && errno == EEXIST {
                unlinkat(folder, leaf, 0)
                result = symlinkat(link.target, folder, leaf)
            }
            if result == 0 {
                madeLinks += 1
                var times = [link.mtime, link.mtime]
                utimensat(folder, leaf, &times, AT_SYMLINK_NOFOLLOW)
            } else {
                problem(link.path, "Couldn't make this link: \(Packer.message(errno)).")
            }
            close(folder)
        }
        // Folders last: making things inside them changed their dates. Deepest first, so a folder
        // made unreadable can't stop the ones inside it.
        folderAttributes.sort { $0.depth > $1.depth }
        for folder in folderAttributes {
            let fd = openat(root, folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            fchmod(fd, mode_t(folder.mode & 0o1777))
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), folder.mtime]
            futimens(fd, &times)
            close(fd)
        }
    }

    /// Gives what was unpacked its place and name. The tar file's one top folder (or file) goes
    /// straight into the destination; several things at the top go together into a folder named
    /// after the archive. Under a name not yet taken: "Research 2", and so on.
    private func place() -> URL? {
        guard let staging, let destination else { return nil }
        if topSet.count == 1, let only = topNames.first {
            var info = stat()
            if fstatat(root, only, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                let isFolder = info.st_mode & S_IFMT == S_IFDIR
                guard let target = Self.moveExclusive(staging + "/" + only, into: destination, name: only,
                                                      isFolder: isFolder) else { return nil }
                rmdir(staging)
                return target
            }
        }
        if topSet.isEmpty {
            // Nothing in it (all left out): no folder to show.
            rmdir(staging)
            return destination
        }
        return Self.moveExclusive(staging, into: destination, name: baseName, isFolder: true)
    }

    static func moveExclusive(_ path: String, into folder: URL, name: String, isFolder: Bool) -> URL? {
        for number in 1...9_999 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : numbered(name, number, isFolder: isFolder))
            if renamex_np(path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    /// "Research 2", "notes 2.txt".
    static func numbered(_ name: String, _ number: Int, isFolder: Bool) -> String {
        if !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "\(name[..<dot]) \(number)\(name[dot...])"
        }
        return "\(name) \(number)"
    }
}

/// One file to make: where, how, and its data (in chunks of the tar stream, which its batch keeps).
struct FileJob: @unchecked Sendable {
    let path: String
    let mode: UInt32
    let mtime: timespec
    let size: Int
    var pieces: [UnsafeRawBufferPointer]
}

/// Files to make together, and the chunks their data is in.
private final class Batch: @unchecked Sendable {
    var jobs: [FileJob] = []
    var chunks: [Chunk] = []
    var bytes = 0

    init() {
        jobs.reserveCapacity(Unpacker.batchItems)
    }

    func retain(_ chunk: Chunk) {
        if chunks.last !== chunk { chunks.append(chunk) }
    }
}
