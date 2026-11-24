import Foundation

/// The tar format, written straight into memory: POSIX.1-2001 ("pax"), which every tar program
/// reads, on macOS, Linux and Windows 10 and later. Each entry gets a plain ustar header; an
/// extended header goes in front of it only for what ustar can't hold: paths that are long or not
/// plain ASCII, files of 8 GiB or more, dates before 1970, and the like.
enum Tar {
    static let blockSize = 512
    /// tar ends a file with two empty blocks, and pads it to a whole record of 20 blocks.
    static let recordSize: Int64 = 10_240

    enum EntryType: UInt8, Sendable {
        case file = 0x30            // "0"
        case hardLink = 0x31        // "1": another name for a file earlier in the tar file
        case symbolicLink = 0x32    // "2"
        case directory = 0x35       // "5"
        case fifo = 0x36            // "6"
        case extendedHeader = 0x78  // "x"
    }

    /// What a header says about one entry.
    struct Header: Sendable {
        /// The path inside the tar file. Folders end in "/".
        var path: String
        var type: EntryType
        /// Bytes of data that follow the header: a file's size, 0 for everything else.
        var size: Int64
        var mode: UInt32
        var owner: UInt32
        var group: UInt32
        /// Seconds since 1970.
        var modified: Int64
        /// Where a link points: for a symbolic link, the path it holds; for a hard link, the path
        /// of the first name in the tar file.
        var linkTarget: String
    }

    /// The largest numbers ustar's 12- and 8-byte octal fields hold.
    static let largest11Digits: Int64 = 0o77777777777
    static let largest7Digits: UInt32 = 0o7777777

    /// Rounds a byte count up to whole blocks.
    @inline(__always)
    static func padded(_ count: Int64) -> Int64 { (count + 511) & ~511 }

    /// Bytes that end the tar file, after `written` bytes of entries.
    static func trailerBytes(after written: Int64) -> Int64 {
        let end = written + 1_024
        return 1_024 + (recordSize - end % recordSize) % recordSize
    }

    // MARK: - Extended headers

    /// The extended header's records for what the ustar header can't hold, or nil when it holds it all.
    static func extendedRecords(for header: Header) -> [UInt8]? {
        var path = header.path
        let pathFits = path.withUTF8 { ustarSplit($0) != nil }
        var link = header.linkTarget
        let linkFits = link.withUTF8 { fits($0, 100) }
        let sizeFits = header.size <= largest11Digits
        let timeFits = header.modified >= 0 && header.modified <= largest11Digits
        let idsFit = header.owner <= largest7Digits && header.group <= largest7Digits
        if pathFits && linkFits && sizeFits && timeFits && idsFit { return nil }

        var records: [UInt8] = []
        if !pathFits { records += record("path", header.path) }
        if !linkFits { records += record("linkpath", header.linkTarget) }
        if !sizeFits { records += record("size", String(header.size)) }
        if !timeFits { records += record("mtime", String(header.modified)) }
        if header.owner > largest7Digits { records += record("uid", String(header.owner)) }
        if header.group > largest7Digits { records += record("gid", String(header.group)) }
        return records
    }

    /// One extended header record: "LENGTH key=value\n", where LENGTH counts the whole record,
    /// its own digits included.
    static func record(_ key: String, _ value: String) -> [UInt8] {
        let body = Array(" \(key)=\(value)\n".utf8)
        var length = body.count + 1
        while String(length).utf8.count + body.count != length {
            length = String(length).utf8.count + body.count
        }
        return Array(String(length).utf8) + body
    }

    /// Bytes an entry's headers take: the ustar header, and the extended header if it has one.
    static func headerBytes(extended: [UInt8]?) -> Int {
        guard let extended else { return blockSize }
        return 2 * blockSize + Int(padded(Int64(extended.count)))
    }

    // MARK: - Writing headers

    /// Writes the entry's headers (`headerBytes` of them) at `start` and returns how many bytes that was.
    static func write(_ header: Header, extended: [UInt8]?, to start: UnsafeMutablePointer<UInt8>) -> Int {
        var at = start
        if let extended {
            // Readers that know pax take the real values from here; the name is only a label.
            var name = Array("PaxHeader/".utf8)
            name += asciiTail(header.path, 100 - name.count)
            name.withUnsafeBufferPointer { name in
                writeUstar(at, name: name, prefix: UnsafeBufferPointer(start: nil, count: 0),
                           type: .extendedHeader, size: Int64(extended.count), mode: 0o644, owner: 0, group: 0,
                           modified: clamped(header.modified), link: UnsafeBufferPointer(start: nil, count: 0))
            }
            at += blockSize
            extended.withUnsafeBufferPointer { at.initialize(from: $0.baseAddress!, count: $0.count) }
            let padding = Int(padded(Int64(extended.count))) - extended.count
            (at + extended.count).initialize(repeating: 0, count: padding)
            at += extended.count + padding
        }

        // The ustar header. Where the extended header holds the real value, the field holds a
        // stand-in for readers that don't know pax.
        var path = header.path
        var link = header.linkTarget
        let linkBytes: [UInt8] = link.withUTF8 { fits($0, 100) ? Array($0) : asciiTail(header.linkTarget, 100) }
        let size = header.size <= largest11Digits ? header.size : 0
        let owner = header.owner <= largest7Digits ? header.owner : 0
        let group = header.group <= largest7Digits ? header.group : 0
        path.withUTF8 { bytes in
            linkBytes.withUnsafeBufferPointer { link in
                if let split = ustarSplit(bytes) {
                    let prefix = split == 0 ? UnsafeBufferPointer(start: nil, count: 0)
                                            : UnsafeBufferPointer(rebasing: bytes[0..<split])
                    let name = split == 0 ? bytes : UnsafeBufferPointer(rebasing: bytes[(split + 1)...])
                    writeUstar(at, name: name, prefix: prefix, type: header.type, size: size, mode: header.mode,
                               owner: owner, group: group, modified: clamped(header.modified), link: link)
                } else {
                    asciiTail(header.path, 100).withUnsafeBufferPointer { name in
                        writeUstar(at, name: name, prefix: UnsafeBufferPointer(start: nil, count: 0),
                                   type: header.type, size: size, mode: header.mode, owner: owner, group: group,
                                   modified: clamped(header.modified), link: link)
                    }
                }
            }
        }
        return at + blockSize - start
    }

    /// How a path goes in a ustar header: nil when it can't (it isn't plain ASCII, or no split
    /// fits), 0 when it fits in the 100-byte name field, else the length of the part that goes in
    /// the 155-byte prefix field, before the "/" the path is split at.
    static func ustarSplit(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        let count = bytes.count
        for byte in bytes where byte >= 0x80 { return nil }
        if count <= 100 { return 0 }
        if count > 256 { return nil }
        // The name (after the "/") holds at most 100 bytes and can't be empty, so a folder's
        // trailing "/" is never the split.
        var split = max(count - 101, 1)
        while split <= min(155, count - 2) {
            if bytes[split] == 0x2F { return split }
            split += 1
        }
        return nil
    }

    private static func fits(_ bytes: UnsafeBufferPointer<UInt8>, _ limit: Int) -> Bool {
        guard bytes.count <= limit else { return false }
        for byte in bytes where byte >= 0x80 { return false }
        return true
    }

    /// The end of `text`, at most `limit` bytes, with anything that isn't plain ASCII made "_".
    private static func asciiTail(_ text: String, _ limit: Int) -> [UInt8] {
        let bytes = text.utf8.map { $0 < 0x80 ? $0 : 0x5F }
        return Array(bytes.suffix(limit))
    }

    private static func clamped(_ time: Int64) -> Int64 {
        min(max(time, 0), largest11Digits)
    }

    private static func writeUstar(_ h: UnsafeMutablePointer<UInt8>, name: UnsafeBufferPointer<UInt8>,
                                   prefix: UnsafeBufferPointer<UInt8>, type: EntryType, size: Int64,
                                   mode: UInt32, owner: UInt32, group: UInt32, modified: Int64,
                                   link: UnsafeBufferPointer<UInt8>) {
        h.initialize(repeating: 0, count: blockSize)
        copy(name, to: h, limit: 100)
        octal(UInt64(mode & 0o7777), h + 100, width: 8)
        octal(UInt64(owner), h + 108, width: 8)
        octal(UInt64(group), h + 116, width: 8)
        octal(UInt64(size), h + 124, width: 12)
        octal(UInt64(modified), h + 136, width: 12)
        h[156] = type.rawValue
        copy(link, to: h + 157, limit: 100)
        // "ustar\0" then version "00"
        h[257] = 0x75; h[258] = 0x73; h[259] = 0x74; h[260] = 0x61; h[261] = 0x72; h[262] = 0
        h[263] = 0x30; h[264] = 0x30
        octal(0, h + 329, width: 8)     // device major and minor: not a device
        octal(0, h + 337, width: 8)
        copy(prefix, to: h + 345, limit: 155)
        // The checksum: the sum of the header's bytes, counting its own field as spaces.
        (h + 148).initialize(repeating: 0x20, count: 8)
        var sum: UInt64 = 0
        for index in 0..<blockSize { sum += UInt64(h[index]) }
        octal(sum, h + 148, width: 7)
        h[155] = 0x20
    }

    @inline(__always)
    private static func copy(_ bytes: UnsafeBufferPointer<UInt8>, to field: UnsafeMutablePointer<UInt8>, limit: Int) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        field.update(from: base, count: min(bytes.count, limit))
    }

    /// `width - 1` octal digits, then a NUL.
    @inline(__always)
    private static func octal(_ value: UInt64, _ field: UnsafeMutablePointer<UInt8>, width: Int) {
        var rest = value
        var index = width - 2
        while index >= 0 {
            field[index] = 0x30 &+ UInt8(truncatingIfNeeded: rest & 7)
            rest >>= 3
            index -= 1
        }
        field[width - 1] = 0
    }
}
