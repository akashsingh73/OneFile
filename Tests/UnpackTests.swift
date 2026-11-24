import Foundation
import Network
import CryptoKit

/// Unpacking, looking inside, folder insights, and sending between two OneFiles (over loopback).
extension OneFileTests {

    // MARK: - Unpacking OneFile's own files

    static func unpackTests(_ fixture: Fixture, _ c: Checks) {
        for method in PackMethod.allCases {
            c.section("Unpacking .\(method.fileExtension) with OneFile")
            let archive = fixture.base + "/out/Root.\(method.fileExtension)"
            guard FileManager.default.fileExists(atPath: archive) else {
                c.fail("no \(archive) to unpack (packing failed earlier)")
                continue
            }
            let folder = fixture.base + "/unpacked-onefile-\(method.rawValue)"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard case .finished(let summary) = unpack(archive, into: folder, c) else { continue }
            c.expect(summary.output?.path == folder + "/" + Fixture.rootName, "unpacked as \(summary.output?.path ?? "nothing")")
            c.expect(summary.format == (method == .plain ? .tar : method == .gzip ? .gzip : .xz), "read as \(String(describing: summary.format))")
            if method == .gzip {
                c.expect(summary.parallel, "OneFile's own .tar.gz decompresses on every core")
            }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.contains("unpacking") } ?? []
            c.expect(leftovers.isEmpty, "no “(unpacking)” folder left: \(leftovers)")
            compare(fixture.root, folder + "/" + Fixture.rootName, c)
            c.expect(summary.problemCount == 0, "no problems: \(summary.problems.prefix(3))")

            if method == .plain {
                // Again, into the same place: a new name, nothing replaced.
                if case .finished(let again) = unpack(archive, into: folder, c) {
                    c.expect(again.output?.lastPathComponent == Fixture.rootName + " 2", "the second goes in “\(again.output?.lastPathComponent ?? "")”")
                }
            }
            fixture.cleanUp(folder)
        }

        c.section("Looking inside without unpacking")
        let inspector = Unpacker(source: .file(URL(fileURLWithPath: fixture.base + "/out/Root.tar.gz")), destination: nil)
        if case .finished(let seen) = wait(inspector) {
            c.expect(seen.output == nil, "nothing written")
            c.expect(seen.topNames == [Fixture.rootName] && seen.topIsFolder, "one folder at the top: \(seen.topNames)")
            if case .finished(let packed) = pack(fixture.root, to: fixture.base + "/out/Counted.tar", leaveOut: Fixture.leaveOut, c) {
                c.expect(seen.files == packed.files, "\(seen.files) files seen, \(packed.files) packed")
                c.expect(seen.folders == packed.folders, "\(seen.folders) folders seen, \(packed.folders) packed")
                c.expect(seen.bytes == packed.bytes, "\(seen.bytes) bytes seen, \(packed.bytes) packed")
            }
            c.expect(seen.kinds.totalFiles > 0 && seen.kinds.ranked.first != nil, "knows what kinds of files: \(seen.kinds.ranked.map(\.kind))")
        } else {
            c.fail("looking inside failed")
        }
    }

    // MARK: - Other tools' files

    static func foreignTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Unpacking files made by other tools (macOS's tar, gzip, xz, Python)")
        // A clean copy of the test folder (nothing unreadable), as OneFile unpacks it.
        let clean = fixture.base + "/clean"
        try? FileManager.default.createDirectory(atPath: clean, withIntermediateDirectories: true)
        guard case .finished = unpack(fixture.base + "/out/Root.tar", into: clean, c) else { return }
        let tree = clean + "/" + Fixture.rootName
        chmod(tree + "/locked-folder", 0o755)
        // A file with an extended attribute: macOS's tar stores it as a "._" file.
        setxattr(tree + "/hello.txt", "com.onefile.test", "hi", 2, 0, 0)

        let made = fixture.base + "/foreign"
        try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        var archives: [(String, String)] = []
        let bsd = run("/usr/bin/tar", ["-cf", made + "/bsdtar.tar", "-C", clean, Fixture.rootName])
        if bsd.status == 0 { archives.append(("macOS's tar (with Mac metadata)", made + "/bsdtar.tar")) }
        else { c.fail("macOS's tar couldn't pack it: \(bsd.errors)") }
        if run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$1\"", made + "/bsdtar.tar", made + "/gzip.tar.gz"]).status == 0 {
            archives.append(("gzip", made + "/gzip.tar.gz"))
        }
        let xz = "/opt/homebrew/bin/xz"
        if FileManager.default.isExecutableFile(atPath: xz) {
            if run("/bin/sh", ["-c", "\"$2\" -c \"$0\" > \"$1\"", made + "/bsdtar.tar", made + "/xz.tar.xz", xz]).status == 0 {
                archives.append(("xz", made + "/xz.tar.xz"))
            }
            if run("/bin/sh", ["-c", "\"$2\" -T0 --block-size=65536 -c \"$0\" > \"$1\"", made + "/bsdtar.tar", made + "/xz-blocks.tar.xz", xz]).status == 0 {
                archives.append(("xz -T0, many blocks", made + "/xz-blocks.tar.xz"))
            }
        }
        let python = run("/usr/bin/python3", ["-I", "-c", """
            import sys, tarfile
            for fmt, name in ((tarfile.GNU_FORMAT, 'gnu.tar'), (tarfile.PAX_FORMAT, 'pax.tar.gz')):
                mode = 'w:gz' if name.endswith('gz') else 'w'
                with tarfile.open(sys.argv[2] + '/' + name, mode, format=fmt) as t:
                    t.add(sys.argv[1], arcname='\(Fixture.rootName)')
            """, tree, made])
        if python.status == 0 {
            archives.append(("Python, GNU format", made + "/gnu.tar"))
            archives.append(("Python, pax format, gzip", made + "/pax.tar.gz"))
        } else {
            print("  (Python not available; skipped its files: \(python.errors.prefix(200)))")
        }

        for (label, archive) in archives {
            let folder = fixture.base + "/foreign-unpacked"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if case .finished(let summary) = unpack(archive, into: folder, c) {
                c.expect(summary.output?.lastPathComponent == Fixture.rootName, "\(label): unpacked as \(summary.output?.lastPathComponent ?? "-")")
                compareExactly(tree, folder + "/" + Fixture.rootName, label, c)
                if label.hasPrefix("macOS") {
                    c.expect(summary.macMetadata >= 1, "\(label): the “._” Mac metadata file was left out (\(summary.macMetadata))")
                }
            }
            fixture.cleanUp(folder)
        }
        fixture.cleanUp(made)

        c.section("A single compressed file, and files that aren't tar files")
        let single = fixture.base + "/single"
        try? FileManager.default.createDirectory(atPath: single, withIntermediateDirectories: true)
        let note = single + "/note.txt"
        FileManager.default.createFile(atPath: note, contents: Data(repeating: 0x61, count: 100_000))
        _ = run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$0.gz\"", note])
        let into = single + "/out"
        try? FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        if case .finished(let summary) = unpack(note + ".gz", into: into, c) {
            c.expect(summary.single && summary.output?.lastPathComponent == "note.txt", "note.txt.gz unpacks to note.txt: \(summary.output?.path ?? "-")")
            c.expect(FileManager.default.contentsEqual(atPath: note, andPath: into + "/note.txt"), "with the same contents")
        }
        let tiny = single + "/tiny.txt"
        FileManager.default.createFile(atPath: tiny, contents: Data("hi\n".utf8))
        _ = run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$0.gz\"", tiny])
        if case .finished = unpack(tiny + ".gz", into: into, c) {
            c.expect((try? String(contentsOfFile: into + "/tiny.txt", encoding: .utf8)) == "hi\n", "a tiny one too")
        }
        FileManager.default.createFile(atPath: single + "/not.tar", contents: Data(repeating: 0x7A, count: 4_096))
        if case .failed(let message) = unpack(single + "/not.tar", into: into, nil) {
            c.expect(message.contains("isn't a tar file"), "a file that isn't a tar file: \(message)")
        } else {
            c.fail("unpacking a file that isn't a tar file didn't fail")
        }
        FileManager.default.createFile(atPath: single + "/a.zip", contents: Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 100)))
        if case .failed(let message) = unpack(single + "/a.zip", into: into, nil) {
            c.expect(message.contains("zip"), "a zip file says so: \(message)")
        } else {
            c.fail("unpacking a zip file didn't fail")
        }
        fixture.cleanUp(single)
        fixture.cleanUp(clean)
    }

    // MARK: - Damage and danger

    static func safetyTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Paths and links that lead outside the folder")
        let work = fixture.base + "/evil"
        let into = work + "/into"
        try? FileManager.default.createDirectory(atPath: into, withIntermediateDirectories: true)
        let outside = work + "/outside"
        try? FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let python = run("/usr/bin/python3", ["-I", "-c", """
            import io, sys, tarfile
            outside = sys.argv[2]
            with tarfile.open(sys.argv[1], 'w', format=tarfile.PAX_FORMAT) as t:
                def add(name, data=b'x', kind=tarfile.REGTYPE, link=''):
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    info.linkname = link
                    info.size = len(data) if kind == tarfile.REGTYPE else 0
                    t.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
                folder = tarfile.TarInfo('top/')
                folder.type = tarfile.DIRTYPE
                folder.mode = 0o755
                t.addfile(folder)
                add('top/fine.txt', b'fine')
                add('../escape.txt')
                add('top/../../escape2.txt')
                add('/absolute/abs.txt', b'abs')
                add('top/./dotted.txt', b'dotted')
                add('top/out', kind=tarfile.SYMTYPE, link=outside)
                add('top/out/through.txt', b'through')
                add('top/hard', kind=tarfile.LNKTYPE, link='../outside.txt')
                add('top/later', kind=tarfile.SYMTYPE, link=outside)
                add('top/later/evil', kind=tarfile.SYMTYPE, link='/etc/passwd')
            """, work + "/evil.tar", outside])
        if python.status != 0 {
            print("  (Python not available; skipped: \(python.errors.prefix(200)))")
        } else if case .finished(let summary) = unpack(work + "/evil.tar", into: into, c) {
            let fm = FileManager.default
            let outsideItems = (try? fm.contentsOfDirectory(atPath: outside)) ?? []
            c.expect(outsideItems.isEmpty, "nothing written in the folder a link points to: \(outsideItems)")
            c.expect(!fm.fileExists(atPath: work + "/escape.txt") && !fm.fileExists(atPath: work + "/escape2.txt")
                     && !fm.fileExists(atPath: fixture.base + "/escape2.txt"), "“..” paths refused")
            c.expect(summary.refused >= 3, "refused \(summary.refused) entries")
            let made = summary.output?.path ?? ""
            c.expect(summary.output?.lastPathComponent == "evil", "several things at the top go in a folder named after the file: \(made)")
            c.expect((try? String(contentsOfFile: made + "/absolute/abs.txt", encoding: .utf8)) == "abs",
                     "an absolute path is unpacked inside the folder")
            c.expect((try? String(contentsOfFile: made + "/top/dotted.txt", encoding: .utf8)) == "dotted", "“./” parts dropped")
            var info = stat()
            c.expect(lstat(made + "/top/out", &info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
                     "a link that would have been written through stays a real folder")
            c.expect(lstat(made + "/top/later/evil", &info) != 0, "no link made inside another link")
        }
        fixture.cleanUp(work)

        c.section("Damaged and cut-off files")
        let damaged = fixture.base + "/damaged"
        try? FileManager.default.createDirectory(atPath: damaged, withIntermediateDirectories: true)
        for method in [PackMethod.gzip, .xz, .plain] {
            let archive = fixture.base + "/out/Root.\(method.fileExtension)"
            guard var data = FileManager.default.contents(atPath: archive) else { continue }
            let cut = damaged + "/Cut.\(method.fileExtension)"
            FileManager.default.createFile(atPath: cut, contents: data.prefix(data.count * 2 / 3))
            if case .failed(let message) = unpack(cut, into: damaged, nil) {
                c.expect(message.contains("too early") || message.contains("damaged"), "a cut-off .\(method.fileExtension) fails: \(message)")
            } else {
                c.fail("a cut-off .\(method.fileExtension) didn't fail")
            }
            if method != .plain {
                data[data.count / 2] ^= 0x5A
                let flipped = damaged + "/Flipped.\(method.fileExtension)"
                FileManager.default.createFile(atPath: flipped, contents: data)
                if case .failed(let message) = unpack(flipped, into: damaged, nil) {
                    c.expect(message.contains("damaged"), "a damaged .\(method.fileExtension) fails: \(message)")
                } else {
                    c.fail("a damaged .\(method.fileExtension) didn't fail")
                }
            }
        }
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: damaged)) ?? []).filter { !$0.hasPrefix("Cut.") && !$0.hasPrefix("Flipped.") }
        c.expect(left.isEmpty, "nothing left behind by the failures: \(left)")

        c.section("Stopping an unpack")
        let unpacker = Unpacker(source: .file(URL(fileURLWithPath: fixture.base + "/out/Root.tar")),
                                destination: URL(fileURLWithPath: damaged))
        let outcome = wait(unpacker) { unpacker.cancel() }
        if case .stopped = outcome { c.expect(true, "") } else { c.fail("stopping gave \(outcome)") }
        let after = ((try? FileManager.default.contentsOfDirectory(atPath: damaged)) ?? []).filter { !$0.hasPrefix("Cut.") && !$0.hasPrefix("Flipped.") }
        c.expect(after.isEmpty, "stopping leaves nothing behind: \(after)")
        fixture.cleanUp(damaged)
    }

    // MARK: - Insights

    static func insightTests(_ fixture: Fixture, _ c: Checks) {
        c.section("What's in a folder: kinds of files, and folders that can be rebuilt")
        guard case .success(let root) = Packer.root(for: URL(fileURLWithPath: fixture.root)),
              let counted = Packer.count(root, rules: WalkRules(leaveOut: [".DS_Store"], device: root.entry.device),
                                         stopped: { false }, progress: { _ in }) else {
            c.fail("couldn't count the test folder")
            return
        }
        let modules = counted.insights.rebuildable[0]
        c.expect(modules.folders == 1 && modules.files == 1, "found node_modules: \(modules)")
        c.expect(counted.insights.suggestions.first?.rule.title == "node_modules", "it's the first suggestion")
        let kinds = counted.insights.kinds
        c.expect(kinds.files[FileKind.code.rawValue] >= 2, "code files: run.sh and index.js")
        c.expect(kinds.files[FileKind.documents.rawValue] >= 2_500, "text files counted as documents")
        c.expect(FileKind.of("Movie.MOV") == .video && FileKind.of("photo.heic") == .images && FileKind.of(".bashrc") == .other
                 && FileKind.of("archive.tar.gz") == .archives, "kinds by extension")

        guard let skipped = Packer.count(root, rules: WalkRules(leaveOut: [".DS_Store"], device: root.entry.device,
                                                                skipRebuildable: [0]),
                                         stopped: { false }, progress: { _ in }) else { return }
        c.expect(skipped.totals.files == counted.totals.files - 1, "leaving out node_modules: \(skipped.totals.files) files, not \(counted.totals.files)")
        let path = fixture.base + "/out/NoModules.tar"
        let packer = Packer(source: URL(fileURLWithPath: fixture.root), destination: URL(fileURLWithPath: path),
                            replaceExisting: true, options: .init(leaveOut: [".DS_Store"], method: .plain, skipRebuildable: [0]))
        if case .finished(let summary) = wait(packer, after: {}) {
            c.expect(summary.rebuildable == 1, "one rebuildable folder left out: \(summary.rebuildable)")
            let list = run("/usr/bin/tar", ["-tf", path]).output
            c.expect(!list.contains("node_modules"), "it isn't in the tar file")
        }
    }

    // MARK: - Sending to another Mac

    static func transferTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Encryption")
        let key = SymmetricKey(size: .bits256)
        let sender = Sealer(sendKey: key, receiveKey: key, sender: true)
        let receiver = Sealer(sendKey: key, receiveKey: key, sender: false)
        let block = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = sender.sealData(block, holds: block.count, index: 7)!
        c.expect(receiver.openData(sealed, index: 7) == block, "a block opens with its own number")
        c.expect(receiver.openData(sealed, index: 8) == nil, "a block moved to another place doesn't open")
        var tampered = sealed
        tampered[tampered.count / 2] ^= 1
        c.expect(receiver.openData(tampered, index: 7) == nil, "a changed block doesn't open")
        var lying = sealed
        lying[3] ^= 1
        c.expect(receiver.openData(lying, index: 7) == nil, "a block that lies about its size doesn't open")

        for method in PackMethod.allCases {
            c.section("Sending the test folder to another OneFile (over loopback), \(method.title)")
            sendAndReceive(fixture, method: method, accept: true, c)
        }
        c.section("Declining")
        sendAndReceive(fixture, method: .plain, accept: false, c)
    }

    private static func sendAndReceive(_ fixture: Fixture, method: PackMethod, accept: Bool, _ c: Checks) {
        let destination = fixture.base + "/received-\(method.rawValue)"
        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let codes = Locked<(sent: String?, received: String?)>((nil, nil))
        let receivedOutcome = Locked<ReceiveSession.Event?>(nil)
        let receiverDone = DispatchSemaphore(value: 0)
        let sessions = Locked<[ReceiveSession]>([])
        let listening = DispatchSemaphore(value: 0)
        let port = Locked<UInt16>(0)
        let advertiser = Advertiser(onConnection: { connection in
            let box = Locked<ReceiveSession?>(nil)
            let session = ReceiveSession(connection: connection, me: ThisMac.identity) { event in
                switch event {
                case .offer(let offer, let code, _, _):
                    codes.withLock { $0.received = code }
                    if offer.name != Fixture.rootName { print("  offer named \(offer.name)") }
                    if accept {
                        box.withLock { $0 }?.accept(into: URL(fileURLWithPath: destination))
                    } else {
                        box.withLock { $0 }?.decline()
                    }
                case .started:
                    break
                default:
                    receivedOutcome.withLock { $0 = event }
                    receiverDone.signal()
                }
            }
            box.withLock { $0 = session }
            sessions.withLock { $0.append(session) }
            session.start()
        }, onStatus: { status in
            if case .ready(let number) = status {
                port.withLock { $0 = number }
                listening.signal()
            }
        })
        advertiser.start(advertise: false)
        defer { advertiser.stop() }
        guard listening.wait(timeout: .now() + 10) == .success, let endpointPort = NWEndpoint.Port(rawValue: port.withLock({ $0 })) else {
            c.fail("couldn't listen on loopback")
            return
        }
        let sentOutcome = Locked<SendSession.Event?>(nil)
        let senderDone = DispatchSemaphore(value: 0)
        let sender = Locked<SendSession?>(nil)
        let session = SendSession(endpoint: .hostPort(host: "127.0.0.1", port: endpointPort), peerName: "Loopback",
                                  source: URL(fileURLWithPath: fixture.root),
                                  options: .init(leaveOut: Fixture.leaveOut, method: method), totals: nil,
                                  me: ThisMac.identity) { event in
            switch event {
            case .code(let code, _):
                codes.withLock { $0.sent = code }
                // The person sending checks the code too.
                sender.withLock { $0 }?.confirm()
            case .connecting, .accepted, .answered: break
            default:
                sentOutcome.withLock { $0 = event }
                senderDone.signal()
            }
        }
        sender.withLock { $0 = session }
        let started = Date()
        session.start()
        guard senderDone.wait(timeout: .now() + 120) == .success else {
            c.fail("sending didn't finish")
            session.cancel()
            return
        }
        if accept { _ = receiverDone.wait(timeout: .now() + 30) }
        let (sent, received) = codes.withLock { $0 }
        c.expect(sent != nil && sent == received, "both Macs show the same code: \(sent ?? "-") and \(received ?? "-")")
        if !accept {
            if case .declined = sentOutcome.withLock({ $0 }) { c.expect(true, "") } else {
                c.fail("declining gave \(String(describing: sentOutcome.withLock { $0 }))")
            }
            return
        }
        guard case .finished(let summary) = sentOutcome.withLock({ $0 }) else {
            c.fail("sending gave \(String(describing: sentOutcome.withLock { $0 }))")
            return
        }
        guard case .finished(let got) = receivedOutcome.withLock({ $0 }) else {
            c.fail("receiving gave \(String(describing: receivedOutcome.withLock { $0 }))")
            return
        }
        c.expect(summary.savedAs == Fixture.rootName, "saved there as \(summary.savedAs ?? "-")")
        c.expect(got.unpack.output?.path == destination + "/" + Fixture.rootName, "received into \(got.unpack.output?.path ?? "-")")
        print(String(format: "  sent %@ (%@ on the wire) in %.2f s", Format.bytes(summary.pack.tarBytes),
                     Format.bytes(summary.sentBytes), Date().timeIntervalSince(started)))
        compare(fixture.root, destination + "/" + Fixture.rootName, c)
        fixture.cleanUp(destination)
    }

    // MARK: - Benchmarks

    static func unpackBenchmark(_ archive: String, _ folder: String) -> Bool {
        let start = Date()
        let unpacker = Unpacker(source: .file(URL(fileURLWithPath: archive)), destination: URL(fileURLWithPath: folder))
        let outcome = wait(unpacker)
        let seconds = Date().timeIntervalSince(start)
        switch outcome {
        case .finished(let summary):
            print(String(format: "Unpacked %@ files and %@ folders (%@) into %@ in %.2f s: %@/s, %@ files/s%@",
                         Format.count(summary.files), Format.count(summary.folders), Format.bytes(summary.bytes),
                         summary.output?.path ?? "-", seconds, Format.bytes(Int64(Double(summary.bytes) / seconds)),
                         Format.count(Int64(Double(summary.files) / seconds)),
                         summary.parallel ? " (decompressed on every core)" : ""))
            if summary.problemCount > 0 { print("\(summary.problemCount) problems; the first: \(summary.problems[0])") }
            return true
        case .stopped:
            print("Stopped.")
        case .failed(let message):
            print("Failed: \(message)")
        }
        return false
    }

    static func inspect(_ archive: String) -> Bool {
        let start = Date()
        let outcome = wait(Unpacker(source: .file(URL(fileURLWithPath: archive)), destination: nil))
        guard case .finished(let seen) = outcome else {
            print("Failed: \(outcome)")
            return false
        }
        print(String(format: "%@: %@ files, %@ folders, %@ links, %@, read in %.2f s%@", seen.format?.title ?? "?",
                     Format.count(seen.files), Format.count(seen.folders), Format.count(seen.links),
                     Format.bytes(seen.bytes), Date().timeIntervalSince(start), seen.parallel ? " on every core" : ""))
        print("At the top: \(seen.topNames.prefix(5).joined(separator: ", "))\(seen.topCount > 5 ? " and \(seen.topCount - 5) more" : "")")
        for kind in seen.kinds.ranked { print("  \(kind.kind.title): \(Format.count(kind.files)) files, \(Format.bytes(kind.bytes))") }
        return true
    }

    // MARK: - Helpers

    static func unpack(_ archive: String, into folder: String, _ c: Checks?) -> Unpacker.Outcome {
        let outcome = wait(Unpacker(source: .file(URL(fileURLWithPath: archive)), destination: URL(fileURLWithPath: folder)))
        if let c {
            switch outcome {
            case .finished: break
            case .stopped: c.fail("unpacking \(archive) stopped")
            case .failed(let message): c.fail("unpacking \((archive as NSString).lastPathComponent) failed: \(message)")
            }
        }
        return outcome
    }

    static func wait(_ unpacker: Unpacker, after start: () -> Void = {}) -> Unpacker.Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Unpacker.Outcome?>(nil)
        unpacker.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        start()
        done.wait()
        return result.withLock { $0 }!
    }

    /// Two folders hold exactly the same: names, kinds, contents, permissions, dates, link targets.
    static func compareExactly(_ expected: String, _ actual: String, _ label: String, _ c: Checks) {
        let want = snapshot(expected)
        let got = snapshot(actual)
        let missing = Set(want.keys).subtracting(got.keys).map { String(decoding: $0, as: UTF8.self) }
        let extra = Set(got.keys).subtracting(want.keys).map { String(decoding: $0, as: UTF8.self) }
        c.expect(missing.isEmpty && extra.isEmpty, "\(label): missing \(missing.sorted().prefix(5)), extra \(extra.sorted().prefix(5))")
        var wrong: [String] = []
        for (key, item) in want {
            guard let other = got[key] else { continue }
            let path = String(decoding: key, as: UTF8.self)
            if other.kind != item.kind { wrong.append("\(path): kind"); continue }
            if item.kind == .symlink {
                if other.target != item.target { wrong.append("\(path): target") }
                continue
            }
            if other.mode != item.mode { wrong.append("\(path): mode \(String(other.mode, radix: 8))") }
            if other.modified != item.modified { wrong.append("\(path): date") }
            if item.kind == .file && !FileManager.default.contentsEqual(atPath: expected + "/" + path, andPath: actual + "/" + path) {
                wrong.append("\(path): contents")
            }
        }
        c.expect(wrong.isEmpty, "\(label): every entry matches: \(wrong.sorted().prefix(8))")
    }
}
