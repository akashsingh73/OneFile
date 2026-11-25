import Foundation
import zlib

/// Other tools' files decompressed on every core: xz's blocks, and gzip's one long stream.
extension OneFileTests {
    static func everyCoreTests(_ fixture: Fixture, _ c: Checks) {
        let folder = fixture.base + "/every-core"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { fixture.cleanUp(folder) }
        xzBlockTests(fixture, folder, c)
        gunzipTests(fixture, folder, c)
    }

    /// What decompressing a file brings: the CRC-32 and length of the stream, whether it went on
    /// every core, the most chunks held at once, or why it failed. `pause` (seconds a chunk) makes
    /// it as slow to take them as unpacking many small files.
    static func decodeAll(_ path: String, pause: Double = 0)
        -> (crc: UInt32, count: Int, parallel: Bool, peak: Int, failure: String?) {
        guard case .success(let file) = InputFile.open(URL(fileURLWithPath: path), password: nil),
              case .success(let format) = ArchiveFormat.detect(file, name: path) else {
            return (0, 0, false, 0, "couldn't open it")
        }
        let decoding = ArchiveDecoder.start(file, format: format)
        var crc = crc32(0, nil, 0)
        var count = 0
        while let result = decoding.pipeline.next() {
            switch result {
            case .failure(let error):
                return (UInt32(crc), count, decoding.parallel, decoding.pipeline.peak, error.message)
            case .success(let chunk):
                crc = crc32(crc, chunk.base.assumingMemoryBound(to: Bytef.self), uInt(chunk.count))
                count += chunk.count
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            }
        }
        return (UInt32(crc), count, decoding.parallel, decoding.pipeline.peak, nil)
    }

    /// The CRC-32 and length of files one after another.
    static func expected(_ paths: [String]) -> (crc: UInt32, count: Int) {
        var crc = crc32(0, nil, 0)
        var count = 0
        for path in paths {
            let data = FileManager.default.contents(atPath: path) ?? Data()
            data.withUnsafeBytes { crc = crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
            count += data.count
        }
        return (UInt32(crc), count)
    }

    // MARK: xz

    static func xzBlockTests(_ fixture: Fixture, _ folder: String, _ c: Checks) {
        c.section("xz files from xz -T0, on every core: each block on its own")
        guard let xz = homebrew("xz") else {
            print("  (xz isn't installed; skipped)")
            return
        }
        let tar = fixture.base + "/out/Root.tar"
        let original = expected([tar])
        for check in ["crc64", "crc32", "sha256", "none"] {
            let made = folder + "/blocks-\(check).tar.xz"
            guard run("/bin/sh", ["-c", "\"$0\" -T0 --block-size=65536 --check=\(check) -c \"$1\" > \"$2\"", xz, tar, made]).status == 0 else {
                c.fail("xz couldn't make \(made)")
                continue
            }
            let decoded = decodeAll(made)
            c.expect(decoded.failure == nil && decoded.crc == original.crc && decoded.count == original.count,
                     "xz -T0 with the \(check) check: decompressed exactly (\(decoded.count) of \(original.count) bytes, \(decoded.failure ?? "no failure"))")
            c.expect(decoded.parallel, "xz -T0 with the \(check) check: on every core")
        }

        // Two files joined: two streams of blocks, and padding between them.
        let joined = folder + "/joined.tar.xz"
        _ = run("/bin/sh", ["-c", "\"$0\" -T0 --block-size=40000 -c \"$1\" > \"$2\" && dd if=/dev/zero bs=8 count=1 >> \"$2\" 2>/dev/null && \"$0\" -T0 --block-size=50000 -c \"$1\" >> \"$2\"",
                            xz, tar, joined])
        let twice = expected([tar, tar])
        let both = decodeAll(joined)
        c.expect(both.failure == nil && both.crc == twice.crc && both.count == twice.count && both.parallel,
                 "two xz files joined, with padding: decompressed exactly, on every core (\(both.failure ?? "no failure"))")

        // One block: nothing to do at once.
        let single = folder + "/single.tar.xz"
        _ = run("/bin/sh", ["-c", "\"$0\" -T1 -c \"$1\" > \"$2\"", xz, tar, single])
        let one = decodeAll(single)
        c.expect(one.failure == nil && one.crc == original.crc && !one.parallel, "a single block: decompressed in order, exactly")

        // Blocks held at once, on smaller Macs too: every core, as long as they fit in memory.
        func blocks(_ count: Int, holding: Int64, size: Int64) -> [ArchiveDecoder.XzBlock] {
            (0..<count).map { ArchiveDecoder.XzBlock(offset: Int64($0) * size, size: size, unpadded: size, holds: holding, stream: 0) }
        }
        let usual = blocks(40, holding: 24 << 20, size: 6 << 20), huge = blocks(8, holding: 192 << 20, size: 40 << 20)
        // (A Mac with room to spare may hold 4 GB, others 512 MB with 8 GB of memory.)
        let macs: [(String, Int, Int64, [ArchiveDecoder.XzBlock], Int)] = [
            ("16 cores, 128 GB, xz's usual 24 MB blocks", 16, 4 << 30, usual, 18),
            ("8 cores, 8 GB, 24 MB blocks", 8, 512 << 20, usual, 10),
            ("4 cores, 8 GB, 24 MB blocks", 4, 512 << 20, usual, 6),
            ("16 cores, 128 GB, xz -9's 192 MB blocks", 16, 4 << 30, huge, 13),
            ("8 cores, 8 GB, 192 MB blocks", 8, 512 << 20, huge, 2),
        ]
        for (label, cores, memory, list, expected) in macs {
            let slots = ArchiveDecoder.xzSlots(list, cores: cores, memory: memory)
            c.expect(slots == expected, "xz on \(label): \(slots) blocks at once (expected \(expected))")
        }

        c.section("Which Macs have room to spare (every core from the start, and more of them)")
        let gigabyte: Int64 = 1 << 30
        let roomy: [(String, Int, Int, Int64, Bool)] = [
            ("M4 Max, 12 + 4 cores, 128 GB", 12, 4, 128 * gigabyte, true),
            ("M1 Pro, 8 + 2 cores, 16 GB", 8, 2, 16 * gigabyte, true),
            ("M3 Pro, 6 + 6 cores, 18 GB", 6, 6, 18 * gigabyte, true),
            ("Intel, 8 cores, 16 GB", 8, 0, 16 * gigabyte, true),
            ("M4, 4 + 6 cores, 16 GB", 4, 6, 16 * gigabyte, false),
            ("M1, 4 + 4 cores, 8 GB", 4, 4, 8 * gigabyte, false),
            ("Intel, 4 cores, 32 GB", 4, 0, 32 * gigabyte, false),
            ("12 + 4 cores, but 8 GB", 12, 4, 8 * gigabyte, false),
        ]
        for (label, performance, efficiency, memory, expected) in roomy {
            let decided = ArchiveDecoder.isRoomy(performance: performance, efficiency: efficiency, memory: memory)
            c.expect(decided == expected, "\(label): \(decided ? "room to spare" : "careful")")
        }

        // A block changed: its CRC catches it.
        let damaged = folder + "/damaged.tar.xz"
        try? FileManager.default.copyItem(atPath: folder + "/blocks-crc64.tar.xz", toPath: damaged)
        flip(damaged, at: 0.5)
        c.expect(decodeAll(damaged).failure != nil, "a damaged block is caught")
    }

    /// Changes a byte of a file, `share` of the way in.
    static func flip(_ path: String, at share: Double) {
        guard var data = FileManager.default.contents(atPath: path), !data.isEmpty else { return }
        let index = Int(Double(data.count) * share)
        data[index] ^= 0x55
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: gzip

    static func gunzipTests(_ fixture: Fixture, _ folder: String, _ c: Checks) {
        c.section("gzip files from other tools, on every core: one stream cut into spans")
        let saved = (ParallelGzip.floor, ParallelGzip.span, ParallelGzip.limit, ParallelGzip.misplace, ParallelGzip.lookEvery,
                     ParallelGzip.eager)
        defer {
            (ParallelGzip.floor, ParallelGzip.span, ParallelGzip.limit, ParallelGzip.misplace, ParallelGzip.lookEvery,
             ParallelGzip.eager) = saved
        }
        // Small spans, to have many, a small limit, so spans reach it, and a look at who's waiting
        // after every stretch (these files decompress in milliseconds).
        ParallelGzip.floor = 0
        ParallelGzip.span = 64 << 10
        ParallelGzip.limit = 512 << 10
        ParallelGzip.lookEvery = 0
        // Every core from the start, as on a Mac with room to spare (the just-in-time way is below).
        ParallelGzip.eager = true

        // Kinds of data: text-like (copies near and far), a mix with random bytes and zeros (blocks
        // kept as they are, and long copies), random bytes alone, and zeros alone.
        let made = run("/usr/bin/python3", ["-I", "-c", """
            import os, random, sys, zlib, struct
            folder = sys.argv[1]
            rng = random.Random(7)
            words = [''.join(rng.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(rng.randint(2, 9))) for _ in range(3000)]
            def text(n):
                out = []
                size = 0
                while size < n:
                    line = ' '.join(rng.choice(words[:rng.choice((50, 300, 3000))]) for _ in range(rng.randint(3, 14)))
                    line += ' %d\\n' % rng.randint(0, 10**rng.randint(1, 9))
                    out.append(line)
                    size += len(line)
                return ''.join(out).encode()[:n]
            data = {
                'text': text(3_000_000),
                'mixed': b''.join(text(60_000) + rng.randbytes(30_000) + bytes(20_000) + text(5_000) * 3 for _ in range(30)),
                'random': rng.randbytes(1_500_000),
                'zeros': bytes(6_000_000),
            }
            data['long'] = data['text'] * 20
            for name, value in data.items():
                open(os.path.join(folder, name), 'wb').write(value)
            def gz(name, raw, header=b'\\x1f\\x8b\\x08\\x00\\x00\\x00\\x00\\x00\\x00\\x03'):
                crc = zlib.crc32(data[raw])
                open(os.path.join(folder, name), 'wb').write(header + compress(raw) + struct.pack('<II', crc, len(data[raw]) & 0xffffffff))
            def deflate(raw, **options):
                c = zlib.compressobj(wbits=-options.pop('window', 15), **options)
                return c.compress(data[raw]) + c.flush()
            options = {
                'filtered': dict(level=6, strategy=zlib.Z_FILTERED),
                'huffman': dict(level=6, strategy=zlib.Z_HUFFMAN_ONLY),
                'rle': dict(level=6, strategy=zlib.Z_RLE),
                'fixed': dict(level=6, strategy=zlib.Z_FIXED),
                'small-memory': dict(level=6, memLevel=1),
                'big-memory': dict(level=9, memLevel=9),
                'small-window': dict(level=6, window=9),
            }
            for label, option in options.items():
                for raw in ('text', 'mixed'):
                    compress = lambda raw, option=option: deflate(raw, **dict(option))
                    gz('%s-%s.gz' % (raw, label), raw)
            # Flushed every 100 KB: empty blocks and byte boundaries (sync), and fresh starts (full).
            for label, mode in (('sync', zlib.Z_SYNC_FLUSH), ('full', zlib.Z_FULL_FLUSH)):
                def compress(raw, mode=mode):
                    c = zlib.compressobj(6, zlib.DEFLATED, -15)
                    body = data[raw]
                    return b''.join(c.compress(body[i:i + 100_000]) + c.flush(mode) for i in range(0, len(body), 100_000)) + c.flush()
                gz('mixed-%s-flush.gz' % label, 'mixed')
            # Every header field: extra, name, comment, and the header's own CRC.
            head = b'\\x1f\\x8b\\x08\\x1e\\x00\\x00\\x00\\x00\\x00\\x03' + struct.pack('<H', 6) + b'AB\\x02\\x00hi' + b'name.tar\\x00' + b'a comment\\x00'
            head += struct.pack('<H', zlib.crc32(head) & 0xffff)
            compress = lambda raw: deflate(raw, level=6)
            gz('text-fields.gz', 'text', header=head)
            """, folder])
        guard made.status == 0 else {
            c.fail("Python couldn't make the test files: \(made.errors.prefix(400))")
            return
        }
        var files: [(label: String, file: String, parts: [String])] = []
        for name in ["text", "mixed", "random", "zeros", "long"] {
            for level in name == "text" || name == "mixed" ? [1, 6, 9] : [6] {
                let file = folder + "/\(name)-\(level).gz"
                if run("/bin/sh", ["-c", "/usr/bin/gzip -\(level) -c \"$0\" > \"$1\"", folder + "/" + name, file]).status == 0 {
                    files.append(("\(name), gzip -\(level)", file, [folder + "/" + name]))
                }
            }
        }
        for label in ["filtered", "huffman", "rle", "fixed", "small-memory", "big-memory", "small-window"] {
            for name in ["text", "mixed"] {
                files.append(("\(name), zlib \(label)", folder + "/\(name)-\(label).gz", [folder + "/" + name]))
            }
        }
        files.append(("mixed, flushed (sync)", folder + "/mixed-sync-flush.gz", [folder + "/mixed"]))
        files.append(("mixed, flushed (full)", folder + "/mixed-full-flush.gz", [folder + "/mixed"]))
        files.append(("text, every header field", folder + "/text-fields.gz", [folder + "/text"]))
        // Two gzip files joined, both decompressed on every core.
        let joined = folder + "/joined.gz"
        _ = run("/bin/sh", ["-c", "cat \"$0\" \"$1\" > \"$2\"", folder + "/text-6.gz", folder + "/mixed-6.gz", joined])
        files.append(("two gzip files joined", joined, [folder + "/text", folder + "/mixed"]))

        var lined = 0
        for (label, file, parts) in files {
            ParallelGzip.stats.withLock { $0 = ParallelGzip.Stats() }
            let decoded = decodeAll(file)
            let original = expected(parts)
            c.expect(decoded.failure == nil && decoded.crc == original.crc && decoded.count == original.count,
                     "\(label): decompressed exactly (\(decoded.count) of \(original.count) bytes\(decoded.failure.map { ", " + $0 } ?? ""))")
            lined += ParallelGzip.stats.withLock { $0.lined }
        }
        c.expect(lined > 100, "spans decompressed on their own lined up: \(lined)")

        // On a smaller Mac, spans only when unpacking is waiting: none when it's slow, or with few
        // full-speed cores. (A longer file, 60 MB, so there's time to look: every 10 ms.)
        let long = expected([folder + "/long"])
        ParallelGzip.eager = true
        let eagerly = decodeAll(folder + "/long-6.gz", pause: 0.002)
        let eagerStats = ParallelGzip.stats.withLock { $0 }
        c.expect(eagerly.failure == nil && eagerly.crc == long.crc && eagerStats.spans > 0,
                 "with room to spare: spans on other cores from the start, even unpacking slowly (\(eagerStats.spans))")
        ParallelGzip.eager = false
        ParallelGzip.lookEvery = 0.01
        let slowly = decodeAll(folder + "/long-6.gz", pause: 0.002)
        let slowStats = ParallelGzip.stats.withLock { $0 }
        c.expect(slowly.failure == nil && slowly.crc == long.crc && slowly.count == long.count && slowStats.spans == 0,
                 "unpacking slowly: decompressed in order, exactly (\(slowStats.spans) spans on other cores, \(slowStats.inOrder) stretches in order)")
        let quickly = decodeAll(folder + "/long-6.gz")
        let quickStats = ParallelGzip.stats.withLock { $0 }
        c.expect(quickly.failure == nil && quickly.crc == long.crc && quickStats.spans > 0 && quickStats.lined > 0,
                 "unpacking quickly: spans on other cores (\(quickStats.spans) started, \(quickStats.lined) lined up)")
        ParallelGzip.lookEvery = 0
        ParallelGzip.eager = true
        let text = expected([folder + "/text"])
        let savedCores = ParallelGzip.fullSpeedCores
        ParallelGzip.fullSpeedCores = 2
        ParallelGzip.stats.withLock { $0 = ParallelGzip.Stats() }
        let twoCores = decodeAll(folder + "/text-6.gz")
        let twoStats = ParallelGzip.stats.withLock { $0 }
        ParallelGzip.fullSpeedCores = savedCores
        c.expect(twoCores.failure == nil && twoCores.crc == text.crc && twoStats.spans == 0,
                 "a Mac with 2 full-speed cores: in order, exactly (\(twoStats.spans) spans)")

        // Spans that can't line up (each other one starts a bit off) are decompressed again in order.
        ParallelGzip.misplace = true
        ParallelGzip.stats.withLock { $0 = ParallelGzip.Stats() }
        let off = decodeAll(folder + "/text-6.gz")
        let stats = ParallelGzip.stats.withLock { $0 }
        c.expect(off.failure == nil && off.crc == text.crc && off.count == text.count,
                 "spans that start in the wrong place: still exactly right (\(off.failure ?? "no failure"))")
        c.expect(stats.redone > 0, "  and they were decompressed again in order: \(stats.redone) of \(stats.spans)")
        ParallelGzip.misplace = false

        // Damage: a changed byte, a CRC that doesn't match, a file cut short.
        let damaged = folder + "/damaged.gz"
        try? FileManager.default.copyItem(atPath: folder + "/text-6.gz", toPath: damaged)
        flip(damaged, at: 0.5)
        c.expect(decodeAll(damaged).failure != nil, "a changed byte is caught")
        let wrongCRC = folder + "/wrong-crc.gz"
        try? FileManager.default.copyItem(atPath: folder + "/mixed-6.gz", toPath: wrongCRC)
        if let size = FileManager.default.contents(atPath: wrongCRC)?.count { flip(wrongCRC, at: Double(size - 6) / Double(size)) }
        let crcCaught = decodeAll(wrongCRC)
        c.expect(crcCaught.failure?.contains("damaged") == true, "a CRC that doesn't match is caught: \(crcCaught.failure ?? "not caught")")
        let cut = folder + "/cut.gz"
        if let data = FileManager.default.contents(atPath: folder + "/text-6.gz") {
            try? data.prefix(data.count * 3 / 5).write(to: URL(fileURLWithPath: cut))
        }
        let cutCaught = decodeAll(cut)
        c.expect(cutCaught.failure != nil, "a file cut short is caught: \(cutCaught.failure ?? "not caught")")

        // A whole tar.gz from macOS's gzip, unpacked on every core, matches the folder exactly.
        let tarball = folder + "/Root.tar.gz"
        _ = run("/bin/sh", ["-c", "/usr/bin/gzip -6 -c \"$0\" > \"$1\"", fixture.base + "/out/Root.tar", tarball])
        ParallelGzip.span = 8 << 10
        let reference = folder + "/reference", unpacked = folder + "/unpacked"
        for place in [reference, unpacked] { try? FileManager.default.createDirectory(atPath: place, withIntermediateDirectories: true) }
        if case .finished = unpack(fixture.base + "/out/Root.tar", into: reference, c),
           case .finished(let summary) = unpack(tarball, into: unpacked, c) {
            c.expect(summary.parallel, "a tar.gz from gzip unpacks on every core")
            compareExactly(reference + "/" + Fixture.rootName, unpacked + "/" + Fixture.rootName, "tar.gz on every core", c)
        }
        fixture.cleanUp(reference)
        fixture.cleanUp(unpacked)
    }

    /// `bash test.sh --decode FILE`: decompresses an archive (without unpacking it), timed, with the
    /// CRC-32 of what came out (quick enough not to slow it down), and for a gzip file what its
    /// spans came to.
    static func decodeBenchmark(_ path: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        ParallelGzip.stats.withLock { $0 = ParallelGzip.Stats() }
        let start = Date()
        let decoded = decodeAll(path, pause: environment["ONEFILE_PAUSE"].flatMap(Double.init) ?? 0)
        let seconds = Date().timeIntervalSince(start)
        if let failure = decoded.failure {
            print("Failed: \(failure)")
            return false
        }
        print(String(format: "%@ in %.3f s (%.0f MB/s)%@", Format.bytes(Int64(decoded.count)), seconds,
                     Double(decoded.count) / seconds / 1e6, decoded.parallel ? " on every core" : ""))
        print(String(format: "CRC-32 %08x, at most %d chunks held at once", decoded.crc, decoded.peak))
        let stats = ParallelGzip.stats.withLock { $0 }
        if stats.spans > 0 {
            print("Spans on other cores: \(stats.spans), lined up \(stats.lined); stretches in order \(stats.inOrder), "
                  + "again in order \(stats.redone); bytes copied from before their span \(Format.bytes(Int64(stats.marked)))")
        }
        return true
    }
}
