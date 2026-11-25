import Foundation

extension OneFileTests {
    /// `bash test.sh --copy FOLDER DESTINATION`: copies a folder into another (on another drive,
    /// say) and says how long it took. A stopped copy is picked up; an earlier one is updated.
    static func copyBenchmark(_ source: String, _ destination: String) -> Bool {
        let from = URL(fileURLWithPath: source).standardizedFileURL
        let into = URL(fileURLWithPath: destination).standardizedFileURL
        let name = from.lastPathComponent
        let target: Copier.Target
        switch Copier.existing(for: from, name: name, in: into) {
        case .folder(let url): target = .update(url)
        case .nothing, .stopped: target = .new(folder: into, name: name)
        }
        let copier = Copier(source: from, target: target, options: Copier.Options(leaveOut: []))
        let outcome = run(copier, timeline: true)
        switch outcome {
        case .finished(let summary):
            let plan = summary.plan
            let copying = summary.seconds - summary.savingSeconds
            print(String(format: "Copied %@ files (%@) in %.2f s: %@ files/s, %@/s%@",
                         Format.count(summary.files), Format.bytes(summary.bytes), copying,
                         Format.count(Int64(Double(summary.files) / max(copying, 0.001))),
                         Format.bytes(Int64(Double(summary.bytes) / max(copying, 0.001))),
                         summary.unchanged > 0 ? ", \(Format.count(summary.unchanged)) already there" : ""))
            if summary.savingSeconds > 0.01 {
                print(String(format: "  then %.2f s making sure it's all on the drive (%.2f s in all)", summary.savingSeconds, summary.seconds))
            }
            print("  \(plan.workers) at a time, big files one by one\(plan.clone ? ", cloned" : "")\(plan.diskOrder ? ", in disk order" : "")\(plan.appleDoubleSource ? ", attributes read from ._ files" : "")")
            print("  → \(summary.destination.path)")
            for problem in summary.problems.prefix(10) { print("  ! \(problem.path): \(problem.message)") }
            return true
        case .stopped:
            print("Stopped.")
            return false
        case .failed(let message, _):
            print("Couldn't copy: \(message)")
            return false
        }
    }

    /// Runs a copier to the end.
    static func run(_ copier: Copier, timeline: Bool = false) -> Copier.Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Copier.Outcome?>(nil)
        copier.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        var finishingSeen = false
        let start = Date()
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            guard timeline else { continue }
            let progress = copier.progress()
            if progress.finishing && !finishingSeen {
                finishingSeen = true
                print(String(format: "  every file copied at %.2f s", Date().timeIntervalSince(start)))
            }
        }
        return result.withLock { $0 }!
    }
}

// MARK: - Tests

extension OneFileTests {
    static func copyTests(_ fixture: Fixture, _ c: Checks) {
        let fm = FileManager.default
        let options = Copier.Options(leaveOut: Fixture.leaveOut)
        // Things only copying keeps: a creation date, extended attributes, the hidden flag.
        setCreated(fixture.path("old.txt"), 978_000_000)
        setxattr(fixture.path("hello.txt"), "com.example.note", "a note", 6, 0, 0)
        let tags = Array("bplist00\u{A1}\u{01}UGreen\u{0A}".utf8)
        setxattr(fixture.path("hello.txt"), "com.apple.metadata:_kMDItemUserTags", tags, tags.count, 0, 0)
        setxattr(fixture.path("folder"), "com.example.folder-note", "folder", 6, 0, 0)
        chflags(fixture.path("run.sh"), UInt32(UF_HIDDEN))
        defer { chflags(fixture.path("run.sh"), 0) }

        c.section("Copying on one drive (clones)")
        let here = fixture.base + "/copies"
        try? fm.createDirectory(atPath: here, withIntermediateDirectories: true)
        if case .finished(let summary) = copy(fixture.root, into: here, options, c) {
            c.expect(summary.plan.clone, "cloned, as both are on one APFS drive")
            compare(fixture.root, here + "/" + Fixture.rootName, c)
            checkExtras(fixture, here + "/" + Fixture.rootName, c)
            c.expect(summary.problemCount == 2, "two problems (the unreadable file and folder): \(summary.problems.map(\.path))")
            c.expect(summary.destination.lastPathComponent == Fixture.rootName, "named \(summary.destination.lastPathComponent)")
            c.expect(!fm.fileExists(atPath: here + "/\(Fixture.rootName) (copying)"), "no “(copying)” folder left")
            c.expect(getxattr(summary.destination.path, Copier.markerName, nil, 0, 0, XATTR_NOFOLLOW) < 0, "the copy's marker is gone")
        }

        c.section("Copying into the folder itself, or into one inside it")
        let inside = Copier(source: URL(fileURLWithPath: fixture.root),
                            target: .new(folder: URL(fileURLWithPath: fixture.path("folder")), name: "again"), options: options)
        if case .failed(let message, _) = run(inside) {
            c.expect(message.contains("inside the folder being copied"), "refused: \(message)")
        } else {
            c.fail("copying a folder into itself wasn't refused")
        }
        let itself = Copier(source: URL(fileURLWithPath: fixture.root), target: .update(URL(fileURLWithPath: fixture.root)), options: options)
        if case .failed = run(itself) {
            c.expect(true, "updating the folder from itself is refused")
        } else {
            c.fail("updating a folder from itself wasn't refused")
        }

        // Other drives: disk images test.sh made, one APFS, one exFAT.
        let environment = ProcessInfo.processInfo.environment
        guard let apfs = environment["ONEFILE_TEST_APFS"].map(DiskImage.init),
              let exfat = environment["ONEFILE_TEST_ExFAT"].map(DiskImage.init) else {
            print("  (Skipped copying to other drives: test.sh couldn't make the disk images.)")
            return
        }

        c.section("Copying to another APFS drive")
        if case .finished(let summary) = copy(fixture.root, into: apfs.mount, options, c) {
            c.expect(!summary.plan.clone && summary.plan.workers == 8, "copied, 8 at a time: \(summary.plan)")
            let copied = apfs.mount + "/" + Fixture.rootName
            compare(fixture.root, copied, c)
            checkExtras(fixture, copied, c)
            c.expect(summary.bytes > 17 << 20, "the big files went too: \(summary.bytes) bytes")
        }

        c.section("Copying in disk order (as from a hard drive)")
        let ordered = Copier(source: URL(fileURLWithPath: fixture.root),
                             target: .new(folder: URL(fileURLWithPath: apfs.mount + "/ordered"), name: Fixture.rootName), options: options)
        ordered.forceDiskOrder = true
        try? fm.createDirectory(atPath: apfs.mount + "/ordered", withIntermediateDirectories: true)
        if case .finished(let summary) = run(ordered) {
            c.expect(summary.plan.diskOrder && summary.plan.workers == 4, "4 at a time, in disk order: \(summary.plan)")
            compare(fixture.root, apfs.mount + "/ordered/" + Fixture.rootName, c)
        } else {
            c.fail("copying in disk order didn't finish")
        }
        let hdd = Drive(mountPath: "/Volumes/Old", name: "Old", fsType: "hfs", medium: .hdd, connection: "USB", product: nil,
                        isInternal: false, device: 1, blockSize: 4_096, nativeAttributes: true, caseSensitive: false,
                        clones: false, hardLinks: true, symbolicLinks: true, capacity: nil)
        let ssd = Drive(mountPath: "/System/Volumes/Data", name: "Mac", fsType: "apfs", medium: .ssd, connection: "Apple Fabric",
                        product: nil, isInternal: true, device: 2, blockSize: 4_096, nativeAttributes: true,
                        caseSensitive: false, clones: true, hardLinks: true, symbolicLinks: true, capacity: nil)
        let fromHardDrive = CopyPlan(from: hdd, to: ssd)
        c.expect(fromHardDrive.diskOrder && fromHardDrive.workers == 4 && !fromHardDrive.clone, "from a hard drive: \(fromHardDrive)")
        let sameDrive = CopyPlan(from: ssd, to: ssd)
        c.expect(sameDrive.clone && !sameDrive.diskOrder, "on one APFS drive: clones")
        c.expect(hdd.kindText == "USB hard drive" && ssd.kindText == "Internal SSD", "\(hdd.kindText), \(ssd.kindText)")

        c.section("Updating a copy")
        let copied = apfs.mount + "/" + Fixture.rootName
        let changed = fixture.path("many/file-7.txt")
        try? "changed, and longer than before\n".write(toFile: changed, atomically: false, encoding: .utf8)
        try? "new\n".write(toFile: fixture.path("folder/new.txt"), atomically: false, encoding: .utf8)
        try? "only in the copy\n".write(toFile: copied + "/only-in-copy.txt", atomically: false, encoding: .utf8)
        switch Copier.existing(for: URL(fileURLWithPath: fixture.root), name: Fixture.rootName, in: URL(fileURLWithPath: apfs.mount)) {
        case .folder(let url):
            c.expect(url.path == copied, "the earlier copy is found")
            let updater = Copier(source: URL(fileURLWithPath: fixture.root), target: .update(url), options: options)
            if case .finished(let summary) = run(updater) {
                c.expect(summary.files == 2, "only the changed and the new file are copied: \(summary.files)")
                c.expect(summary.unchanged > 2_500, "the rest are skipped: \(summary.unchanged)")
                c.expect(fm.contentsEqual(atPath: changed, andPath: copied + "/many/file-7.txt"), "the changed file is updated")
                c.expect(fm.fileExists(atPath: copied + "/folder/new.txt"), "the new file is there")
                c.expect(fm.fileExists(atPath: copied + "/only-in-copy.txt"), "nothing in the copy is deleted")
                c.expect(summary.updated && summary.destination.path == copied, "updated in place")
            } else {
                c.fail("updating didn't finish")
            }
        default:
            c.fail("the earlier copy isn't found")
        }
        try? fm.removeItem(atPath: fixture.path("folder/new.txt"))

        c.section("Updating never writes through a link at the destination")
        let outside = fixture.base + "/outside"
        try? fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        fixture.cleanUp(copied + "/many")
        symlink(outside, copied + "/many")
        if case .finished(let summary) = run(Copier(source: URL(fileURLWithPath: fixture.root),
                                                    target: .update(URL(fileURLWithPath: copied)), options: options)) {
            let leaked = (try? fm.contentsOfDirectory(atPath: outside)) ?? []
            c.expect(leaked.isEmpty, "nothing went through the link: \(leaked.prefix(3))")
            c.expect(summary.problems.contains { $0.path.hasPrefix("many") }, "and it says why")
        }

        c.section("Stopping, then picking up where it stopped")
        let resumed = fixture.base + "/resume"
        try? fm.createDirectory(atPath: resumed, withIntermediateDirectories: true)
        let stopping = Copier(source: URL(fileURLWithPath: fixture.root),
                              target: .new(folder: URL(fileURLWithPath: apfs.mount + "/r"), name: Fixture.rootName), options: options)
        try? fm.createDirectory(atPath: apfs.mount + "/r", withIntermediateDirectories: true)
        let stopped = DispatchSemaphore(value: 0)
        let outcome = Locked<Copier.Outcome?>(nil)
        stopping.start { result in
            outcome.withLock { $0 = result }
            stopped.signal()
        }
        while stopping.progress().files < 300 && outcome.withLock({ $0 }) == nil { usleep(200) }
        stopping.cancel()
        stopped.wait()
        let staging = apfs.mount + "/r/\(Fixture.rootName) (copying)"
        if case .stopped(let partial) = outcome.withLock({ $0 }) {
            c.expect(partial?.path == staging, "what's copied stays, in “(copying)”: \(partial?.path ?? "")")
            c.expect(Copier.existing(for: URL(fileURLWithPath: fixture.root), name: Fixture.rootName,
                                     in: URL(fileURLWithPath: apfs.mount + "/r")) == .stopped(URL(fileURLWithPath: staging)),
                     "and is found as a stopped copy of this folder")
            let again = Copier(source: URL(fileURLWithPath: fixture.root),
                               target: .new(folder: URL(fileURLWithPath: apfs.mount + "/r"), name: Fixture.rootName), options: options)
            if case .finished(let summary) = run(again) {
                c.expect(summary.resumed, "picked up")
                c.expect(summary.unchanged >= 300 - 64 * 8, "files copied before the stop aren't copied again: \(summary.unchanged)")
                compare(fixture.root, apfs.mount + "/r/" + Fixture.rootName, c)
                c.expect(!fm.fileExists(atPath: staging), "the “(copying)” folder became the copy")
            } else {
                c.fail("copying again didn't finish")
            }
        } else if case .finished = outcome.withLock({ $0 }) {
            c.expect(true, "(it finished before it could be stopped)")
        } else {
            c.fail("stopping: \(String(describing: outcome.withLock { $0 }))")
        }

        c.section("Copying to an exFAT drive, and back")
        let small = fixture.base + "/small"
        for folder in 0..<4 { try? fm.createDirectory(atPath: small + "/\(folder)", withIntermediateDirectories: true) }
        for index in 0..<200 {
            try? "file \(index)\n".write(toFile: small + "/\(index / 50)/f\(index).txt", atomically: false, encoding: .utf8)
        }
        try? Data(Fixture.noise(12 << 20)).write(to: URL(fileURLWithPath: small + "/big.bin"))
        setxattr(small + "/0/f0.txt", "com.example.note", "tagged", 6, 0, 0)
        setxattr(small + "/1", "com.example.folder-note", "folder", 6, 0, 0)
        setCreated(small + "/0/f1.txt", 900_000_000)
        if case .finished(let summary) = copy(small, into: exfat.mount, Copier.Options(leaveOut: []), c) {
            let onDrive = exfat.mount + "/small"
            c.expect(summary.files == 201 && summary.problemCount == 0, "\(summary.files) files, problems: \(summary.problems.prefix(2))")
            c.expect(fm.contentsEqual(atPath: small + "/big.bin", andPath: onDrive + "/big.bin"), "the big file is the same")
            c.expect(attribute(onDrive + "/0/f0.txt", "com.example.note") == "tagged", "attributes go to exFAT (in its ._ files)")
            // And back to APFS: the "._" files become attributes again, not files.
            let back = apfs.mount + "/back"
            try? fm.createDirectory(atPath: back, withIntermediateDirectories: true)
            if case .finished(let returned) = copy(onDrive, into: back, Copier.Options(leaveOut: []), c) {
                c.expect(returned.plan.appleDoubleSource, "reads attributes from ._ files")
                let names = (try? fm.subpathsOfDirectory(atPath: back + "/small")) ?? []
                c.expect(!names.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") }, "no ._ files come back as files")
                c.expect(names.filter { $0.hasSuffix(".txt") }.count == 200, "all 200 small files")
                c.expect(attribute(back + "/small/0/f0.txt", "com.example.note") == "tagged", "the file's attribute is back")
                c.expect(attribute(back + "/small/1", "com.example.folder-note") == "folder", "and the folder's")
                c.expect(created(back + "/small/0/f1.txt") == 900_000_000, "the creation date made the round trip")
                c.expect(modified(back + "/small/0/f2.txt") == modified(small + "/0/f2.txt"), "and the modification date")
                c.expect(fm.contentsEqual(atPath: small + "/big.bin", andPath: back + "/small/big.bin"), "the big file came back the same")
            }
        }

        c.section("The fixture on exFAT: what it can't hold is said")
        if case .finished(let summary) = copy(fixture.root, into: exfat.mount, options, c) {
            let onDrive = exfat.mount + "/" + Fixture.rootName
            c.expect(fm.contentsEqual(atPath: fixture.path("folder/hard-link-to-hello.txt"), andPath: onDrive + "/folder/hard-link-to-hello.txt"),
                     "no hard links on exFAT: the second name gets its own copy")
            c.expect(fm.contentsEqual(atPath: fixture.path("big-1.bin"), andPath: onDrive + "/big-1.bin"), "big files are whole")
            c.expect(summary.problems.allSatisfy { !$0.message.isEmpty }, "every problem says why: \(summary.problems.map(\.message).prefix(3))")
        }

        c.section("AppleDouble files")
        let sidecar = exfat.mount + "/small/0/._f0.txt"
        if let bytes = fm.contents(atPath: sidecar) {
            let attributes = bytes.withUnsafeBytes { AppleDouble.attributes($0) }
            c.expect(attributes?.contains { $0.name == "com.example.note" && $0.value == Array("tagged".utf8) } == true,
                     "read from the ._ file: \(attributes?.map(\.name) ?? [])")
            let cut = Data(bytes.prefix(60))
            c.expect(cut.withUnsafeBytes { AppleDouble.attributes($0) } == nil, "a cut-off one is refused")
            var broken = bytes
            for index in 34..<38 { broken[index] = 0xFF }  // the first entry's length
            c.expect(broken.withUnsafeBytes { AppleDouble.attributes($0) } == nil, "so is one that doesn't add up")
            c.expect(Data("not one".utf8).withUnsafeBytes { AppleDouble.attributes($0) } == nil, "so is something else")
        } else {
            c.fail("no ._ file for an attribute on exFAT")
        }
        c.expect(!AppleDouble.copies("com.apple.provenance"), "macOS's provenance tag isn't copied")
        c.expect(AppleDouble.copies("com.apple.metadata:_kMDItemUserTags"), "Finder tags are")
        fixture.cleanUp(small)
    }

    /// What `compare` doesn't look at: creation dates, attributes, the hidden flag.
    static func checkExtras(_ fixture: Fixture, _ copy: String, _ c: Checks) {
        c.expect(created(copy + "/old.txt") == 978_000_000, "the creation date is kept: \(created(copy + "/old.txt"))")
        c.expect(attribute(copy + "/hello.txt", "com.example.note") == "a note", "extended attributes are kept")
        c.expect(attribute(copy + "/hello.txt", "com.apple.metadata:_kMDItemUserTags") != nil, "Finder tags are kept")
        c.expect(attribute(copy + "/folder", "com.example.folder-note") == "folder", "a folder's attributes are kept")
        var info = stat()
        c.expect(lstat(copy + "/run.sh", &info) == 0 && info.st_flags & UInt32(UF_HIDDEN) != 0, "the hidden flag is kept")
    }

    static func copy(_ source: String, into folder: String, _ options: Copier.Options, _ c: Checks) -> Copier.Outcome {
        let from = URL(fileURLWithPath: source)
        let copier = Copier(source: from, target: .new(folder: URL(fileURLWithPath: folder), name: from.lastPathComponent),
                            options: options)
        let outcome = run(copier)
        switch outcome {
        case .finished: break
        case .stopped: c.fail("copying \(from.lastPathComponent) stopped")
        case .failed(let message, _): c.fail("copying \(from.lastPathComponent) failed: \(message)")
        }
        return outcome
    }

    static func setCreated(_ path: String, _ seconds: Int) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var time = timespec(tv_sec: seconds, tv_nsec: 0)
        setattrlist(path, &request, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
    }

    static func created(_ path: String) -> Int {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_birthtimespec.tv_sec : -1
    }

    static func modified(_ path: String) -> Int {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mtimespec.tv_sec : -1
    }

    static func attribute(_ path: String, _ name: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = getxattr(path, name, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        return count >= 0 ? String(decoding: bytes[0..<count], as: UTF8.self) : nil
    }
}

/// A disk image test.sh made and mounted (hidden from Finder) for the tests to copy to.
struct DiskImage {
    let mount: String

    init(_ mount: String) {
        self.mount = Copier.realPath(mount)
    }
}

extension OneFileTests {
    /// `bash test.sh --delete FOLDER`: deletes a folder for good, many files at once, and says how
    /// long it took. (For measuring against `rm -rf`.)
    static func deleteBenchmark(_ path: String) -> Bool {
        let deleter = Deleter(folder: URL(fileURLWithPath: path))
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Deleter.Outcome?>(nil)
        deleter.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        switch result.withLock({ $0 })! {
        case .finished(let summary):
            print(String(format: "Deleted %@ items in %.2f s (%@ a second)", Format.count(summary.deleted), summary.seconds,
                         Format.count(Int64(Double(summary.deleted) / max(summary.seconds, 0.001)))))
            return true
        case .stopped: return false
        case .failed(let message):
            print("Couldn't delete: \(message)")
            return false
        }
    }
}
