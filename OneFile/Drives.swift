import Foundation
import IOKit

/// A drive (a mounted volume), and what copying to or from it needs to know: what it is, how it's
/// connected, and what its format can and can't hold.
struct Drive: Sendable, Equatable, Identifiable {
    enum Medium: Sendable, Equatable {
        case ssd, hdd, network, image, unknown
    }

    /// Where it's mounted.
    let mountPath: String
    let name: String
    /// The format's kernel name: apfs, hfs, exfat, msdos, ntfs, smbfs…
    let fsType: String
    let medium: Medium
    /// How it's connected, as macOS says ("USB", "Thunderbolt"), if it says.
    let connection: String?
    /// The model, as the drive reports it ("SN580 2TB").
    let product: String?
    let isInternal: Bool
    /// Its `st_dev`, to tell whether two paths are on the same drive.
    let device: UInt64
    /// The least space a file takes: an exFAT drive of 2 TB hands out 128 KB at a time.
    let blockSize: Int64
    /// Keeps extended attributes (Finder tags and the like) itself. exFAT and FAT don't: macOS
    /// keeps them in "._" files next to each file.
    let nativeAttributes: Bool
    let caseSensitive: Bool
    /// Can make clones: copies that share the original's data until either changes (APFS).
    let clones: Bool
    let hardLinks: Bool
    let symbolicLinks: Bool
    let capacity: Int64?

    var id: String { mountPath }

    /// The drive that `path` is on.
    static func of(_ path: String) -> Drive? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let mount = string(info.f_mntonname)
        let from = string(info.f_mntfromname)
        let fsType = string(info.f_fstypename)
        var rootInfo = stat()
        let device = stat(mount, &rootInfo) == 0 ? FolderEntry.device(rootInfo.st_dev) : UInt64(UInt32(bitPattern: info.f_fsid.val.0))
        let caps = capabilities(mount)
        let local = info.f_flags & UInt32(MNT_LOCAL) != 0
        var medium: Medium = local ? .unknown : .network
        var connection: String?
        var product: String?
        var isInternal = false
        if local, from.hasPrefix("/dev/"), let hardware = hardware(bsdName: String(from.dropFirst(5))) {
            medium = hardware.medium
            connection = hardware.connection
            product = hardware.product
            isInternal = hardware.isInternal
        } else if !local {
            connection = networkName(fsType)
        }
        // The startup disk's data lives on a volume called "Data", which Finder shows as the disk.
        var name = URL(fileURLWithPath: mount).lastPathComponent
        if let values = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeNameKey]),
           let volume = values.volumeName {
            name = volume
        }
        if mount == "/System/Volumes/Data" || mount == "/" {
            name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        }
        name = shownNames[name] ?? name
        let capacity = Int64(info.f_blocks) * Int64(info.f_bsize)
        return Drive(mountPath: mount, name: name, fsType: fsType, medium: medium, connection: connection,
                     product: product, isInternal: isInternal, device: device,
                     blockSize: Int64(max(info.f_bsize, 512)),
                     nativeAttributes: caps?.nativeAttributes ?? (fsType == "apfs" || fsType == "hfs"),
                     caseSensitive: caps?.caseSensitive ?? (pathconf(mount, _PC_CASE_SENSITIVE) == 1),
                     clones: caps?.clones ?? false, hardLinks: caps?.hardLinks ?? true,
                     symbolicLinks: caps?.symbolicLinks ?? true, capacity: capacity > 0 ? capacity : nil)
    }

    /// Whether the drive that `path` is on keeps extended attributes itself (APFS, Mac OS
    /// Extended), rather than in "._" files (exFAT, FAT).
    static func keepsAttributes(_ path: String) -> Bool {
        capabilities(path)?.nativeAttributes ?? true
    }

    /// Names to show instead of drives' own, for screenshots: ONEFILE_DRIVE_NAMES="Real=Shown;…".
    private static let shownNames: [String: String] = {
        guard let list = ProcessInfo.processInfo.environment["ONEFILE_DRIVE_NAMES"] else { return [:] }
        var names: [String: String] = [:]
        for pair in list.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { names[parts[0]] = parts[1] }
        }
        return names
    }()

    /// Free space now (for important things, on APFS: purgeable space counts as free).
    var free: Int64? { Packer.freeSpace(mountPath) }

    /// The drives Finder shows, the startup disk first.
    static func mounted() -> [Drive] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                          options: [.skipHiddenVolumes]) ?? []
        var drives: [Drive] = []
        var seen = Set<UInt64>()
        for url in urls {
            guard let drive = of(url.path), seen.insert(drive.device).inserted else { continue }
            // The read-only system volume isn't anywhere to copy to; its data volume is.
            if url.path == "/" {
                if let data = of("/System/Volumes/Data"), seen.insert(data.device).inserted { drives.append(data) }
                continue
            }
            drives.append(drive)
        }
        return drives.sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }

    var isStartup: Bool { mountPath == "/System/Volumes/Data" || mountPath == "/" }

    /// "exFAT", "APFS", "Mac OS Extended"…
    var formatName: String {
        switch fsType {
        case "apfs": "APFS"
        case "hfs": "Mac OS Extended"
        case "exfat": "exFAT"
        case "msdos": "FAT32"
        case "ntfs": "NTFS"
        case "smbfs": "SMB"
        case "afpfs": "AFP"
        case "nfs": "NFS"
        case "webdav": "WebDAV"
        default: fsType.uppercased()
        }
    }

    var isFAT: Bool { fsType == "msdos" }
    var isNetwork: Bool { medium == .network }
    /// exFAT and FAT: writing several big files at once is slow, and every file takes a whole block.
    var isWindowsFormat: Bool { fsType == "exfat" || fsType == "msdos" || fsType == "ntfs" }

    /// "Internal SSD", "USB SSD", "USB hard drive", "Network (SMB)"…
    var kindText: String {
        switch medium {
        case .network: return "Network drive"
        case .image: return "Disk image"
        case .ssd, .hdd, .unknown:
            let what = medium == .ssd ? "SSD" : medium == .hdd ? "hard drive" : "drive"
            if isInternal { return "Internal \(what)" }
            if let connection, connection != "Apple Fabric", connection != "PCI-Express" {
                return "\(connection) \(what)"
            }
            return "External \(what)"
        }
    }

    /// The SF Symbol for it.
    var symbol: String {
        switch medium {
        case .network: "externaldrive.connected.to.line.below"
        case .image: "opticaldiscdrive"
        default: isInternal ? "internaldrive" : "externaldrive"
        }
    }

    // MARK: Asking macOS

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private struct Capabilities {
        var nativeAttributes: Bool
        var caseSensitive: Bool
        var clones: Bool
        var hardLinks: Bool
        var symbolicLinks: Bool
    }

    /// What the volume's format can do, as it says itself (`getattrlist` volume capabilities).
    private static func capabilities(_ mount: String) -> Capabilities? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // The length, then vol_capabilities_attr_t: four capability words, then four valid words.
        var buffer = [UInt32](repeating: 0, count: 1 + 8)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(mount, &request, raw.baseAddress, raw.count, 0)
        }
        guard result == 0 else { return nil }
        let format = buffer[1 + Int(VOL_CAPABILITIES_FORMAT)]
        let formatValid = buffer[1 + 4 + Int(VOL_CAPABILITIES_FORMAT)]
        let interfaces = buffer[1 + Int(VOL_CAPABILITIES_INTERFACES)]
        let interfacesValid = buffer[1 + 4 + Int(VOL_CAPABILITIES_INTERFACES)]
        func has(_ word: UInt32, _ valid: UInt32, _ bit: Int32) -> Bool {
            valid & UInt32(bit) != 0 && word & UInt32(bit) != 0
        }
        return Capabilities(
            nativeAttributes: has(interfaces, interfacesValid, VOL_CAP_INT_EXTENDED_ATTR),
            caseSensitive: has(format, formatValid, VOL_CAP_FMT_CASE_SENSITIVE),
            clones: has(interfaces, interfacesValid, VOL_CAP_INT_CLONE),
            hardLinks: formatValid & UInt32(VOL_CAP_FMT_HARDLINKS) == 0 || has(format, formatValid, VOL_CAP_FMT_HARDLINKS),
            symbolicLinks: formatValid & UInt32(VOL_CAP_FMT_SYMBOLICLINKS) == 0
                || has(format, formatValid, VOL_CAP_FMT_SYMBOLICLINKS))
    }

    private struct Hardware {
        var medium: Medium
        var connection: String?
        var product: String?
        var isInternal: Bool
    }

    /// What the drive under a disk is (from the I/O Registry): an SSD or a spinning disk, and how
    /// it's connected. Searching up from the volume finds the physical drive, even under APFS.
    private static func hardware(bsdName: String) -> Hardware? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ key: String) -> [String: Any]? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
                as? [String: Any]
        }
        let device = search("Device Characteristics")
        let protocols = search("Protocol Characteristics")
        let interconnect = protocols?["Physical Interconnect"] as? String
        let location = protocols?["Physical Interconnect Location"] as? String
        var medium: Medium
        switch device?["Medium Type"] as? String {
        case "Solid State": medium = .ssd
        case "Rotational": medium = .hdd
        default: medium = .unknown
        }
        if interconnect == "Virtual Interface" || (device?["Product Name"] as? String) == "Disk Image" {
            medium = .image
        }
        let product = (device?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces)
        return Hardware(medium: medium, connection: interconnect, product: product,
                        isInternal: location == "Internal")
    }

    private static func networkName(_ fsType: String) -> String {
        switch fsType {
        case "smbfs": "SMB"
        case "afpfs": "AFP"
        case "nfs": "NFS"
        case "webdav": "WebDAV"
        default: "Network"
        }
    }
}

/// How a copy goes, given the two drives: how many files at a time, and how big files go.
struct CopyPlan: Sendable, Equatable {
    /// Small files copied at the same time.
    var workers: Int
    /// Files bigger than this go one at a time, in big pieces, alongside the small ones.
    let bigFile: Int64
    /// Both are on one APFS drive: clone instead of copying (instant, and no extra space).
    let clone: Bool
    /// The source is a spinning disk: read files in the order they are on it.
    var diskOrder: Bool
    /// The source keeps extended attributes in "._" files (exFAT, FAT): read those as files.
    let appleDoubleSource: Bool

    init(from source: Drive?, to destination: Drive?) {
        let sameDrive = source != nil && source?.device == destination?.device
        clone = sameDrive && destination?.clones == true
        bigFile = 8 << 20
        diskOrder = source?.medium == .hdd
        appleDoubleSource = source.map { !$0.nativeAttributes } ?? false
        // Measured on a USB SSD (exFAT) and the Mac's own SSD: 8 at a time was quickest both
        // ways (16 a little slower). A spinning disk can't do much at once; a network drive
        // waits on every request, so more at once hides more of the wait.
        if source?.medium == .hdd || destination?.medium == .hdd {
            workers = 4
        } else if source?.isNetwork == true || destination?.isNetwork == true {
            workers = 16
        } else {
            workers = 8
        }
    }
}
