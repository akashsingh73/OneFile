import Foundation
import Compression
import zlib

/// OneFile's table of contents for its own archives: every entry, with where it is in the tar
/// stream, and each file's SHA-256 (worked out while packing). With it, OneFile lists what's in an
/// archive at once, takes out one file without unpacking the rest, and checks every file.
///
/// It goes after the end of the tar (where every tar reader stops, so other tools never see it),
/// as its own gzip member or xz stream in a compressed archive (in a .tar.zst, a skippable frame,
/// which zstd itself passes over), followed by a 32-byte locator, wrapped the same way, that says
/// where it is. For a compressed archive it also lists where each
/// compressed block starts, which is what lets one file be read from the middle.
struct ArchiveIndex: Sendable {
    enum Kind: UInt8, Sendable {
        case file = 0, folder = 1, symlink = 2, hardLink = 3, fifo = 4
    }

    struct Entry: Sendable, Identifiable, Hashable {
        var id: Int
        /// As in the tar: "Research/data/run.csv"; folders end in "/".
        let path: String
        let kind: Kind
        /// Where its header starts in the tar stream, and where its data does.
        let header: Int64
        let data: Int64
        let size: Int64
        let modified: Int64
        let mode: UInt32
        /// Where a link points (for a hard link, the path of the first name).
        let link: String
        /// SHA-256 of a file's data; empty for everything else.
        let digest: [UInt8]
    }

    /// Where a compressed block starts: in the tar stream, and in the file.
    struct Block: Sendable, Equatable {
        let tar: Int64
        let file: Int64
    }

    var entries: [Entry] = []
    var blocks: [Block] = []
    /// The tar stream's length, its end included.
    var tarSize: Int64 = 0
    /// Where the index starts in the file (the end of the archive's own blocks). Not stored: found
    /// when it's read.
    var start: Int64 = 0

    static let magic = Array("OneFile index 1\n".utf8)
    static let locatorMagic = Array("OFINDEX1".utf8)
    static let locatorSize = 32

    // MARK: Writing

    /// The index or its locator as it goes in a file packed with `method`: as it is in a .tar, in a
    /// gzip member or xz stream of its own, or a skippable frame of a .tar.zst.
    static func wrap(_ bytes: [UInt8], method: PackMethod) -> Data? {
        switch method {
        case .plain: return Data(bytes)
        case .zstd: return Zstd.skippable(bytes)
        case .gzip, .xz:
            var bytes = bytes
            return bytes.withUnsafeMutableBufferPointer { BlockCompressor.compress($0.baseAddress!, $0.count, method) }
        }
    }

    /// The index as bytes: a magic, the counts, the entries, the blocks (little-endian).
    func encode() -> [UInt8] {
        var out = Self.magic
        out.reserveCapacity(64 + entries.count * 100 + blocks.count * 16)
        func u8(_ value: UInt8) { out.append(value) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func i64(_ value: Int64) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func text(_ value: String) {
            let bytes = Array(value.utf8)
            u32(UInt32(bytes.count))
            out.append(contentsOf: bytes)
        }
        i64(tarSize)
        i64(Int64(entries.count))
        for entry in entries {
            text(entry.path)
            u8(entry.kind.rawValue)
            i64(entry.header)
            i64(entry.data)
            i64(entry.size)
            i64(entry.modified)
            u32(entry.mode)
            text(entry.link)
            u8(UInt8(entry.digest.count))
            out.append(contentsOf: entry.digest)
        }
        i64(Int64(blocks.count))
        for block in blocks {
            i64(block.tar)
            i64(block.file)
        }
        return out
    }

    static func decode(_ bytes: [UInt8]) -> ArchiveIndex? {
        guard bytes.count >= magic.count, Array(bytes.prefix(magic.count)) == magic else { return nil }
        var at = magic.count
        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, at + count <= bytes.count else { return nil }
            defer { at += count }
            return bytes[at..<(at + count)]
        }
        func u8() -> UInt8? { take(1)?.first }
        func u32() -> UInt32? {
            take(4).map { slice in slice.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        }
        func i64() -> Int64? {
            take(8).map { slice in Int64(bitPattern: slice.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) }
        }
        func text() -> String? {
            guard let length = u32(), let slice = take(Int(length)) else { return nil }
            return String(decoding: slice, as: UTF8.self)
        }
        var index = ArchiveIndex()
        guard let tarSize = i64(), let count = i64(), count >= 0, count < 1 << 32 else { return nil }
        index.tarSize = tarSize
        index.entries.reserveCapacity(Int(min(count, 10_000_000)))
        for number in 0..<Int(count) {
            guard let path = text(), let kindByte = u8(), let kind = Kind(rawValue: kindByte),
                  let header = i64(), let data = i64(), let size = i64(), let modified = i64(), let mode = u32(),
                  let link = text(), let digestLength = u8(), let digest = take(Int(digestLength)) else { return nil }
            index.entries.append(Entry(id: number, path: path, kind: kind, header: header, data: data, size: size,
                                       modified: modified, mode: mode, link: link, digest: Array(digest)))
        }
        guard let blockCount = i64(), blockCount >= 0, blockCount < 1 << 32 else { return nil }
        for _ in 0..<Int(blockCount) {
            guard let tar = i64(), let file = i64() else { return nil }
            index.blocks.append(Block(tar: tar, file: file))
        }
        return index
    }

    /// What goes in the archive: "OFIX", the index's length, and the index, deflated.
    func container() -> [UInt8]? {
        let raw = encode()
        let capacity = raw.count + raw.count / 8 + 4_096
        var deflated = [UInt8](repeating: 0, count: capacity)
        let count = raw.withUnsafeBufferPointer { input in
            deflated.withUnsafeMutableBufferPointer { output in
                compression_encode_buffer(output.baseAddress!, capacity, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0 else { return nil }
        var out = Array("OFIX".utf8)
        withUnsafeBytes(of: UInt64(raw.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: deflated.prefix(count))
        return out
    }

    static func fromContainer<C: Collection>(_ bytes: C) -> ArchiveIndex? where C.Element == UInt8 {
        let bytes = Array(bytes)
        guard bytes.count > 12, Array(bytes.prefix(4)) == Array("OFIX".utf8) else { return nil }
        let length = Int(bytes[4..<12].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard length > 0, length < 1 << 34 else { return nil }
        var raw = [UInt8](repeating: 0, count: length)
        let count = bytes[12...].withContiguousStorageIfAvailable { input in
            raw.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, length, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        } ?? Array(bytes[12...]).withUnsafeBufferPointer { input in
            raw.withUnsafeMutableBufferPointer { output in
                compression_decode_buffer(output.baseAddress!, length, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == length else { return nil }
        return decode(raw)
    }

    /// The 32 bytes at the end that say where the index is: "OFINDEX1", its offset and length in
    /// the file, and a CRC of those bytes.
    static func locator(offset: Int64, length: Int64, crc: UInt32) -> [UInt8] {
        var out = locatorMagic
        withUnsafeBytes(of: offset.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: length.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: crc.littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: [0, 0, 0, 0])
        return out
    }

    static func parseLocator<C: Collection>(_ bytes: C) -> (offset: Int64, length: Int64, crc: UInt32)? where C.Element == UInt8 {
        let bytes = Array(bytes)
        guard bytes.count == locatorSize, Array(bytes.prefix(8)) == locatorMagic else { return nil }
        func value(_ range: Range<Int>) -> UInt64 { bytes[range].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        return (Int64(bitPattern: value(8..<16)), Int64(bitPattern: value(16..<24)), UInt32(truncatingIfNeeded: value(24..<28)))
    }

    static func crc(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32(0, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(bytes.count)))
    }

    // MARK: Reading

    /// The index of a OneFile archive, if it has one (archives from other tools don't).
    static func read(_ file: InputFile, format: ArchiveFormat) -> ArchiveIndex? {
        // The locator, unwrapped, and where its wrapping starts.
        let found: (bytes: [UInt8], at: Int64)?
        switch format {
        case .tar:
            guard file.size >= Int64(locatorSize), let bytes = file.bytes(locatorSize, at: file.size - Int64(locatorSize)) else { return nil }
            found = (bytes, file.size - Int64(locatorSize))
        case .gzip:
            found = lastGzipMember(file)
        case .zstd:
            let size = Int64(Zstd.skippableHeaderSize + locatorSize)
            guard file.size >= size, let tail = file.bytes(Int(size), at: file.size - size),
                  let payload = Zstd.skippablePayload(tail) else { return nil }
            found = (Array(payload), file.size - size)
        case .xz:
            guard let last = ArchiveDecoder.xzStreams(file)?.last,
                  case .success(let chunk) = ArchiveDecoder.decodeXz(file, last) else { return nil }
            found = (Array(UnsafeRawBufferPointer(start: chunk.base, count: chunk.count)), last.offset)
        }
        guard let found, let place = parseLocator(found.bytes), place.offset >= 0, place.length > 0,
              place.offset + place.length <= found.at, place.length < 1 << 34 else { return nil }
        guard let stored = file.bytes(Int(place.length), at: place.offset),
              stored.withUnsafeBytes({ crc($0) }) == place.crc else { return nil }
        // Unwrap the index the way the archive is compressed.
        var index: ArchiveIndex?
        switch format {
        case .tar:
            index = fromContainer(stored)
        case .gzip:
            // The index can be bigger than the blocks of the tar stream (millions of files): no
            // limit but the header's own.
            guard let member = ArchiveDecoder.indexedMember(Array(stored.prefix(32)), limit: Int(UInt32.max)),
                  case .success(let chunk) = ArchiveDecoder.inflateMember(file, at: place.offset, size: member.size,
                                                                          holds: member.holds) else { return nil }
            index = fromContainer(UnsafeRawBufferPointer(start: chunk.base, count: chunk.count))
        case .zstd:
            guard let payload = Zstd.skippablePayload(stored) else { return nil }
            index = fromContainer(payload)
        case .xz:
            guard let stream = ArchiveDecoder.xzStreams(file)?.first(where: { $0.offset == place.offset }),
                  case .success(let chunk) = ArchiveDecoder.decodeXz(file, stream) else { return nil }
            index = fromContainer(UnsafeRawBufferPointer(start: chunk.base, count: chunk.count))
        }
        index?.start = place.offset
        return index
    }

    /// A OneFile .tar.gz ends with a small member holding the locator: found by its own header,
    /// which says how long it is.
    private static func lastGzipMember(_ file: InputFile) -> (bytes: [UInt8], at: Int64)? {
        let span = Int(min(file.size, 256))
        guard let tail = file.bytes(span, at: file.size - Int64(span)) else { return nil }
        for start in stride(from: span - 40, through: 0, by: -1) where tail[start] == 0x1F && tail[start + 1] == 0x8B {
            guard let member = ArchiveDecoder.indexedMember(Array(tail[start...])),
                  start + member.size == span, member.holds == locatorSize else { continue }
            let at = file.size - Int64(span - start)
            guard case .success(let chunk) = ArchiveDecoder.inflateMember(file, at: at, size: member.size, holds: member.holds) else {
                return nil
            }
            return (Array(UnsafeRawBufferPointer(start: chunk.base, count: chunk.count)), at)
        }
        return nil
    }

    // MARK: Using it

    /// The compressed block holding tar offset `offset`, and where it ends in the file.
    func block(holding offset: Int64) -> (index: Int, start: Int64, end: Int64)? {
        guard !blocks.isEmpty else { return nil }
        var low = 0, high = blocks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if blocks[middle].tar <= offset { low = middle } else { high = middle - 1 }
        }
        guard blocks[low].tar <= offset else { return nil }
        let end = low + 1 < blocks.count ? blocks[low + 1].file : start
        return (low, blocks[low].file, end)
    }

    /// The file's own folders and files (what's at the top first), for listing.
    var files: [Entry] { entries.filter { $0.kind == .file } }
}
