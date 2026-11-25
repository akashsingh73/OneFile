import Foundation

/// Tests for what came after Copy: pausing, cloud folders, and the rest as they're added.
extension OneFileTests {
    static func featureTests(_ fixture: Fixture, _ c: Checks) {
        pauseTests(fixture, c)
        cloudFolderTests(c)
        splitTests(fixture, c)
        gitTests(fixture, c)
        compareTests(fixture, c)
        verifyAndMirrorTests(fixture, c)
        speedTestTests(c)
        deleteTests(fixture, c)
        indexTests(fixture, c)
        ageTests(fixture, c)
    }

    // MARK: Locking with a password (age)

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func ageTests(_ fixture: Fixture, _ c: Checks) {
        c.section("scrypt (RFC 7914's test vectors)")
        c.expect(hex(Scrypt.derive(password: [], salt: [], n: 16, r: 1, p: 1, length: 64) ?? [])
                 == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906",
                 "the empty one")
        c.expect(hex(Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1_024, r: 8, p: 16, length: 64) ?? [])
                 == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640",
                 "password and NaCl")

        let fm = FileManager.default
        let folder = fixture.base + "/locked"
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for method in [PackMethod.gzip, .zstd, .plain] {
            c.section("Locking a .\(method.fileExtension) with a password")
            let archive = folder + "/Root.\(method.fileExtension).age"
            var options = Packer.Options(leaveOut: Fixture.leaveOut, method: method)
            options.password = "correct horse battery staple"
            options.ageWorkFactor = 10
            guard case .finished = wait(Packer(source: URL(fileURLWithPath: fixture.root), destination: URL(fileURLWithPath: archive),
                                               replaceExisting: false, options: options), after: {}) else {
                c.fail("locking failed")
                continue
            }
            let head = fm.contents(atPath: archive)?.prefix(22) ?? Data()
            c.expect(head == Data("age-encryption.org/v1\n".utf8), "it's an age file")
            let out = folder + "/out-\(method.rawValue)"
            try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            for (password, works) in [(nil, false), ("wrong", false), ("correct horse battery staple", true)] as [(String?, Bool)] {
                let outcome = wait(Unpacker(source: .file(URL(fileURLWithPath: archive)), destination: URL(fileURLWithPath: out),
                                            password: password))
                switch outcome {
                case .finished(let summary):
                    c.expect(works, "opened with \(password ?? "no password")")
                    c.expect(summary.output?.lastPathComponent == Fixture.rootName, "unpacked as \(summary.output?.lastPathComponent ?? "")")
                    compare(fixture.root, out + "/" + Fixture.rootName, c)
                case .failed(let message):
                    c.expect(!works, "\(password ?? "no password") doesn't open it: \(message)")
                case .stopped:
                    c.fail("stopped")
                }
            }
            if case .success(let file) = InputFile.open(URL(fileURLWithPath: archive), password: "correct horse battery staple"),
               case .success(let format) = ArchiveFormat.detect(file, name: archive), let index = ArchiveIndex.read(file, format: format) {
                c.expect(format == self.format(of: method), "unlocked, it's a .\(method.fileExtension) inside")
                if case .finished(let checked) = check(archive, index, format, password: "correct horse battery staple") {
                    c.expect(checked.mismatched.isEmpty && checked.checked > 2_500, "every file checks out through the lock")
                }
            } else {
                c.fail("the index can't be read through the lock")
            }
            fixture.cleanUp(out)
        }

        c.section("Another age reads it (an independent decryptor, from the spec)")
        let small = fixture.base + "/Small"
        for index in 0..<40 {
            try? fm.createDirectory(atPath: small + "/d\(index % 3)", withIntermediateDirectories: true)
            try? String(repeating: "line \(index)\n", count: index * 40).write(toFile: small + "/d\(index % 3)/f\(index).txt",
                                                                                atomically: false, encoding: .utf8)
        }
        try? Data(Fixture.noise(200_000)).write(to: URL(fileURLWithPath: small + "/noise.bin"))
        var options = Packer.Options(leaveOut: [], method: .gzip)
        options.password = "pässwörd ✓"
        options.ageWorkFactor = 10
        let locked = folder + "/Small.tar.gz.age"
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { fm.isExecutableFile(atPath: $0) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("age_reference.py").path
        if case .finished = wait(Packer(source: URL(fileURLWithPath: small), destination: URL(fileURLWithPath: locked),
                                        replaceExisting: false, options: options), after: {}),
           let python, fm.fileExists(atPath: script) {
            let decrypted = folder + "/Small.tar.gz"
            let result = run(python, ["-I", "-B", script, locked, "hex:" + hex(Array("pässwörd ✓".utf8)), decrypted])
            if result.errors.contains("scrypt") && result.status != 0 {
                print("  (Skipped: this Python has no scrypt.)")
            } else {
                c.expect(result.status == 0, "it decrypts: \(result.errors.suffix(300))")
                let listed = run("/usr/bin/tar", ["-tzf", decrypted])
                c.expect(listed.status == 0 && listed.output.contains("Small/noise.bin"), "and it's the .tar.gz: \(listed.output.prefix(80))")
            }
        } else {
            print("  (Skipped: no Python here.)")
        }
        fixture.cleanUp(small)
        fixture.cleanUp(folder)
    }

    static func check(_ archive: String, _ index: ArchiveIndex, _ format: ArchiveFormat, password: String) -> ArchiveChecker.Outcome {
        let checker = ArchiveChecker(archive: URL(fileURLWithPath: archive), index: index, format: format, password: password)
        let done = DispatchSemaphore(value: 0)
        let result = Locked<ArchiveChecker.Outcome?>(nil)
        checker.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }!
    }

    // MARK: The index: listing, taking files out, checking

    static func indexTests(_ fixture: Fixture, _ c: Checks) {
        let fm = FileManager.default
        for method in PackMethod.allCases {
            c.section("The index of a .\(method.fileExtension): listing, taking files out, checking")
            let folder = fixture.base + "/index-\(method.rawValue)"
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let archive = folder + "/Root." + method.fileExtension
            guard case .finished(let packed) = pack(fixture.root, to: archive, leaveOut: Fixture.leaveOut, method: method, c),
                  let file = InputFile(path: archive),
                  case .success(let format) = ArchiveFormat.detect(file, name: archive),
                  let index = ArchiveIndex.read(file, format: format) else {
                c.fail("no index in the .\(method.fileExtension)")
                continue
            }
            let files = index.entries.filter { $0.kind == .file }
            c.expect(Int64(index.entries.filter { $0.kind != .folder }.count) == packed.files, "lists every entry: \(index.entries.count)")
            c.expect(index.entries.filter { $0.kind == .folder }.count == packed.folders, "and every folder")
            if let hello = index.entries.first(where: { $0.path == "\(Fixture.rootName)/hello.txt" }),
               let original = fm.contents(atPath: fixture.path("hello.txt")) {
                let digest = original.withUnsafeBytes { Digest.of($0.baseAddress!, $0.count).bytes }
                c.expect(hello.digest == digest, "each file's SHA-256 is the original's")
            }
            c.expect(method == .plain ? index.blocks.isEmpty : index.blocks.count >= 2, "\(index.blocks.count) compressed blocks mapped")
            c.expect(files.allSatisfy { $0.digest.count == 32 }, "every file has a SHA-256")

            // One file from the middle, and a folder.
            let out = folder + "/out"
            try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            let chosen = index.entries.filter { $0.path == "\(Fixture.rootName)/many/file-1234.txt" || $0.path == "\(Fixture.rootName)/folder/" }
            c.expect(chosen.count == 2, "finds what to take out")
            if case .finished(let summary) = extract(archive, index, format, chosen, out) {
                c.expect(summary.mismatched == 0 && summary.problems.isEmpty, "taken out, all matching: \(summary.problems.prefix(2))")
                c.expect(fm.contentsEqual(atPath: fixture.path("many/file-1234.txt"), andPath: out + "/file-1234.txt"),
                         "the file is the same")
                c.expect(fm.contentsEqual(atPath: fixture.path("folder/big-2.bin"), andPath: out + "/folder/big-2.bin"),
                         "so is the big file in the folder (across blocks)")
                c.expect(fm.contentsEqual(atPath: fixture.path("folder/after-big.txt"), andPath: out + "/folder/after-big.txt"),
                         "and what's after it")
            }
            if case .finished(let again) = extract(archive, index, format, Array(chosen.prefix(1)), out) {
                c.expect(again.made.first?.lastPathComponent.hasSuffix(" 2") == true || again.made.first?.lastPathComponent.contains(" 2.") == true,
                         "taking it out again doesn't replace it: \(again.made.map(\.lastPathComponent))")
            }

            // Checking every file.
            if case .finished(let checked) = check(archive, index, format) {
                c.expect(checked.mismatched.isEmpty && checked.checked == Int64(files.count),
                         "every file checks out: \(checked.checked) of \(files.count)")
            }
            if method == .plain, let target = files.first(where: { $0.size > 100 }) {
                // A changed byte in a file's data: the check names that file.
                let fd = open(archive, O_WRONLY)
                var byte: UInt8 = 0x21
                pwrite(fd, &byte, 1, off_t(target.data + 10))
                close(fd)
                if case .finished(let damaged) = check(archive, index, format) {
                    c.expect(damaged.mismatched == [target.path], "a damaged file is found: \(damaged.mismatched)")
                }
            }
            fixture.cleanUp(folder)
        }

        c.section("The index of a split archive")
        let split = fixture.base + "/index-split"
        try? fm.createDirectory(atPath: split, withIntermediateDirectories: true)
        let options = Packer.Options(leaveOut: Fixture.leaveOut, method: .gzip, splitSize: 2_000_000)
        if case .finished(let summary) = wait(Packer(source: URL(fileURLWithPath: fixture.root),
                                                     destination: URL(fileURLWithPath: split + "/Root.tar.gz"),
                                                     replaceExisting: false, options: options), after: {}),
           let file = InputFile(paths: summary.parts.map(\.path)), let index = ArchiveIndex.read(file, format: .gzip) {
            if case .finished(let checked) = check(summary.parts[1].path, index, .gzip) {
                c.expect(checked.mismatched.isEmpty && checked.checked > 2_500, "read across its parts, all files check out")
            }
        } else {
            c.fail("no index across the parts")
        }
        fixture.cleanUp(split)
    }

    static func extract(_ archive: String, _ index: ArchiveIndex, _ format: ArchiveFormat, _ chosen: [ArchiveIndex.Entry],
                        _ destination: String) -> Extractor.Outcome {
        let extractor = Extractor(archive: URL(fileURLWithPath: archive), index: index, format: format, chosen: chosen,
                                  destination: URL(fileURLWithPath: destination))
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Extractor.Outcome?>(nil)
        extractor.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }!
    }

    static func check(_ archive: String, _ index: ArchiveIndex, _ format: ArchiveFormat) -> ArchiveChecker.Outcome {
        let checker = ArchiveChecker(archive: URL(fileURLWithPath: archive), index: index, format: format)
        let done = DispatchSemaphore(value: 0)
        let result = Locked<ArchiveChecker.Outcome?>(nil)
        checker.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }!
    }

    // MARK: Drive tools

    static func speedTestTests(_ c: Checks) {
        c.section("Testing a drive's speed with many files")
        guard let image = ProcessInfo.processInfo.environment["ONEFILE_TEST_APFS"].map(DiskImage.init) else {
            print("  (Skipped: no disk image.)")
            return
        }
        let test = SpeedTest(place: URL(fileURLWithPath: image.mount), bigLimit: 64 << 20)
        let done = DispatchSemaphore(value: 0)
        let result = Locked<SpeedTest.Outcome?>(nil)
        test.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        if case .finished(let measured) = result.withLock({ $0 }) {
            c.expect(measured.smallWrite > 0 && measured.smallRead > 0 && measured.bigWrite > 0 && measured.bigRead > 0,
                     "measures small and big files: \(Int(measured.smallWrite))/s, \(Int(measured.smallRead))/s, \(Format.bytes(Int64(measured.bigWrite)))/s, \(Format.bytes(Int64(measured.bigRead)))/s")
            c.expect(measured.spacePerSmallFile >= 4_096, "and the room a small file takes: \(measured.spacePerSmallFile)")
        } else {
            c.fail("the speed test didn't finish: \(String(describing: result.withLock { $0 }))")
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: image.mount))?.filter { $0.hasPrefix(".OneFile speed test") } ?? []
        c.expect(left.isEmpty, "its folder is gone afterwards: \(left)")
    }

    static func deleteTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Deleting a folder fast, and safely")
        let home = NSHomeDirectory()
        for refused in ["/", home, home + "/Documents", "/System", "/Users", "/Volumes"] {
            c.expect(Deleter.refusal(URL(fileURLWithPath: refused)) != nil, "refuses \(refused)")
        }
        let fm = FileManager.default
        let target = fixture.base + "/to-delete"
        makeTree(target)
        // A link to something outside: the link goes, never what it points to.
        let outside = fixture.base + "/keep-me.txt"
        try? "keep\n".write(toFile: outside, atomically: false, encoding: .utf8)
        symlink(outside, target + "/f1/link-out")
        // Locked (Finder's Locked) and in a read-only folder.
        chflags(target + "/f0/sub0/file-0.txt", UInt32(UF_IMMUTABLE))
        chmod(target + "/f2/sub2", 0o555)
        c.expect(Deleter.refusal(URL(fileURLWithPath: target)) == nil, "an ordinary folder is fine")
        let counted = Deleter.count(URL(fileURLWithPath: target), stopped: { false })
        c.expect(counted?.items == 80, "counts everything first: \(counted?.items ?? -1)")
        let deleter = Deleter(folder: URL(fileURLWithPath: target))
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Deleter.Outcome?>(nil)
        deleter.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        if case .finished(let summary) = result.withLock({ $0 }) {
            c.expect(!fm.fileExists(atPath: target), "the folder is gone (\(summary.deleted) items, problems: \(summary.problems.prefix(2)))")
            c.expect(fm.fileExists(atPath: outside), "what a link pointed to is still there")
        } else {
            c.fail("deleting didn't finish: \(String(describing: result.withLock { $0 }))")
        }
        // A Trash: what's in it goes, the folder stays.
        let trash = fixture.base + "/Trash-like"
        makeTree(trash)
        let emptier = Deleter(folder: URL(fileURLWithPath: trash), keepFolder: true)
        let emptied = DispatchSemaphore(value: 0)
        emptier.start { _ in emptied.signal() }
        emptied.wait()
        c.expect(fm.fileExists(atPath: trash) && ((try? fm.contentsOfDirectory(atPath: trash)) ?? ["?"]).isEmpty,
                 "emptying keeps the folder itself")
        fixture.cleanUp(trash)
        try? fm.removeItem(atPath: outside)
    }

    /// A small tree to compare and mirror: files in nested folders, a link, an empty folder.
    static func makeTree(_ root: String) {
        let fm = FileManager.default
        for index in 0..<60 {
            let path = root + "/f\(index % 4)/sub\(index % 3)/file-\(index).txt"
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? "file \(index)\n".write(toFile: path, atomically: false, encoding: .utf8)
        }
        try? Data(Fixture.noise(10 << 20)).write(to: URL(fileURLWithPath: root + "/big.bin"))
        symlink("f0", root + "/link")
        try? fm.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
    }

    static func compare(_ a: String, _ b: String, contents: Bool) -> Comparer.Summary? {
        let comparer = Comparer(first: URL(fileURLWithPath: a), second: URL(fileURLWithPath: b),
                                options: Comparer.Options(contents: contents))
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Comparer.Outcome?>(nil)
        comparer.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        if case .finished(let summary) = result.withLock({ $0 }) { return summary }
        return nil
    }

    // MARK: Comparing folders

    static func compareTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Comparing two folders")
        let fm = FileManager.default
        let a = fixture.base + "/compare-a", b = fixture.base + "/compare-b"
        makeTree(a)
        _ = run("/usr/bin/ditto", [a, b])
        if let same = compare(a, b, contents: true) {
            c.expect(same.identical && same.same == 62, "a copy is the same, contents too: \(same.same) same, \(same.items.prefix(3))")
        }
        // Same size and date, different bytes: only reading the contents finds it.
        let changed = b + "/f1/sub1/file-1.txt"
        let date = (try? fm.attributesOfItem(atPath: changed)[.modificationDate]) as? Date
        try? "FILE 1\n".write(toFile: changed, atomically: false, encoding: .utf8)
        if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: changed) }
        try? "new\n".write(toFile: b + "/only-in-b.txt", atomically: false, encoding: .utf8)
        try? fm.removeItem(atPath: b + "/f2")
        try? "finder\n".write(toFile: b + "/.DS_Store", atomically: false, encoding: .utf8)
        if let quick = compare(a, b, contents: false) {
            c.expect(quick.onlySecond == 1 && quick.onlyFirst == 1 && quick.different == 0,
                     "quickly: one only in each, nothing else: \(quick.items.map { "\($0.path) \($0.difference)" })")
            c.expect(quick.items.contains { $0.path == "f2" && $0.isFolder && $0.difference == .onlyFirst },
                     "a missing folder is one item")
        }
        if let thorough = compare(a, b, contents: true) {
            c.expect(thorough.items.contains { $0.path == "f1/sub1/file-1.txt" && $0.difference == .contents },
                     "reading them finds the changed bytes")
            c.expect(!thorough.items.contains { $0.path == ".DS_Store" }, ".DS_Store files are ignored")
        }
        fixture.cleanUp(a)
        fixture.cleanUp(b)
    }

    // MARK: Verifying and mirroring copies

    static func verifyAndMirrorTests(_ fixture: Fixture, _ c: Checks) {
        guard let image = ProcessInfo.processInfo.environment["ONEFILE_TEST_APFS"].map(DiskImage.init) else {
            print("  (Skipped verifying and mirroring: no disk image.)")
            return
        }
        let fm = FileManager.default
        c.section("Verifying a copy on the drive")
        let source = fixture.base + "/Tree"
        makeTree(source)
        let into = URL(fileURLWithPath: image.mount + "/verify")
        try? fm.createDirectory(at: into, withIntermediateDirectories: true)
        var options = Copier.Options(leaveOut: [".DS_Store"])
        options.verify = true
        if case .finished(let summary) = run(Copier(source: URL(fileURLWithPath: source),
                                                    target: .new(folder: into, name: "Tree"), options: options)) {
            c.expect(summary.verified == 61 && summary.mismatched == 0, "every file read back matches: \(summary.verified), \(summary.mismatched) didn't")
        } else {
            c.fail("the verified copy didn't finish")
        }

        c.section("Mirroring: what the original no longer has")
        try? fm.removeItem(atPath: source + "/f3")
        try? fm.removeItem(atPath: source + "/f0/sub0/file-0.txt")
        try? "finder\n".write(toFile: into.path + "/Tree/.DS_Store", atomically: false, encoding: .utf8)
        options.verify = false
        options.mirror = true
        if case .finished(let summary) = run(Copier(source: URL(fileURLWithPath: source),
                                                    target: .update(into.appendingPathComponent("Tree")), options: options)) {
            let paths = Set(summary.extras.map(\.path))
            c.expect(paths == ["f3", "f0/sub0/file-0.txt"], "the deleted folder and file are noted: \(paths.sorted())")
            c.expect(summary.extras.first { $0.path == "f3" }?.isFolder == true, "the folder as one item")
            c.expect(fm.fileExists(atPath: into.path + "/Tree/f3"), "nothing is deleted by copying")
        } else {
            c.fail("the mirrored update didn't finish")
        }
        fixture.cleanUp(source)
        fixture.cleanUp(into.path)
    }

    // MARK: Split into parts

    static func splitTests(_ fixture: Fixture, _ c: Checks) {
        let fm = FileManager.default
        for method in PackMethod.allCases {
            c.section("Splitting a .\(method.fileExtension) into parts")
            let folder = fixture.base + "/split-\(method.rawValue)"
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: folder + "/Split." + method.fileExtension)
            let options = Packer.Options(leaveOut: Fixture.leaveOut, method: method, splitSize: 1_000_000)
            guard case .finished(let summary) = wait(Packer(source: URL(fileURLWithPath: fixture.root), destination: target,
                                                            replaceExisting: false, options: options), after: {}) else {
                c.fail("packing into parts failed")
                continue
            }
            let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            c.expect(summary.parts.count > 3 && names.count == summary.parts.count, "\(summary.parts.count) parts: \(names.prefix(3))…")
            c.expect(names.first == "Split.\(method.fileExtension).001" && !names.contains { $0.hasSuffix(".part") },
                     "named .001 on, nothing left half-written")
            let sizes = summary.parts.map { fileSize($0.path) }
            c.expect(sizes.dropLast().allSatisfy { $0 == 1_000_000 } && (sizes.last ?? 0) <= 1_000_000,
                     "every part but the last is exactly 1 MB: \(sizes.suffix(2))")
            c.expect(sizes.reduce(0, +) == summary.archiveBytes, "the parts add up to the file")
            // OneFile reads them back from any part; macOS's tar from the parts put together.
            for start in [summary.parts[0], summary.parts[2]] {
                let into = fixture.base + "/split-out-\(method.rawValue)-\(start.pathExtension)"
                try? fm.createDirectory(atPath: into, withIntermediateDirectories: true)
                if case .finished(let unpacked) = unpack(start.path, into: into, c) {
                    c.expect(unpacked.output?.lastPathComponent == Fixture.rootName, "opened from part \(start.pathExtension)")
                    compare(fixture.root, into + "/" + Fixture.rootName, c)
                }
                fixture.cleanUp(into)
            }
            let joined = fixture.base + "/joined-\(method.rawValue)"
            try? fm.createDirectory(atPath: joined, withIntermediateDirectories: true)
            let quoted = summary.parts.map { "'" + $0.path + "'" }.joined(separator: " ")
            let flag = method == .gzip ? "z" : method == .xz ? "J" : ""
            // (macOS's tar has no zstd of its own: zstd decompresses it, if it's installed.)
            let zstd = homebrew("zstd")
            if method != .zstd || zstd != nil {
                let unzstd = method == .zstd ? " | '\(zstd ?? "")' -dc" : ""
                let tar = run("/bin/sh", ["-c", "cat \(quoted)\(unzstd) | /usr/bin/tar -x\(flag)f - -C '\(joined)'"])
                c.expect(tar.status == 0, "cat … | tar -x works: \(tar.errors.prefix(200))")
                if tar.status == 0 { compare(fixture.root, joined + "/" + Fixture.rootName, c) }
            }
            fixture.cleanUp(joined)
            // Again into the same place: a new name for all of them.
            if case .finished(let again) = wait(Packer(source: URL(fileURLWithPath: fixture.root), destination: target,
                                                       replaceExisting: false, options: options), after: {}) {
                c.expect(again.output?.lastPathComponent == "Split 2.\(method.fileExtension).001", "a second goes beside it: \(again.output?.lastPathComponent ?? "")")
            }
            fixture.cleanUp(folder)
        }

        c.section("A split file that fits in one part")
        let small = fixture.base + "/split-small"
        try? fm.createDirectory(atPath: small, withIntermediateDirectories: true)
        let one = Packer.Options(leaveOut: Fixture.leaveOut, method: .gzip, splitSize: 1_000_000_000)
        if case .finished(let summary) = wait(Packer(source: URL(fileURLWithPath: fixture.root),
                                                     destination: URL(fileURLWithPath: small + "/Whole.tar.gz"),
                                                     replaceExisting: false, options: one), after: {}) {
            c.expect(summary.parts.isEmpty && summary.output?.lastPathComponent == "Whole.tar.gz", "keeps its plain name")
        }
        fixture.cleanUp(small)
        c.expect(SplitParts.wholeName("Research.tar.gz.001") == "Research.tar.gz" && SplitParts.wholeName("v1.2") == "v1.2",
                 "part names are told apart")
        c.expect(ArchiveName.unpackedName("Research.tar.gz.003") == "Research", "and unpack as their folder")
    }

    // MARK: What Git ignores

    static func gitTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Leaving out what Git ignores")
        guard let git = GitIgnore.git else {
            print("  (Skipped: no git here.)")
            return
        }
        let fm = FileManager.default
        let project = fixture.base + "/Project"
        for (path, text) in [("src/app.swift", "app\n"), ("README.md", "readme\n"), ("build/out.o", "object\n"),
                             ("build/deep/more.o", "object\n"), ("debug.log", "log\n"), ("src/notes.log", "log\n"),
                             ("tracked.log", "tracked\n"), (".gitignore", "build/\n*.log\n")] {
            try? fm.createDirectory(atPath: (project + "/" + path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: project + "/" + path, atomically: false, encoding: .utf8)
        }
        _ = run(git, ["-C", project, "init", "-q"])
        // A file added before it was ignored stays: Git tracks it.
        _ = run(git, ["-C", project, "add", "-f", "tracked.log"])
        guard let ignored = GitIgnore.ignored(in: project) else {
            c.fail("Git's ignored files weren't found")
            return
        }
        let names = Set(ignored.map { String($0.dropFirst(project.count + 1)) })
        c.expect(names == ["build", "debug.log", "src/notes.log"], "Git ignores build, debug.log and src/notes.log: \(names.sorted())")
        c.expect(GitIgnore.ignored(in: fixture.root) == nil, "a folder outside Git has nothing to ask")
        let out = fixture.base + "/project-out"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let options = Packer.Options(leaveOut: [], method: .plain, excluded: Set(ignored))
        if case .finished(let summary) = wait(Packer(source: URL(fileURLWithPath: project),
                                                     destination: URL(fileURLWithPath: out + "/Project.tar"),
                                                     replaceExisting: false, options: options), after: {}) {
            c.expect(summary.gitIgnored == 3, "3 left out: \(summary.gitIgnored)")
            let listed = run("/usr/bin/tar", ["-tf", out + "/Project.tar"]).output
            c.expect(!listed.contains("build") && !listed.contains("debug.log") && !listed.contains("notes.log"),
                     "none of them is in the file")
            c.expect(listed.contains("Project/tracked.log") && listed.contains("Project/src/app.swift") && listed.contains(".gitignore"),
                     "what Git keeps is")
        }
        fixture.cleanUp(out)
        fixture.cleanUp(project)
    }

    // MARK: Pausing

    static func pauseTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Pausing and carrying on")
        let gate = PauseGate()
        gate.pause()
        let passed = Locked(false)
        let waiter = Thread {
            gate.wait()
            passed.withLock { $0 = true }
        }
        waiter.start()
        usleep(150_000)
        c.expect(!passed.withLock { $0 } && gate.isPaused, "a paused gate holds its threads")
        gate.resume()
        let deadline = Date().addingTimeInterval(2)
        while !passed.withLock({ $0 }) && Date() < deadline { usleep(1_000) }
        c.expect(passed.withLock { $0 }, "and lets them go on resuming")

        // A real copy, paused part way: it stops moving, then finishes after resuming.
        let into = fixture.base + "/paused-copy"
        try? FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        let copier = Copier(source: URL(fileURLWithPath: fixture.root),
                            target: .new(folder: URL(fileURLWithPath: into), name: "paused"),
                            options: Copier.Options(leaveOut: Fixture.leaveOut))
        copier.pause()
        let done = DispatchSemaphore(value: 0)
        let outcome = Locked<Copier.Outcome?>(nil)
        copier.start { result in
            outcome.withLock { $0 = result }
            done.signal()
        }
        usleep(400_000)
        let before = copier.progress().files
        usleep(400_000)
        let after = copier.progress().files
        c.expect(before == after && outcome.withLock({ $0 }) == nil, "paused, nothing more is copied (\(before), then \(after))")
        c.expect(copier.isPaused, "and it says it's paused")
        copier.resume()
        done.wait()
        if case .finished(let summary) = outcome.withLock({ $0 }) {
            c.expect(summary.files > 2_500, "resumed, it finishes: \(summary.files) files")
            compare(fixture.root, into + "/paused", c)
        } else {
            c.fail("the paused copy didn't finish: \(String(describing: outcome.withLock { $0 }))")
        }
        fixture.cleanUp(into)

        // Stopping a paused copy doesn't hang.
        let stopped = Copier(source: URL(fileURLWithPath: fixture.root),
                             target: .new(folder: URL(fileURLWithPath: fixture.base), name: "stopped-while-paused"),
                             options: Copier.Options(leaveOut: Fixture.leaveOut))
        stopped.pause()
        let ended = DispatchSemaphore(value: 0)
        stopped.start { _ in ended.signal() }
        usleep(200_000)
        stopped.cancel()
        c.expect(ended.wait(timeout: .now() + 10) == .success, "stopping a paused copy ends it")
        fixture.cleanUp(fixture.base + "/stopped-while-paused (copying)")
    }

    // MARK: Cloud folders

    static func cloudFolderTests(_ c: Checks) {
        c.section("Folders a cloud service syncs")
        let home = Copier.realPath(NSHomeDirectory())
        c.expect(CloudSync.service(for: home + "/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/Backups") == "Google Drive",
                 "Google Drive")
        c.expect(CloudSync.service(for: home + "/Library/CloudStorage/OneDrive-Personal/Work") == "OneDrive", "OneDrive")
        c.expect(CloudSync.service(for: home + "/Library/CloudStorage/Dropbox/Photos") == "Dropbox", "Dropbox")
        c.expect(CloudSync.service(for: home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes") == "iCloud Drive", "iCloud Drive")
        c.expect(CloudSync.service(for: NSTemporaryDirectory()) == nil, "not a temporary folder")
    }
}
