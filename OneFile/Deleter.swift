import Foundation

/// Deletes a folder of many files for good, many at once, with progress: emptying a Trash of a
/// million files, or an old node_modules, takes Finder a long time, one file at a time.
///
/// It never follows a link (a link is deleted, not what it points to), never leaves the folder,
/// and refuses folders that hold the system, the home folder or a whole drive.
final class Deleter: @unchecked Sendable {
    struct Progress: Sendable {
        var started = Date()
        var deleted: Int64 = 0
        var bytes: Int64 = 0
        var current = ""
        var finishing = false
    }

    struct Summary: Sendable {
        var deleted: Int64
        var bytes: Int64
        var seconds: Double
        var problems: [Problem]
        var problemCount: Int
    }

    enum Outcome: Sendable {
        case finished(Summary)
        case stopped(Int64)
        case failed(String)
    }

    /// What's in it, counted before asking.
    struct Count: Sendable {
        var items: Int64 = 0
        var bytes: Int64 = 0
    }

    static let workers = 8

    let folder: URL
    /// Delete what's in the folder, but keep the folder itself (a Trash).
    let keepFolder: Bool

    private struct State {
        var progress = Progress()
        var stopped = false
        var problems: [Problem] = []
        var problemCount = 0
    }

    private let state = Locked(State())
    private let jobs = WorkQueue<(String, [String])>(limit: 256)

    init(folder: URL, keepFolder: Bool = false) {
        self.folder = folder
        self.keepFolder = keepFolder
    }

    /// Why OneFile won't delete `folder`, if it won't.
    static func refusal(_ folder: URL) -> String? {
        let path = Copier.realPath(folder.path)
        let home = Copier.realPath(NSHomeDirectory())
        var protected: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private",
                                      "/usr", "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", home]
        for name in ["Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Applications"] {
            protected.insert(home + "/" + name)
        }
        if protected.contains(path) || home.hasPrefix(path + "/") {
            return "OneFile won't delete “\(folder.lastPathComponent)”: it holds the system or your home folder."
        }
        if let drive = Drive.of(path), Copier.realPath(drive.mountPath) == path {
            return "That's a whole drive. To clear one, erase it in Disk Utility."
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return "“\(folder.lastPathComponent)” isn't there any more." }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "“\(folder.lastPathComponent)” isn't a folder." }
        return nil
    }

    /// Counts what's in the folder (all of it: nothing is left out), for asking first.
    static func count(_ folder: URL, stopped: () -> Bool) -> Count? {
        var count = Count()
        let pairs = !Drive.keepsAttributes(folder.path)
        var stack = [folder.path]
        while let path = stack.popLast() {
            if stopped() { return nil }
            for entry in listing(path, pairs: pairs) {
                count.items += 1
                count.bytes += entry.size
                if entry.kind == .directory { stack.append(path + "/" + entry.name) }
            }
        }
        return count
    }

    /// A folder's entries. On exFAT and FAT drives, "._" files go with the file beside them
    /// (deleting a file deletes its "._" file too).
    private static func listing(_ path: String, pairs: Bool) -> [FolderEntry] {
        var entries: [FolderEntry] = []
        FolderReader.read(path) { batch in
            entries.append(contentsOf: batch)
            return true
        }
        return pairs ? AppleDouble.pair(entries) : entries
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in completion(run()) }
        thread.name = "OneFile delete"
        thread.qualityOfService = Work.qos
        thread.start()
    }

    func cancel() {
        state.withLock { $0.stopped = true }
        jobs.stop()
    }

    func progress() -> Progress { state.withLock { $0.progress } }
    private var isStopped: Bool { state.withLock { $0.stopped } }

    // MARK: Deleting

    private func run() -> Outcome {
        if let refusal = Self.refusal(folder) { return .failed(refusal) }
        let started = Date()
        let root = Copier.realPath(folder.path)
        let group = DispatchGroup()
        for _ in 0..<Self.workers {
            group.enter()
            let thread = Thread { [self] in
                unlinkFiles()
                group.leave()
            }
            thread.qualityOfService = Work.qos
            thread.start()
        }
        // Files go to the threads a folder at a time; folders are kept for the end.
        let rootDevice = FolderEntry.device(Self.device(root))
        var folders: [String] = [root]
        var stack = [root]
        let pairs = !Drive.keepsAttributes(root)
        while let path = stack.popLast(), !isStopped {
            var names: [String] = []
            for entry in Self.listing(path, pairs: pairs) {
                if entry.kind == .directory && entry.device == rootDevice {
                    let child = path + "/" + entry.name
                    folders.append(child)
                    stack.append(child)
                } else if entry.kind == .directory {
                    // Another drive mounted inside: never go into it.
                    problem(path + "/" + entry.name, "Not deleted: another disk is mounted there.")
                } else {
                    names.append(entry.name)
                    if names.count == 512 {
                        guard jobs.push((path, names)) else { break }
                        names = []
                    }
                }
            }
            if !names.isEmpty { _ = jobs.push((path, names)) }
        }
        jobs.finish()
        group.wait()
        if isStopped { return .stopped(state.withLock { $0.progress.deleted }) }

        // Then the folders, deepest first (each is empty by then).
        state.withLock { $0.progress.finishing = true }
        for path in folders.reversed() where !(keepFolder && path == root) {
            if isStopped { break }
            if rmdir(path) == 0 {
                state.withLock { $0.progress.deleted += 1 }
            } else if errno == EACCES || errno == EPERM {
                let parent = (path as NSString).deletingLastPathComponent
                chmod(parent, 0o755)
                chflags(path, 0)
                if rmdir(path) == 0 { state.withLock { $0.progress.deleted += 1 } }
                else { problem(path, "Couldn't delete this folder: \(Packer.message(errno)).") }
            } else if errno != ENOENT {
                problem(path, "Couldn't delete this folder: \(Packer.message(errno)).")
            }
        }
        if isStopped { return .stopped(state.withLock { $0.progress.deleted }) }
        let seconds = Date().timeIntervalSince(started)
        return state.withLock { s in
            .finished(Summary(deleted: s.progress.deleted, bytes: s.progress.bytes, seconds: seconds,
                              problems: s.problems, problemCount: s.problemCount))
        }
    }

    private static func device(_ path: String) -> dev_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : 0
    }

    /// Deletes the files (and links, and anything else that isn't a folder) handed out, from a
    /// handle on their folder: a link in the path can't send it elsewhere.
    private func unlinkFiles() {
        while let (path, names) = jobs.pop() {
            if isStopped { return }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else {
                problem(path, "Couldn't open this folder: \(Packer.message(errno)).")
                continue
            }
            var deleted: Int64 = 0, bytes: Int64 = 0
            for name in names {
                var info = stat()
                let size = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? Int64(info.st_size) : 0
                var result = unlinkat(fd, name, 0)
                if result != 0 && (errno == EPERM || errno == EACCES) {
                    // Locked (Finder's Locked), or a folder without write permission: unlock and retry.
                    lchflags(path + "/" + name, 0)
                    fchmod(fd, 0o755)
                    result = unlinkat(fd, name, 0)
                }
                if result == 0 {
                    deleted += 1
                    bytes += size
                } else if errno != ENOENT {
                    problem(path + "/" + name, "Couldn't delete this: \(Packer.message(errno)).")
                }
            }
            close(fd)
            state.withLock { s in
                s.progress.deleted += deleted
                s.progress.bytes += bytes
                s.progress.current = path
            }
        }
    }

    private func problem(_ path: String, _ message: String) {
        state.withLock { s in
            s.problemCount += 1
            if s.problems.count < Packer.problemsKept {
                s.problems.append(Problem(id: s.problems.count, path: path, message: message))
            }
        }
    }
}
