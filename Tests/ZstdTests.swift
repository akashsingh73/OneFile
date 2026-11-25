import Foundation

/// zstd on its own: how OneFile lays out its frames, what other tools make of them, and an index
/// big enough for millions of files.
extension OneFileTests {

    static func zstdTests(_ fixture: Fixture, _ c: Checks) {
        c.section("zstd: frames laid out as pzstd writes them")
        // 3 MB that compress: a pattern with some variety.
        let bytes = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: ($0 / 7) ^ ($0 >> 12)) }
        guard let block = bytes.withUnsafeBufferPointer({ Zstd.block($0.baseAddress!, $0.count) }) else {
            c.fail("zstd couldn't compress a block")
            return
        }
        let head = [UInt8](block.prefix(Zstd.peekSize))
        func word(_ at: Int) -> Int { Int(head[at]) | Int(head[at + 1]) << 8 | Int(head[at + 2]) << 16 | Int(head[at + 3]) << 24 }
        c.expect(Array(head[0..<8]) == [0x50, 0x2A, 0x4D, 0x18, 4, 0, 0, 0], "a skippable frame first, 12 bytes, as pzstd's")
        c.expect(word(8) == block.count - 12, "saying how long the frame after it is: \(word(8))")
        c.expect(Array(head[12..<16]) == [0x28, 0xB5, 0x2F, 0xFD], "then a zstd frame")
        c.expect(head[16] & 0x04 != 0, "with a checksum")
        c.expect(block.count < bytes.count / 4, "compressed: \(block.count) bytes for \(bytes.count)")
        let header = Zstd.header(head)
        c.expect(header?.size == block.count && header?.holds == bytes.count, "the headers give its length and what it holds: \(String(describing: header))")
        c.expect(Zstd.header(head, limit: 1 << 20) == nil, "more than the limit isn't taken")
        let back = block.withUnsafeBytes { Zstd.decompress($0, holds: bytes.count) }
        c.expect(back.map { Array(UnsafeRawBufferPointer(start: $0.base, count: $0.count)) == bytes } == true, "it decompresses to what went in")
        c.expect(block.withUnsafeBytes { Zstd.decompress($0, holds: bytes.count - 1) } == nil, "not if it holds more than it's said to")
        var changed = block
        changed[block.count - 2] ^= 0x01
        c.expect(changed.withUnsafeBytes { Zstd.decompress($0, holds: bytes.count) } == nil, "a changed checksum is caught")
        let empty = [UInt8]().withUnsafeBufferPointer { Zstd.block($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, 0) }
        c.expect(empty.flatMap { Zstd.header($0) }?.holds == 0
                 && empty?.withUnsafeBytes({ Zstd.decompress($0, holds: 0) })?.count == 0, "nothing compresses and comes back too")

        c.section("zstd: other tools read OneFile's .tar.zst")
        let archive = fixture.base + "/out/Root.tar.zst"
        guard FileManager.default.fileExists(atPath: archive) else {
            c.fail("no \(archive) (packing failed earlier)")
            return
        }
        if let file = InputFile(path: archive), case .success(let format) = ArchiveFormat.detect(file, name: "Root.tar.zst"),
           let index = ArchiveIndex.read(file, format: format) {
            if let zstd = homebrew("zstd") {
                let listed = run(zstd, ["-lv", archive])
                func count(_ label: String) -> Int? {
                    listed.output.split(separator: "\n").first { $0.hasPrefix("# \(label): ") }.flatMap { Int($0.split(separator: " ").last ?? "") }
                }
                // A frame for every block of the tar stream, with a skippable frame before each, and
                // the index and its locator in skippable frames of their own.
                let frames = index.blocks.count
                c.expect(count("Zstandard Frames") == frames && count("Skippable Frames") == frames + 2,
                         "zstd -l sees \(count("Zstandard Frames") ?? -1) frames and \(count("Skippable Frames") ?? -1) skippable ones, for \(frames) blocks")
                // What it decompresses ends where the tar does, so a reader that stops there (macOS's
                // tar running zstd) never leaves zstd with more to write.
                let decompressed = run("/bin/sh", ["-c", "\"$1\" -dc \"$0\" | wc -c", archive, zstd])
                c.expect(Int64(decompressed.output.trimmingCharacters(in: .whitespacesAndNewlines)) == index.tarSize,
                         "zstd -d gives the tar alone: \(decompressed.output.trimmingCharacters(in: .whitespacesAndNewlines)) bytes, for \(index.tarSize)")
                c.expect(listed.output.contains("Check: XXH64"), "each with its checksum")
            } else {
                print("  (zstd isn't installed: skipped zstd -l)")
            }
            if let pzstd = homebrew("pzstd") {
                let tested = run(pzstd, ["-t", "-p", "4", archive])
                c.expect(tested.status == 0, "pzstd -t reads it, its frames in parallel: \(tested.errors.prefix(200))")
            }
        } else {
            c.fail("no index in \(archive)")
        }

        c.section("An index of over a million files (.tar.gz and .tar.zst)")
        // Bigger than a block of the tar stream may be (64 MB): it's read all the same.
        var index = ArchiveIndex()
        var generator = SystemRandomNumberGenerator()
        let count = 1_500_000
        index.entries.reserveCapacity(count)
        for number in 0..<count {
            let digest = (0..<4).flatMap { _ in withUnsafeBytes(of: generator.next() as UInt64) { Array($0) } }
            index.entries.append(ArchiveIndex.Entry(
                id: number, path: "Root/folder-\(number / 1_000)/file-\(String(generator.next() as UInt64, radix: 36)).txt",
                kind: .file, header: Int64(number) * 1_024, data: Int64(number) * 1_024 + 512, size: 100,
                modified: 1_700_000_000, mode: 0o644, link: "", digest: digest))
        }
        index.tarSize = Int64(count) * 1_024
        guard let container = index.container() else {
            c.fail("the big index couldn't be made")
            return
        }
        c.expect(container.count > ArchiveDecoder.largestPiece, "its container is \(Format.bytes(Int64(container.count)))")
        let folder = fixture.base + "/big-index"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for method in [PackMethod.gzip, .zstd] {
            // An archive of the index and its locator alone, wrapped as packing wraps them.
            guard let stored = ArchiveIndex.wrap(container, method: method),
                  let locator = ArchiveIndex.wrap(ArchiveIndex.locator(offset: 0, length: Int64(stored.count),
                                                                       crc: stored.withUnsafeBytes { ArchiveIndex.crc($0) }),
                                                  method: method) else {
                c.fail("couldn't wrap the big index")
                continue
            }
            let path = folder + "/Big." + method.fileExtension
            FileManager.default.createFile(atPath: path, contents: stored + locator)
            if let file = InputFile(path: path), let read = ArchiveIndex.read(file, format: format(of: method)) {
                c.expect(read.entries.count == count && read.entries.last?.path == index.entries.last?.path,
                         "a .\(method.fileExtension)'s reads back: \(read.entries.count) entries")
            } else {
                c.fail("a .\(method.fileExtension)'s big index can't be read")
            }
        }
        fixture.cleanUp(folder)
    }
}
