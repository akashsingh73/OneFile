import Foundation
import CZstd

/// zstd, from its own library (Vendor/zstd): the Efficient method's .tar.zst.
///
/// OneFile writes a .tar.zst the way pzstd, zstd's own parallel tool, does. The tar stream is cut
/// into blocks, each compressed on its own into a zstd frame, on every core, and before each frame
/// goes a 12-byte skippable frame (which every zstd reader passes over) saying how long the frame
/// is. Each frame says how much it holds, and carries a checksum of it. So OneFile can find every
/// frame without decompressing the ones before it, and decompress them all at once; to `zstd`,
/// `tar` and every other reader, it's one stream.
///
/// OneFile's index, and the locator that finds it, go after the last frame in skippable frames of
/// their own, so what any zstd reader decompresses ends where the tar does. (Were they frames,
/// `tar` would stop reading at the end of the tar while `zstd` still had them to write out, and
/// `zstd` fails when it can't write.)
enum Zstd {
    /// zstd's own default.
    static let level: Int32 = 3

    /// The skippable frame before each frame: zstd's first skippable magic number, the length of
    /// what follows it (4), and the length of the frame after it. All little-endian.
    static let headerSize = 12
    static let skippableMagic: UInt32 = 0x184D2A50
    static let frameMagic: UInt32 = 0xFD2FB528
    /// Enough of a block's start to read both headers: the skippable frame's, and the frame's own
    /// (at most 18 bytes), which says how much it holds.
    static let peekSize = headerSize + 18
    /// The skippable frames holding OneFile's index and its locator: zstd's last skippable magic
    /// number, then the length of what follows.
    static let indexMagic: UInt32 = 0x184D2A5F
    static let skippableHeaderSize = 8

    /// Bytes in a skippable frame of OneFile's (for the index and its locator).
    static func skippable(_ payload: [UInt8]) -> Data? {
        guard payload.count <= Int(UInt32.max) else { return nil }
        var out = Data(count: skippableHeaderSize + payload.count)
        out.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            BlockCompressor.littleEndian32(indexMagic, base)
            BlockCompressor.littleEndian32(UInt32(payload.count), base + 4)
            payload.withUnsafeBufferPointer { (base + skippableHeaderSize).update(from: $0.baseAddress!, count: $0.count) }
        }
        return out
    }

    /// What's in a skippable frame of OneFile's that's exactly `bytes`. Nil if it isn't one.
    static func skippablePayload(_ bytes: [UInt8]) -> ArraySlice<UInt8>? {
        guard bytes.count >= skippableHeaderSize else { return nil }
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard word(0) == indexMagic, Int(word(4)) == bytes.count - skippableHeaderSize else { return nil }
        return bytes[skippableHeaderSize...]
    }

    /// How long a skippable frame starting `bytes` is, header and all: any of zstd's sixteen kinds.
    static func skippableSize(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= skippableHeaderSize, bytes[0] & 0xF0 == 0x50, bytes[1] == 0x2A, bytes[2] == 0x4D,
              bytes[3] == 0x18 else { return nil }
        return skippableHeaderSize + (Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24)
    }

    /// One block of the tar stream compressed: the skippable frame, then the frame.
    static func block(_ input: UnsafePointer<UInt8>, _ count: Int, level: Int32 = level) -> Data? {
        guard let context = ZSTD_createCCtx() else { return nil }
        defer { ZSTD_freeCCtx(context) }
        guard ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, level)) == 0,
              ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)) == 0 else { return nil }
        let bound = ZSTD_compressBound(count)
        var out = Data(count: headerSize + bound)
        let total = out.withUnsafeMutableBytes { raw -> Int? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            // ZSTD_compress2 knows the size, so the frame's header says it.
            let written = ZSTD_compress2(context, base + headerSize, bound, input, count)
            guard ZSTD_isError(written) == 0, written <= Int(UInt32.max) else { return nil }
            BlockCompressor.littleEndian32(skippableMagic, base)
            BlockCompressor.littleEndian32(4, base + 4)
            BlockCompressor.littleEndian32(UInt32(written), base + 8)
            return headerSize + written
        }
        guard let total else { return nil }
        out.count = total
        return out
    }

    /// What the start of a block says: how long it is (skippable frame and all) and how much it
    /// holds. Nil if it doesn't start that way, the frame doesn't say how much it holds, or either
    /// is more than `limit`.
    static func header<C: Collection>(_ bytes: C, limit: Int = ArchiveDecoder.largestPiece) -> (size: Int, holds: Int)?
    where C.Element == UInt8 {
        let bytes = Array(bytes.prefix(peekSize))
        guard bytes.count >= headerSize + 6 else { return nil }
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard word(0) == skippableMagic, word(4) == 4, word(headerSize) == frameMagic else { return nil }
        let frame = Int(word(8))
        // UInt64.max and one less: zstd's "unknown" and "error".
        let holds = bytes.withUnsafeBufferPointer {
            ZSTD_getFrameContentSize($0.baseAddress! + headerSize, $0.count - headerSize)
        }
        guard frame > 0, frame <= limit, holds < UInt64.max - 1, holds <= UInt64(limit) else { return nil }
        return (headerSize + frame, Int(holds))
    }

    /// Decompresses whole frames (passing over skippable ones) that hold `holds` bytes in all,
    /// checking each frame's checksum.
    static func decompress(_ input: UnsafeRawBufferPointer, holds: Int) -> Chunk? {
        guard let base = input.baseAddress, let context = ZSTD_createDCtx() else { return nil }
        defer { ZSTD_freeDCtx(context) }
        let chunk = Chunk(capacity: holds)
        let produced = ZSTD_decompressDCtx(context, chunk.base, chunk.capacity, base, input.count)
        guard ZSTD_isError(produced) == 0, produced == holds else { return nil }
        chunk.count = holds
        return chunk
    }
}

// MARK: - Decoding a .tar.zst

extension ArchiveDecoder {
    /// OneFile's frames (and pzstd's, when they say how much they hold), each found from the
    /// skippable frame before it, decompressed on every core. Other skippable frames (OneFile's
    /// index) are passed over unread; anything else after them is read in order.
    static func readIndexedZstd(_ file: InputFile, _ pipeline: OrderedPipeline) {
        var offset: Int64 = 0
        while offset < file.size {
            guard let head = file.bytes(Int(min(Int64(Zstd.peekSize), file.size - offset)), at: offset) else { break }
            if let block = Zstd.header(head), offset + Int64(block.size) <= file.size {
                let at = offset
                guard pipeline.submit({ decodeZstd(file, at: at, size: block.size, holds: block.holds) }) else { return }
                offset += Int64(block.size)
            } else if let skipped = Zstd.skippableSize(head), offset + Int64(skipped) <= file.size {
                offset += Int64(skipped)
            } else {
                break
            }
        }
        if offset < file.size {
            readZstd(file, from: offset, pipeline)
        } else {
            pipeline.finish()
        }
    }

    static func decodeZstd(_ file: InputFile, at offset: Int64, size: Int, holds: Int) -> Result<Chunk, DecodeError> {
        let input = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
        defer { input.deallocate() }
        guard file.read(size, at: offset, into: input) else { return .failure(DecodeError(message: unreadable)) }
        guard let chunk = Zstd.decompress(UnsafeRawBufferPointer(start: input, count: size), holds: holds) else {
            return .failure(DecodeError(message: damaged(offset)))
        }
        chunk.inputEnd = offset + Int64(size)
        return .success(chunk)
    }

    /// Decompresses zstd frames one after another, from `start` to the end of the file: a .tar.zst
    /// from anything (`zstd`, `tar --zstd`…), on one core.
    static func readZstd(_ file: InputFile, from start: Int64, _ pipeline: OrderedPipeline) {
        guard let stream = ZSTD_createDStream() else {
            pipeline.fail("Couldn't start decompressing.")
            return
        }
        defer { ZSTD_freeDStream(stream) }
        // Up to zstd's largest window (`zstd --long=31`): the memory is only taken if a frame needs it.
        _ = ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 31)
        let capacity = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var input = ZSTD_inBuffer(src: buffer, size: 0, pos: 0)
        var offset = start
        var chunk = Chunk(capacity: chunkSize)
        // What zstd last said: 0 between frames, else how much more it wants.
        var wants = 0

        func emit() -> Bool {
            chunk.inputEnd = offset - Int64(input.size - input.pos)
            let full = chunk
            chunk = Chunk(capacity: chunkSize)
            return pipeline.submit(full)
        }

        while true {
            if input.pos == input.size && offset < file.size {
                let want = Int(min(Int64(capacity), file.size - offset))
                guard file.read(want, at: offset, into: buffer) else {
                    pipeline.fail(unreadable)
                    return
                }
                input = ZSTD_inBuffer(src: buffer, size: want, pos: 0)
                offset += Int64(want)
            }
            let drained = input.pos == input.size
            if drained && wants == 0 { break }
            var output = ZSTD_outBuffer(dst: chunk.base + chunk.count, size: chunk.capacity - chunk.count, pos: 0)
            let result = ZSTD_decompressStream(stream, &output, &input)
            guard ZSTD_isError(result) == 0 else {
                pipeline.fail(damaged(offset - Int64(input.size - input.pos)))
                return
            }
            chunk.count += output.pos
            wants = result
            if chunk.count == chunk.capacity {
                guard emit() else { return }
            }
            // The file has ended, part way through a frame.
            if drained && output.pos == 0 && result != 0 {
                pipeline.fail(endsEarly)
                return
            }
        }
        if chunk.count > 0 {
            guard emit() else { return }
        }
        pipeline.finish()
    }
}
