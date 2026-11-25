import Foundation

/// An archive on the internet: at a web address that answers range requests (a link to a file,
/// or a file in cloud storage), and what each request needs to be let in.
struct RemoteObject: Sendable {
    let url: URL
    let size: Int64
    /// Adds what the server needs to each request (a signature, a sign-in token).
    var authorize: (@Sendable (inout URLRequest) -> Void)?
}

/// Requests to web servers and cloud storage, waited for, and tried again when the connection
/// fails or the server says it's busy.
enum HTTP {
    struct Response: Sendable {
        let status: Int
        /// Header names in lower case.
        let headers: [String: String]
        let body: Data
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Statuses worth trying again: the server is busy, or briefly broken.
    static func isTransient(_ status: Int) -> Bool { [408, 429, 500, 502, 503, 504].contains(status) }

    /// Sends `request` (with `body`, if any) and waits for the answer. `prepare` runs before each
    /// attempt (to sign it afresh). A failed connection or a busy server is tried again, up to
    /// `attempts` times in all, waiting longer each time.
    static func send(_ request: URLRequest, body: Data? = nil, attempts: Int = 4,
                     prepare: (@Sendable (inout URLRequest) -> Void)? = nil) -> Result<Response, DecodeError> {
        var last = DecodeError(message: "Couldn't reach \(request.url?.host ?? "the server").")
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { Thread.sleep(forTimeInterval: min(8, 0.5 * pow(2, Double(attempt - 1)))) }
            var prepared = request
            prepare?(&prepared)
            let host = prepared.url?.host ?? "the server"
            let done = DispatchSemaphore(value: 0)
            let answer = Locked<Result<Response, DecodeError>?>(nil)
            let finished: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                if let response = response as? HTTPURLResponse {
                    var headers: [String: String] = [:]
                    for (key, value) in response.allHeaderFields {
                        if let key = key as? String { headers[key.lowercased()] = "\(value)" }
                    }
                    answer.withLock { $0 = .success(Response(status: response.statusCode, headers: headers, body: data ?? Data())) }
                } else {
                    let reason = (error as? URLError)?.localizedDescription ?? error?.localizedDescription ?? "no answer"
                    answer.withLock { $0 = .failure(DecodeError(message: "Couldn't reach \(host): \(reason)")) }
                }
                done.signal()
            }
            let task = body.map { session.uploadTask(with: prepared, from: $0, completionHandler: finished) }
                ?? session.dataTask(with: prepared, completionHandler: finished)
            task.resume()
            done.wait()
            switch answer.withLock({ $0 })! {
            case .success(let response):
                if isTransient(response.status) && attempt + 1 < attempts {
                    last = DecodeError(message: "\(host) is busy (\(response.status)).")
                    continue
                }
                return .success(response)
            case .failure(let error):
                last = error
            }
        }
        return .failure(last)
    }
}

/// Reads an archive on the internet as if it were a file on the disk, in pieces, with range
/// requests. Read from start to end (unpacking, checking), the next pieces are asked for ahead,
/// many at once, so it goes at the connection's speed; read here and there (listing what's in it,
/// taking one file out), only the pieces needed are fetched.
final class RemoteFile: @unchecked Sendable {
    let objects: [RemoteObject]
    /// Where each object starts in the whole (a split archive is several).
    private let starts: [Int64]
    let size: Int64

    static let piece: Int64 = 2 << 20
    /// Pieces asked for ahead, reading in order, and pieces kept.
    static let ahead = 16
    static let kept = 32

    private struct PieceID: Hashable {
        let object: Int
        let index: Int64
    }

    private let condition = NSCondition()
    private var pieces: [PieceID: Data] = [:]
    private var fetching: Set<PieceID> = []
    private var failed: [PieceID: String] = [:]
    private var used: [PieceID] = []
    private var lastRead: PieceID?
    /// Why the last read failed, if it did.
    private(set) var failure: String?

    init(_ objects: [RemoteObject]) {
        self.objects = objects
        var starts: [Int64] = []
        var total: Int64 = 0
        for object in objects {
            starts.append(total)
            total += object.size
        }
        self.starts = starts
        size = total
    }

    /// Reads exactly `count` bytes at `offset`; false if they can't be had.
    func read(_ count: Int, at offset: Int64, into buffer: UnsafeMutableRawPointer) -> Bool {
        var done = 0
        while done < count {
            let position = offset + Int64(done)
            guard position < size else { return false }
            var object = objects.count - 1
            while starts[object] > position { object -= 1 }
            let within = position - starts[object]
            let id = PieceID(object: object, index: within / Self.piece)
            guard let data = piece(id) else { return false }
            let skip = Int(within - id.index * Self.piece)
            let take = min(count - done, data.count - skip)
            guard take > 0 else { return false }
            data.withUnsafeBytes { buffer.advanced(by: done).copyMemory(from: $0.baseAddress! + skip, byteCount: take) }
            done += take
        }
        return true
    }

    private func pieceCount(_ object: Int) -> Int64 { (objects[object].size + Self.piece - 1) / Self.piece }

    private func next(after id: PieceID) -> PieceID? {
        if id.index + 1 < pieceCount(id.object) { return PieceID(object: id.object, index: id.index + 1) }
        var object = id.object + 1
        while object < objects.count {
            if pieceCount(object) > 0 { return PieceID(object: object, index: 0) }
            object += 1
        }
        return nil
    }

    private func piece(_ id: PieceID) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        // In order: the next pieces are asked for now, so they're here when they're wanted.
        let inOrder = lastRead.map { $0 == id || next(after: $0) == id } ?? (id.index == 0)
        lastRead = id
        if pieces[id] == nil && !fetching.contains(id) { fetch(id) }
        if inOrder {
            var ahead = id
            for _ in 0..<Self.ahead {
                guard let following = next(after: ahead) else { break }
                ahead = following
                if pieces[ahead] == nil && !fetching.contains(ahead) && failed[ahead] == nil { fetch(ahead) }
            }
        }
        while pieces[id] == nil {
            if let reason = failed[id] {
                failed[id] = nil
                failure = reason
                return nil
            }
            // Fetched, then let go to make room before this read got to it: fetched again.
            if !fetching.contains(id) { fetch(id) }
            condition.wait()
        }
        used.removeAll { $0 == id }
        used.append(id)
        // Keep the most recent; the rest go (none that are on their way).
        while used.count > Self.kept {
            let oldest = used.removeFirst()
            pieces[oldest] = nil
        }
        return pieces[id]
    }

    /// Asks for a piece (the lock is held).
    private func fetch(_ id: PieceID) {
        fetching.insert(id)
        failed[id] = nil
        let object = objects[id.object]
        let start = id.index * Self.piece
        let end = min(object.size, start + Self.piece) - 1
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var request = URLRequest(url: object.url)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            let result = HTTP.send(request, prepare: object.authorize)
            condition.lock()
            fetching.remove(id)
            switch result {
            case .success(let response) where (response.status == 206 || (response.status == 200 && start == 0 && end == object.size - 1))
                                              && Int64(response.body.count) == end - start + 1:
                pieces[id] = response.body
                if !used.contains(id) { used.append(id) }
            case .success(let response):
                failed[id] = Remote.problem(response.status, object.url)
            case .failure(let error):
                failed[id] = error.message
            }
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// Opening archives on the internet the way files are opened.
enum Remote {
    /// Objects in cloud storage, given an address to be opened by (`onefile-remote://ID/Name`).
    private static let registered = Locked([String: [RemoteObject]]())

    static func register(_ objects: [RemoteObject], name: String) -> URL {
        let id = UUID().uuidString
        registered.withLock { $0[id] = objects }
        var components = URLComponents()
        components.scheme = "onefile-remote"
        components.host = id
        components.path = "/" + name
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func isRemote(_ url: URL) -> Bool {
        ["http", "https", "onefile-remote"].contains(url.scheme?.lowercased() ?? "")
    }

    /// What's at the address: one object, or every part of a split archive ("….001", "….002"…).
    static func objects(for url: URL) -> Result<[RemoteObject], DecodeError> {
        if url.scheme == "onefile-remote" {
            guard let objects = registered.withLock({ $0[url.host ?? ""] }) else {
                return .failure(DecodeError(message: "“\(url.lastPathComponent)” isn't open any more."))
            }
            return .success(objects)
        }
        let first: Int64
        switch size(of: url, authorize: nil) {
        case .success(let size): first = size
        case .failure(let error): return .failure(error)
        }
        var objects = [RemoteObject(url: url, size: first)]
        // Parts: "….002" and on, at the same place (a signed link can't be changed into another).
        if url.query == nil, SplitParts.isPartName(url.lastPathComponent), url.lastPathComponent.hasSuffix(".001") {
            let base = url.deletingLastPathComponent()
            let stem = String(url.lastPathComponent.dropLast(4))
            for number in 2...999 {
                let part = base.appendingPathComponent(stem + String(format: ".%03d", number))
                guard case .success(let size) = Self.size(of: part, authorize: nil) else { break }
                objects.append(RemoteObject(url: part, size: size))
            }
        }
        return .success(objects)
    }

    /// The size of what's at `url`, from asking for its first byte (which a link signed for
    /// reading allows, where asking only for its size might not be).
    static func size(of url: URL, authorize: (@Sendable (inout URLRequest) -> Void)?) -> Result<Int64, DecodeError> {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        switch HTTP.send(request, prepare: authorize) {
        case .failure(let error):
            return .failure(error)
        case .success(let response):
            switch response.status {
            case 206:
                guard let range = response.headers["content-range"], let slash = range.lastIndex(of: "/"),
                      let total = Int64(range[range.index(after: slash)...]) else {
                    return .failure(DecodeError(message: "\(url.host ?? "The server") didn't say how big “\(url.lastPathComponent)” is."))
                }
                return .success(total)
            case 416:
                return .success(0)
            case 200:
                return .failure(DecodeError(message: "\(url.host ?? "The server") sends “\(url.lastPathComponent)” only whole, not in parts: download it, then open the file."))
            default:
                return .failure(DecodeError(message: problem(response.status, url)))
            }
        }
    }

    static func problem(_ status: Int, _ url: URL) -> String {
        switch status {
        case 401, 403: "\(url.host ?? "The server") said no to “\(url.lastPathComponent)” (\(status)): the link may have run out, or need signing in."
        case 404: "There's nothing at that address (“\(url.lastPathComponent)”)."
        default: "\(url.host ?? "The server") answered \(status) for “\(url.lastPathComponent)”."
        }
    }
}
