import Foundation

/// How the tar file is compressed, if at all. Every one makes a file that macOS opens with a
/// double-click (Archive Utility) and Linux with `tar -xf`, without installing anything.
///
/// Measured on an M4 Max on macOS's own /usr/share (523 MB of mixed text and binaries):
/// gzip level 1 on all cores ran at 1.6 GB/s to 36% of the size, gzip level 6 at 560 MB/s to 33%,
/// and xz at 63 MB/s to 20%. On photos and video (already compressed) neither got any smaller.
/// zstd beats gzip on both counts but isn't offered: neither macOS nor Windows can open a
/// `.tar.zst` without installing something.
enum PackMethod: String, CaseIterable, Identifiable, Sendable {
    case plain
    case gzip
    case xz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: "Fastest"
        case .gzip: "Balanced"
        case .xz: "Smallest"
        }
    }

    var format: String {
        switch self {
        case .plain: "No compression"
        case .gzip: "gzip"
        case .xz: "xz"
        }
    }

    var fileExtension: String {
        switch self {
        case .plain: "tar"
        case .gzip: "tar.gz"
        case .xz: "tar.xz"
        }
    }

    var symbol: String {
        switch self {
        case .plain: "bolt.fill"
        case .gzip: "gauge.with.dots.needle.50percent"
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
        case .xz:
            "Squeezes hardest, but takes far longer. For slow uploads, or for keeping."
        }
    }

    /// Where the file opens without installing anything.
    var opensWith: String {
        switch self {
        case .plain, .gzip:
            "Opens anywhere: double-click it on a Mac, or tar -xf on Windows and Linux."
        case .xz:
            "Opens with a double-click on a Mac and tar -xf on Linux; on Windows, use 7-Zip."
        }
    }

    /// Bytes of the tar stream compressed as one independent piece (a gzip member, an xz stream).
    /// Bigger pieces compress a little better but take more memory.
    var blockSize: Int {
        switch self {
        case .plain: 0
        case .gzip: 4 << 20
        case .xz: 16 << 20
        }
    }

    /// How many pieces are compressed at once. xz needs about 100 MB of memory for each, so
    /// it uses fewer on Macs with less memory.
    var workers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch self {
        case .plain: return 0
        case .gzip: return max(cores, 1)
        case .xz:
            let gigabytes = Int(ProcessInfo.processInfo.physicalMemory >> 30)
            return max(1, min(cores, gigabytes))
        }
    }
}

/// File names with tar's double extensions: "Research.tar.gz" is "Research" plus "tar.gz".
enum ArchiveName {
    private static let extensions = ["tar.gz", "tar.xz", "tgz", "txz", "tar"]

    /// The name without a tar extension, and the extension (nil if there isn't one).
    static func split(_ name: String) -> (base: String, ext: String?) {
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
        let (base, ext) = split(name)
        if ext != nil { return base }
        let lower = name.lowercased()
        for ext in ["gz", "xz"] where lower.hasSuffix("." + ext) && lower.count > ext.count + 1 {
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
