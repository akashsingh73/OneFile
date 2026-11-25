import Foundation
import CryptoKit

/// Takes chosen files and folders out of a OneFile archive without unpacking the rest: its index
/// says where each is, so only the blocks holding them are read and decompressed. Each file is
/// checked against the SHA-256 recorded when it was packed.
final class Extractor: @unchecked Sendable {
    struct Progress: Sendable {
        var files: Int64 = 0
        var bytes: Int64 = 0
        var current = ""
    }

    struct Summary: Sendable {
        /// What was made in the destination, at the top.
        var made: [URL]
        var files: Int64
        var bytes: Int64
        var mismatched: Int64
        var seconds: Double
        var problems: [Problem]
    }

    enum Outcome: Sendable {
        case finished(Summary)
        case stopped
        case failed(String)
    }

    let archive: URL
    let index: ArchiveIndex
    let format: ArchiveFormat
    let chosen: [ArchiveIndex.Entry]
    let destination: URL
    let password: String?

    private let state = Locked((progress: Progress(), stopped: false, problems: [Problem]()))
    /// The last block decompressed, kept for the next file (usually in the same one).
    private var cached: (index: Int, chunk: Chunk)?

    init(archive: URL, index: ArchiveIndex, format: ArchiveFormat, chosen: [ArchiveIndex.Entry], destination: URL,
         password: String? = nil) {
        self.archive = archive
        self.index = index
        self.format = format
        self.chosen = chosen
        self.destination = destination
        self.password = password
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in completion(run()) }
        thread.name = "OneFile extract"
        thread.qualityOfService = Work.qos
        thread.start()
    }

    func cancel() { state.withLock { $0.stopped = true } }
    func progress() -> Progress { state.withLock { $0.progress } }
    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func problem(_ path: String, _ message: String) {
        state.withLock { s in
            if s.problems.count < Packer.problemsKept {
                s.problems.append(Problem(id: s.problems.count, path: path, message: message))
            }
        }
    }

    /// Everything that goes out: each chosen item, and for a folder all that's in it, with the
    /// path it gets in the destination (from the chosen item's own name down).
    static func plan(_ chosen: [ArchiveIndex.Entry], in index: ArchiveIndex) -> [(entry: ArchiveIndex.Entry, path: String)] {
        var seen = Set<Int>()
        var out: [(ArchiveIndex.Entry, String)] = []
        for item in chosen.sorted(by: { $0.path < $1.path }) {
            let trimmed = item.path.hasSuffix("/") ? String(item.path.dropLast()) : item.path
            let parent = trimmed.lastIndex(of: "/").map { String(trimmed[...$0]) } ?? ""
            let members = item.kind == .folder ? index.entries.filter { $0.path.hasPrefix(item.path) } : [item]
            for entry in members where seen.insert(entry.id).inserted {
                var path = String(entry.path.dropFirst(parent.count))
                if path.hasSuffix("/") { path.removeLast() }
                if !path.isEmpty { out.append((entry, path)) }
            }
        }
        return out
    }

    private func run() -> Outcome {
        let started = Date()
        let file: InputFile
        switch InputFile.open(archive, password: password) {
        case .success(let opened): file = opened
        case .failure(let error): return .failed(error.message)
        }
        let planned = Self.plan(chosen, in: index)
        // A name taken in the destination gets a number, at the top: nothing is replaced.
        var renamed: [String: String] = [:]
        var made: [URL] = []
        for (_, path) in planned {
            let top = String(path.prefix { $0 != "/" })
            guard renamed[top] == nil else { continue }
            var name = top
            var number = 2
            let isFolder = path.contains("/") || planned.contains { $0.path == top && $0.entry.kind == .folder }
            while FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path) {
                name = Unpacker.numbered(top, number, isFolder: isFolder)
                number += 1
            }
            renamed[top] = name
            made.append(destination.appendingPathComponent(name))
        }
        func target(_ path: String) -> String {
            let top = String(path.prefix { $0 != "/" })
            return destination.path + "/" + (renamed[top] ?? top) + path.dropFirst(top.count)
        }

        var mismatched: Int64 = 0
        let byPath = Dictionary(index.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // In the order they are in the archive, so each block is read once.
        for (entry, path) in planned.sorted(by: { $0.entry.data < $1.entry.data }) {
            if isStopped { return .stopped }
            let out = target(path)
            try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            switch entry.kind {
            case .folder:
                mkdir(out, mode_t(entry.mode & 0o777 | 0o700))
            case .symlink:
                if symlink(entry.link, out) != 0 { problem(path, "Couldn't make this link: \(Packer.message(errno)).") }
            case .fifo:
                mkfifo(out, mode_t(entry.mode & 0o777))
            case .file, .hardLink:
                // A hard link's data is its first name's.
                let source = entry.kind == .hardLink ? byPath[entry.link] ?? entry : entry
                switch write(source, to: out, file) {
                case .ok:
                    state.withLock { s in
                        s.progress.files += 1
                        s.progress.bytes += source.size
                        s.progress.current = path
                    }
                case .mismatch:
                    mismatched += 1
                    problem(path, "Taken out, but it doesn't match the SHA-256 recorded when it was packed: the archive is damaged here.")
                case .failed(let message):
                    problem(path, message)
                }
            }
        }
        if isStopped { return .stopped }
        return state.withLock { s in
            .finished(Summary(made: made, files: s.progress.files, bytes: s.progress.bytes, mismatched: mismatched,
                              seconds: Date().timeIntervalSince(started), problems: s.problems))
        }
    }

    private enum Written { case ok, mismatch, failed(String) }

    private func write(_ entry: ArchiveIndex.Entry, to path: String, _ file: InputFile) -> Written {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(entry.mode & 0o777 | 0o600))
        guard fd >= 0 else { return .failed("Couldn't make it: \(Packer.message(errno)).") }
        var hasher = SHA256()
        var done: Int64 = 0
        let piece = 4 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: piece, alignment: 16)
        defer { buffer.deallocate() }
        while done < entry.size {
            if isStopped {
                close(fd)
                unlink(path)
                return .failed("Stopped.")
            }
            let count = Int(min(Int64(piece), entry.size - done))
            guard read(entry.data + done, count, into: buffer, file) else {
                close(fd)
                unlink(path)
                return .failed("Couldn't read it from the archive.")
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            guard Unpacker.writeAll(fd, buffer, count) else {
                let code = errno
                close(fd)
                unlink(path)
                return .failed("Couldn't write it: \(Packer.message(code)).")
            }
            done += Int64(count)
        }
        if entry.mode & 0o777 != (entry.mode & 0o777 | 0o600) & ~Unpacker.umaskBits { fchmod(fd, mode_t(entry.mode & 0o777)) }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(entry.modified), tv_nsec: 0)]
        futimens(fd, &times)
        close(fd)
        if !entry.digest.isEmpty && Array(hasher.finalize()) != entry.digest { return .mismatch }
        return .ok
    }

    /// Reads `count` bytes of the tar stream at `offset`: straight from a .tar, or from the
    /// compressed blocks that hold them.
    private func read(_ offset: Int64, _ count: Int, into buffer: UnsafeMutableRawPointer, _ file: InputFile) -> Bool {
        if format == .tar { return file.read(count, at: offset, into: buffer) }
        var copied = 0
        while copied < count {
            let at = offset + Int64(copied)
            guard let block = index.block(holding: at), let chunk = decoded(block, file) else { return false }
            let blockTar = index.blocks[block.index].tar
            let within = Int(at - blockTar)
            guard within < chunk.count else { return false }
            let take = min(count - copied, chunk.count - within)
            (buffer + copied).copyMemory(from: chunk.base + within, byteCount: take)
            copied += take
        }
        return true
    }

    private func decoded(_ block: (index: Int, start: Int64, end: Int64), _ file: InputFile) -> Chunk? {
        if let cached, cached.index == block.index { return cached.chunk }
        let holds = Int((block.index + 1 < index.blocks.count ? index.blocks[block.index + 1].tar : index.tarSize)
                        - index.blocks[block.index].tar)
        let size = Int(block.end - block.start)
        let result: Result<Chunk, DecodeError>
        switch format {
        case .gzip:
            result = ArchiveDecoder.inflateMember(file, at: block.start, size: size, holds: holds)
        case .zstd:
            result = ArchiveDecoder.decodeZstd(file, at: block.start, size: size, holds: holds)
        case .xz:
            result = ArchiveDecoder.decodeXz(file, ArchiveDecoder.XzStream(offset: block.start, size: Int64(size),
                                                                             holds: Int64(holds)))
        case .tar:
            return nil
        }
        guard case .success(let chunk) = result else { return nil }
        cached = (block.index, chunk)
        return chunk
    }
}

/// Checks every file in a OneFile archive against the SHA-256 recorded when it was packed:
/// reads the whole archive once (on every core, for OneFile's own compressed files).
final class ArchiveChecker: @unchecked Sendable {
    struct Summary: Sendable {
        var checked: Int64
        var mismatched: [String]
        var seconds: Double
    }

    enum Outcome: Sendable {
        case finished(Summary)
        case stopped
        case failed(String)
    }

    let archive: URL
    let index: ArchiveIndex
    let format: ArchiveFormat
    let password: String?
    private let state = Locked((read: Int64(0), stopped: false, pipeline: OrderedPipeline?.none))

    init(archive: URL, index: ArchiveIndex, format: ArchiveFormat, password: String? = nil) {
        self.archive = archive
        self.index = index
        self.format = format
        self.password = password
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in completion(run()) }
        thread.name = "OneFile check"
        thread.qualityOfService = Work.qos
        thread.start()
    }

    func cancel() {
        let pipeline = state.withLock { s -> OrderedPipeline? in
            s.stopped = true
            return s.pipeline
        }
        pipeline?.stop()
    }

    /// How much of the tar stream has been read.
    var fraction: Double {
        Double(state.withLock { $0.read }) / Double(max(index.tarSize, 1))
    }

    private func run() -> Outcome {
        let started = Date()
        let file: InputFile
        switch InputFile.open(archive, password: password) {
        case .success(let opened): file = opened
        case .failure(let error): return .failed(error.message)
        }
        let decoding = ArchiveDecoder.start(file, format: format)
        state.withLock { $0.pipeline = decoding.pipeline }
        let files = index.entries.filter { $0.kind == .file && !$0.digest.isEmpty }.sorted { $0.data < $1.data }
        var next = 0
        var hasher = SHA256()
        var position: Int64 = 0
        var checked: Int64 = 0
        var mismatched: [String] = []
        func finishFile(_ entry: ArchiveIndex.Entry) {
            if Array(hasher.finalize()) != entry.digest { mismatched.append(entry.path) }
            checked += 1
            hasher = SHA256()
            next += 1
        }
        // Empty files at the very start.
        while next < files.count && files[next].size == 0 && files[next].data <= position { finishFile(files[next]) }
        while let result = decoding.pipeline.next() {
            if state.withLock({ $0.stopped }) { return .stopped }
            guard case .success(let chunk) = result else {
                if case .failure(let error) = result { return .failed(error.message) }
                break
            }
            let end = position + Int64(chunk.count)
            while next < files.count {
                let entry = files[next]
                let from = max(entry.data, position), to = min(entry.data + entry.size, end)
                if from < to {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: chunk.base + Int(from - position),
                                                                        count: Int(to - from)))
                }
                if entry.data + entry.size <= end && entry.data <= end {
                    finishFile(entry)
                } else {
                    break
                }
            }
            position = end
            state.withLock { $0.read = end }
            if next == files.count { break }
        }
        decoding.pipeline.stop()
        if next < files.count {
            for entry in files[next...] { mismatched.append(entry.path) }
        }
        return .finished(Summary(checked: checked, mismatched: mismatched, seconds: Date().timeIntervalSince(started)))
    }
}
