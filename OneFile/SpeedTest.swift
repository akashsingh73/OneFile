import Foundation

/// Measures what matters for moving many files: how many small files a second a drive takes and
/// gives back, how fast it reads and writes one big file, and how much room a small file really
/// takes there. Disk speed tests usually measure only big files, which is the part that matters
/// least here.
///
/// Everything happens in a hidden folder of its own, deleted at the end. Writes count only once
/// they're on the drive (made sure of, as copying does), and reads come from the drive, not from
/// what macOS still has in memory.
final class SpeedTest: @unchecked Sendable {
    struct Result: Sendable, Equatable {
        var smallWrite: Double = 0
        var smallRead: Double = 0
        var bigWrite: Double = 0
        var bigRead: Double = 0
        /// What one small file (4 KB) took on the drive, its "._" companion included.
        var spacePerSmallFile: Int64 = 0
        var smallFiles = 0
        var bigBytes: Int64 = 0
    }

    struct Progress: Sendable {
        var step = "Getting ready…"
        var fraction: Double = 0
    }

    enum Outcome: Sendable {
        case finished(Result)
        case stopped
        case failed(String)
    }

    static let smallCount = 2_000
    static let smallSize = 4_096
    static let bigLimit: Int64 = 1 << 30
    /// Writing the big file stops after this long, on a slow drive.
    static let bigSeconds = 4.0
    static let threads = 8

    /// Where the test folder goes: a folder on the drive OneFile can write in.
    let place: URL
    /// The most the big file gets (less for the tests).
    let bigLimit: Int64
    private let state = Locked((progress: Progress(), stopped: false))

    init(place: URL, bigLimit: Int64 = SpeedTest.bigLimit) {
        self.place = place
        self.bigLimit = bigLimit
    }

    /// Where to test a drive: its top folder, or for the Mac's own disk, a temporary folder.
    static func place(for drive: Drive) -> URL {
        drive.isStartup ? FileManager.default.temporaryDirectory : URL(fileURLWithPath: drive.mountPath)
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in completion(run()) }
        thread.name = "OneFile speed test"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() { state.withLock { $0.stopped = true } }
    func progress() -> Progress { state.withLock { $0.progress } }
    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func step(_ text: String, _ fraction: Double) {
        state.withLock { $0.progress = Progress(step: text, fraction: fraction) }
    }

    private func run() -> Outcome {
        guard let free = Packer.freeSpace(place.path), free > bigLimit + (200 << 20) else {
            return .failed("There isn't room for the test: it needs about 1.2 GB free.")
        }
        let folder = place.path + "/.OneFile speed test \(UUID().uuidString.prefix(8))"
        guard mkdir(folder, 0o755) == 0 else {
            return .failed("Couldn't make a folder for the test here: \(Packer.message(errno)).")
        }
        defer { removefile(folder, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) }
        var result = Result()
        result.smallFiles = Self.smallCount

        // Small files: made 8 at a time, then made sure of on the drive.
        step("Writing \(Format.count(Int64(Self.smallCount))) small files…", 0.05)
        let names = (0..<Self.smallCount).map { "\(folder)/d\($0 % 20)/f\($0)" }
        for index in 0..<20 { mkdir("\(folder)/d\(index)", 0o755) }
        let payload = [UInt8](repeating: 0x61, count: Self.smallSize)
        var started = Date()
        let wroteAll = everyFile(names) { path in
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == payload.count
        }
        guard wroteAll else { return isStopped ? .stopped : .failed("Couldn't write the test files: \(Packer.message(errno)).") }
        syncDrive(folder)
        result.smallWrite = Double(Self.smallCount) / Date().timeIntervalSince(started)
        result.spacePerSmallFile = spaceTaken(names.first ?? folder)

        // Read back from the drive.
        step("Reading them back…", 0.3)
        for path in names { forget(path) }
        started = Date()
        let readAll = everyFile(names) { path in
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: Self.smallSize)
            return buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) } == Self.smallSize
        }
        guard readAll else { return isStopped ? .stopped : .failed("Couldn't read the test files back.") }
        result.smallRead = Double(Self.smallCount) / Date().timeIntervalSince(started)
        if isStopped { return .stopped }

        // One big file, in 8 MB pieces, past the memory macOS keeps for files.
        step("Writing a big file…", 0.5)
        let big = folder + "/big.bin"
        let fd = open(big, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failed("Couldn't write the big test file: \(Packer.message(errno)).") }
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16_384)
        defer { buffer.deallocate() }
        // Random bytes: a drive that compresses can't make a block of zeros look fast.
        arc4random_buf(buffer, chunk)
        started = Date()
        var written: Int64 = 0
        while written < bigLimit && Date().timeIntervalSince(started) < Self.bigSeconds && !isStopped {
            guard write(fd, buffer, chunk) == chunk else {
                close(fd)
                return .failed("Couldn't write the big test file: \(Packer.message(errno)).")
            }
            written += Int64(chunk)
            step("Writing a big file… \(Format.bytes(written))", 0.5 + 0.25 * Double(written) / Double(bigLimit))
        }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        result.bigWrite = Double(written) / Date().timeIntervalSince(started)
        result.bigBytes = written
        if isStopped { return .stopped }

        step("Reading it back…", 0.8)
        forget(big)
        let input = open(big, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { return .failed("Couldn't read the big test file back.") }
        _ = fcntl(input, F_NOCACHE, 1)
        started = Date()
        var got: Int64 = 0
        while true {
            let count = read(input, buffer, chunk)
            if count <= 0 { break }
            got += Int64(count)
        }
        close(input)
        result.bigRead = Double(got) / Date().timeIntervalSince(started)
        step("Cleaning up…", 0.97)
        return .finished(result)
    }

    /// Runs `body` for every path, `threads` at a time. False if any failed (or it was stopped).
    private func everyFile(_ paths: [String], _ body: @escaping @Sendable (String) -> Bool) -> Bool {
        let next = Locked(0)
        let failed = Locked(false)
        DispatchQueue.concurrentPerform(iterations: Self.threads) { _ in
            while !failed.withLock({ $0 }) && !isStopped {
                let index = next.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                guard index < paths.count else { return }
                if !body(paths[index]) { failed.withLock { $0 = true } }
            }
        }
        return !failed.withLock { $0 } && !isStopped
    }

    private func syncDrive(_ path: String) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        fsync_volume_np(fd, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)
        close(fd)
    }

    private func forget(_ path: String) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        Comparer.forgetCached(fd)
        close(fd)
    }

    /// The room one test file takes on the drive, with its "._" file if the drive made one.
    private func spaceTaken(_ path: String) -> Int64 {
        var total: Int64 = 0
        var info = stat()
        if lstat(path, &info) == 0 { total += Int64(info.st_blocks) * 512 }
        let url = URL(fileURLWithPath: path)
        let sidecar = url.deletingLastPathComponent().path + "/._" + url.lastPathComponent
        if lstat(sidecar, &info) == 0 { total += Int64(info.st_blocks) * 512 }
        return total
    }

    /// What the numbers mean for copying to this drive, in a sentence or two.
    static func advice(_ result: Result, drive: Drive) -> [String] {
        var notes: [String] = []
        if result.smallWrite < 3_000 {
            notes.append("Slow with many small files (\(Format.count(Int64(result.smallWrite))) a second): for a folder of thousands, packing it into one file first is much faster.")
        } else {
            notes.append("Good with small files: copying folders of many files here works well, 8 at a time.")
        }
        if result.spacePerSmallFile >= 64 << 10 {
            var line = "Each small file takes \(Format.bytes(result.spacePerSmallFile)) here"
            if drive.isWindowsFormat {
                line += ": \(drive.formatName) hands out room in big blocks. Formatted as APFS (for Macs only), a small file would take 4 KB."
            } else {
                line += "."
            }
            notes.append(line)
        }
        if result.bigWrite > 0 && result.bigRead > 0 {
            notes.append("Big files: \(Format.bytes(Int64(result.bigWrite)))/s in, \(Format.bytes(Int64(result.bigRead)))/s out.")
        }
        return notes
    }
}
