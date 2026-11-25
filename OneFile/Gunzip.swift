import Foundation
import zlib

/// Decompresses a gzip file made by another tool (`tar -czf`, `gzip`, Python) on every core.
///
/// Such a file is one long deflate stream: a run of blocks, each of which can copy from the 32 KB
/// decompressed before it, and nothing says where a block starts. So the file is cut into spans,
/// and each span is decompressed on a core of its own, from the first place in it where a block
/// could start (its header holds together, by zlib's own checks), without the 32 KB before it.
/// In their place go made-up bytes, and the span is decompressed twice at once, with two different
/// made-up 32 KB: a byte that comes out the same both times is the span's own, and one that differs
/// was copied from before the span, and the two values say from where. Once the last 32 KB
/// decompressed are all the span's own, nothing after can reach back before it, and the first
/// decompression carries on alone, at zlib's full speed.
///
/// The spans are then taken in order. Each stops at the first place past the end of its span
/// where a block starts and the next span could have started, so the next span is used only if it
/// starts exactly there: then it began at a real block, and the bytes it copied from before it are
/// filled in from the span before. A place that only looked like a block start never lines up,
/// and that stretch is decompressed again, in order. The gzip CRC and length are checked at the
/// end, as always.
///
/// rapidgzip and pugz work this way; here zlib, which decompresses 1.2 to 2.6 GB/s on one core of
/// an M4, does all the decompressing.
///
/// How far it goes depends on the Mac. One with room to spare (`ArchiveDecoder.roomy`: an M4 Max,
/// say) decompresses spans on every core from the start, the quickest way. On a smaller one,
/// decompressing twice (2 to 3 times the work) would take cores the writing needs, so it starts in
/// order, on one core, and spans go to other cores only while unpacking is waiting for what's
/// decompressed (see `decompressMember`); with fewer than 4 cores at full speed, never. On an M4
/// Max, that way, unpacking 41,704 small files took the same time with 11% less CPU and 150 MB less
/// memory, but 1.5 GB of big files took 0.33 s instead of 0.29 s.
enum ParallelGzip {
    /// Files smaller than this decompress in order: on one core that takes a fraction of a second.
    nonisolated(unsafe) static var floor: Int64 = 16 << 20
    /// The compressed bytes in each span. (The tests make it small, to have many.) On an M4 Max,
    /// spans of 1 MB, ten at a time, decompressed a 1.5 GB tar.gz at 5 GB/s holding about 300 MB;
    /// spans of 2 MB went at 6 GB/s, holding 450 MB. Unpacking writes slower than either.
    nonisolated(unsafe) static var span = 1 << 20
    /// The most a span decompresses: past it, it stops at the next block, and the rest of the span
    /// is decompressed in order. (A file of zeros shrinks a thousand times, and would fill memory.)
    nonisolated(unsafe) static var limit = 32 << 20
    /// The most spans decompressing at once (or done, waiting their turn), past the one being
    /// handed on: on a Mac with room to spare, its cores and 2 more (16 on an M4 Max, where 17
    /// unpacked 1.5 GB of big files in 0.23 s, 9 in 0.29 s, and plain tar takes 0.21 s); otherwise 9
    /// at most, which hold less.
    nonisolated(unsafe) static var ahead = ArchiveDecoder.roomy
        ? max(ArchiveDecoder.decoders + 1, ArchiveDecoder.performanceCores + ArchiveDecoder.efficiencyCores / 2 + 2)
        : ArchiveDecoder.decoders + 1
    /// Cores at full speed (the tests make it fewer): spans are decompressed only with 4 or more.
    nonisolated(unsafe) static var fullSpeedCores = ArchiveDecoder.performanceCores
    /// Spans on every core from the start (true), or only as unpacking needs (false); nil, by what
    /// the Mac has (`ArchiveDecoder.roomy`). The tests choose.
    nonisolated(unsafe) static var eager: Bool?
    /// How often (seconds) it looks again at whether unpacking needs more. (The tests look after
    /// every stretch.)
    nonisolated(unsafe) static var lookEvery = 0.05
    /// For the tests: every other span starts a bit after the block it found, so it can't line up
    /// and has to be decompressed again in order.
    nonisolated(unsafe) static var misplace = false

    /// How far back deflate copies from.
    static let window = 32_768
    /// Spans are handed on in pieces this big.
    static let pieceSize = 4 << 20

    /// What the last file's spans came to, for the tests.
    struct Stats: Sendable {
        /// Spans started on other cores.
        var spans = 0
        /// Spans used as decompressed on their own.
        var lined = 0
        /// Stretches decompressed in order because unpacking didn't need more.
        var inOrder = 0
        /// Stretches decompressed again in order: spans that didn't line up, or stopped at `limit`.
        var redone = 0
        /// Bytes copied from before their span, filled in afterwards.
        var marked = 0
    }
    static let stats = Locked(Stats())

    // MARK: The gzip header

    /// Where the compressed data starts, after the gzip header at `offset` (and its name, comment
    /// and extra field). Nil if it isn't a header zlib reads.
    static func dataStart(_ file: InputFile, at offset: Int64) -> Int64? {
        guard let head = file.bytes(Int(min(file.size - offset, 64 << 10)), at: offset), head.count >= 18,
              head[0] == 0x1F, head[1] == 0x8B, head[2] == 8, head[3] & 0xE0 == 0 else { return nil }
        let flags = head[3]
        var at = 10
        if flags & 4 != 0 {
            at += 2 + (Int(head[10]) | Int(head[11]) << 8)
        }
        for flag in [UInt8(8), 16] where flags & flag != 0 {
            guard at < head.count, let zero = head[at...].firstIndex(of: 0) else { return nil }
            at = zero + 1
        }
        if flags & 2 != 0 {
            // The header's own CRC, which zlib checks too.
            guard at + 2 <= head.count,
                  UInt16(head[at]) | UInt16(head[at + 1]) << 8 == UInt16(truncatingIfNeeded: crc32(0, head, uInt(at))) else { return nil }
            at += 2
        }
        return at < head.count ? offset + Int64(at) : nil
    }

    // MARK: Where a block can start

    /// Bits read as deflate stores them: from the low bit of each byte up.
    private struct Bits {
        let base: UnsafePointer<UInt8>
        let count: Int
        var at: Int

        /// The next `n` bits (at most 57), or nil past the end.
        @inline(__always) func peek(_ n: Int) -> UInt64? {
            let byte = at >> 3
            let mask: UInt64 = (1 << UInt64(n)) - 1
            if byte + 8 <= count {
                return (UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self) >> UInt64(at & 7)) & mask
            }
            guard at + n <= count * 8 else { return nil }
            var word: UInt64 = 0
            for index in 0..<(count - byte) { word |= UInt64(base[byte + index]) << UInt64(8 * index) }
            return (word >> UInt64(at & 7)) & mask
        }

        @inline(__always) mutating func take(_ n: Int) -> UInt64? {
            guard let value = peek(n) else { return nil }
            at += n
            return value
        }
    }

    /// The order the code-length codes' lengths come in.
    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Whether a block that isn't the last, with codes of its own (the kind zlib writes for all but
    /// tiny or incompressible stretches), starts at bit `bit` of `base`: whether zlib would accept
    /// its header, checked the way zlib checks it. Nil if `count` bytes aren't enough to tell.
    static func blockStarts(_ base: UnsafePointer<UInt8>, count: Int, at bit: Int) -> Bool? {
        var bits = Bits(base: base, count: count, at: bit)
        guard let head = bits.take(17) else { return nil }
        // Not the last block (0), with codes of its own (10).
        guard head & 7 == 4 else { return false }
        let lengths = Int((head >> 3) & 31) + 257, distances = Int((head >> 8) & 31) + 1, codes = Int(head >> 13) + 4
        guard lengths <= 286, distances <= 30 else { return false }
        // The code-length code: complete, its lengths' 2^-length adding up to exactly 1.
        guard let packed = bits.take(3 * codes) else { return nil }
        var kraft = 0
        for index in 0..<codes {
            let length = Int((packed >> UInt64(3 * index)) & 7)
            if length > 0 { kraft += 128 >> length }
        }
        guard kraft == 128 else { return false }

        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 128 + 19 + 316 + 8) { buffer -> Bool? in
            let table = buffer.baseAddress!, lens = table + 128, symbols = lens + 19, next = symbols + 316
            lens.initialize(repeating: 0, count: 19)
            for index in 0..<codes { lens[order[index]] = UInt16((packed >> UInt64(3 * index)) & 7) }
            // Its table, seven bits in, a symbol and its length out; codes are given in order of
            // length, then symbol, and stored first bit first.
            var code = 0
            next[0] = 0
            for length in 1...7 {
                var shorter = 0
                for symbol in 0..<19 where Int(lens[symbol]) == length - 1 && length > 1 { shorter += 1 }
                code = (code + shorter) << 1
                next[length] = UInt16(code)
            }
            for symbol in 0..<19 {
                let length = Int(lens[symbol])
                guard length > 0 else { continue }
                let assigned = Int(next[length])
                next[length] += 1
                var reversed = 0
                for index in 0..<length where assigned & (1 << (length - 1 - index)) != 0 { reversed |= 1 << index }
                for fill in stride(from: reversed, to: 128, by: 1 << length) {
                    table[fill] = UInt16(symbol << 4 | length)
                }
            }
            // The lengths of the literal/length and distance codes.
            let total = lengths + distances
            var have = 0
            while have < total {
                guard let peeked = bits.peek(min(7, bits.count * 8 - bits.at)) else { return nil }
                let entry = table[Int(peeked)]
                let length = Int(entry & 15), symbol = Int(entry >> 4)
                guard bits.at + length <= bits.count * 8 else { return nil }
                bits.at += length
                if symbol < 16 {
                    symbols[have] = UInt16(symbol)
                    have += 1
                    continue
                }
                var value: UInt16 = 0
                let repeats: Int
                if symbol == 16 {
                    guard have > 0 else { return false }
                    value = symbols[have - 1]
                    guard let extra = bits.take(2) else { return nil }
                    repeats = 3 + Int(extra)
                } else if symbol == 17 {
                    guard let extra = bits.take(3) else { return nil }
                    repeats = 3 + Int(extra)
                } else {
                    guard let extra = bits.take(7) else { return nil }
                    repeats = 11 + Int(extra)
                }
                guard have + repeats <= total else { return false }
                (symbols + have).update(repeating: value, count: repeats)
                have += repeats
            }
            // An end-of-block code, and codes zlib builds tables for.
            guard symbols[256] != 0 else { return false }
            return isUsable(symbols, lengths) && isUsable(symbols + lengths, distances)
        }
    }

    /// Whether zlib builds a table for these code lengths: not over-subscribed (2^-length adding up
    /// to more than 1), and complete unless it's a single code one bit long, or none at all.
    private static func isUsable(_ lengths: UnsafePointer<UInt16>, _ count: Int) -> Bool {
        var kraft = 0, used = 0, longest = 0
        for index in 0..<count {
            let length = Int(lengths[index])
            guard length > 0 else { continue }
            kraft += 32_768 >> length
            used += 1
            longest = max(longest, length)
        }
        return used == 0 || kraft == 32_768 || (used == 1 && longest == 1)
    }

    /// The first bit in [`from`, `to`) of `base` where a block can start.
    static func findBlock(_ base: UnsafePointer<UInt8>, count: Int, from: Int, to: Int) -> Int? {
        var bit = from
        let end = min(to, count * 8)
        while bit < end {
            let byte = bit >> 3
            if byte + 8 <= count {
                // The quick test first: not last, codes of its own, at most 286 and 30 codes.
                let word = UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self) >> UInt64(bit & 7)
                if word & 7 == 4 && (word >> 3) & 31 <= 29 && (word >> 8) & 31 <= 29,
                   blockStarts(base, count: count, at: bit) == true {
                    return bit
                }
            } else if blockStarts(base, count: count, at: bit) == true {
                return bit
            }
            bit += 1
        }
        return nil
    }

    /// Whether a block can start at bit `bit` of the file.
    static func blockStarts(_ file: InputFile, at bit: Int64) -> Bool {
        let byte = bit >> 3
        let count = Int(min(1_024, file.size - byte))
        guard count > 0, let bytes = file.bytes(count, at: byte) else { return false }
        return bytes.withUnsafeBufferPointer { blockStarts($0.baseAddress!, count: count, at: Int(bit & 7)) } == true
    }

    // MARK: Decompressing a span

    /// The compressed file, read a piece at a time as zlib uses it.
    private final class Input {
        let file: InputFile
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int
        /// Where in the file `buffer` starts, and how much of it is read.
        var base: Int64
        var count = 0

        private init(_ file: InputFile, at offset: Int64, capacity: Int) {
            self.file = file
            self.capacity = capacity
            buffer = .allocate(capacity: capacity)
            base = offset
        }

        deinit { buffer.deallocate() }

        /// The file from `offset`, `count` bytes of it read to begin with.
        static func open(_ file: InputFile, at offset: Int64, count: Int) -> Input? {
            let input = Input(file, at: offset, capacity: max(count, 1 << 20))
            return input.read(count) ? input : nil
        }

        private func read(_ want: Int) -> Bool {
            let length = Int(min(Int64(min(want, capacity)), file.size - base))
            guard length > 0, file.read(length, at: base, into: buffer) else { return false }
            count = length
            return true
        }

        /// The next piece of the file, once all of this one is used.
        func advance() -> Bool {
            base += Int64(count)
            count = 0
            return read(1 << 20)
        }

        var atEnd: Bool { base + Int64(count) >= file.size }
    }

    /// A z_stream at an address that doesn't move (zlib checks that it doesn't).
    private final class Inflater {
        let stream: UnsafeMutablePointer<z_stream>

        private init(_ stream: UnsafeMutablePointer<z_stream>) { self.stream = stream }

        /// A raw deflate decompressor, with `dictionary` as the 32 KB before.
        static func make(dictionary: [UInt8]) -> Inflater? {
            let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            stream.initialize(to: z_stream())
            guard inflateInit2_(stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                stream.deallocate()
                return nil
            }
            let inflater = Inflater(stream)
            if !dictionary.isEmpty {
                guard dictionary.withUnsafeBufferPointer({ inflateSetDictionary(stream, $0.baseAddress, uInt($0.count)) }) == Z_OK else {
                    return nil
                }
            }
            return inflater
        }

        deinit {
            inflateEnd(stream)
            stream.deallocate()
        }
    }

    /// Two made-up 32 KB: at each place k, bytes that differ (a and b), and from which k can be
    /// told again: k = a + 256 × ((b − a − 1) mod 256).
    private static let madeUp: (first: [UInt8], second: [UInt8]) = {
        let first = (0..<window).map { UInt8($0 & 0xFF) }
        let second = (0..<window).map { UInt8(truncatingIfNeeded: ($0 & 0xFF) + 1 + ($0 >> 8)) }
        return (first, second)
    }()

    /// Which bytes of a piece were copied from before its stretch: a bit for each byte, and for
    /// each one copied, in turn, the high bits of where from (the low bits are the byte itself).
    final class Marks: @unchecked Sendable {
        let words: UnsafeMutablePointer<UInt64>
        let wordCount: Int
        /// Room for a byte for each byte of the piece; only the pages used take memory.
        let highs: UnsafeMutablePointer<UInt8>

        init(bytes: Int) {
            wordCount = (bytes + 63) / 64
            words = .allocate(capacity: wordCount)
            words.initialize(repeating: 0, count: wordCount)
            highs = .allocate(capacity: bytes)
        }

        deinit {
            words.deallocate()
            highs.deallocate()
        }

        /// How many of the bytes before `offset` were copied.
        func copies(before offset: Int) -> Int {
            var total = 0
            for word in 0..<(offset >> 6) { total += words[word].nonzeroBitCount }
            if offset & 63 != 0 { total += (words[offset >> 6] & ((1 << UInt64(offset & 63)) - 1)).nonzeroBitCount }
            return total
        }
    }

    /// A stretch of the stream, decompressed from a block start.
    final class Stretch: @unchecked Sendable {
        /// The bit it starts at, and the one it stopped at (a block start, or the end of the data).
        let start: Int64
        var end: Int64 = 0
        var pieces: [Chunk] = []
        var count = 0
        /// Decompressed without the 32 KB before it: what its pieces copied from before it (as far
        /// as the second decompression went), and how many bytes that is.
        var marks: [Marks] = []
        var copies = 0
        /// It reached the end of the compressed data; the gzip trailer starts at this byte.
        var trailer: Int64?
        /// Why it stopped short, if it did.
        var failure: String?
        /// How long it took (a span: finding its start, and decompressing).
        var seconds = 0.0

        init(start: Int64) { self.start = start }
    }

    /// Decompresses from the block at bit `start` to the first block start at or after bit `until`
    /// (or to the end of the data, or `limit`): with the 32 KB before it, `window`, or if that isn't
    /// known (nil), twice at once, with the made-up ones.
    private static func decompress(_ input: Input, from start: Int64, until: Int64, window: [UInt8]?,
                                   stopped: () -> Bool) -> Stretch {
        let stretch = Stretch(start: start)
        func fail(_ message: String) -> Stretch {
            stretch.failure = message
            return stretch
        }
        guard let first = Inflater.make(dictionary: window ?? madeUp.first) else { return fail("Couldn't start decompressing.") }
        var second = window == nil ? Inflater.make(dictionary: madeUp.second) : nil
        if window == nil && second == nil { return fail("Couldn't start decompressing.") }
        // Where the second decompression's bytes go, to be compared and dropped.
        let scratch = second == nil ? nil : UnsafeMutablePointer<UInt8>.allocate(capacity: pieceSize)
        defer { scratch?.deallocate() }

        // Start at the bit: the rest of its byte goes in first.
        let byte = Int(start >> 3 - input.base), shift = Int(start & 7)
        guard byte >= 0, byte < input.count else { return fail(ArchiveDecoder.endsEarly) }
        for inflater in [first, second].compactMap({ $0 }) {
            if shift > 0 { inflatePrime(inflater.stream, Int32(8 - shift), Int32(input.buffer[byte] >> shift)) }
            let skip = byte + (shift > 0 ? 1 : 0)
            inflater.stream.pointee.next_in = input.buffer + skip
            inflater.stream.pointee.avail_in = uInt(input.count - skip)
        }
        func position() -> Int64 {
            input.base + Int64(UnsafeMutablePointer(first.stream.pointee.next_in) - input.buffer)
        }

        var piece = Chunk(capacity: pieceSize)
        var marks: Marks? = second == nil ? nil : Marks(bytes: pieceSize)
        // Copies in the stretch's earlier pieces.
        var copiesBefore = 0
        stretch.pieces.append(piece)
        if let marks { stretch.marks.append(marks) }
        // The last byte copied from before the start, counted from the start.
        var lastCopied = -1

        func finish(at bit: Int64) -> Stretch {
            stretch.end = bit
            piece.inputEnd = position()
            return stretch
        }

        while true {
            if stopped() { return fail("Stopped.") }
            if piece.count == piece.capacity {
                piece.inputEnd = position()
                piece = Chunk(capacity: pieceSize)
                stretch.pieces.append(piece)
                if second != nil {
                    marks = Marks(bytes: pieceSize)
                    stretch.marks.append(marks!)
                    copiesBefore = stretch.copies
                }
            }
            if first.stream.pointee.avail_in == 0 {
                if input.atEnd { return fail(ArchiveDecoder.endsEarly) }
                guard input.advance() else { return fail(ArchiveDecoder.unreadable) }
                for inflater in [first, second].compactMap({ $0 }) {
                    inflater.stream.pointee.next_in = input.buffer
                    inflater.stream.pointee.avail_in = uInt(input.count)
                }
            }
            let room = piece.capacity - piece.count
            let stream = first.stream
            let out = piece.base.assumingMemoryBound(to: UInt8.self) + piece.count
            stream.pointee.next_out = out
            stream.pointee.avail_out = uInt(room)
            let result = inflate(stream, Z_BLOCK)
            let made = room - Int(stream.pointee.avail_out)
            if let other = second, let scratch, let marks = marks {
                // The same again, with the other made-up 32 KB: it goes exactly the same way.
                other.stream.pointee.next_out = scratch
                other.stream.pointee.avail_out = uInt(room)
                let again = inflate(other.stream, Z_BLOCK)
                guard again == result, other.stream.pointee.avail_in == stream.pointee.avail_in,
                      other.stream.pointee.avail_out == stream.pointee.avail_out,
                      other.stream.pointee.data_type == stream.pointee.data_type else {
                    return fail("The two decompressions went different ways.")
                }
                // Where they differ, the byte was copied from before the start.
                let words = marks.words, highs = marks.highs
                var copies = stretch.copies - copiesBefore
                var last = -1
                var at = 0
                while at < made {
                    if at + 8 <= made && UnsafeRawPointer(out + at).loadUnaligned(as: UInt64.self)
                        == UnsafeRawPointer(scratch + at).loadUnaligned(as: UInt64.self) {
                        at += 8
                        continue
                    }
                    for index in at..<min(at + 8, made) where out[index] != scratch[index] {
                        let high = scratch[index] &- out[index] &- 1
                        guard high < 128 else { return fail("The two decompressions went different ways.") }
                        let place = piece.count + index
                        words[place >> 6] |= 1 << UInt64(place & 63)
                        highs[copies] = high
                        copies += 1
                        last = index
                    }
                    at += 8
                }
                stretch.copies = copiesBefore + copies
                if last >= 0 { lastCopied = stretch.count + last }
            }
            piece.count += made
            stretch.count += made
            if second != nil && stretch.count - (lastCopied + 1) >= Self.window {
                // The last 32 KB are all its own: nothing after them can reach back before it.
                second = nil
            }
            switch result {
            case Z_STREAM_END:
                stretch.trailer = position()
                return finish(at: position() * 8)
            case Z_OK:
                break
            case Z_BUF_ERROR:
                // No room or nothing left to read: both are seen to above, so it's stuck.
                if stream.pointee.avail_in > 0 && stream.pointee.avail_out > 0 { return fail(ArchiveDecoder.damaged(position())) }
            default:
                return fail(ArchiveDecoder.damaged(position()))
            }
            // At the end of a block (not the last): stop if it's far enough, or enough is decompressed.
            if stream.pointee.data_type & 128 != 0 && stream.pointee.data_type & 64 == 0 {
                let bit = position() * 8 - Int64(stream.pointee.data_type & 7)
                if (bit >= until && blockStarts(input.file, at: bit)) || stretch.count >= limit {
                    return finish(at: bit)
                }
            }
        }
    }

    /// Fills in the bytes of `piece` that were copied from the 32 KB before its stretch, now that
    /// they're known (`before`, all 32 KB of them).
    private static func fillIn(_ piece: Chunk, _ marks: Marks, from before: UnsafePointer<UInt8>) {
        let bytes = piece.base.assumingMemoryBound(to: UInt8.self)
        let words = marks.words, highs = marks.highs
        var next = 0
        for word in 0..<min(marks.wordCount, (piece.count + 63) / 64) {
            var bits = words[word]
            while bits != 0 {
                let place = word << 6 | bits.trailingZeroBitCount
                bytes[place] = before[Int(bytes[place]) | Int(highs[next]) << 8]
                next += 1
                bits &= bits - 1
            }
        }
    }

    /// The last 32 KB decompressed, once `stretch` is: its own last bytes, with what they copied
    /// filled in from `before` (the 32 KB before it), and the end of `before` if it's shorter.
    /// Nil if a copy reaches back before the start of the data.
    private static func window(after stretch: Stretch, before: [UInt8]) -> [UInt8]? {
        let missing = Self.window - before.count
        var window = stretch.count >= Self.window ? [] : Array(before.suffix(Self.window - stretch.count))
        var start = max(stretch.count - Self.window, 0)
        var offset = 0
        for (index, piece) in stretch.pieces.enumerated() {
            defer { offset += piece.count }
            let end = offset + piece.count
            guard end > start, piece.count > 0 else { continue }
            let from = start - offset
            let bytes = piece.base.assumingMemoryBound(to: UInt8.self)
            let first = window.count
            window.append(contentsOf: UnsafeBufferPointer(start: bytes + from, count: piece.count - from))
            if index < stretch.marks.count {
                let marks = stretch.marks[index]
                var next = marks.copies(before: from)
                for place in from..<piece.count where marks.words[place >> 6] & (1 << UInt64(place & 63)) != 0 {
                    let source = Int(bytes[place]) | Int(marks.highs[next]) << 8
                    next += 1
                    guard source >= missing else { return nil }
                    window[first + place - from] = before[source - missing]
                }
            }
            start = end
        }
        return window
    }

    // MARK: Spans, on every core

    /// Spans decompressing on other threads, each started when it's wanted.
    private final class Spans: @unchecked Sendable {
        private let condition = NSCondition()
        /// A span's stretch, or nil if no block starts in it.
        private var done: [Int: Stretch?] = [:]
        private var running: Set<Int> = []
        /// When each running one began.
        private var began: [Int: UInt64] = [:]
        /// Running, but no longer wanted: they stop where they are.
        private var unwanted: Set<Int> = []
        private var stopped = false
        private let queue = DispatchQueue(label: "OneFile.gunzip", qos: Work.dispatchQoS, attributes: .concurrent)
        private let work: @Sendable (Int, Spans) -> Stretch?

        init(work: @escaping @Sendable (Int, Spans) -> Stretch?) {
            self.work = work
        }

        /// Starts span `index` on a thread of its own.
        func start(_ index: Int) {
            condition.lock()
            running.insert(index)
            condition.unlock()
            stats.withLock { $0.spans += 1 }
            queue.async { [self] in
                let now = DispatchTime.now().uptimeNanoseconds
                condition.lock()
                began[index] = now
                condition.unlock()
                let result = work(index, self)
                result?.seconds = Double(DispatchTime.now().uptimeNanoseconds - now) / 1e9
                condition.lock()
                running.remove(index)
                began.removeValue(forKey: index)
                if !stopped && !unwanted.contains(index) { done[index] = .some(result) }
                unwanted.remove(index)
                condition.broadcast()
                condition.unlock()
            }
        }

        /// Whether span `index` was started, and not yet taken or dropped.
        func has(_ index: Int) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return (running.contains(index) && !unwanted.contains(index)) || done[index] != nil
        }

        /// Whether span `index` is done, or else how long it has been going (nil if it hasn't begun).
        func progress(_ index: Int) -> (done: Bool, seconds: Double?) {
            condition.lock()
            defer { condition.unlock() }
            if done[index] != nil { return (true, nil) }
            return (false, began[index].map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1e9 })
        }

        /// Span `index` won't be used: dropped, or stopped where it is.
        func drop(_ index: Int) {
            condition.lock()
            if done.removeValue(forKey: index) == nil && running.contains(index) { unwanted.insert(index) }
            condition.unlock()
        }

        /// The stretch span `index` decompressed (nil if no block starts in it), once it's done.
        func take(_ index: Int) -> Stretch? {
            condition.lock()
            defer { condition.unlock() }
            while !stopped && done[index] == nil && running.contains(index) && !unwanted.contains(index) { condition.wait() }
            return done.removeValue(forKey: index) ?? nil
        }

        /// Spans before `index` can't line up any more: what they made is dropped, and those still
        /// running stop.
        func drop(before index: Int) {
            condition.lock()
            for key in done.keys where key < index { done.removeValue(forKey: key) }
            for key in running where key < index { unwanted.insert(key) }
            condition.unlock()
        }

        /// Whether span `index` can stop: it's no longer wanted, or everything has stopped.
        func isUnwanted(_ index: Int) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return stopped || unwanted.contains(index)
        }

        func stop() {
            condition.lock()
            stopped = true
            done.removeAll()
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The CRC of pieces checked on other threads, put together in order at the end.
    private final class Checksums: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [Int: (crc: uLong, count: Int)] = [:]
        let group = DispatchGroup()

        func set(_ index: Int, crc: uLong, count: Int) {
            lock.lock()
            parts[index] = (crc, count)
            lock.unlock()
        }

        /// Once every piece is checked: the CRC of them all, one after another.
        func combined(_ count: Int) -> UInt32? {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            var crc = crc32(0, nil, 0)
            for index in 0..<count {
                guard let part = parts[index] else { return nil }
                crc = crc32_combine(crc, part.crc, part.count)
            }
            return UInt32(crc)
        }
    }

    /// Decompresses a gzip file from the member at `offset` on, into `pipeline`: members big enough
    /// on every core when unpacking needs it, the rest in order.
    static func read(_ file: InputFile, from offset: Int64, _ pipeline: OrderedPipeline) {
        stats.withLock { $0 = Stats() }
        var member = offset
        while true {
            guard let start = dataStart(file, at: member), file.size - start >= floor else {
                ArchiveDecoder.readGzip(file, from: member, pipeline)
                return
            }
            guard let next = decompressMember(file, from: start, pipeline) else { return }
            // Another member, or the end (zeros or anything else are ignored, as gzip does).
            guard let head = file.bytes(Int(min(2, file.size - next)), at: next), head == [0x1F, 0x8B] else {
                pipeline.finish()
                return
            }
            member = next
        }
    }

    /// One member, its data starting at byte `start`: where the next one would start, or nil if it
    /// failed or was stopped (and the pipeline has been told).
    private static func decompressMember(_ file: InputFile, from start: Int64, _ pipeline: OrderedPipeline) -> Int64? {
        let ranges = Array(stride(from: start, to: file.size, by: Self.span))
        let count = ranges.count
        let misplace = Self.misplace
        // On a Mac with few cores at full speed, decompressing twice can't beat doing it once.
        let most = fullSpeedCores >= 4 ? Self.ahead : 0
        // A Mac with room to spare decompresses on every core from the start: the quickest way,
        // and what it costs (cores, memory), it has. Others only as far as unpacking needs.
        let eager = (Self.eager ?? ArchiveDecoder.roomy) && most > 0

        let spans = Spans { index, spans in
            let from = ranges[index]
            let to = index + 1 < count ? ranges[index + 1] : file.size
            let until = index + 1 < count ? to * 8 : Int64.max
            guard let input = Input.open(file, at: from, count: Int(min(file.size - from, to - from + (64 << 10)))) else {
                let stretch = Stretch(start: from * 8)
                stretch.failure = ArchiveDecoder.unreadable
                return stretch
            }
            guard var bit = findBlock(input.buffer, count: input.count, from: 0, to: Int(to - from) * 8) else { return nil }
            if misplace && index % 2 == 1 { bit += 1 }
            return decompress(input, from: from * 8 + Int64(bit), until: until, window: nil,
                              stopped: { spans.isUnwanted(index) })
        }
        defer { spans.stop() }

        let checksums = Checksums()
        var pieces = 0
        var position = start * 8
        var window: [UInt8] = []
        var total: UInt64 = 0
        // Spans before this one have been started, or passed.
        var started = 1
        // The span of the range `position` is in, taken: it's used if it starts right there.
        var taken: (index: Int, stretch: Stretch?)?
        // How many spans to decompress ahead, on other cores: on a Mac with room to spare, all it can
        // have, throughout. Otherwise none to begin with: decompressing in order here, on one
        // core, does half the work, and keeps up while unpacking is the slow part (writing many
        // small files, on most Macs). Every 50 ms it's looked at again. If this
        // thread hardly waited to hand on what it made, unpacking was waiting for it, and gets
        // every span there can be. If it waited a while, what it handed on is what unpacking took:
        // enough spans to give a third more than that (each gives `each` bytes a second), or none
        // if decompressing in order here (`alone`) does. An archive can change half way, from big
        // files (decompressing is the slow part) to small ones (writing is), and this follows:
        // quickly to more spans (too few costs time), and slowly to fewer (too many costs only a
        // core): a third fewer at a time, and none only after two looks with this thread waiting
        // over half the time.
        var lead = eager ? most : 0
        var waitingLooks = 0
        var handed = 0
        var demand: Double?
        var alone: Double?
        var each: Double?
        var lastLook = DispatchTime.now().uptimeNanoseconds
        var blocked = 0.0
        // How long a span takes on another core, and a range here, in order, lately.
        var spanSeconds: Double?
        var rangeSeconds: Double?

        /// The range a bit is in.
        func range(of bit: Int64) -> Int {
            var low = 0, high = count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if ranges[middle] <= bit >> 3 { low = middle } else { high = middle - 1 }
            }
            return low
        }

        /// The 32 KB after a stretch that starts here, if it can be used. (One that copies from
        /// before it right at the start of the data, before there are 32 KB, is done in order.)
        func lined(_ candidate: Stretch) -> [UInt8]? {
            guard candidate.copies == 0 || window.count == Self.window else { return nil }
            return Self.window(after: candidate, before: window)
        }

        while true {
            if pipeline.isStopped { return nil }
            let current = range(of: position)
            spans.drop(before: current)
            if taken.map({ $0.index != current }) ?? false { taken = nil }

            // Spans ahead, on other cores, as far as unpacking needs.
            while started <= min(count - 1, current + lead) {
                if started > current { spans.start(started) }
                started += 1
            }

            // This range's span, if one was started: waited for if it will be done sooner than the
            // range could be decompressed here, else dropped. So it can only make it quicker.
            var chosen = false
            if taken == nil && spans.has(current) {
                let progress = spans.progress(current)
                let here = rangeSeconds ?? 0
                let takes = spanSeconds ?? here * 2.5
                if progress.done || takes - (progress.seconds ?? 0) <= here {
                    taken = (current, spans.take(current))
                    if let span = taken?.stretch, span.failure == nil, span.seconds > 0 {
                        spanSeconds = spanSeconds.map { $0 * 0.7 + span.seconds * 0.3 } ?? span.seconds
                        let rate = Double(span.count) / span.seconds
                        each = each.map { $0 * 0.7 + rate * 0.3 } ?? rate
                    }
                } else {
                    spans.drop(current)
                    taken = (current, nil)
                    chosen = true
                }
            }
            var stretch: Stretch?
            var next: [UInt8]?
            var until = current + 1 < count ? ranges[current + 1] * 8 : Int64.max
            var passedOver = false
            if let candidate = taken?.stretch, candidate.failure == nil {
                if candidate.start == position, let after = lined(candidate) {
                    stretch = candidate
                    next = after
                    taken = (current, nil)
                    stats.withLock { $0.lined += 1; $0.marked += candidate.copies }
                } else if candidate.start > position {
                    until = candidate.start
                } else {
                    passedOver = true
                }
            } else if taken != nil && !chosen {
                passedOver = true
            }
            if stretch == nil {
                // In order, here, with the 32 KB before known: to the next span's start.
                guard let input = Input.open(file, at: position >> 3, count: Self.span + (64 << 10)) else {
                    pipeline.fail(ArchiveDecoder.unreadable)
                    return nil
                }
                let begun = DispatchTime.now().uptimeNanoseconds
                let known = decompress(input, from: position, until: until, window: window, stopped: { pipeline.isStopped })
                if let failure = known.failure {
                    if !pipeline.isStopped { pipeline.fail(failure) }
                    return nil
                }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1e9
                rangeSeconds = rangeSeconds.map { $0 * 0.7 + seconds * 0.3 } ?? seconds
                if seconds > 0 {
                    let rate = Double(known.count) / seconds
                    alone = alone.map { $0 * 0.7 + rate * 0.3 } ?? rate
                }
                stats.withLock { if passedOver { $0.redone += 1 } else { $0.inOrder += 1 } }
                if passedOver { taken = (current, nil) }
                stretch = known
                next = Self.window(after: known, before: window)
            }
            guard let stretch, let next else { return nil }

            // Hand it on: each piece has its copies filled in, and its CRC worked out, on a core of
            // its own, with the 32 KB from before the stretch.
            let before = window
            for (place, piece) in stretch.pieces.enumerated() where piece.count > 0 {
                let marks = place < stretch.marks.count && stretch.copies > 0 ? stretch.marks[place] : nil
                let number = pieces
                pieces += 1
                checksums.group.enter()
                let handing = DispatchTime.now().uptimeNanoseconds
                defer { blocked += Double(DispatchTime.now().uptimeNanoseconds - handing) / 1e9 }
                guard pipeline.submit({
                    if let marks { before.withUnsafeBufferPointer { fillIn(piece, marks, from: $0.baseAddress!) } }
                    checksums.set(number, crc: crc32(0, piece.base.assumingMemoryBound(to: Bytef.self), uInt(piece.count)),
                                  count: piece.count)
                    checksums.group.leave()
                    return .success(piece)
                }) else {
                    checksums.group.leave()
                    return nil
                }
            }
            total += UInt64(stretch.count)
            handed += stretch.count
            window = next
            position = stretch.end

            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - lastLook) / 1e9
            if !eager && most > 0 && elapsed >= Self.lookEvery {
                waitingLooks = blocked > elapsed * 0.5 ? waitingLooks + 1 : 0
                if blocked < elapsed * 0.1 {
                    lead = most
                } else {
                    let took = Double(handed) / elapsed
                    let wanted = (demand.map { $0 * 0.5 + took * 0.5 } ?? took)
                    demand = wanted
                    var needed = 0
                    if alone.map({ wanted * 1.3 > $0 }) ?? true {
                        let perSpan = each ?? (alone ?? wanted) / 2.5
                        needed = min(most, max(1, Int(min(Double(most), (wanted * 1.3 / max(perSpan, 1)).rounded(.up)))))
                    }
                    lead = needed >= lead || waitingLooks >= 2 ? needed : max(needed, lead - max(1, lead / 3))
                }
                lastLook = now
                blocked = 0
                handed = 0
            }

            if let trailer = stretch.trailer {
                guard let tail = file.bytes(8, at: trailer) else {
                    pipeline.fail(ArchiveDecoder.endsEarly)
                    return nil
                }
                let storedCRC = UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24
                let storedSize = UInt32(tail[4]) | UInt32(tail[5]) << 8 | UInt32(tail[6]) << 16 | UInt32(tail[7]) << 24
                guard checksums.combined(pieces) == storedCRC, storedSize == UInt32(truncatingIfNeeded: total) else {
                    pipeline.fail(ArchiveDecoder.damaged(trailer))
                    return nil
                }
                return trailer + 8
            }
        }
    }
}
