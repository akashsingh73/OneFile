import Foundation

// MARK: - Kinds of files

/// What sort of file something is, going by its name's extension: to show what a folder (or a tar
/// file) holds, and why it will or won't compress.
enum FileKind: Int, CaseIterable, Sendable {
    case video, images, audio, documents, code, archives, apps, other

    var title: String {
        switch self {
        case .video: "Video"
        case .images: "Images"
        case .audio: "Audio"
        case .documents: "Documents"
        case .code: "Code"
        case .archives: "Archives"
        case .apps: "Apps & libraries"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .images: "photo"
        case .audio: "waveform"
        case .documents: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archives: "archivebox"
        case .apps: "app.dashed"
        case .other: "doc"
        }
    }

    /// Stored compressed already, so compressing it again gains next to nothing.
    var isCompressed: Bool {
        switch self {
        case .video, .images, .audio, .archives: true
        default: false
        }
    }

    private static let byExtension: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { table[String(ext)] = kind }
        }
        add(.video, "mov mp4 m4v avi mkv webm mpg mpeg 3gp mts m2ts wmv flv braw r3d mxf vob")
        add(.images, "jpg jpeg png heic heif gif tif tiff bmp webp avif raw cr2 cr3 nef arw dng orf rw2 raf psd svg ico icns exr hdr jxl")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf alac mid midi wma amr")
        add(.documents, "pdf doc docx xls xlsx ppt pptx key pages numbers txt md rtf csv tsv json xml html htm epub odt ods odp tex log yaml yml ini plist sqlite db parquet")
        add(.code, "swift c h cc cpp hpp m mm js mjs cjs jsx ts tsx py pyc rb go rs java kt kts cs php sh zsh bash fish css scss sass less sql lua dart vue svelte r pl scala clj ex exs erl hs ml zig nim gradle cmake mk ipynb toml lock map")
        add(.archives, "zip gz tgz xz txz bz2 tbz 7z rar tar dmg iso pkg zst lz4 lzma jar war apk ipa xip sparseimage sparsebundle")
        add(.apps, "app dylib so a o bin exe dll framework bundle plugin appex kext node wasm class")
        return table
    }()

    /// The kind of a file named `name`.
    static func of(_ name: String) -> FileKind {
        let bytes = name.utf8
        guard let dot = bytes.lastIndex(of: 0x2E), dot != bytes.startIndex else { return .other }
        let ext = bytes[bytes.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 12 else { return .other }
        var text = String(decoding: ext, as: UTF8.self)
        if ext.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) { text = text.lowercased() }
        return byExtension[text] ?? .other
    }
}

/// Files and bytes of each kind.
struct KindTotals: Sendable, Equatable {
    private(set) var files = [Int64](repeating: 0, count: FileKind.allCases.count)
    private(set) var bytes = [Int64](repeating: 0, count: FileKind.allCases.count)

    mutating func add(_ name: String, size: Int64) {
        let kind = FileKind.of(name).rawValue
        files[kind] += 1
        bytes[kind] += size
    }

    var totalBytes: Int64 { bytes.reduce(0, +) }
    var totalFiles: Int64 { files.reduce(0, +) }

    /// The kinds there are, the one with the most data first.
    var ranked: [(kind: FileKind, files: Int64, bytes: Int64)] {
        FileKind.allCases
            .map { (kind: $0, files: files[$0.rawValue], bytes: bytes[$0.rawValue]) }
            .filter { $0.files > 0 }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.files > $1.files }
    }

    /// The share of the data that's compressed already (photos, video, audio, archives).
    var compressedShare: Double {
        let total = totalBytes
        guard total > 0 else { return 0 }
        let compressed = FileKind.allCases.filter(\.isCompressed).reduce(Int64(0)) { $0 + bytes[$1.rawValue] }
        return Double(compressed) / Double(total)
    }
}

// MARK: - Folders that can be rebuilt

/// Folders a tool makes and can make again (`node_modules`, Python's caches, Xcode's DerivedData,
/// Rust's `target`…). They're often most of a project's files, and moving them is wasted time: on
/// the other computer, `npm install` and the like bring them back.
struct RebuildableRule: Sendable {
    enum Marker: Sendable {
        /// The folder holds this file (a Python virtual environment holds `pyvenv.cfg`).
        case inside(String)
        /// The folder is next to this file (Rust's `target` is next to `Cargo.toml`).
        case beside(String)
    }

    let id: Int16
    let title: String
    let names: [String]
    let marker: Marker?
    /// How it comes back.
    let hint: String
}

enum Rebuildable {
    static let rules: [RebuildableRule] = [
        RebuildableRule(id: 0, title: "node_modules", names: ["node_modules", "bower_components"], marker: nil,
                        hint: "npm install (or yarn, pnpm) brings them back"),
        RebuildableRule(id: 1, title: "Python caches", names: ["__pycache__", ".pytest_cache", ".mypy_cache",
                                                               ".ruff_cache", ".tox", ".nox", ".hypothesis"],
                        marker: nil, hint: "Python makes them again as it runs"),
        RebuildableRule(id: 2, title: "Python virtual environments", names: [".venv", "venv", "env"],
                        marker: .inside("pyvenv.cfg"), hint: "python -m venv and pip install make them again"),
        RebuildableRule(id: 3, title: "Xcode DerivedData", names: ["DerivedData"], marker: nil,
                        hint: "Xcode rebuilds it"),
        RebuildableRule(id: 4, title: "Swift .build", names: [".build"], marker: .beside("Package.swift"),
                        hint: "swift build makes it again"),
        RebuildableRule(id: 5, title: "CocoaPods", names: ["Pods"], marker: .beside("Podfile"),
                        hint: "pod install brings them back"),
        RebuildableRule(id: 6, title: "Rust target", names: ["target"], marker: .beside("Cargo.toml"),
                        hint: "cargo build makes it again"),
        RebuildableRule(id: 7, title: "Gradle caches", names: [".gradle"], marker: nil,
                        hint: "Gradle makes it again"),
        RebuildableRule(id: 8, title: "Web build caches", names: [".next", ".nuxt", ".svelte-kit", ".parcel-cache",
                                                                  ".turbo", ".angular", ".expo", ".vercel"],
                        marker: nil, hint: "the next build makes them again"),
        RebuildableRule(id: 9, title: "Dart tool caches", names: [".dart_tool"], marker: nil,
                        hint: "dart pub get makes it again"),
        RebuildableRule(id: 10, title: "Terraform providers", names: [".terraform"], marker: nil,
                        hint: "terraform init brings them back"),
    ]

    private static let byName: [String: Int16] = {
        var table: [String: Int16] = [:]
        for rule in rules { for name in rule.names { table[name] = rule.id } }
        return table
    }()

    static func rule(_ id: Int16) -> RebuildableRule? {
        rules.indices.contains(Int(id)) ? rules[Int(id)] : nil
    }

    /// The rule a folder named `name` inside `parent` matches, or -1.
    static func classify(parent: String, name: String) -> Int16 {
        guard let id = byName[name] else { return -1 }
        switch rules[Int(id)].marker {
        case nil:
            return id
        case .inside(let file):
            return access(parent + "/" + name + "/" + file, F_OK) == 0 ? id : -1
        case .beside(let file):
            return access(parent + "/" + file, F_OK) == 0 ? id : -1
        }
    }
}

/// How much of a folder is in folders of one rebuildable kind.
struct RebuildableTotals: Sendable, Equatable {
    var folders: Int64 = 0
    var files: Int64 = 0
    var bytes: Int64 = 0
}

/// What counting a folder learns about it, besides how big it is.
struct FolderInsights: Sendable, Equatable {
    var kinds = KindTotals()
    /// By rule id.
    var rebuildable = [RebuildableTotals](repeating: RebuildableTotals(), count: Rebuildable.rules.count)
    /// The space the files would take on a drive that hands out space in blocks of each of
    /// `blockSizes`: every file takes whole blocks, so small files take far more than their size
    /// on an exFAT drive (128 KB each, on one of 2 TB).
    var allocated = [Int64](repeating: 0, count: FolderInsights.blockSizes.count)
    /// The biggest file (a FAT32 drive can't hold one of 4 GB or more).
    var largest: Int64 = 0

    static let blockSizes: [Int64] = [4 << 10, 8 << 10, 16 << 10, 32 << 10, 64 << 10, 128 << 10, 256 << 10,
                                      512 << 10, 1 << 20, 2 << 20, 4 << 20]

    mutating func allocate(_ size: Int64) {
        for index in Self.blockSizes.indices {
            let block = Self.blockSizes[index]
            allocated[index] += size == 0 ? 0 : (size + block - 1) / block * block
        }
    }

    /// The space the files take on a drive with blocks of `blockSize`, if it's one of the sizes kept.
    func space(withBlocks blockSize: Int64) -> Int64? {
        Self.blockSizes.firstIndex(of: blockSize).map { allocated[$0] }
    }

    /// Rebuildable kinds found, the one with the most files first.
    var suggestions: [(rule: RebuildableRule, totals: RebuildableTotals)] {
        Rebuildable.rules
            .map { (rule: $0, totals: rebuildable[Int($0.id)]) }
            .filter { $0.totals.folders > 0 }
            .sorted { $0.totals.files > $1.totals.files }
    }
}
