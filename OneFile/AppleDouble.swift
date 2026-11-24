import Foundation

/// The "._" files macOS writes next to files on drives that can't keep extended attributes
/// themselves (exFAT, FAT, some network drives): AppleDouble, holding a file's Finder info,
/// resource fork and extended attributes (Finder tags, where it was downloaded from…).
///
/// Asking for a file's attributes on such a drive makes macOS open and read its "._" file, for
/// the list and again for each attribute: on a USB exFAT drive that made copying 20,000 small
/// files 3.5× slower. Reading the "._" file once, as a file, and taking it apart here is about as
/// quick as copying any small file.
enum AppleDouble {
    struct Attribute: Equatable, Sendable {
        let name: String
        let value: [UInt8]
    }

    static let magic: UInt32 = 0x0005_1607
    private static let attributesMagic: UInt32 = 0x4154_5452  // "ATTR"
    private static let resourceFork: UInt32 = 2
    private static let finderInfo: UInt32 = 9

    /// The attributes an AppleDouble file holds, Finder info and resource fork included (under
    /// their attribute names). Nil if it isn't one, or doesn't hang together.
    static func attributes(_ bytes: UnsafeRawBufferPointer) -> [Attribute]? {
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
        }
        func u16(_ at: Int) -> UInt16? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            return UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self))
        }
        func slice(_ offset: Int, _ length: Int) -> [UInt8]? {
            guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else { return nil }
            return Array(bytes[offset..<(offset + length)])
        }
        guard u32(0) == magic, let version = u32(4), version == 0x0002_0000, let count = u16(24) else { return nil }

        var attributes: [Attribute] = []
        for index in 0..<Int(count) {
            let at = 26 + index * 12
            guard let type = u32(at), let offset = u32(at + 4), let length = u32(at + 8),
                  Int(offset) + Int(length) <= bytes.count else { return nil }
            let start = Int(offset), size = Int(length)
            switch type {
            case finderInfo:
                guard size >= 32, let info = slice(start, 32) else { return nil }
                if info.contains(where: { $0 != 0 }) {
                    attributes.append(Attribute(name: "com.apple.FinderInfo", value: info))
                }
                // Extended attributes follow the Finder info, after two bytes of padding.
                let header = start + 34
                guard size >= 34 + 36, u32(header) == attributesMagic else { continue }
                guard let total = u16(header + 34) else { return nil }
                var entry = header + 36
                for _ in 0..<Int(total) {
                    guard let valueOffset = u32(entry), let valueLength = u32(entry + 4),
                          entry + 11 <= bytes.count else { return nil }
                    let nameLength = Int(bytes[entry + 10])
                    guard nameLength > 0, let nameBytes = slice(entry + 11, nameLength),
                          let value = slice(Int(valueOffset), Int(valueLength)) else { return nil }
                    // The name ends in a NUL, counted in its length.
                    let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
                    if !name.isEmpty { attributes.append(Attribute(name: name, value: value)) }
                    // Each entry's length is rounded up to a multiple of four.
                    entry += (11 + nameLength + 3) & ~3
                }
            case resourceFork:
                guard size > 0 else { continue }
                guard let fork = slice(start, size) else { return nil }
                attributes.append(Attribute(name: "com.apple.ResourceFork", value: fork))
            default:
                continue
            }
        }
        return attributes
    }

    /// A folder's entries without the "._" files that belong to another entry in it, and with
    /// those entries marked (`hasAppleDouble`). A "._" file with nothing beside it is kept.
    static func pair(_ entries: [FolderEntry]) -> [FolderEntry] {
        var names = Set<String>()
        for entry in entries where !entry.name.hasPrefix("._") { names.insert(entry.name) }
        var owners = Set<String>()
        for entry in entries where entry.kind == .file && entry.name.hasPrefix("._") {
            let owner = String(entry.name.dropFirst(2))
            if names.contains(owner) { owners.insert(owner) }
        }
        guard !owners.isEmpty else { return entries }
        var kept: [FolderEntry] = []
        kept.reserveCapacity(entries.count - owners.count)
        for var entry in entries {
            if entry.kind == .file, entry.name.hasPrefix("._"), owners.contains(String(entry.name.dropFirst(2))) { continue }
            if owners.contains(entry.name) { entry.hasAppleDouble = true }
            kept.append(entry)
        }
        return kept
    }

    /// Whether a copy should carry this attribute, as macOS decides for Finder's copies (some are
    /// only meaningful on the original: they're left behind). macOS's provenance tag is never
    /// copied: the system sets its own.
    static func copies(_ name: String) -> Bool {
        if name == "com.apple.provenance" { return false }
        return name.withCString { xattr_preserve_for_intent($0, xattr_operation_intent_t(XATTR_OPERATION_INTENT_COPY)) } != 0
    }

    /// Gives the open file `fd` the attributes. False if any couldn't be set (and copied).
    @discardableResult
    static func apply(_ attributes: [Attribute], to fd: Int32) -> Bool {
        var allSet = true
        for attribute in attributes where copies(attribute.name) {
            let result = attribute.value.withUnsafeBytes { value in
                fsetxattr(fd, attribute.name, value.baseAddress, value.count, 0, 0)
            }
            if result != 0 { allSet = false }
        }
        return allSet
    }
}
