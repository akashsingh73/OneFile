import Foundation

/// How the tar file is compressed, if at all. Fastest, Balanced and Smallest make files that
/// macOS opens with a double-click (Archive Utility) and Linux with `tar -xf`, without installing
/// anything. Efficient's .tar.zst is smaller than Balanced's and quicker to make, but it opens only
/// where OneFile or zstd is.
///
/// Measured on an M4 Max, packing macOS's own /usr/share (534 MB of mixed text and binaries, 19,270
/// files), one method after another: without compressing it took 0.22 s; gzip level 1, on all
/// cores, 0.42 s to 37% of the size (level 6 compresses at a third of the speed, to 33%); zstd level
/// 3, 0.23 s to 31% (reading the files is what held it back: compressing alone, it ran 3.5 times
/// as fast as gzip); xz, 9.6 s to 21%. On photos and video (already compressed) none got any
/// smaller.
enum PackMethod: String, CaseIterable, Identifiable, Sendable {
    case plain
    case gzip
    case zstd
    case xz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Fastest"
        case .gzip: "Balanced"
        case .zstd: "Efficient"
        case .xz: "Smallest"
        }
    }

    var format: String {
        switch self {
        case .plain: "No compression"
        case .gzip: "gzip"
        case .zstd: "zstd"
        case .xz: "xz"
        }
    }

    var fileExtension: String {
        switch self {
        case .plain: "tar"
        case .gzip: "tar.gz"
        case .zstd: "tar.zst"
        case .xz: "tar.xz"
        }
    }

    var symbol: String {
        switch self {
        case .plain: "bolt.fill"
        case .gzip: "gauge.with.dots.needle.50percent"
        case .zstd: "gauge.with.dots.needle.67percent"
        case .xz: "arrow.down.right.and.arrow.up.left"
        }
    }

    /// What it's for, in a sentence.
    var advice: String {
        switch self {
        case .plain:
            "Packs as fast as your disks allow. Best for photos and video, or for copying to a drive."
        case .gzip:
            "Compresses on every core as it packs: smaller, and still fast. Best for sending over the internet."
        case .zstd:
            "Smaller than Balanced, and quicker, on every core. Best when OneFile will open it: for keeping, or for Macs with OneFile."
        case .xz:
            "Squeezes hardest, but takes far longer. For slow uploads, or for keeping."
        }
    }

    /// Where the file opens without installing anything.
    var opensWith: String {
        switch self {
        case .plain, .gzip:
            "Opens anywhere: double-click it on a Mac, or tar -xf on Windows and Linux."
        case .zstd:
            "Opens in OneFile, and with tar -xf where zstd is installed: most Linux has it; on a Mac, brew install zstd."
        case .xz:
            "Opens with a double-click on a Mac and tar -xf on Linux; on Windows, use 7-Zip."
        }
    }

    /// Bytes of the tar stream compressed as one independent piece (a gzip member, a zstd frame,
    /// an xz stream). Bigger pieces compress a little better but take more memory.
    var blockSize: Int {
        switch self {
        case .plain: 0
        case .gzip: 4 << 20
        case .zstd: 8 << 20
        case .xz: 16 << 20
        }
    }

    /// How many pieces are compressed at once. xz needs about 100 MB of memory for each, so
    /// it uses fewer on Macs with less memory.
    var workers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch self {
        case .plain: return 0
        case .gzip, .zstd: return max(cores, 1)
        case .xz:
            let gigabytes = Int(ProcessInfo.processInfo.physicalMemory >> 30)
            return max(1, min(cores, gigabytes))
        }
    }
}

/// File names with tar's double extensions: "Research.tar.gz" is "Research" plus "tar.gz".
enum ArchiveName {
    private static let extensions = ["tar.gz", "tar.xz", "tar.zst", "tgz", "txz", "tzst", "tar"]

    /// The name without a tar extension, and the extension (nil if there isn't one).
    static func split(_ name: String) -> (base: String, ext: String?) {
        // Locked with a password: the tar extension is before ".age".
        let name = name.lowercased().hasSuffix(".age") && name.count > 4 ? String(name.dropLast(4)) : name
        let lower = name.lowercased()
        for ext in extensions where lower.hasSuffix("." + ext) && lower.count > ext.count + 1 {
            return (String(name.dropLast(ext.count + 1)), String(name.suffix(ext.count)))
        }
        return (name, nil)
    }

    /// The same file with the method's extension in place of any tar extension it had.
    static func with(_ url: URL, method: PackMethod) -> URL {
        let base = split(url.lastPathComponent).base
        return url.deletingLastPathComponent().appendingPathComponent(base + "." + method.fileExtension)
    }

    /// What unpacking a file with this name makes: "Research" for "Research.tar.gz", and for a
    /// single compressed file, "notes.txt" for "notes.txt.gz".
    static func unpackedName(_ name: String) -> String {
        var name = SplitParts.wholeName(name)
        // Locked with a password: "Research.tar.gz.age".
        if name.lowercased().hasSuffix(".age") && name.count > 4 { name = String(name.dropLast(4)) }
        let (base, ext) = split(name)
        if ext != nil { return base }
        let lower = name.lowercased()
        for ext in ["gz", "xz", "zst"] where lower.hasSuffix("." + ext) && lower.count > ext.count + 1 {
            return String(name.dropLast(ext.count + 1))
        }
        return name
    }

    /// "Research 2.tar.gz" for "Research.tar.gz" and 2.
    static func numbered(_ url: URL, _ number: Int) -> URL {
        let (base, ext) = split(url.lastPathComponent)
        let name = ext.map { "\(base) \(number).\($0)" } ?? "\(base) \(number)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}

/// A file split into parts ("Research.tar.gz.001", ".002"…), read back one part after another.
enum SplitParts {
    /// For any part of a split file, all its parts in order, from ".001" for as long as they follow
    /// on. Nil if it isn't one.
    static func parts(of url: URL) -> [URL]? {
        let name = url.lastPathComponent
        guard isPartName(name) else { return nil }
        let base = url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(4))).path
        var found: [URL] = []
        for number in 1...999 {
            let path = base + String(format: ".%03d", number)
            guard FileManager.default.fileExists(atPath: path) else { break }
            found.append(URL(fileURLWithPath: path))
        }
        let chosen = url.standardizedFileURL.path
        return found.contains { $0.standardizedFileURL.path == chosen } ? found : nil
    }

    /// "Research.tar.gz" for "Research.tar.gz.001"; other names as they are.
    static func wholeName(_ name: String) -> String {
        isPartName(name) ? String(name.dropLast(4)) : name
    }

    /// Ends in a dot and three digits, after something.
    static func isPartName(_ name: String) -> Bool {
        let utf8 = Array(name.utf8)
        guard utf8.count > 4, utf8[utf8.count - 4] == UInt8(ascii: ".") else { return false }
        return utf8.suffix(3).allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}
