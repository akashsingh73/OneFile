import Foundation

/// An entry of a folder, with what OneFile needs to pack it.
struct FolderEntry: Sendable {
    enum Kind: Sendable {
        case file, directory, symlink, fifo
        /// Sockets and devices, which a tar file can't usefully hold.
        case other
    }

    let name: String
    let kind: Kind
    /// Bytes of data. For a symbolic link, the length of the path it holds; for a folder, 0.
    let size: Int64
    /// The permission bits (`st_mode & 0o7777`).
    let permissions: UInt32
    let owner: UInt32
    let group: UInt32
    /// Seconds since 1970.
    let modified: Int64
    /// When it was made ("Date Created"), seconds since 1970; 0 where the drive doesn't keep it.
    let created: Int64
    let device: UInt64
    let inode: UInt64
    let links: UInt32
    let flags: UInt32
    /// On a drive that keeps Mac attributes in "._" files (exFAT, FAT): this one has one.
    var hasAppleDouble = false

    /// Only in the cloud (iCloud Drive and the like): its data isn't on this Mac.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

    init(name: String, kind: Kind, size: Int64, permissions: UInt32, owner: UInt32, group: UInt32,
         modified: Int64, created: Int64 = 0, device: UInt64, inode: UInt64, links: UInt32, flags: UInt32) {
        self.name = name
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.modified = modified
        self.created = created
        self.device = device
        self.inode = inode
        self.links = links
        self.flags = flags
    }

    init(name: String, _ st: stat) {
        let kind: Kind
        switch UInt32(st.st_mode) & UInt32(S_IFMT) {
        case UInt32(S_IFREG): kind = .file
        case UInt32(S_IFDIR): kind = .directory
        case UInt32(S_IFLNK): kind = .symlink
        case UInt32(S_IFIFO): kind = .fifo
        default: kind = .other
        }
        self.init(name: name, kind: kind, size: kind == .directory ? 0 : Int64(st.st_size),
                  permissions: UInt32(st.st_mode) & 0o7777, owner: st.st_uid, group: st.st_gid,
                  modified: Int64(st.st_mtimespec.tv_sec), created: Int64(st.st_birthtimespec.tv_sec),
                  device: FolderEntry.device(st.st_dev),
                  inode: UInt64(st.st_ino), links: UInt32(st.st_nlink), flags: st.st_flags)
    }

    static func device(_ value: dev_t) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
    }
}

/// Lists folders with the details of everything in them, a few thousand entries per system call
/// (`getattrlistbulk`, as Finder does). Asking for each file's details by name instead (`stat`)
/// costs a lookup per file, which on exFAT and FAT drives searches the whole folder every time.
enum FolderReader {
    /// Hands what's in the folder at `path` to `handle`, a batch at a time, until `handle` returns
    /// false. Returns 0 once it has read everything (or was told to stop), else the error that stopped it.
    @discardableResult
    static func read(_ path: String, _ handle: ([FolderEntry]) -> Bool) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        switch readInBulk(fd, handle) {
        case .done: return 0
        case .failed(let code): return code
        case .unsupported: return readOneByOne(path, handle)
        }
    }

    private enum BulkResult { case done, failed(Int32), unsupported }

    private static func readInBulk(_ fd: Int32, _ handle: ([FolderEntry]) -> Bool) -> BulkResult {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The values come back in this order: the returned set, the error (if any), then the
        // common attributes by bit, then the file attributes by bit.
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_CRTIME)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_OWNERID) | attrgroup_t(ATTR_CMN_GRPID) | attrgroup_t(ATTR_CMN_ACCESSMASK)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID) | attrgroup_t(ATTR_CMN_ERROR)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)
        // The creation date is a bonus: a drive without one (FAT, say) still lists in bulk.
        let neededCommon = request.commonattr
            & ~(attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_CRTIME))
        let neededFile = request.fileattr

        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [FolderEntry] = []
        var first = true
        while true {
            // Attributes a drive can't give are packed too (as zeros), so every entry has the same
            // layout; the returned set says which values are real.
            let count = getattrlistbulk(fd, &request, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                let code = errno
                // A drive that can't do this at all says so on the first call: read it one by one.
                if first && (code == ENOTSUP || code == EINVAL || code == ENOSYS) { return .unsupported }
                return .failed(code)
            }
            first = false
            if count == 0 { return .done }
            entries.removeAll(keepingCapacity: true)
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                var offset = 0
                func next<T>(_: T.Type) -> T {
                    let value = entry.loadUnaligned(fromByteOffset: offset, as: T.self)
                    offset += MemoryLayout<T>.size
                    return value
                }
                let length = Int(next(UInt32.self))
                let returned = next(attribute_set_t.self)
                // The entry's error, if any, comes right after the returned set (not in bit order).
                let error = returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 ? next(UInt32.self) : 0
                let nameStart = offset
                let nameOffset = Int(next(Int32.self))
                _ = next(UInt32.self)
                let name = String(cString: (entry + nameStart + nameOffset).assumingMemoryBound(to: CChar.self))
                let device = next(dev_t.self)
                let type = next(fsobj_type_t.self)
                let created = next(timespec.self)
                let modified = next(timespec.self)
                let owner = next(uid_t.self)
                let group = next(gid_t.self)
                let access = next(UInt32.self)
                let flags = next(UInt32.self)
                let inode = next(UInt64.self)
                let links = next(UInt32.self)
                let size = next(off_t.self)
                entry += length

                let kind = Self.kind(type)
                let complete = error == 0 && returned.commonattr & neededCommon == neededCommon
                    && (kind == .directory || returned.fileattr & neededFile == neededFile)
                if complete {
                    entries.append(FolderEntry(
                        name: name, kind: kind, size: kind == .directory ? 0 : Int64(size),
                        permissions: access & 0o7777, owner: owner, group: group, modified: Int64(modified.tv_sec),
                        created: returned.commonattr & attrgroup_t(ATTR_CMN_CRTIME) != 0 ? Int64(created.tv_sec) : 0,
                        device: FolderEntry.device(device), inode: inode,
                        links: links, flags: flags))
                } else {
                    // This drive left something out for this entry: ask for it the usual way.
                    // (If that fails too, the entry went away in the meantime.)
                    var st = stat()
                    guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    entries.append(FolderEntry(name: name, st))
                }
            }
            if !entries.isEmpty, !handle(entries) { return .done }
        }
    }

    private static func kind(_ type: fsobj_type_t) -> FolderEntry.Kind {
        switch type {
        case VREG.rawValue: return .file
        case VDIR.rawValue: return .directory
        case VLNK.rawValue: return .symlink
        case VFIFO.rawValue: return .fifo
        default: return .other
        }
    }

    private static let nameCapacity = MemoryLayout.size(ofValue: dirent().d_name)

    /// Lists the folder and asks for each entry's details by name: for drives that can't do `readInBulk`.
    private static func readOneByOne(_ path: String, _ handle: ([FolderEntry]) -> Bool) -> Int32 {
        guard let dir = opendir(path) else { return errno }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var entries: [FolderEntry] = []
        while true {
            // readdir returns nil both at the end and on an error; only an error sets errno.
            errno = 0
            guard let item = readdir(dir) else { break }
            let name = withUnsafePointer(to: &item.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            entries.append(FolderEntry(name: name, st))
            if entries.count == 1_000 {
                guard handle(entries) else { return 0 }
                entries.removeAll(keepingCapacity: true)
            }
        }
        let code = errno
        if !entries.isEmpty { _ = handle(entries) }
        return code
    }
}
