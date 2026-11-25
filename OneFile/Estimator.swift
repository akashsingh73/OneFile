import Foundation
import zlib

/// How big each method's file will be, and how fast each compresses on this Mac: guessed from
/// compressing a sample of the folder.
struct Estimates: Sendable {
    /// Bytes of the finished file, for each method.
    var bytes: [PackMethod: Int64]
    /// Bytes of tar stream compressed per second on this Mac, with every core (none for `.plain`).
    var speed: [PackMethod: Double]
    /// What OneFile suggests: Balanced if compressing saves a good share, else Fastest.
    var recommended: PackMethod
    /// Why, in a few words.
    var reason: String

    /// How long the compression takes on its own; packing that way can't be quicker.
    func seconds(for method: PackMethod, tarBytes: Int64) -> Double? {
        guard let speed = speed[method], speed > 0 else { return nil }
        return Double(tarBytes) / speed
    }
}

enum Estimator {
    /// Tar's header blocks and padding compress to next to nothing; these are typical.
    private static let overhead: [PackMethod: Double] = [.plain: 1, .gzip: 0.08, .zstd: 0.06, .xz: 0.05]
    /// Compressing on every core isn't every-core-times faster: the cores share memory, and xz's
    /// big dictionaries crowd it. Measured on an M4 Max (16 cores), packing 2.1 GB: gzip ran at 0.9
    /// of one core's speed times the cores, xz at 0.4. zstd, compressing tars of 290 and 550 MB in
    /// its 8 MB pieces, ran at 0.75 and 0.9. The sample's own pieces (smaller, and fewer at once)
    /// run faster than that.
    private static let parallelShare: [PackMethod: Double] = [.gzip: 0.9, .zstd: 0.8, .xz: 0.4]

    /// Compresses about 12 MB read from the sampled files each way, several pieces at once, and
    /// scales up. Takes well under a second.
    ///
    /// The sample picks files in proportion to their size, but each file only once, so a few big
    /// files can't be picked as often as their share of the data deserves. They're measured on
    /// their own: any file holding at least 1/N of the data was certain to be picked, and stands
    /// for exactly its own bytes. The other picks stand, equally, for all the other files.
    ///
    /// Equally: but a small file can't fill its share of the sample, so compressing the picks
    /// together would weigh the bigger ones (often photos, which don't compress) more than they
    /// should. So each pick's own ratio is measured too (one gzip stream, flushed after each), and
    /// the group's measurements are scaled by how far the average of those ratios is from the
    /// ratio of the picks taken together. On a web project of code, photos and video, that took
    /// the Balanced estimate from 46% too big to within a few percent.
    static func estimate(_ totals: Packer.Totals, samples: [Packer.SampleFile]) -> Estimates {
        let headers = Double(max(totals.archiveBytes - totals.bytes, 0))
        let fair = totals.bytes / Int64(max(samples.count, 1))
        let big = samples.filter { fair > 0 && $0.size >= fair }
        let small = samples.filter { !(fair > 0 && $0.size >= fair) }
        let bigBytes = Double(big.reduce(0) { $0 + $1.size })
        let smallBytes = max(Double(totals.bytes) - bigBytes, 0)
        let smallPieces = pieces(small, limit: 6 << 20, bySize: false)
        let groups = [
            (sample: pieces(big, limit: 6 << 20, bySize: true).reduce(Data(), +), bytes: bigBytes, bias: 1.0),
            (sample: smallPieces.reduce(Data(), +), bytes: smallBytes, bias: evenBias(smallPieces)),
        ].filter { $0.sample.count >= 4_096 }

        var bytes: [PackMethod: Int64] = [.plain: totals.archiveBytes]
        var speed: [PackMethod: Double] = [:]
        for method in [PackMethod.gzip, .zstd, .xz] {
            if groups.isEmpty {
                // Next to no data: it's nearly all headers.
                bytes[method] = Int64(headers * overhead[method, default: 1]) + 1_024
                continue
            }
            var data = 0.0, sampled = 0, seconds = 0.0
            let represented = groups.reduce(0) { $0 + $1.bytes }
            for group in groups {
                // Every method compresses the same bytes: a part of the sample could be all video
                // and another all text.
                let result = measure(group.sample, method, piece: method == .gzip ? 1 << 20 : 2 << 20, limit: 6 << 20)
                data += group.bytes * min(result.ratio * group.bias, 1.01)
                sampled += result.sampled
                seconds += result.seconds
            }
            data *= Double(totals.bytes) / max(represented, 1)
            bytes[method] = Int64(data + headers * overhead[method, default: 1])
            if seconds > 0 {
                speed[method] = Double(sampled) / seconds * Double(method.workers) * parallelShare[method, default: 1]
            }
        }

        let gzipped = Double(bytes[.gzip] ?? totals.archiveBytes)
        let saving = 1 - gzipped / Double(max(totals.archiveBytes, 1))
        if saving >= 0.15 {
            let times = Double(totals.archiveBytes) / max(gzipped, 1)
            return Estimates(bytes: bytes, speed: speed, recommended: .gzip,
                             reason: String(format: "compresses well, to about %.1f× smaller", times))
        }
        return Estimates(bytes: bytes, speed: speed, recommended: .plain,
                         reason: "is mostly already compressed (photos, video, archives), so compressing barely helps")
    }

    /// Up to `limit` bytes from the files, a piece from each: shares in proportion to their sizes
    /// (`bySize`), or equal.
    private static func pieces(_ files: [Packer.SampleFile], limit: Int, bySize: Bool) -> [Data] {
        let total = Double(files.reduce(0) { $0 + $1.size })
        guard total > 0 else { return [] }
        var pieces: [Data] = []
        for file in files {
            let share = bySize ? Double(limit) * Double(file.size) / total : Double(limit) / Double(files.count)
            let want = min(Int64(share), file.size)
            var data = Data()
            if want > 0 { append(file, bytes: Int(want), to: &data) }
            if !data.isEmpty { pieces.append(data) }
        }
        return pieces
    }

    /// How much smaller compressing comes out with every piece counting the same, than with the
    /// pieces taken together (where the bigger ones count for more): the average of each piece's
    /// own ratio, over the ratio of them all. From one gzip stream, flushed after each piece, so
    /// a piece compresses as it would among others in a tar stream.
    private static func evenBias(_ pieces: [Data]) -> Double {
        guard pieces.count > 1 else { return 1 }
        var stream = z_stream()
        guard deflateInit2_(&stream, 1, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 1 }
        defer { deflateEnd(&stream) }
        let capacity = 1 << 20
        let out = UnsafeMutablePointer<Bytef>.allocate(capacity: capacity)
        defer { out.deallocate() }
        var ratios: [Double] = []
        var totalIn = 0, totalOut = 0
        for piece in pieces {
            var produced = 0
            piece.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(raw.count)
                repeat {
                    stream.next_out = out
                    stream.avail_out = uInt(capacity)
                    deflate(&stream, Z_SYNC_FLUSH)
                    produced += capacity - Int(stream.avail_out)
                } while stream.avail_out == 0
            }
            ratios.append(Double(produced) / Double(piece.count))
            totalIn += piece.count
            totalOut += produced
        }
        guard totalIn > 0, totalOut > 0 else { return 1 }
        let even = ratios.reduce(0, +) / Double(ratios.count)
        let together = Double(totalOut) / Double(totalIn)
        return min(max(even / together, 0.2), 5)
    }

    /// Reads `bytes` of the file, in pieces of up to 256 KB spread evenly through it.
    private static func append(_ file: Packer.SampleFile, bytes: Int, to data: inout Data) {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let piece = 256 << 10
        let pieces = max(1, (bytes + piece - 1) / piece)
        let span = max(Int(file.size) - min(piece, bytes), 0)
        for index in 0..<pieces {
            let length = min(piece, bytes - index * piece)
            guard length > 0 else { break }
            let offset = pieces == 1 ? span / 2 : span * index / (pieces - 1)
            var chunk = Data(count: length)
            let got = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset & ~4_095)) }
            if got > 0 { data.append(chunk.prefix(got)) }
        }
    }

    /// Compresses up to `limit` bytes of `sample` in pieces, several at once: the share of the size
    /// left, the bytes compressed, and the seconds one core spent on them.
    private static func measure(_ sample: Data, _ method: PackMethod, piece: Int,
                                limit: Int) -> (ratio: Double, sampled: Int, seconds: Double) {
        let usable = min(sample.count, limit)
        let pieces = stride(from: 0, to: usable, by: piece).map { $0..<min($0 + piece, usable) }
        let results = Locked<[(bytes: Int, seconds: Double)]>([])
        sample.withUnsafeBytes { raw in
            let base = SharedPointer(UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress!))
            DispatchQueue.concurrentPerform(iterations: pieces.count) { index in
                let range = pieces[index]
                let start = DispatchTime.now().uptimeNanoseconds
                let compressed = BlockCompressor.compress(base.pointer + range.lowerBound, range.count, method)
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                results.withLock { $0.append((compressed?.count ?? range.count, seconds)) }
            }
        }
        let (compressed, seconds) = results.withLock { list in
            list.reduce((0, 0.0)) { ($0.0 + $1.bytes, $0.1 + $1.seconds) }
        }
        return (Double(compressed) / Double(max(usable, 1)), usable, seconds)
    }
}
