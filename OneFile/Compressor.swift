import Foundation
import Compression
import zlib

/// Compresses the tar stream as it's written, on every core.
///
/// The stream is cut into blocks (`PackMethod.blockSize`), each compressed on its own into a
/// complete gzip member or xz stream, and written in order. Both formats allow several of these
/// one after another in a file, and every reader (macOS's tar, gzip and Archive Utility, xz,
/// Python, 7-Zip) reads them back as one stream. It's how `pigz` and `xz -T0` work too.
///
/// Each gzip member also says, in a field of its header that other readers skip, how long it is
/// and how much it holds: OneFile unpacks its own .tar.gz files on every core with that (see
/// `ArchiveDecoder`). For a stream to another Mac, `frame` encrypts each block as well.
final class BlockCompressor: @unchecked Sendable {
    private let method: PackMethod
    private let blockSize: Int
    /// Turns a compressed block into what's written (encrypts it), with its index. Optional.
    private let frame: (@Sendable (Data, Int, Int) -> Data?)?
    /// Writes compressed bytes to the file, in order, with how many tar bytes they hold. Called on
    /// compression threads, one at a time.
    private let output: (Data, Int) -> Bool

    // Filled by the writer queue only.
    private var block: UnsafeMutablePointer<UInt8>
    private var filled = 0
    private var shipped = 0

    /// Blocks handed out and not yet written; waiting for one keeps memory bounded.
    private let slots: DispatchSemaphore
    private let group = DispatchGroup()
    private let workers = DispatchQueue(label: "OneFile.compress", qos: .userInitiated, attributes: .concurrent)

    // Shared between compression threads, behind the lock.
    private let lock = NSLock()
    private var finished: [Int: (data: Data, input: Int)] = [:]
    private var nextToWrite = 0
    private var failure: String?

    init(method: PackMethod, blockSize: Int? = nil, frame: (@Sendable (Data, Int, Int) -> Data?)? = nil,
         output: @escaping (Data, Int) -> Bool) {
        self.method = method
        self.blockSize = blockSize ?? method.blockSize
        self.frame = frame
        self.output = output
        block = .allocate(capacity: self.blockSize)
        // Enough to keep every worker busy, and not much more held in memory. (Uncompressed blocks
        // are only encrypted: one worker per core.)
        let workers = method == .plain ? max(ProcessInfo.processInfo.activeProcessorCount, 1) : method.workers
        slots = DispatchSemaphore(value: workers + 4)
    }

    deinit {
        block.deallocate()
    }

    /// Why it failed, if it did.
    var failureMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Adds bytes of the tar stream. Writer queue only. False once something has failed.
    func append(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let take = min(count - offset, blockSize - filled)
            (block + filled).update(from: bytes + offset, count: take)
            filled += take
            offset += take
            if filled == blockSize { ship() }
        }
        return failureMessage == nil
    }

    /// Compresses what's left and waits until everything is written. Writer queue only.
    func finish() -> Bool {
        if filled > 0 { ship() }
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return failure == nil && nextToWrite == shipped
    }

    /// Stops writing and waits for the blocks being compressed, so nothing touches the file after.
    func abandon() {
        lock.lock()
        if failure == nil { failure = "Stopped." }
        lock.unlock()
        group.wait()
    }

    private func ship() {
        let index = shipped
        shipped += 1
        let data = SharedPointer(block)
        let size = filled
        block = .allocate(capacity: blockSize)
        filled = 0
        slots.wait()
        group.enter()
        workers.async { [self] in
            var compressed = Self.compress(data.pointer, size, method)
            data.pointer.deallocate()
            if let frame, let block = compressed { compressed = frame(block, size, index) }
            done(index, compressed, input: size)
            group.leave()
        }
    }

    /// Writes whatever is next in order. A slot frees up only once its block is written, so a
    /// slow block can't let finished ones pile up in memory.
    private func done(_ index: Int, _ compressed: Data?, input: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else {
            slots.signal()
            return
        }
        guard let compressed else {
            failure = "Couldn't compress the file."
            slots.signal()
            return
        }
        finished[index] = (compressed, input)
        while let next = finished.removeValue(forKey: nextToWrite) {
            guard output(next.data, next.input) else {
                failure = "Couldn't write the file."
                slots.signal()
                // The blocks waiting here will never be written: free their slots too.
                for _ in finished { slots.signal() }
                finished.removeAll()
                return
            }
            nextToWrite += 1
            slots.signal()
        }
    }

    static func compress(_ input: UnsafeMutablePointer<UInt8>, _ count: Int, _ method: PackMethod) -> Data? {
        switch method {
        case .plain: Data(bytes: input, count: count)
        case .gzip: gzipMember(input, count, level: 1)
        case .xz: xzStream(input, count)
        }
    }

    /// The header of every gzip member OneFile writes: gzip's 10 bytes, then an extra field (which
    /// every gzip reader skips) holding OneFile's subfield "OF": the member's length and how many
    /// bytes it holds, so OneFile can find each member without decompressing the ones before it.
    static let gzipHeaderSize = 24

    /// One complete gzip member (header, deflate data, CRC and length), from zlib.
    static func gzipMember(_ input: UnsafeMutablePointer<UInt8>, _ count: Int, level: Int32) -> Data? {
        var stream = z_stream()
        // Raw deflate: the gzip header and trailer are written here, to hold the member's length.
        guard deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(count)))
        var out = Data(count: gzipHeaderSize + bound + 8)
        let total = out.withUnsafeMutableBytes { raw -> Int? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.next_in = input
            stream.avail_in = uInt(count)
            stream.next_out = base + gzipHeaderSize
            stream.avail_out = uInt(bound)
            guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return nil }
            let deflated = Int(stream.total_out)
            let total = gzipHeaderSize + deflated + 8
            // ID1 ID2, deflate, FEXTRA, no time, XFL "fastest", OS Unix, XLEN 12, then "OF", 8 bytes.
            let header: [UInt8] = [0x1F, 0x8B, 8, 0x04, 0, 0, 0, 0, level == 1 ? 4 : 0, 3, 12, 0, 0x4F, 0x46, 8, 0]
            base.update(from: header, count: header.count)
            littleEndian32(UInt32(total), base + 16)
            littleEndian32(UInt32(count), base + 20)
            let trailer = base + gzipHeaderSize + deflated
            littleEndian32(UInt32(truncatingIfNeeded: crc32(0, input, uInt(count))), trailer)
            littleEndian32(UInt32(truncatingIfNeeded: count), trailer + 4)
            return total
        }
        guard let total else { return nil }
        out.count = total
        return out
    }

    @inline(__always)
    static func littleEndian32(_ value: UInt32, _ at: UnsafeMutablePointer<UInt8>) {
        at[0] = UInt8(truncatingIfNeeded: value)
        at[1] = UInt8(truncatingIfNeeded: value >> 8)
        at[2] = UInt8(truncatingIfNeeded: value >> 16)
        at[3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    /// One complete .xz stream, from Apple's Compression framework (LZMA2, as `xz -6`), with a
    /// CRC32 of the data added (see `withCRC32`).
    static func xzStream(_ input: UnsafeMutablePointer<UInt8>, _ count: Int) -> Data? {
        let capacity = count + count / 2 + 65_536
        var out = Data(count: capacity)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: max(compression_encode_scratch_buffer_size(COMPRESSION_LZMA), 1), alignment: 16)
        defer { scratch.deallocate() }
        let written = out.withUnsafeMutableBytes { raw in
            compression_encode_buffer(raw.bindMemory(to: UInt8.self).baseAddress!, capacity, input, count,
                                      scratch, COMPRESSION_LZMA)
        }
        guard written > 0 else { return nil }
        out.count = written
        return withCRC32(out, crc: UInt32(truncatingIfNeeded: crc32(0, input, uInt(count))), holds: count)
    }

    /// Apple's encoder writes .xz streams with no check, so damage to the data can go unnoticed
    /// (its one-shot decoder never checks anything). This gives such a stream, of one block, a
    /// CRC32 of its data, as `xz --check=crc32` would: the stream's flags say so, the check follows
    /// the block, and the index and footer are written again to match. Every xz reader checks it.
    static func withCRC32(_ stream: Data, crc: UInt32, holds: Int) -> Data? {
        stream.withUnsafeBytes { raw -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 32, bytes[0] == 0xFD, bytes[1] == 0x37, bytes[5] == 0, bytes[6] == 0, bytes[7] == 0,
                  bytes[count - 2] == 0x59, bytes[count - 1] == 0x5A else { return nil }
            let stored = Int(bytes[count - 8]) | Int(bytes[count - 7]) << 8 | Int(bytes[count - 6]) << 16
                | Int(bytes[count - 5]) << 24
            let indexStart = count - 12 - (stored + 1) * 4
            guard indexStart > 12, bytes[indexStart] == 0 else { return nil }
            var at = indexStart + 1
            func number() -> Int? {
                var value = 0
                var shift = 0
                while at < count - 12 && shift < 63 {
                    let byte = bytes[at]
                    at += 1
                    value |= Int(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                }
                return nil
            }
            guard number() == 1, let unpadded = number(), let uncompressed = number(), uncompressed == holds,
                  12 + (unpadded + 3) & ~3 == indexStart else { return nil }
            func le(_ value: UInt32) -> [UInt8] {
                [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                 UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
            }
            func checksum(_ data: [UInt8]) -> UInt32 {
                UInt32(truncatingIfNeeded: data.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
            }
            func varint(_ value: Int) -> [UInt8] {
                var rest = value
                var out: [UInt8] = []
                while rest >= 0x80 {
                    out.append(UInt8(rest & 0x7F) | 0x80)
                    rest >>= 7
                }
                out.append(UInt8(rest))
                return out
            }
            let flags: [UInt8] = [0x00, 0x01]   // check: CRC32
            var index: [UInt8] = [0x00] + varint(1) + varint(unpadded + 4) + varint(uncompressed)
            while index.count % 4 != 0 { index.append(0) }
            index += le(checksum(index))
            let backward = le(UInt32(index.count / 4 - 1))
            var out = Data(capacity: count + 16)
            out.append(contentsOf: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] + flags + le(checksum(flags)))
            out.append(UnsafeBufferPointer(rebasing: bytes[12..<indexStart]))
            out.append(contentsOf: le(crc))
            out.append(contentsOf: index)
            out.append(contentsOf: le(checksum(backward + flags)) + backward + flags + [0x59, 0x5A])
            return out
        }
    }
}
