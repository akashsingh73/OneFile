import Foundation
import Security

/// A place in the cloud for archives: a bucket at an S3-compatible service, or Google Drive.
/// Secrets (keys, sign-ins) are kept in the Keychain, never in the accounts file.
struct CloudAccount: Codable, Identifiable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case s3, googleDrive
    }

    var id = UUID()
    var name: String
    var kind = Kind.s3
    // An S3-compatible bucket.
    var endpoint = ""
    var region = ""
    var bucket = ""
    var keyID = ""
    var pathStyle = false
    /// Where archives go: a folder in the bucket (a prefix), or in Google Drive.
    var folder = "OneFile"
    // Google Drive: the person's own Google Cloud client.
    var clientID = ""

    var kindText: String { kind == .googleDrive ? "Google Drive" : (S3Service.guess(endpoint) ?? .other).title }

    /// "photos/OneFile", "Google Drive/OneFile".
    var placeText: String {
        let top = kind == .googleDrive ? "Google Drive" : bucket
        return folder.isEmpty ? top : top + "/" + folder
    }

    /// The Keychain names of its secrets.
    var secretName: String { id.uuidString }
    var clientSecretName: String { id.uuidString + ".client" }
    var refreshName: String { id.uuidString + ".refresh" }
}

/// S3-compatible services, and how each is reached.
enum S3Service: String, CaseIterable, Identifiable, Sendable {
    case aws, r2, b2, gcs, wasabi, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aws: "Amazon S3"
        case .r2: "Cloudflare R2"
        case .b2: "Backblaze B2"
        case .gcs: "Google Cloud Storage"
        case .wasabi: "Wasabi"
        case .other: "Other S3-compatible"
        }
    }

    /// What the region field holds, as the service names it.
    var regionHint: String {
        switch self {
        case .aws: "us-east-1"
        case .r2: "auto"
        case .b2: "us-west-004"
        case .gcs: "auto"
        case .wasabi: "us-east-1"
        case .other: "us-east-1"
        }
    }

    /// The endpoint for a region (R2: for an account ID).
    func endpoint(region: String, account: String = "") -> String {
        switch self {
        case .aws: "https://s3.\(region).amazonaws.com"
        case .r2: "https://\(account.isEmpty ? "ACCOUNT_ID" : account).r2.cloudflarestorage.com"
        case .b2: "https://s3.\(region).backblazeb2.com"
        case .gcs: "https://storage.googleapis.com"
        case .wasabi: "https://s3.\(region).wasabisys.com"
        case .other: ""
        }
    }

    /// Amazon wants the bucket in the host name; the rest take it in the path.
    var pathStyle: Bool { self != .aws }

    static func guess(_ endpoint: String) -> S3Service? {
        let host = URL(string: endpoint)?.host ?? endpoint
        if host.hasSuffix("amazonaws.com") { return .aws }
        if host.hasSuffix("r2.cloudflarestorage.com") { return .r2 }
        if host.hasSuffix("backblazeb2.com") { return .b2 }
        if host == "storage.googleapis.com" { return .gcs }
        if host.hasSuffix("wasabisys.com") { return .wasabi }
        return nil
    }
}

/// The accounts, in a file the app and the onefile command share (secrets apart, in the Keychain).
enum CloudStore {
    static var file: URL { BackupStore.folder.appendingPathComponent("Clouds.json") }

    static func load() -> [CloudAccount] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([CloudAccount].self, from: data)) ?? []
    }

    @discardableResult
    static func change(_ body: (inout [CloudAccount]) -> Void) -> [CloudAccount] {
        try? FileManager.default.createDirectory(at: BackupStore.folder, withIntermediateDirectories: true)
        var accounts = load()
        body(&accounts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(accounts) { try? data.write(to: file, options: .atomic) }
        return accounts
    }

    static func named(_ name: String) -> CloudAccount? {
        load().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Secrets in the login keychain, as OneFile's own.
enum Keychain {
    static let service = "OneFile"

    @discardableResult
    static func set(_ secret: String, for name: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        let data = Data(secret.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var adding = query
        adding[kSecValueData as String] = data
        adding[kSecAttrLabel as String] = "OneFile cloud"
        return SecItemAdd(adding as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
    }
}

/// An account, connected: what archives are read from and sent to.
enum CloudPlace: Sendable {
    case s3(S3Bucket, prefix: String)
    case drive(GoogleDrive, folderID: String)

    /// Where in it a new archive called `name` goes.
    func target(_ name: String) -> CloudTarget {
        switch self {
        case .s3(let bucket, let prefix): .s3(bucket, key: prefix + name)
        case .drive(let drive, let folderID): .drive(drive, folderID: folderID, name: name)
        }
    }
}

/// Where an archive goes, in the cloud.
enum CloudTarget: Sendable {
    case s3(S3Bucket, key: String)
    case drive(GoogleDrive, folderID: String, name: String)

    var name: String {
        switch self {
        case .s3(_, let key): (key as NSString).lastPathComponent
        case .drive(_, _, let name): name
        }
    }
}

enum Cloud {
    /// Connects to an account, with its secrets from the Keychain.
    static func connect(_ account: CloudAccount) -> Result<CloudPlace, CloudError> {
        switch account.kind {
        case .s3:
            guard let secret = Keychain.get(account.secretName) else {
                return .failure(CloudError(message: "The secret key for “\(account.name)” isn't in the Keychain: remove the account (Settings › Cloud) and add it again."))
            }
            guard let endpoint = URL(string: account.endpoint), endpoint.host != nil else {
                return .failure(CloudError(message: "“\(account.endpoint)” isn't an address."))
            }
            let bucket = S3Bucket(endpoint: endpoint, bucket: account.bucket, pathStyle: account.pathStyle,
                                  signer: SigV4(accessKey: account.keyID, secretKey: secret, region: account.region.isEmpty ? "us-east-1" : account.region))
            return .success(.s3(bucket, prefix: prefix(account.folder)))
        case .googleDrive:
            guard let secret = Keychain.get(account.clientSecretName), let refresh = Keychain.get(account.refreshName) else {
                return .failure(CloudError(message: "OneFile isn't signed in to Google Drive for “\(account.name)”: remove the account (Settings › Cloud) and add it again."))
            }
            let drive = GoogleDrive(clientID: account.clientID, clientSecret: secret, refreshToken: refresh)
            switch drive.folder(named: account.folder.isEmpty ? "OneFile" : account.folder) {
            case .success(let folderID): return .success(.drive(drive, folderID: folderID))
            case .failure(let error): return .failure(error)
            }
        }
    }

    /// "OneFile/" for "OneFile"; nothing for nothing.
    static func prefix(_ folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    /// A bucket from the environment, as Amazon's own tools take it: AWS_ACCESS_KEY_ID,
    /// AWS_SECRET_ACCESS_KEY, AWS_REGION, and AWS_ENDPOINT_URL for a service other than Amazon's.
    static func environmentBucket(_ bucket: String) -> Result<S3Bucket, CloudError> {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["AWS_ACCESS_KEY_ID"], let secret = environment["AWS_SECRET_ACCESS_KEY"] else {
            return .failure(CloudError(message: "s3:// needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY set (or set up an account with onefile cloud add, and use cloud:NAME/…)."))
        }
        let region = environment["AWS_REGION"] ?? environment["AWS_DEFAULT_REGION"] ?? "us-east-1"
        let custom = environment["AWS_ENDPOINT_URL_S3"] ?? environment["AWS_ENDPOINT_URL"]
        guard let endpoint = URL(string: custom ?? S3Service.aws.endpoint(region: region)) else {
            return .failure(CloudError(message: "AWS_ENDPOINT_URL isn't an address."))
        }
        return .success(S3Bucket(endpoint: endpoint, bucket: bucket, pathStyle: custom != nil,
                                 signer: SigV4(accessKey: key, secretKey: secret, region: region)))
    }

    /// Whether a name is an archive (or a part of one) OneFile can open.
    static func isArchive(_ name: String) -> Bool {
        let whole = SplitParts.wholeName(name)
        return ArchiveName.split(whole).ext != nil
    }

    /// The archives in a place, newest first; a split archive's parts as its first part.
    static func archives(in place: CloudPlace) -> Result<[CloudItem], CloudError> {
        let listed: Result<[CloudItem], CloudError>
        switch place {
        case .s3(let bucket, let prefix):
            listed = bucket.list(prefix: prefix).map { items in items.filter { !$0.key.dropFirst(prefix.count).contains("/") } }
        case .drive(let drive, let folderID):
            listed = drive.list(folderID: folderID)
        }
        return listed.map { items in
            items.filter { isArchive($0.name) && (!SplitParts.isPartName($0.name) || $0.name.hasSuffix(".001")) }
                .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    /// An archive in the cloud, to open like a file (with all its parts, if it was split).
    static func open(_ item: CloudItem, in place: CloudPlace, among items: [CloudItem]? = nil) -> URL {
        var parts = [item]
        if SplitParts.isPartName(item.name), item.name.hasSuffix(".001") {
            let stem = String(item.name.dropLast(4))
            let all: [CloudItem]
            if let items {
                all = items
            } else {
                switch place {
                case .s3(let bucket, let prefix): all = (try? bucket.list(prefix: prefix + stem).get()) ?? []
                case .drive(let drive, let folderID): all = (try? drive.list(folderID: folderID).get()) ?? []
                }
            }
            for number in 2...999 {
                guard let next = all.first(where: { $0.name == stem + String(format: ".%03d", number) }) else { break }
                parts.append(next)
            }
        }
        let objects: [RemoteObject]
        switch place {
        case .s3(let bucket, _): objects = parts.map(bucket.object)
        case .drive(let drive, _): objects = parts.map(drive.object)
        }
        return Remote.register(objects, name: item.name)
    }

    /// A link to download it with: for S3, signed for `days` (at most 7); for Drive, shared
    /// with anyone who has it.
    static func link(_ item: CloudItem, in place: CloudPlace, days: Int = 7) -> Result<URL, CloudError> {
        switch place {
        case .s3(let bucket, _): .success(bucket.link(item.key, days: days))
        case .drive(let drive, _): drive.share(item)
        }
    }

    static func delete(_ item: CloudItem, in place: CloudPlace) -> Result<Void, CloudError> {
        switch place {
        case .s3(let bucket, _): bucket.delete(item.key)
        case .drive(let drive, _): drive.delete(item)
        }
    }
}

// MARK: - Sending

/// Sends a file in pieces: S3's several at once, Drive's one after another.
private protocol CloudSender: AnyObject, Sendable {
    var parallel: Int { get }
    func begin() -> Result<Void, CloudError>
    func send(_ number: Int, at offset: Int64, _ data: Data, total: Int64?) -> Result<Void, CloudError>
    func finish(total: Int64) -> Result<CloudItem, CloudError>
    func abort()
}

private final class S3Sender: CloudSender, @unchecked Sendable {
    let bucket: S3Bucket
    let key: String
    private var uploadID = ""
    private let tags = Locked([Int: String]())
    let parallel = 4

    init(_ bucket: S3Bucket, key: String) {
        self.bucket = bucket
        self.key = key
    }

    func begin() -> Result<Void, CloudError> {
        bucket.startUpload(key).map { uploadID = $0 }
    }

    func send(_ number: Int, at offset: Int64, _ data: Data, total: Int64?) -> Result<Void, CloudError> {
        bucket.uploadPart(key, uploadID: uploadID, number: number, body: data).map { tag in tags.withLock { $0[number] = tag } }
    }

    func finish(total: Int64) -> Result<CloudItem, CloudError> {
        let list = tags.withLock { tags in (1...max(1, tags.count)).compactMap { tags[$0] } }
        return bucket.finishUpload(key, uploadID: uploadID, tags: list)
            .map { CloudItem(key: key, name: (key as NSString).lastPathComponent, size: total, modified: Date()) }
    }

    func abort() {
        if !uploadID.isEmpty { bucket.abortUpload(key, uploadID: uploadID) }
    }
}

private final class DriveSender: CloudSender, @unchecked Sendable {
    let drive: GoogleDrive
    let folderID: String
    let name: String
    private var session: URL?
    private let made = Locked<CloudItem?>(nil)
    let parallel = 1

    init(_ drive: GoogleDrive, folderID: String, name: String) {
        self.drive = drive
        self.folderID = folderID
        self.name = name
    }

    func begin() -> Result<Void, CloudError> {
        drive.startUpload(name: name, folderID: folderID).map { session = $0 }
    }

    func send(_ number: Int, at offset: Int64, _ data: Data, total: Int64?) -> Result<Void, CloudError> {
        guard let session else { return .failure(CloudError(message: "Not started.")) }
        return drive.uploadPiece(session, offset: offset, data, total: total).map { item in
            if let item { made.withLock { $0 = item } }
        }
    }

    func finish(total: Int64) -> Result<CloudItem, CloudError> {
        guard let item = made.withLock({ $0 }) else { return .failure(CloudError(message: "Google Drive didn't take the last piece.")) }
        return .success(item)
    }

    func abort() {
        if let session { drive.cancelUpload(session) }
    }
}

/// Packs a folder and sends the archive to the cloud at the same time: packing writes it to a
/// temporary file, and each piece goes up as soon as it's in the file (several at once to S3),
/// after which the room it took on the disk is given back. So the disk never holds much more than
/// what's still to send, and it's done soon after packing is.
final class CloudPack: @unchecked Sendable {
    struct Progress: Sendable {
        var packing = Packer.Progress()
        /// Sent so far.
        var sent: Int64 = 0
        /// Packing is done; the rest is being sent.
        var packed = false
    }

    enum Outcome: Sendable {
        case finished(Packer.Summary, CloudItem)
        case stopped
        case failed(String)
    }

    let source: URL
    let target: CloudTarget
    let options: Packer.Options
    /// The smallest piece (smaller only for the tests: S3 takes no piece but the last under 5 MB).
    let pieceFloor: Int64

    private struct State {
        var progress = Progress()
        var packer: Packer?
        var stopped = false
        var failure: String?
    }

    private let state = Locked(State())

    init(source: URL, target: CloudTarget, options: Packer.Options, pieceFloor: Int64 = 16 << 20) {
        self.source = source
        self.target = target
        self.options = options
        self.pieceFloor = pieceFloor
    }

    func start(completion: @escaping @Sendable (Outcome) -> Void) {
        let thread = Thread { [self] in completion(run()) }
        thread.name = "OneFile cloud pack"
        thread.qualityOfService = Work.qos
        thread.start()
    }

    func cancel() {
        let packer = state.withLock { s -> Packer? in
            s.stopped = true
            return s.packer
        }
        packer?.cancel()
    }

    func pause() { state.withLock { $0.packer }?.pause() }
    func resume() { state.withLock { $0.packer }?.resume() }

    func progress() -> Progress {
        let packer = state.withLock { $0.packer }
        var progress = state.withLock { $0.progress }
        if let packer, !progress.packed { progress.packing = packer.progress() }
        return progress
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func fail(_ message: String) {
        state.withLock { if $0.failure == nil { $0.failure = message } }
    }

    /// A piece's size: at least 16 MB, and big enough that S3's 10,000 pieces hold the whole tar
    /// (which the compressed archive never outgrows).
    static func pieceSize(for totals: Packer.Totals?, floor: Int64 = 16 << 20) -> Int64 {
        guard let totals else { return floor }
        let needed = ((totals.archiveBytes / 9_000 + (1 << 20)) >> 20) << 20
        return max(floor, needed)
    }

    /// Reads exactly `count` bytes at `offset`.
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, at offset: Int64) -> Bool {
        var done = 0
        while done < count {
            let got = pread(fd, buffer + done, count - done, off_t(offset + Int64(done)))
            if got > 0 {
                done += got
                continue
            }
            if got < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    private func run() -> Outcome {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("OneFile upload \(UUID().uuidString)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed("Couldn't make a temporary folder to pack in.")
        }
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent(target.name)

        let sender: CloudSender
        switch target {
        case .s3(let bucket, let key): sender = S3Sender(bucket, key: key)
        case .drive(let drive, let folderID, let name): sender = DriveSender(drive, folderID: folderID, name: name)
        }
        if isStopped { return .stopped }
        if case .failure(let error) = sender.begin() { return .failed(error.message) }

        var options = self.options
        options.splitSize = nil
        options.uploading = true
        let packer = Packer(source: source, destination: file, replaceExisting: true, options: options)
        state.withLock { $0.packer = packer }
        if isStopped {
            sender.abort()
            return .stopped
        }
        let packed = Locked<Packer.Outcome?>(nil)
        packer.start { outcome in packed.withLock { $0 = outcome } }

        // The pieces, sent as they're handed out.
        struct Piece: Sendable {
            let number: Int
            let offset: Int64
            let length: Int
            let total: Int64?
        }
        let pieces = WorkQueue<Piece>(limit: sender.parallel)
        let descriptor = Locked<Int32>(-1)
        let senders = DispatchGroup()
        for _ in 0..<sender.parallel {
            senders.enter()
            Thread.detachNewThread { [self] in
                defer { senders.leave() }
                while let piece = pieces.pop() {
                    let fd = descriptor.withLock { $0 }
                    var data = Data(count: piece.length)
                    let read = data.withUnsafeMutableBytes { Self.read(fd, $0.baseAddress!, piece.length, at: piece.offset) }
                    guard read else {
                        fail("Couldn't read the packed file back to send it.")
                        pieces.stop()
                        return
                    }
                    if case .failure(let error) = sender.send(piece.number, at: piece.offset, data, total: piece.total) {
                        fail(error.message)
                        pieces.stop()
                        return
                    }
                    // Sent: the disk can have that room back.
                    var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(piece.offset), fp_length: off_t(piece.length))
                    _ = fcntl(fd, F_PUNCHHOLE, &hole)
                    state.withLock { $0.progress.sent += Int64(piece.length) }
                }
            }
        }

        var number = 1
        var offset: Int64 = 0
        var outcome: Packer.Outcome?
        while true {
            outcome = packed.withLock { $0 }
            if state.withLock({ $0.failure != nil || $0.stopped }) { packer.cancel() }
            if descriptor.withLock({ $0 }) < 0 {
                // The file being written, or (packing already done) the one it became.
                var fd = open(file.path + ".part", O_RDWR | O_CLOEXEC)
                if fd < 0, case .finished = outcome { fd = open(file.path, O_RDWR | O_CLOEXEC) }
                descriptor.withLock { $0 = fd }
            }
            let progress = packer.progress()
            if descriptor.withLock({ $0 }) >= 0 && outcome == nil {
                // Whole pieces, keeping back at least a byte: the last piece is sent once the size is known.
                let size = Self.pieceSize(for: progress.totals, floor: pieceFloor)
                while progress.outputBytes - offset > size {
                    guard pieces.push(Piece(number: number, offset: offset, length: Int(size), total: nil)) else { break }
                    number += 1
                    offset += size
                }
            }
            if outcome != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        switch outcome {
        case .finished(let summary)?:
            let total = summary.archiveBytes
            let size = Self.pieceSize(for: packer.progress().totals, floor: pieceFloor)
            if descriptor.withLock({ $0 }) < 0 { fail("Couldn't open the packed file to send it.") }
            while offset < total && descriptor.withLock({ $0 }) >= 0 && state.withLock({ $0.failure == nil }) {
                let length = min(size, total - offset)
                let last = offset + length == total
                guard pieces.push(Piece(number: number, offset: offset, length: Int(length), total: last ? total : nil)) else { break }
                number += 1
                offset += length
            }
            pieces.finish()
            state.withLock { $0.progress.packed = true; $0.progress.packing = packer.progress() }
            senders.wait()
            close(descriptor.withLock { $0 })
            if isStopped {
                sender.abort()
                return .stopped
            }
            if let failure = state.withLock({ $0.failure }) {
                sender.abort()
                return .failed(failure)
            }
            switch sender.finish(total: total) {
            case .success(let item): return .finished(summary, item)
            case .failure(let error):
                sender.abort()
                return .failed(error.message)
            }
        case .stopped?, .failed?, nil:
            pieces.stop()
            senders.wait()
            let fd = descriptor.withLock { $0 }
            if fd >= 0 { close(fd) }
            sender.abort()
            if let failure = state.withLock({ $0.failure }) { return .failed(failure) }
            if case .failed(let message)? = outcome { return .failed(message) }
            return .stopped
        }
    }
}
