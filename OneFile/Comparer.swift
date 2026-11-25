import Foundation
import CryptoKit

/// Compares two folders: what's only in one, what differs, what's the same. Quickly, by names,
/// kinds, sizes and dates, a folder at a time from both sides together; or thoroughly, also
/// reading every file on both sides, many at once.
final class Comparer: @unchecked Sendable {
    struct Options: Sendable {
        /// Read and compare every file's contents, not only sizes and dates.
        var contents = false
        /// Names (or patterns) to ignore on both sides, like `.DS_Store`.
        var leaveOut: [String] = [".DS_Store"]
    }

    enum Difference: String, Sendable {
        case onlyFirst, onlySecond, kind, size, date, contents, link
    }

    struct Item: Sendable, Identifiable, Hashable {
        let id: Int
        let path: String
        let difference: Difference
        let isFolder: Bool
    }

    struct Progress: Sendable {
        var started = Date()
        var compared: Int64 = 0
        var bytesRead: Int64 = 0
        var current = ""
        var finishing = false
    }

    struct Summary: Sendable {
        let first: URL
        let second: URL
        var same: Int64 = 0
        var onlyFirst: Int64 = 0
        var onlySecond: Int64 = 0
        var different: Int64 = 0
        var items: [Item] = []
        var problems: [Problem] = []
        var seconds: Double = 0
        var contents = false

        var identical: Bool { onlyFirst == 0 && onlySecond == 0 && different == 0 && problems.isEmpty }
    }

    enum Outcome: Sendable {
        case finished(Summary)
        case stopped
        case failed(String)
    }

    static let itemsKept = 5_000

    let first: URL
    let second: URL
    let options: Options

    private struct State {
        var progress = Progress()
        var stopped = false
        var summary: Summary
    }

    private let state: Locked<State>
    private let rules: WalkRules
    /// Files to read on both sides (thorough mode), and the threads reading them.
    private let reads = WorkQueue<[(String, Int64)]>(limit: 64)
    /// Seconds two dates may differ by and still be the same (FAT keeps them to 2 s).
    private var slack: Int64 = 1
    private var pairFirst = false
    private var pairSecond = false

    init(first: URL, second: URL, options: Options) {
        self.first = first
        self.second = second
        self.options = options
        rules = WalkRules(leaveOut: options.leaveOut, device: 0)
        state = Locked(State(summary: Summary(first: first, second: second, contents: options.contents)))
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in completion(run()) }
        thread.name = "OneFile compare"
        thread.qualityOfService = Work.qos
        thread.start()
    }

    func cancel() {
        state.withLock { $0.stopped = true }
        reads.stop()
    }

    func progress() -> Progress { state.withLock { $0.progress } }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    // MARK: Comparing

    private func run() -> Outcome {
        let started = Date()
        for url in [first, second] {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
                return .failed("“\(url.lastPathComponent)” isn't a folder.")
            }
        }
        let firstDrive = Drive.of(first.path), secondDrive = Drive.of(second.path)
        slack = firstDrive?.isFAT == true || secondDrive?.isFAT == true ? 2 : 1
        // On exFAT and FAT drives, "._" files hold the attributes of the file beside them.
        pairFirst = !(firstDrive?.nativeAttributes ?? true)
        pairSecond = !(secondDrive?.nativeAttributes ?? true)

        let readers = DispatchGroup()
        if options.contents {
            for _ in 0..<8 {
                readers.enter()
                let thread = Thread { [self] in
                    readFiles()
                    readers.leave()
                }
                thread.qualityOfService = Work.qos
                thread.start()
            }
        }
        var stack = [""]
        var pending: [(String, Int64)] = []
        while let relative = stack.popLast(), !isStopped {
            let subfolders = compareFolder(relative, &pending)
            stack.append(contentsOf: subfolders.reversed())
            if pending.count >= 32 {
                _ = reads.push(pending)
                pending = []
            }
        }
        if !pending.isEmpty { _ = reads.push(pending) }
        reads.finish()
        readers.wait()
        if isStopped { return .stopped }
        let seconds = Date().timeIntervalSince(started)
        return state.withLock { s in
            s.summary.seconds = seconds
            return .finished(s.summary)
        }
    }

    /// Lists one folder on both sides and compares what's in them. Returns the subfolders both
    /// have; files to read go into `pending`.
    private func compareFolder(_ relative: String, _ pending: inout [(String, Int64)]) -> [String] {
        let a = list(first.path, relative, pair: pairFirst)
        let b = list(second.path, relative, pair: pairSecond)
        if let error = a.error ?? b.error {
            problem(relative.isEmpty ? "(the top)" : relative, "Couldn't read this folder: \(Packer.message(error)).")
        }
        var byKey: [String: FolderEntry] = [:]
        for entry in b.entries { byKey[Self.key(entry.name)] = entry }
        var subfolders: [String] = []
        var same: Int64 = 0
        var compared: Int64 = 0
        for entry in a.entries {
            let path = relative.isEmpty ? entry.name : relative + "/" + entry.name
            compared += 1
            guard let other = byKey.removeValue(forKey: Self.key(entry.name)) else {
                add(path, .onlyFirst, folder: entry.kind == .directory)
                continue
            }
            if entry.kind != other.kind {
                add(path, .kind, folder: entry.kind == .directory)
                continue
            }
            switch entry.kind {
            case .directory:
                subfolders.append(path)
            case .file:
                if entry.size != other.size {
                    add(path, .size, folder: false)
                } else if abs(entry.modified - other.modified) > slack && !options.contents {
                    add(path, .date, folder: false)
                } else if options.contents && entry.size > 0 {
                    pending.append((path, entry.size))
                } else {
                    same += 1
                }
            case .symlink:
                if Packer.linkTarget(first.path + "/" + path) == Packer.linkTarget(second.path + "/" + path) {
                    same += 1
                } else {
                    add(path, .link, folder: false)
                }
            case .fifo, .other:
                same += 1
            }
        }
        for entry in byKey.values {
            let path = relative.isEmpty ? entry.name : relative + "/" + entry.name
            add(path, .onlySecond, folder: entry.kind == .directory)
        }
        state.withLock { s in
            s.summary.same += same
            s.progress.compared += compared
            if !relative.isEmpty { s.progress.current = relative }
        }
        return subfolders
    }

    private func list(_ root: String, _ relative: String, pair: Bool) -> (entries: [FolderEntry], error: Int32?) {
        var entries: [FolderEntry] = []
        let code = FolderReader.read(relative.isEmpty ? root : root + "/" + relative) { batch in
            entries.append(contentsOf: batch)
            return true
        }
        if pair { entries = AppleDouble.pair(entries) }
        entries.removeAll { rules.leavesOut($0.name) }
        return (entries, code == 0 ? nil : code)
    }

    /// Names match as the Mac matches them: the same characters, however composed.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Reads files on both sides and compares them, a piece at a time.
    private func readFiles() {
        let size = 4 << 20
        let left = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        let right = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer {
            left.deallocate()
            right.deallocate()
        }
        while let batch = reads.pop() {
            var same: Int64 = 0
            var read: Int64 = 0
            for (path, length) in batch {
                if isStopped { return }
                switch Self.sameContents(first.path + "/" + path, second.path + "/" + path, left, right, size) {
                case .same:
                    same += 1
                case .different:
                    add(path, .contents, folder: false)
                case .failed(let code):
                    problem(path, "Couldn't read it to compare: \(Packer.message(code)).")
                }
                read += length * 2
            }
            state.withLock { s in
                s.summary.same += same
                s.progress.bytesRead += read
            }
        }
    }

    enum ContentResult { case same, different, failed(Int32) }

    /// Whether two files hold the same bytes, read from the drives (not from memory, where macOS
    /// may still have them from a copy just made).
    static func sameContents(_ a: String, _ b: String, _ left: UnsafeMutableRawPointer,
                             _ right: UnsafeMutableRawPointer, _ size: Int) -> ContentResult {
        let fa = open(a, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fa >= 0 else { return .failed(errno) }
        defer { close(fa) }
        let fb = open(b, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fb >= 0 else { return .failed(errno) }
        defer { close(fb) }
        forgetCached(fa)
        forgetCached(fb)
        while true {
            let ga = readFull(fa, left, size)
            let gb = readFull(fb, right, size)
            if ga < 0 || gb < 0 { return .failed(errno) }
            if ga != gb || memcmp(left, right, ga) != 0 { return .different }
            if ga < size { return .same }
        }
    }

    /// Drops what macOS has of the file in memory, so reading it reads the drive.
    static func forgetCached(_ fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return }
        _ = fcntl(fd, F_NOCACHE, 1)
        if let mapped = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, fd, 0), mapped != MAP_FAILED {
            msync(mapped, Int(info.st_size), MS_INVALIDATE)
            munmap(mapped, Int(info.st_size))
        }
    }

    static func readFull(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int {
        var got = 0
        while got < size {
            let count = Darwin.read(fd, buffer + got, size - got)
            if count > 0 { got += count; continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return -1
        }
        return got
    }

    private func add(_ path: String, _ difference: Difference, folder: Bool) {
        state.withLock { s in
            switch difference {
            case .onlyFirst: s.summary.onlyFirst += 1
            case .onlySecond: s.summary.onlySecond += 1
            default: s.summary.different += 1
            }
            if s.summary.items.count < Self.itemsKept {
                s.summary.items.append(Item(id: s.summary.items.count, path: path, difference: difference, isFolder: folder))
            }
        }
    }

    private func problem(_ path: String, _ message: String) {
        state.withLock { s in
            if s.summary.problems.count < Packer.problemsKept {
                s.summary.problems.append(Problem(id: s.summary.problems.count, path: path, message: message))
            }
        }
    }
}

/// SHA-256 of a file's data as it's copied, a piece at a time: to check the copy later.
struct Digest: Sendable, Equatable {
    let bytes: [UInt8]

    static func of(_ pointer: UnsafeRawPointer, _ count: Int) -> Digest {
        Digest(bytes: Array(SHA256.hash(data: UnsafeRawBufferPointer(start: pointer, count: count))))
    }
}
