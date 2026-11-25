import Foundation

/// OneFile's tests. Run them with `bash test.sh` (no Xcode needed).
///
/// They build a folder with everything a tar file has to get right (long and non-ASCII names, empty
/// and big files, both kinds of links, a named pipe, odd permissions and dates, unreadable items,
/// names to leave out), pack it, unpack the result with macOS's own `tar`, and compare the two
/// folders byte for byte. `bash test.sh --pack FOLDER FILE.tar` packs a folder of your own and says
/// how long it took; `--unpack FILE FOLDER` unpacks one, and `--inspect FILE` looks inside one.
@main
struct OneFileTests {
    static func main() {
        Packer.stopDownloadingCloudFiles()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--pack" {
            guard arguments.count == 3 || arguments.count == 4,
                  let method = PackMethod(rawValue: arguments.count == 4 ? arguments[3] : "plain") else {
                print("Use: bash test.sh --pack FOLDER FILE [plain|gzip|zstd|xz]")
                exit(2)
            }
            exit(benchmark(arguments[1], arguments[2], method) ? 0 : 1)
        }

        if arguments.first == "--estimate", arguments.count == 2 {
            guard case .success(let root) = Packer.root(for: URL(fileURLWithPath: arguments[1])),
                  let counted = Packer.count(root, rules: WalkRules(leaveOut: [], device: root.entry.device),
                                             stopped: { false }, progress: { _ in }) else { exit(1) }
            let start = Date()
            let estimates = Estimator.estimate(counted.totals, samples: counted.samples)
            print(String(format: "Estimated in %.2f s, recommends %@ (%@):", Date().timeIntervalSince(start),
                         estimates.recommended.title, estimates.reason))
            for method in PackMethod.allCases {
                let seconds = estimates.seconds(for: method, tarBytes: counted.totals.archiveBytes)
                print("  \(method.title.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Format.bytes(estimates.bytes[method] ?? 0))"
                      + (seconds.map { ", compressing takes ~\(Format.duration($0))" } ?? ""))
            }
            exit(0)
        }

        if arguments.first == "--unpack", arguments.count == 3 {
            exit(unpackBenchmark(arguments[1], arguments[2]) ? 0 : 1)
        }
        if arguments.first == "--inspect", arguments.count == 2 {
            exit(inspect(arguments[1]) ? 0 : 1)
        }
        if arguments.first == "--delete", arguments.count == 2 {
            exit(deleteBenchmark(arguments[1]) ? 0 : 1)
        }
        if arguments.first == "--copy", arguments.count == 3 {
            exit(copyBenchmark(arguments[1], arguments[2]) ? 0 : 1)
        }

        _ = Unpacker.umaskBits
        let checks = Checks()
        formatTests(checks)
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            roundTripTests(fixture, checks)
            for method in [PackMethod.gzip, .zstd, .xz] { compressedTests(fixture, method, checks) }
            estimateTests(fixture, checks)
            repeatTests(fixture, checks)
            stopTests(fixture, checks)
            insideTests(fixture, checks)
            unpackTests(fixture, checks)
            foreignTests(fixture, checks)
            safetyTests(fixture, checks)
            insightTests(fixture, checks)
            transferTests(fixture, checks)
            copyTests(fixture, checks)
            featureTests(fixture, checks)
            cliTests(fixture, checks)
            backupTests(fixture, checks)
            cloudTests(fixture, checks)
            zstdTests(fixture, checks)
        } catch {
            checks.fail("Couldn't build the test folder: \(error)")
        }
        print(checks.failed == 0
              ? "\nAll \(checks.passed) checks passed."
              : "\n\(checks.failed) of \(checks.passed + checks.failed) checks FAILED.")
        exit(checks.failed == 0 ? 0 : 1)
    }

    // MARK: - The tar format on its own

    static func formatTests(_ c: Checks) {
        c.section("The tar format")

        // Every record says its own length, digits included, across the digit boundaries.
        var recordsRight = true
        for length in 0...1_100 {
            let record = Tar.record("path", String(repeating: "a", count: length))
            let digits = record.prefix { $0 != 0x20 }
            let said = Int(String(decoding: digits, as: UTF8.self)) ?? -1
            if said != record.count || record.last != 0x0A { recordsRight = false }
        }
        c.expect(recordsRight, "extended header records give their own length")

        func split(_ path: String) -> Int? {
            var path = path
            return path.withUTF8 { Tar.ustarSplit($0) }
        }
        let a50 = String(repeating: "a", count: 50), b50 = String(repeating: "b", count: 50)
        c.expect(split("folder/file.txt") == 0, "a short path fits the name field")
        c.expect(split(String(repeating: "n", count: 100)) == 0, "100 bytes fit the name field")
        c.expect(split(a50 + "/" + b50) == 50, "101 bytes split at the slash")
        c.expect(split(String(repeating: "p", count: 155) + "/" + String(repeating: "n", count: 100)) == 155,
                 "155 + 1 + 100 bytes split into prefix and name")
        c.expect(split(String(repeating: "p", count: 156) + "/" + String(repeating: "n", count: 99)) == nil,
                 "a prefix of 156 bytes doesn't fit")
        c.expect(split(String(repeating: "n", count: 101)) == nil, "101 bytes with no slash don't fit")
        c.expect(split(String(repeating: "p", count: 60) + "/" + String(repeating: "q", count: 60) + "/") == 60,
                 "a folder's trailing slash isn't where it splits")
        c.expect(split("caf\u{E9}.txt") == nil, "a name that isn't ASCII needs an extended header")

        // A header's checksum and fields.
        let header = Tar.Header(path: "folder/file.txt", type: .file, size: 1_234, mode: 0o644, owner: 501,
                                group: 20, modified: 1_700_000_000, linkTarget: "")
        c.expect(Tar.extendedRecords(for: header) == nil, "a plain file needs no extended header")
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { block.deallocate() }
        c.expect(Tar.write(header, extended: nil, to: block) == 512, "a plain header is one block")
        func field(_ offset: Int, _ length: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: block + offset, count: length).prefix { $0 != 0 && $0 != 0x20 },
                   as: UTF8.self)
        }
        var sum = 0
        for index in 0..<512 { sum += (148..<156).contains(index) ? 0x20 : Int(block[index]) }
        c.expect(Int(field(148, 8), radix: 8) == sum, "the checksum adds up")
        c.expect(field(0, 100) == "folder/file.txt", "name field")
        c.expect(Int(field(124, 12), radix: 8) == 1_234, "size field")
        c.expect(Int(field(136, 12), radix: 8) == 1_700_000_000, "time field")
        c.expect(field(257, 6) == "ustar", "ustar magic")

        let huge = Tar.Header(path: "huge.bin", type: .file, size: 9 << 30, mode: 0o644, owner: 501, group: 20,
                              modified: -100, linkTarget: "")
        let records = Tar.extendedRecords(for: huge).map { String(decoding: $0, as: UTF8.self) } ?? ""
        c.expect(records.contains(" size=9663676416\n") && records.contains(" mtime=-100\n"),
                 "9 GiB and a date before 1970 go in the extended header: \(records)")

        c.section("File names")
        c.expect(ArchiveName.split("Research.tar.gz") == ("Research", "tar.gz"), "splits .tar.gz")
        c.expect(ArchiveName.split("Old.Photos.tar") == ("Old.Photos", "tar"), "splits .tar after other dots")
        c.expect(ArchiveName.split("notes.txt") == ("notes.txt", nil), "leaves other names alone")
        let folder = URL(fileURLWithPath: "/tmp/x")
        c.expect(ArchiveName.with(folder.appendingPathComponent("A.tar"), method: .xz).lastPathComponent == "A.tar.xz",
                 "swaps in the method's extension")
        c.expect(ArchiveName.with(folder.appendingPathComponent("A.tar.gz"), method: .zstd).lastPathComponent == "A.tar.zst",
                 "and .tar.zst for zstd")
        c.expect(ArchiveName.split("Research.tar.zst") == ("Research", "tar.zst") && ArchiveName.split("R.tzst") == ("R", "tzst"),
                 "splits .tar.zst and .tzst")
        c.expect(ArchiveName.unpackedName("Research.tar.zst.age") == "Research" && ArchiveName.unpackedName("notes.txt.zst") == "notes.txt",
                 "names what a .tar.zst and a .zst unpack to")
        c.expect(ArchiveName.numbered(folder.appendingPathComponent("A.tar.gz"), 2).lastPathComponent == "A 2.tar.gz",
                 "numbers before a double extension")

        c.section("Names to leave out")
        let parsed = WalkRules.parse(" .DS_Store, node_modules ,*.tmp,, \n Thumbs.db")
        c.expect(parsed == [".DS_Store", "node_modules", "*.tmp", "Thumbs.db"], "parsed \(parsed)")
        let rules = WalkRules(leaveOut: parsed, device: 0)
        c.expect(rules.leavesOut(".DS_Store") && rules.leavesOut("node_modules") && rules.leavesOut("a.tmp"),
                 "leaves out names and patterns")
        c.expect(!rules.leavesOut("notes.txt") && !rules.leavesOut("tmp"), "keeps the rest")
    }

    // MARK: - Round trip

    static func roundTripTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Packing the test folder and unpacking it with macOS's tar")
        let tarPath = fixture.base + "/out/Root.tar"
        guard case .finished(let summary) = pack(fixture.root, to: tarPath, leaveOut: Fixture.leaveOut, c) else { return }
        c.expect(summary.output?.path == tarPath, "saved as \(summary.output?.path ?? "-")")
        c.expect(!FileManager.default.fileExists(atPath: tarPath + ".part"), "no .part file left")
        let problems = summary.problems.map { ($0.path as NSString).lastPathComponent }.sorted()
        c.expect(problems == ["locked-folder", "secret.txt"],
                 "the unreadable file and folder are problems: \(summary.problems)")
        c.expect(summary.leftOut == 4, "left out 2 .DS_Store, node_modules and a .tmp file: \(summary.leftOut)")
        let size = fileSize(tarPath)
        c.expect(summary.archiveBytes == size, "says the file is \(summary.archiveBytes) bytes; it's \(size)")
        c.expect(summary.tarBytes % 10_240 == 0, "the tar stream is padded to whole tar records")
        if let file = InputFile(path: tarPath), let index = ArchiveIndex.read(file, format: .tar) {
            c.expect(index.tarSize == summary.tarBytes && index.start == summary.tarBytes,
                     "OneFile's index follows the end of the tar: \(index.start), \(summary.tarBytes)")
        } else {
            c.fail("the .tar has no index OneFile can read")
        }

        let list = run("/usr/bin/tar", ["-tvf", tarPath])
        c.expect(list.status == 0 && list.errors.isEmpty, "macOS's tar lists it without complaint: \(list.errors)")
        let entries = list.output.split(separator: "\n").count
        c.expect(Int64(entries) == summary.files + summary.folders,
                 "\(entries) entries listed, \(summary.files) files and \(summary.folders) folders packed")

        let unpacked = fixture.base + "/unpacked"
        try? FileManager.default.createDirectory(atPath: unpacked, withIntermediateDirectories: true)
        let extract = run("/usr/bin/tar", ["-xpf", tarPath, "-C", unpacked])
        c.expect(extract.status == 0 && extract.errors.isEmpty, "macOS's tar unpacks it without complaint: \(extract.errors)")
        compare(fixture.root, unpacked + "/" + Fixture.rootName, c)

        // A second, independent reader, if this Mac has Python.
        let python = run("/usr/bin/python3", ["-I", "-c",
            "import sys, tarfile\nwith tarfile.open(sys.argv[1]) as t:\n    print(len(t.getmembers()))", tarPath])
        if python.status == 0 {
            let members = Int(python.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            c.expect(members == entries, "Python's tarfile reads \(members) entries, tar listed \(entries)")
        } else {
            print("  (Python not available; skipped its check)")
        }
        fixture.cleanUp(unpacked)
    }

    static func compressedTests(_ fixture: Fixture, _ method: PackMethod, _ c: Checks) {
        c.section("Packing to .\(method.fileExtension) (\(method.title)) and unpacking with macOS's tar")
        let path = fixture.base + "/out/Root.\(method.fileExtension)"
        guard case .finished(let summary) = pack(fixture.root, to: path, leaveOut: Fixture.leaveOut, method: method, c)
        else { return }
        c.expect(summary.method == method, "made with \(summary.method)")
        c.expect(summary.archiveBytes == fileSize(path), "says the file is \(summary.archiveBytes) bytes; it's \(fileSize(path))")
        c.expect(summary.archiveBytes < summary.tarBytes,
                 "smaller than the tar stream: \(summary.archiveBytes) of \(summary.tarBytes)")
        c.expect(summary.tarBytes % 10_240 == 0, "the tar stream inside is padded to whole records")
        let tool = method == .gzip ? "/usr/bin/gzip" : homebrew(method == .zstd ? "zstd" : "xz")
        if let tool {
            let check = run(tool, ["-t", path])
            c.expect(check.status == 0, "\(tool) -t says it's sound: \(check.errors)")
        }
        let unpacked = fixture.base + "/unpacked-\(method.rawValue)"
        try? FileManager.default.createDirectory(atPath: unpacked, withIntermediateDirectories: true)
        // macOS's tar has no zstd of its own: it runs the zstd program, if it's installed.
        let zstd = homebrew("zstd")
        if method != .zstd || zstd != nil {
            let environment = "PATH=" + (zstd.map { ($0 as NSString).deletingLastPathComponent + ":" } ?? "") + "/usr/bin:/bin"
            let extract = run("/usr/bin/env", [environment, "/usr/bin/tar", "-xpf", path, "-C", unpacked])
            c.expect(extract.status == 0 && extract.errors.isEmpty, "macOS's tar unpacks it without complaint: \(extract.errors)")
            compare(fixture.root, unpacked + "/" + Fixture.rootName, c)
        } else {
            print("  (zstd isn't installed, so macOS's tar can't open it: skipped)")
        }
        if let python = method == .zstd ? zstdPython : "/usr/bin/python3" {
            let read = run(python, ["-I", "-c",
                "import sys, tarfile\nwith tarfile.open(sys.argv[1], 'r:*') as t:\n    print(len(t.getmembers()))", path])
            if read.status == 0 || method == .zstd {
                let members = Int64(read.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
                c.expect(members == summary.files + summary.folders, "Python's tarfile reads \(members) entries \(read.errors.prefix(200))")
            }
        }
        fixture.cleanUp(unpacked)

        let again = fixture.base + "/out/Root again.\(method.fileExtension)"
        if case .finished = pack(fixture.root, to: again, leaveOut: Fixture.leaveOut, method: method, c) {
            c.expect(FileManager.default.contentsEqual(atPath: again, andPath: path),
                     "packing twice gives the same bytes")
        }

        let stopped = fixture.base + "/out/Stopped.\(method.fileExtension)"
        let packer = Packer(source: URL(fileURLWithPath: fixture.root), destination: URL(fileURLWithPath: stopped),
                            replaceExisting: true, options: .init(leaveOut: [], method: method))
        let outcome = wait(packer) { packer.cancel() }
        if case .stopped = outcome {
            c.expect(true, "")
        } else {
            c.fail("stopping gave \(outcome)")
        }
        c.expect(!FileManager.default.fileExists(atPath: stopped) && !FileManager.default.fileExists(atPath: stopped + ".part"),
                 "stopping leaves no file behind")
    }

    static func estimateTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Estimating each method's size from a sample")
        guard case .success(let root) = Packer.root(for: URL(fileURLWithPath: fixture.root)),
              let counted = Packer.count(root, rules: WalkRules(leaveOut: Fixture.leaveOut, device: root.entry.device),
                                         stopped: { false }, progress: { _ in }) else {
            c.fail("couldn't count the test folder")
            return
        }
        c.expect(!counted.samples.isEmpty && counted.samples.count <= 48, "sampled \(counted.samples.count) files")
        let estimates = Estimator.estimate(counted.totals, samples: counted.samples)
        let plain = estimates.bytes[.plain] ?? 0, gzip = estimates.bytes[.gzip] ?? 0, xz = estimates.bytes[.xz] ?? 0
        let zstd = estimates.bytes[.zstd] ?? 0
        c.expect(plain == counted.totals.archiveBytes, "no compression: the tar's size")
        c.expect(gzip > 0 && gzip < plain && zstd > 0 && zstd < plain && xz > 0 && xz < plain,
                 "compressed estimates are smaller: \(gzip), \(zstd), \(xz) of \(plain)")
        c.expect((estimates.speed[.gzip] ?? 0) > (estimates.speed[.xz] ?? 0), "gzip is estimated faster than xz")
        c.expect((estimates.speed[.zstd] ?? 0) > (estimates.speed[.gzip] ?? 0), "zstd is estimated faster than gzip")
        // The real sizes, from the packs above.
        for method in [PackMethod.gzip, .zstd, .xz] {
            let real = fileSize(fixture.base + "/out/Root.\(method.fileExtension)")
            let guess = estimates.bytes[method] ?? 0
            let off = abs(Double(guess - real)) / Double(max(real, 1))
            c.expect(off < 0.5, "the \(method.rawValue) estimate is within half: \(guess) for \(real)")
        }
    }

    /// The unpacked folder must match the original, less what was left out or couldn't be read.
    static func compare(_ original: String, _ unpacked: String, _ c: Checks) {
        var expected = snapshot(original)
        for key in expected.keys {
            let path = String(decoding: key, as: UTF8.self)
            let parts = path.split(separator: "/").map(String.init)
            if parts.contains(".DS_Store") || parts.contains("node_modules") || path.hasSuffix(".tmp")
                || path == "secret.txt" {
                expected[key] = nil
            }
        }
        let actual = snapshot(unpacked)
        let missing = Set(expected.keys).subtracting(actual.keys).map { String(decoding: $0, as: UTF8.self) }
        let extra = Set(actual.keys).subtracting(expected.keys).map { String(decoding: $0, as: UTF8.self) }
        c.expect(missing.isEmpty, "nothing missing: \(missing.sorted().prefix(10))")
        c.expect(extra.isEmpty, "nothing extra: \(extra.sorted().prefix(10))")

        var wrong: [String] = []
        for (key, want) in expected {
            guard let got = actual[key] else { continue }
            let path = String(decoding: key, as: UTF8.self)
            if got.kind != want.kind { wrong.append("\(path): kind"); continue }
            switch want.kind {
            case .file:
                if got.size != want.size { wrong.append("\(path): size \(got.size), not \(want.size)") }
                let same = FileManager.default.contentsEqual(atPath: original + "/" + path, andPath: unpacked + "/" + path)
                if !same { wrong.append("\(path): contents") }
                if got.mode != want.mode { wrong.append("\(path): mode \(String(got.mode, radix: 8))") }
                if got.modified != want.modified { wrong.append("\(path): date \(got.modified), not \(want.modified)") }
            case .directory:
                if got.mode != want.mode { wrong.append("\(path): mode \(String(got.mode, radix: 8))") }
                if got.modified != want.modified { wrong.append("\(path): date \(got.modified), not \(want.modified)") }
            case .symlink:
                if got.target != want.target { wrong.append("\(path): points to \(got.target)") }
            case .fifo:
                if got.mode != want.mode { wrong.append("\(path): mode \(String(got.mode, radix: 8))") }
            case .other:
                break
            }
        }
        c.expect(wrong.isEmpty, "every entry matches: \(wrong.sorted().prefix(12))")

        let first = actual[Array("hello.txt".utf8)]?.inode
        let second = actual[Array("folder/hard-link-to-hello.txt".utf8)]?.inode
        c.expect(first != nil && first == second, "the hard link is still one file under two names")
    }

    // MARK: - More

    static func repeatTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Packing twice gives the same bytes (the parallel reads put everything in its place)")
        let again = fixture.base + "/out/Root again.tar"
        guard case .finished = pack(fixture.root, to: again, leaveOut: Fixture.leaveOut, c) else { return }
        c.expect(FileManager.default.contentsEqual(atPath: again, andPath: fixture.base + "/out/Root.tar"),
                 "byte for byte the same")
    }

    static func stopTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Stopping")
        let tarPath = fixture.base + "/out/Stopped.tar"
        let packer = Packer(source: URL(fileURLWithPath: fixture.root), destination: URL(fileURLWithPath: tarPath),
                            replaceExisting: true, options: .init(leaveOut: []))
        let outcome = wait(packer) { packer.cancel() }
        if case .stopped = outcome {
            c.expect(true, "")
        } else {
            c.fail("stopping gave \(outcome)")
        }
        c.expect(!FileManager.default.fileExists(atPath: tarPath), "no tar file")
        c.expect(!FileManager.default.fileExists(atPath: tarPath + ".part"), "no .part file")

        c.section("Not replacing a file that's already there")
        let taken = fixture.base + "/out/Taken.tar"
        FileManager.default.createFile(atPath: taken, contents: Data("keep me".utf8))
        guard case .finished(let summary) = pack(fixture.root, to: taken, leaveOut: Fixture.leaveOut, replace: false, c)
        else { return }
        c.expect(summary.output?.lastPathComponent == "Taken 2.tar", "saved as \(summary.output?.lastPathComponent ?? "-")")
        c.expect((try? String(contentsOfFile: taken, encoding: .utf8)) == "keep me", "the other file is untouched")
    }

    static func insideTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Saving the tar file inside the folder being packed")
        let inside = fixture.root + "/inside.tar"
        defer { try? FileManager.default.removeItem(atPath: inside) }
        guard case .finished = pack(fixture.root, to: inside, leaveOut: Fixture.leaveOut, c) else { return }
        let list = run("/usr/bin/tar", ["-tf", inside])
        let names = list.output.split(separator: "\n")
        c.expect(list.status == 0 && !names.isEmpty, "lists it")
        c.expect(!names.contains { $0.hasSuffix("inside.tar") || $0.hasSuffix("inside.tar.part") },
                 "it doesn't pack itself")
    }

    // MARK: - Benchmark

    static func benchmark(_ source: String, _ destination: String, _ method: PackMethod) -> Bool {
        let checks = Checks()
        let start = Date()
        let outcome = pack(source, to: destination, leaveOut: [], method: method, checks)
        let seconds = Date().timeIntervalSince(start)
        guard case .finished(let summary) = outcome else { return false }
        print(String(format: "Packed %@ files and %@ folders (%@) into %@ (%@ before compression) in %.2f s: %@/s, %@ files/s",
                     Format.count(summary.files), Format.count(summary.folders), Format.bytes(summary.bytes),
                     Format.bytes(summary.archiveBytes), Format.bytes(summary.tarBytes), seconds,
                     Format.bytes(Int64(Double(summary.archiveBytes) / seconds)),
                     Format.count(Int64(Double(summary.files) / seconds))))
        if summary.problemCount > 0 {
            print("\(summary.problemCount) problems; the first: \(summary.problems[0].path): \(summary.problems[0].message)")
        }
        return true
    }

    // MARK: - Helpers

    static func pack(_ source: String, to destination: String, leaveOut: [String], replace: Bool = true,
                     method: PackMethod = .plain, _ c: Checks) -> Packer.Outcome {
        let packer = Packer(source: URL(fileURLWithPath: source), destination: URL(fileURLWithPath: destination),
                            replaceExisting: replace, options: .init(leaveOut: leaveOut, method: method))
        let outcome = wait(packer) {}
        switch outcome {
        case .finished: break
        case .stopped: c.fail("packing \(source) stopped")
        case .failed(let message): c.fail("packing \(source) failed: \(message)")
        }
        return outcome
    }

    static func wait(_ packer: Packer, after start: () -> Void) -> Packer.Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Packer.Outcome?>(nil)
        packer.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        start()
        done.wait()
        return result.withLock { $0 }!
    }

    struct Item {
        var kind: FolderEntry.Kind
        var mode: UInt32
        var size: Int64
        var modified: Int64
        var target: String
        var inode: UInt64
    }

    /// Everything under `root`, by relative path. Keys are the path's bytes, so a name that changed
    /// Unicode form (é as one character or two) counts as different.
    static func snapshot(_ root: String) -> [[UInt8]: Item] {
        var items: [[UInt8]: Item] = [:]
        func visit(_ path: String, _ relative: String) {
            var folders: [(String, String)] = []
            FolderReader.read(path) { entries in
                for entry in entries {
                    let name = relative.isEmpty ? entry.name : relative + "/" + entry.name
                    let full = path + "/" + entry.name
                    let target = entry.kind == .symlink ? (Packer.linkTarget(full) ?? "?") : ""
                    items[Array(name.utf8)] = Item(kind: entry.kind, mode: entry.permissions, size: entry.size,
                                                   modified: entry.modified, target: target, inode: entry.inode)
                    if entry.kind == .directory { folders.append((full, name)) }
                }
                return true
            }
            for (full, name) in folders { visit(full, name) }
        }
        visit(root, "")
        return items
    }

    static func fileSize(_ path: String) -> Int64 {
        var info = stat()
        return stat(path, &info) == 0 ? Int64(info.st_size) : -1
    }

    /// A tool Homebrew installs (zstd, pzstd, xz), if it's on this Mac.
    static func homebrew(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A Python that reads and writes zstd (3.14 or later), if there's one.
    static let zstdPython: String? = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first {
        FileManager.default.isExecutableFile(atPath: $0) && run($0, ["-I", "-c", "import compression.zstd"]).status == 0
    }

    /// What OneFile reads a file packed with the method as.
    static func format(of method: PackMethod) -> ArchiveFormat {
        switch method {
        case .plain: .tar
        case .gzip: .gzip
        case .zstd: .zstd
        case .xz: .xz
        }
    }

    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String, errors: String) {
        let folder = FileManager.default.temporaryDirectory
        let out = folder.appendingPathComponent("OneFileTests-\(UUID().uuidString).out")
        let err = folder.appendingPathComponent("OneFileTests-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = try? FileHandle(forWritingTo: out)
        process.standardError = try? FileHandle(forWritingTo: err)
        do {
            try process.run()
        } catch {
            return (-1, "", "\(error)")
        }
        process.waitUntilExit()
        let output = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        let errors = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output, errors)
    }
}

final class Checks {
    var passed = 0
    var failed = 0

    func section(_ name: String) {
        print("\n\(name)")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("  FAILED: \(message())")
        }
    }

    func fail(_ message: String) {
        failed += 1
        print("  FAILED: \(message)")
    }
}

/// A folder with everything a tar file has to get right.
final class Fixture {
    static let rootName = "Root Folder"
    static let leaveOut = [".DS_Store", "node_modules", "*.tmp"]

    /// Holds the folder, the tar files and what's unpacked from them.
    let base: String
    /// The folder that gets packed.
    let root: String

    init() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("OneFileTests-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        guard let real = realpath(temporary.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        base = String(cString: real)
        free(real)
        root = base + "/" + Fixture.rootName
        try fm.createDirectory(atPath: base + "/out", withIntermediateDirectories: true)

        try write("hello.txt", "Hello, world\n")
        try write("empty.txt", "")
        try write("exactly-512.bin", Data(repeating: 0x41, count: 512))
        try write("just-over-512.bin", Data(repeating: 0x42, count: 513))
        // Over 8 MB: copied a piece at a time, between batches of small files.
        try write("big-1.bin", Fixture.noise(9 << 20 + 123))
        try write("folder/after-big.txt", "after\n")
        try write("folder/big-2.bin", Fixture.noise(8 << 20 + 1))
        // More than one batch of small files.
        for index in 0..<2_500 { try write("many/file-\(index).txt", "file \(index)\n") }

        let long = String(repeating: "long-folder-name-", count: 5)
        try write("\(long)/\(long)/a-file-whose-path-is-longer-than-a-hundred-bytes.txt", "long\n")
        try write("\(long)/\(long)/\(long)/\(String(repeating: "x", count: 80)).txt", "longer than ustar can hold\n")
        try write("\u{FC}n\u{EF}c\u{F8}d\u{E9}/\u{6587}\u{4EF6} \u{1F4E6}.txt", "unicode\n")
        try write("cafe\u{301}.txt", "decomposed e-acute\n")
        try write("with space/it's \"quoted\" & odd.txt", "odd\n")

        try write("run.sh", "#!/bin/sh\necho hi\n")
        chmod(path("run.sh"), 0o755)
        try write("read-only.txt", "read only\n")
        chmod(path("read-only.txt"), 0o444)
        try write("old.txt", "2001\n")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978_307_200)], ofItemAtPath: path("old.txt"))
        try write("before-1970.txt", "1960\n")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: -315_619_200)],
                             ofItemAtPath: path("before-1970.txt"))

        symlink("hello.txt", path("link-to-hello"))
        symlink("nowhere/at/all", path("dangling-link"))
        symlink("folder", path("link-to-folder"))
        symlink(String(repeating: "../", count: 40) + "far-away", path("long-link"))
        link(path("hello.txt"), path("folder/hard-link-to-hello.txt"))
        mkdir(path("empty-folder"), 0o755)
        mkfifo(path("pipe"), 0o644)

        try write(".DS_Store", "finder\n")
        try write("folder/.DS_Store", "finder\n")
        try write("node_modules/package/index.js", "js\n")
        try write("scratch.tmp", "tmp\n")

        try write("secret.txt", "secret\n")
        chmod(path("secret.txt"), 0o000)
        mkdir(path("locked-folder"), 0o000)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    private func write(_ relative: String, _ text: String) throws {
        try write(relative, Data(text.utf8))
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func noise(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in words.indices { words[index] = generator.next() }
        }
        return data
    }

    /// Deletes a folder made from the fixture, opening up locked folders first. (Only real
    /// folders: chmod follows symbolic links, and some of the fixture's point elsewhere.)
    func cleanUp(_ folder: String) {
        if let items = FileManager.default.enumerator(atPath: folder) {
            for case let item as String in items {
                var info = stat()
                let full = folder + "/" + item
                if lstat(full, &info) == 0, UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) {
                    chmod(full, 0o755)
                }
            }
        }
        chmod(folder, 0o755)
        try? FileManager.default.removeItem(atPath: folder)
    }

    func remove() {
        chmod(path("secret.txt"), 0o644)
        chmod(path("locked-folder"), 0o755)
        cleanUp(base)
    }
}
