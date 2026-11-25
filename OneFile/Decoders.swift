import Foundation
import Compression
import zlib

// MARK: - Chunks and the ordered pipeline

/// A stretch of the tar stream, decompressed, on its way to the unpacker.
final class Chunk: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let capacity: Int
    var count = 0
    /// How far into the input (the archive file, or the stream sent) this chunk reaches.
    var inputEnd: Int64 = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        base = .allocate(byteCount: self.capacity, alignment: 64)
    }

    deinit { base.deallocate() }
}

struct DecodeError: Error, Sendable {
    let message: String
}

/// Runs jobs on several threads at once and hands their chunks back in the order the jobs came in.
/// At most `slots` are held at a time, running or waiting to be taken, so memory stays bounded and
/// a slow consumer slows the producer down.
final class OrderedPipeline: @unchecked Sendable {
    typealias Job = @Sendable () -> Result<Chunk, DecodeError>

    private let condition = NSCondition()
    private var ready: [Int: Result<Chunk, DecodeError>] = [:]
    private var submitted = 0
    private var delivered = 0
    private let slots: Int
    private var finished = false
    private var stopped = false
    private let queue = DispatchQueue(label: "OneFile.decode", qos: Work.dispatchQoS, attributes: .concurrent)

    init(slots: Int) {
        self.slots = max(slots, 1)
    }

    /// Waits for a free slot, then starts the job. False once stopped.
    @discardableResult
    func submit(_ job: @escaping Job) -> Bool {
        condition.lock()
        while submitted - delivered >= slots && !stopped { condition.wait() }
        guard !stopped else {
            condition.unlock()
            return false
        }
        let index = submitted
        submitted += 1
        condition.unlock()
        queue.async { [self] in
            let result = job()
            condition.lock()
            if !stopped { ready[index] = result }
            condition.broadcast()
            condition.unlock()
        }
        return true
    }

    /// A chunk already made, in its turn.
    @discardableResult
    func submit(_ chunk: Chunk) -> Bool {
        submit { .success(chunk) }
    }

    /// Ends the stream with a failure, after the chunks before it.
    func fail(_ message: String) {
        submit { .failure(DecodeError(message: message)) }
        finish()
    }

    /// Nothing more is coming.
    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// The next chunk in order, waiting for it if need be; nil at the end, or once stopped.
    func next() -> Result<Chunk, DecodeError>? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped { return nil }
            if let result = ready.removeValue(forKey: delivered) {
                delivered += 1
                condition.broadcast()
                return result
            }
            if finished && delivered == submitted { return nil }
            condition.wait()
        }
    }

    /// Stops it: waiting producers and the consumer return at once, and results are dropped.
    func stop() {
        condition.lock()
        stopped = true
        ready.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }
}

// MARK: - The archive file

/// An archive file open for reading, from any thread. It closes when the last job using it is done.
final class InputFile: @unchecked Sendable {
    /// One file, or the parts of a split one, read one after another as if they were one.
    private let fds: [Int32]
    /// Where each part starts in the whole.
    private let starts: [Int64]
    /// What's read: the file itself, or once a locked (age) file is unlocked, its contents.
    private(set) var size: Int64
    /// The file on the disk, all its parts.
    let rawSize: Int64
    /// Unlocked: reads come from the age payload, decrypted on the way.
    private var age: AgeReader?
    /// On the internet: reads are range requests.
    private let remote: RemoteFile?

    convenience init?(path: String) {
        self.init(paths: [path])
    }

    init?(paths: [String]) {
        var fds: [Int32] = []
        var starts: [Int64] = []
        var total: Int64 = 0
        for path in paths {
            let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0 else {
                let code = errno
                if fd >= 0 { close(fd) }
                fds.forEach { close($0) }
                errno = code
                return nil
            }
            fds.append(fd)
            starts.append(total)
            total += Int64(info.st_size)
        }
        guard !fds.isEmpty else { return nil }
        self.fds = fds
        self.starts = starts
        size = total
        rawSize = total
        remote = nil
    }

    /// An archive on the internet (see `RemoteFile`).
    init(remote: RemoteFile) {
        fds = []
        starts = [0]
        size = remote.size
        rawSize = remote.size
        self.remote = remote
    }

    /// Why reading from the internet failed, if that's where it is and it did.
    var remoteFailure: String? { remote?.failure }

    /// Opens an archive (all its parts, if it was split), unlocked with `password` if it's locked.
    static func open(_ url: URL, password: String?) -> Result<InputFile, DecodeError> {
        let file: InputFile
        if Remote.isRemote(url) {
            switch Remote.objects(for: url) {
            case .success(let objects): file = InputFile(remote: RemoteFile(objects))
            case .failure(let error): return .failure(error)
            }
        } else {
            let parts = SplitParts.parts(of: url)?.map(\.path) ?? [url.path]
            guard let local = InputFile(paths: parts) else {
                return .failure(DecodeError(message: "Couldn't open “\(url.lastPathComponent)”: \(Packer.message(errno))."))
            }
            file = local
        }
        guard file.isLocked else { return .success(file) }
        guard let password, !password.isEmpty else {
            return .failure(DecodeError(message: "“\(url.lastPathComponent)” is locked with a password."))
        }
        switch file.unlock(password) {
        case nil: return .success(file)
        case .wrongPassword?: return .failure(DecodeError(message: "That isn't the password for “\(url.lastPathComponent)”."))
        case .unsupported(let why)?: return .failure(DecodeError(message: why))
        default: return .failure(DecodeError(message: "“\(url.lastPathComponent)” is damaged: its lock can't be read."))
        }
    }

    /// Locked with a password: an age file.
    var isLocked: Bool {
        guard age == nil else { return false }
        let intro = Array((Age.intro + "\n").utf8)
        var head = [UInt8](repeating: 0, count: intro.count)
        guard rawSize >= Int64(intro.count), head.withUnsafeMutableBytes({ rawRead($0.count, at: 0, into: $0.baseAddress!) }) else {
            return false
        }
        return head == intro
    }

    /// Unlocks an age file with its password: nil once it's open, else why not.
    func unlock(_ password: String) -> Age.OpenError? {
        let span = Int(min(rawSize, 4_096))
        var head = [UInt8](repeating: 0, count: span)
        guard head.withUnsafeMutableBytes({ rawRead(span, at: 0, into: $0.baseAddress!) }) else { return .damaged }
        switch Age.open(head, password: password) {
        case .failure(let error):
            return error
        case .success(let opened):
            var nonce = [UInt8](repeating: 0, count: 16)
            guard Int64(opened.headerEnd + 16) <= rawSize,
                  nonce.withUnsafeMutableBytes({ rawRead(16, at: Int64(opened.headerEnd), into: $0.baseAddress!) }),
                  let reader = AgeReader(fileKey: opened.fileKey, headerEnd: opened.headerEnd, nonce: nonce, fileSize: rawSize) else {
                return .damaged
            }
            age = reader
            size = reader.size
            return nil
        }
    }

    deinit { fds.forEach { close($0) } }

    /// Reads exactly `count` bytes at `offset` (decrypted, for an unlocked file). False if it can't
    /// (or, locked, if they've been changed).
    func read(_ count: Int, at offset: Int64, into buffer: UnsafeMutableRawPointer) -> Bool {
        guard let age else { return rawRead(count, at: offset, into: buffer) }
        guard offset >= 0, offset + Int64(count) <= size else { return false }
        let plain = Int64(Age.chunk)
        let sealed = plain + Int64(Age.tagSize)
        var piece = [UInt8](repeating: 0, count: Int(sealed))
        var done = 0
        while done < count {
            let position = offset + Int64(done)
            let index = position / plain
            let within = Int(position % plain)
            let at = age.start + index * sealed
            let length = Int(min(sealed, rawSize - at))
            guard length > Age.tagSize,
                  piece.withUnsafeMutableBytes({ rawRead(length, at: at, into: $0.baseAddress!) }),
                  let opened = piece.withUnsafeBytes({ age.open(index, UnsafeRawBufferPointer(rebasing: $0.prefix(length))) }),
                  within < opened.count else { return false }
            let take = min(count - done, opened.count - within)
            opened.withUnsafeBytes { (buffer + done).copyMemory(from: $0.baseAddress! + within, byteCount: take) }
            done += take
        }
        return true
    }

    /// Reads exactly `count` bytes of the file itself (across parts, if need be).
    private func rawRead(_ count: Int, at offset: Int64, into buffer: UnsafeMutableRawPointer) -> Bool {
        if let remote { return remote.read(count, at: offset, into: buffer) }
        var done = 0
        while done < count {
            let position = offset + Int64(done)
            guard position < rawSize else { return false }
            var part = fds.count - 1
            while starts[part] > position { part -= 1 }
            let partEnd = part + 1 < starts.count ? starts[part + 1] : rawSize
            let want = min(count - done, Int(partEnd - position))
            let got = pread(fds[part], buffer + done, want, off_t(position - starts[part]))
            if got > 0 { done += got; continue }
            if got < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    func bytes(_ count: Int, at offset: Int64) -> [UInt8]? {
        guard count >= 0, offset >= 0, offset + Int64(count) <= size else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let ok = bytes.withUnsafeMutableBytes { read(count, at: offset, into: $0.baseAddress!) }
        return ok ? bytes : nil
    }
}

/// How an archive file is compressed, going by its first bytes (not its name).
enum ArchiveFormat: String, Sendable {
    case tar, gzip, zstd, xz

    var title: String {
        switch self {
        case .tar: "tar, uncompressed"
        case .gzip: "tar.gz (gzip)"
        case .zstd: "tar.zst (zstd)"
        case .xz: "tar.xz (xz)"
        }
    }

    static func detect(_ file: InputFile, name: String) -> Result<ArchiveFormat, DecodeError> {
        guard file.size > 0 else { return .failure(DecodeError(message: "“\(name)” is empty.")) }
        let head = file.bytes(Int(min(file.size, 512)), at: 0) ?? []
        func starts(_ magic: [UInt8]) -> Bool { head.count >= magic.count && Array(head.prefix(magic.count)) == magic }
        if starts([0x1F, 0x8B]) { return .success(.gzip) }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .success(.xz) }
        // A zstd frame, or a skippable frame (OneFile's and pzstd's files start with one).
        if starts([0x28, 0xB5, 0x2F, 0xFD]) || (head.count >= 4 && head[0] & 0xF0 == 0x50 && Array(head[1..<4]) == [0x2A, 0x4D, 0x18]) {
            return .success(.zstd)
        }
        let other: String?
        if starts([0x42, 0x5A, 0x68]) { other = "a bzip2 file (.tar.bz2)" }
        else if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { other = "a zip file" }
        else if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { other = "a 7-Zip file" }
        else if starts([0x52, 0x61, 0x72, 0x21]) { other = "a RAR file" }
        else { other = nil }
        if let other {
            return .failure(DecodeError(message: "“\(name)” is \(other). OneFile unpacks .tar, .tar.gz, .tar.zst and .tar.xz files; double-click this one to open it with Archive Utility."))
        }
        if head.count == 512 && TarHeader.checksumOK(head) { return .success(.tar) }
        return .failure(DecodeError(message: "“\(name)” isn't a tar file, or it's damaged at the start."))
    }
}

// MARK: - Decoding

/// Reads an archive file and hands its tar stream, decompressed, to an `OrderedPipeline`.
///
/// OneFile's own files decompress on every core: each gzip member says in its header how long it
/// is (see `BlockCompressor`), so does the skippable frame before each zstd frame (see `Zstd`), and
/// each xz stream is listed in the index at its end, so every piece can be found and decompressed
/// at once. Other files decompress in order, on one core.
enum ArchiveDecoder {
    /// Plain tar is read in pieces this big.
    static let readPiece = 8 << 20
    /// Decompressed chunks of files read in order.
    static let chunkSize = 4 << 20
    /// The biggest piece decompressed on its own; bigger xz streams are read in order instead.
    static let largestPiece = 64 << 20

    static var decoders: Int { min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8) }

    struct Started {
        let pipeline: OrderedPipeline
        /// It decompresses on several cores.
        let parallel: Bool
    }

    /// Starts decoding on threads of its own.
    static func start(_ file: InputFile, format: ArchiveFormat) -> Started {
        switch format {
        case .tar:
            let pipeline = OrderedPipeline(slots: 4)
            run("OneFile reader") { readPlain(file, pipeline) }
            return Started(pipeline: pipeline, parallel: false)
        case .gzip:
            let indexed = file.bytes(Int(min(file.size, 32)), at: 0).flatMap { indexedMember($0) } != nil
            let pipeline = OrderedPipeline(slots: indexed ? decoders + 2 : 4)
            run("OneFile gunzip") {
                if indexed { readIndexedGzip(file, pipeline) } else { readGzip(file, from: 0, pipeline) }
            }
            return Started(pipeline: pipeline, parallel: indexed)
        case .zstd:
            let indexed = file.bytes(Int(min(file.size, Int64(Zstd.peekSize))), at: 0).flatMap { Zstd.header($0) } != nil
            let pipeline = OrderedPipeline(slots: indexed ? decoders + 2 : 4)
            run("OneFile unzstd") {
                if indexed { readIndexedZstd(file, pipeline) } else { readZstd(file, from: 0, pipeline) }
            }
            return Started(pipeline: pipeline, parallel: indexed)
        case .xz:
            let streams = xzStreams(file)
            let parallel = (streams?.count ?? 0) > 1 && streams!.allSatisfy { $0.holds <= Int64(largestPiece) }
            let pipeline = OrderedPipeline(slots: parallel ? decoders + 2 : 4)
            run("OneFile unxz") {
                if parallel, let streams { readIndexedXz(file, streams, pipeline) } else { readXz(file, pipeline) }
            }
            return Started(pipeline: pipeline, parallel: parallel)
        }
    }

    private static func run(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    static func damaged(_ offset: Int64) -> String {
        "The file is damaged: it stops making sense \(Format.bytes(offset)) in. Copy it again from where it came from."
    }

    static let endsEarly = "The file ends too early: it's incomplete (still copying, or cut off). Copy it again from where it came from."
    static let unreadable = "Couldn't read the file: the disk may have been disconnected."

    // MARK: Plain tar

    private static func readPlain(_ file: InputFile, _ pipeline: OrderedPipeline) {
        var offset: Int64 = 0
        while offset < file.size {
            let at = offset
            let length = Int(min(Int64(readPiece), file.size - offset))
            guard pipeline.submit({
                let chunk = Chunk(capacity: length)
                guard file.read(length, at: at, into: chunk.base) else { return .failure(DecodeError(message: unreadable)) }
                chunk.count = length
                chunk.inputEnd = at + Int64(length)
                return .success(chunk)
            }) else { return }
            offset += Int64(length)
        }
        pipeline.finish()
    }

    // MARK: gzip

    /// The member's length and how much it holds, from OneFile's subfield of its header. Nil if
    /// either is more than `limit`.
    static func indexedMember(_ header: [UInt8], limit: Int = largestPiece) -> (size: Int, holds: Int)? {
        guard header.count >= 24, header[0] == 0x1F, header[1] == 0x8B, header[2] == 8, header[3] & 0x04 != 0 else {
            return nil
        }
        let extraEnd = 12 + (Int(header[10]) | Int(header[11]) << 8)
        var at = 12
        while at + 4 <= min(extraEnd, header.count) {
            let length = Int(header[at + 2]) | Int(header[at + 3]) << 8
            if header[at] == 0x4F && header[at + 1] == 0x46 && length == 8 && at + 12 <= header.count {
                func word(_ i: Int) -> Int {
                    Int(header[i]) | Int(header[i + 1]) << 8 | Int(header[i + 2]) << 16 | Int(header[i + 3]) << 24
                }
                let size = word(at + 4), holds = word(at + 8)
                guard size >= 32, size <= limit, holds <= limit else { return nil }
                return (size, holds)
            }
            at += 4 + length
        }
        return nil
    }

    private static func readIndexedGzip(_ file: InputFile, _ pipeline: OrderedPipeline) {
        var offset: Int64 = 0
        while offset < file.size {
            guard let header = file.bytes(Int(min(32, file.size - offset)), at: offset),
                  let member = indexedMember(header), offset + Int64(member.size) <= file.size else { break }
            let at = offset
            guard pipeline.submit({ inflateMember(file, at: at, size: member.size, holds: member.holds) }) else { return }
            offset += Int64(member.size)
        }
        // Anything after OneFile's members (another gzip file joined on, say) is read in order.
        if offset < file.size {
            readGzip(file, from: offset, pipeline)
        } else {
            pipeline.finish()
        }
    }

    static func inflateMember(_ file: InputFile, at offset: Int64, size: Int, holds: Int) -> Result<Chunk, DecodeError> {
        let input = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { input.deallocate() }
        guard file.read(size, at: offset, into: input) else { return .failure(DecodeError(message: unreadable)) }
        let chunk = Chunk(capacity: holds)
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return .failure(DecodeError(message: "Couldn't start decompressing."))
        }
        defer { inflateEnd(&stream) }
        stream.next_in = input.assumingMemoryBound(to: Bytef.self)
        stream.avail_in = uInt(size)
        stream.next_out = chunk.base.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(chunk.capacity)
        // zlib checks the member's CRC and length too.
        let result = inflate(&stream, Z_FINISH)
        guard result == Z_STREAM_END, Int(stream.total_out) == holds, Int(stream.total_in) == size else {
            return .failure(DecodeError(message: damaged(offset)))
        }
        chunk.count = holds
        chunk.inputEnd = offset + Int64(size)
        return .success(chunk)
    }

    /// Decompresses gzip members one after another, from `start` to the end of the file.
    private static func readGzip(_ file: InputFile, from start: Int64, _ pipeline: OrderedPipeline) {
        let inputCapacity = 1 << 20
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        defer { input.deallocate() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            pipeline.fail("Couldn't start decompressing.")
            return
        }
        defer { inflateEnd(&stream) }
        var offset = start
        var chunk = Chunk(capacity: chunkSize)
        var inMember = true

        func emit() -> Bool {
            chunk.inputEnd = offset - Int64(stream.avail_in)
            let full = chunk
            chunk = Chunk(capacity: chunkSize)
            return pipeline.submit(full)
        }

        while true {
            if stream.avail_in == 0 {
                let want = Int(min(Int64(inputCapacity), file.size - offset))
                if want == 0 {
                    if inMember {
                        pipeline.fail(endsEarly)
                        return
                    }
                    break
                }
                guard file.read(want, at: offset, into: input) else {
                    pipeline.fail(unreadable)
                    return
                }
                stream.next_in = input
                stream.avail_in = uInt(want)
                offset += Int64(want)
            }
            if !inMember {
                // Between members: another one, or the end (zeros or anything else are ignored, as
                // gzip itself does).
                if stream.avail_in < 2 && offset < file.size {
                    // Too little left in the buffer to tell: move it to the front and read more.
                    let left = Int(stream.avail_in)
                    if left > 0 { input.update(from: stream.next_in, count: left) }
                    let want = Int(min(Int64(inputCapacity - left), file.size - offset))
                    guard file.read(want, at: offset, into: input + left) else {
                        pipeline.fail(unreadable)
                        return
                    }
                    stream.next_in = input
                    stream.avail_in = uInt(left + want)
                    offset += Int64(want)
                }
                guard stream.avail_in >= 2, stream.next_in[0] == 0x1F, stream.next_in[1] == 0x8B else { break }
                inflateReset(&stream)
                inMember = true
            }
            stream.next_out = chunk.base.assumingMemoryBound(to: Bytef.self) + chunk.count
            stream.avail_out = uInt(chunk.capacity - chunk.count)
            let result = inflate(&stream, Z_NO_FLUSH)
            chunk.count = chunk.capacity - Int(stream.avail_out)
            if chunk.count == chunk.capacity {
                guard emit() else { return }
            }
            switch result {
            case Z_OK, Z_BUF_ERROR:
                continue
            case Z_STREAM_END:
                inMember = false
            default:
                pipeline.fail(damaged(offset - Int64(stream.avail_in)))
                return
            }
        }
        if chunk.count > 0 { guard emit() else { return } }
        pipeline.finish()
    }

    // MARK: xz

    struct XzStream {
        let offset: Int64
        let size: Int64
        let holds: Int64
    }

    /// The streams of an xz file, found from the end: each ends in a footer that says how long its
    /// index is, and the index lists its blocks' sizes. Nil if the file isn't laid out that way.
    static func xzStreams(_ file: InputFile) -> [XzStream]? {
        var streams: [XzStream] = []
        var end = file.size
        while end > 0 {
            // Stream padding: zeros, four at a time.
            while end >= 4, let word = file.bytes(4, at: end - 4), word == [0, 0, 0, 0] { end -= 4 }
            guard end >= 24, let footer = file.bytes(12, at: end - 12), footer[10] == 0x59, footer[11] == 0x5A else {
                return nil
            }
            let stored = UInt32(footer[4]) | UInt32(footer[5]) << 8 | UInt32(footer[6]) << 16 | UInt32(footer[7]) << 24
            let indexSize = (Int64(stored) + 1) * 4
            let indexStart = end - 12 - indexSize
            guard indexStart >= 12, indexSize <= 16 << 20,
                  let index = file.bytes(Int(indexSize), at: indexStart), index.first == 0 else { return nil }
            var at = 1
            func number() -> Int64? {
                var value: Int64 = 0
                var shift: Int64 = 0
                while at < index.count - 4 {
                    let byte = index[at]
                    at += 1
                    value |= Int64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                    if shift > 63 { return nil }
                }
                return nil
            }
            guard let records = number() else { return nil }
            var blocks: Int64 = 0
            var holds: Int64 = 0
            for _ in 0..<records {
                guard let unpadded = number(), let uncompressed = number() else { return nil }
                blocks += (unpadded + 3) & ~3
                holds += uncompressed
            }
            let start = indexStart - blocks - 12
            guard start >= 0, let magic = file.bytes(6, at: start), magic == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] else {
                return nil
            }
            streams.append(XzStream(offset: start, size: end - start, holds: holds))
            end = start
        }
        return streams.reversed()
    }

    private static func readIndexedXz(_ file: InputFile, _ streams: [XzStream], _ pipeline: OrderedPipeline) {
        for stream in streams {
            guard pipeline.submit({ decodeXz(file, stream) }) else { return }
        }
        pipeline.finish()
    }

    static func decodeXz(_ file: InputFile, _ stream: XzStream) -> Result<Chunk, DecodeError> {
        let size = Int(stream.size)
        let input = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { input.deallocate() }
        guard file.read(size, at: stream.offset, into: input) else { return .failure(DecodeError(message: unreadable)) }
        guard let chunk = xzWhole(UnsafeRawBufferPointer(start: input, count: size), holds: Int(stream.holds)) else {
            return .failure(DecodeError(message: damaged(stream.offset)))
        }
        chunk.inputEnd = stream.offset + stream.size
        return .success(chunk)
    }

    /// Decompresses one whole xz stream known to hold `holds` bytes. With the streaming decoder:
    /// unlike the one-shot `compression_decode_buffer`, it checks the stream's CRC.
    static func xzWhole(_ input: UnsafeRawBufferPointer, holds: Int) -> Chunk? {
        guard let base = input.baseAddress else { return nil }
        // A byte to spare, so the end of the stream can be seen with room left.
        let chunk = Chunk(capacity: holds + 1)
        var stream = compression_stream(dst_ptr: chunk.base.assumingMemoryBound(to: UInt8.self), dst_size: 0,
                                        src_ptr: base.assumingMemoryBound(to: UInt8.self), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = base.assumingMemoryBound(to: UInt8.self)
        stream.src_size = input.count
        stream.dst_ptr = chunk.base.assumingMemoryBound(to: UInt8.self)
        stream.dst_size = chunk.capacity
        var status = COMPRESSION_STATUS_OK
        while status == COMPRESSION_STATUS_OK {
            let before = (stream.src_size, stream.dst_size)
            status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            if status == COMPRESSION_STATUS_OK && before == (stream.src_size, stream.dst_size) { return nil }
        }
        let produced = chunk.capacity - stream.dst_size
        guard status == COMPRESSION_STATUS_END, produced == holds else { return nil }
        chunk.count = produced
        return chunk
    }

    /// Decompresses xz streams one after another, with Apple's Compression framework.
    private static func readXz(_ file: InputFile, _ pipeline: OrderedPipeline) {
        let inputCapacity = 1 << 20
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        defer { input.deallocate() }
        var stream = compression_stream(dst_ptr: input, dst_size: 0, src_ptr: input, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            pipeline.fail("Couldn't start decompressing.")
            return
        }
        var live = true
        defer { if live { compression_stream_destroy(&stream) } }
        var offset: Int64 = 0
        var chunk = Chunk(capacity: chunkSize)
        var inStream = true

        func emit() -> Bool {
            chunk.inputEnd = offset - Int64(stream.src_size)
            let full = chunk
            chunk = Chunk(capacity: chunkSize)
            return pipeline.submit(full)
        }

        func refill(keeping left: Int) -> Bool {
            if left > 0 && stream.src_ptr != UnsafePointer(input) {
                input.update(from: stream.src_ptr, count: left)
            }
            let want = Int(min(Int64(inputCapacity - left), file.size - offset))
            guard want > 0 else { return true }
            guard file.read(want, at: offset, into: input + left) else { return false }
            stream.src_ptr = UnsafePointer(input)
            stream.src_size = left + want
            offset += Int64(want)
            return true
        }

        while true {
            if stream.src_size == 0 {
                guard refill(keeping: 0) else {
                    pipeline.fail(unreadable)
                    return
                }
            }
            if !inStream {
                // Between streams: padding (zeros), then another stream, or the end.
                while true {
                    while stream.src_size > 0 && stream.src_ptr[0] == 0 {
                        stream.src_ptr += 1
                        stream.src_size -= 1
                    }
                    if stream.src_size >= 6 || offset >= file.size { break }
                    guard refill(keeping: stream.src_size) else {
                        pipeline.fail(unreadable)
                        return
                    }
                }
                guard stream.src_size >= 6, stream.src_ptr[0] == 0xFD, stream.src_ptr[1] == 0x37 else { break }
                let pointer = stream.src_ptr, size = stream.src_size
                compression_stream_destroy(&stream)
                live = false
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
                    pipeline.fail("Couldn't start decompressing.")
                    return
                }
                live = true
                stream.src_ptr = pointer
                stream.src_size = size
                inStream = true
            }
            let atEnd = offset >= file.size
            stream.dst_ptr = chunk.base.assumingMemoryBound(to: UInt8.self) + chunk.count
            stream.dst_size = chunk.capacity - chunk.count
            let before = (stream.src_size, stream.dst_size)
            let status = compression_stream_process(&stream, atEnd ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            chunk.count = chunk.capacity - stream.dst_size
            if chunk.count == chunk.capacity {
                guard emit() else { return }
            }
            switch status {
            case COMPRESSION_STATUS_OK:
                if atEnd && stream.src_size == 0 && before == (stream.src_size, stream.dst_size) {
                    pipeline.fail(endsEarly)
                    return
                }
            case COMPRESSION_STATUS_END:
                inStream = false
                if stream.src_size == 0 && offset >= file.size {
                    if chunk.count > 0 { guard emit() else { return } }
                    pipeline.finish()
                    return
                }
            default:
                pipeline.fail(damaged(offset - Int64(stream.src_size)))
                return
            }
        }
        if chunk.count > 0 { guard emit() else { return } }
        pipeline.finish()
    }
}

// MARK: - Decoding a block sent from another Mac

extension ArchiveDecoder {
    /// Decompresses one block (a gzip member, a zstd frame, an xz stream, or plain bytes) known to
    /// hold `holds` bytes of the tar stream.
    static func decodeBlock(_ block: UnsafeRawBufferPointer, holds: Int, method: PackMethod) -> Chunk? {
        let chunk = Chunk(capacity: holds)
        guard let base = block.baseAddress else { return holds == 0 ? chunk : nil }
        switch method {
        case .plain:
            guard block.count == holds else { return nil }
            chunk.base.copyMemory(from: base, byteCount: holds)
        case .gzip:
            var stream = z_stream()
            guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(block.count)
            stream.next_out = chunk.base.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(chunk.capacity)
            guard inflate(&stream, Z_FINISH) == Z_STREAM_END, Int(stream.total_out) == holds else { return nil }
        case .zstd:
            return Zstd.decompress(block, holds: holds)
        case .xz:
            return xzWhole(block, holds: holds)
        }
        chunk.count = holds
        return chunk
    }
}
