import Foundation
import Network

/// A small S3 for the tests, on 127.0.0.1: objects, multipart uploads, ranges and listing, with
/// every request's signature checked the way S3 checks it (presigned links too).
final class FakeS3: @unchecked Sendable {
    let accessKey = "AKIDTESTKEY"
    let secretKey = "test/secret+key="
    let region = "us-east-1"
    let objects = Locked([String: Data]())
    let parts = Locked(0)
    let rejected = Locked(0)
    private let uploads = Locked([String: (id: String, parts: [Int: Data])]())
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "FakeS3", attributes: .concurrent)
    private(set) var port: UInt16 = 0

    var endpoint: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var pendingUploads: Int { uploads.withLock { $0.count } }

    func start() -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return false }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
        self.listener = listener
        return port != 0
    }

    func stop() { listener?.cancel() }

    private struct Request {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                connection.send(content: handle(request), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            receive(connection, buffer)
        }
    }

    private func parse(_ data: Data) -> Request? {
        let bytes = [UInt8](data)
        guard let end = (0..<max(0, bytes.count - 3)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }) else {
            return nil
        }
        var lines = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard bytes.count - (end + 4) >= length else { return nil }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers,
                       body: Data(bytes[(end + 4)..<(end + 4 + length)]))
    }

    /// Checks the request's signature, as S3 would.
    private func verify(_ request: Request) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)" + request.target),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let signer = SigV4(accessKey: accessKey, secretKey: secretKey, region: region)
        let items = components.percentEncodedQueryItems ?? []
        if let signature = items.first(where: { $0.name == "X-Amz-Signature" })?.value {
            guard let time = items.first(where: { $0.name == "X-Amz-Date" })?.value else { return false }
            components.percentEncodedQueryItems = items.filter { $0.name != "X-Amz-Signature" }
            guard let unsigned = components.url else { return false }
            let (path, query) = SigV4.canonical(unsigned)
            let canonical = [request.method, path, query, "host:\(request.headers["host"] ?? "")\n", "host", "UNSIGNED-PAYLOAD"]
                .joined(separator: "\n")
            return signer.signature(canonical, day: String(time.prefix(8)), time: time) == signature
        }
        guard let authorization = request.headers["authorization"], let time = request.headers["x-amz-date"],
              let payload = request.headers["x-amz-content-sha256"] else { return false }
        var fields: [String: String] = [:]
        for part in authorization.dropFirst("AWS4-HMAC-SHA256 ".count).components(separatedBy: ", ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard fields["Credential"]?.hasPrefix(accessKey + "/") == true, let names = fields["SignedHeaders"]?.split(separator: ";").map(String.init),
              let signature = fields["Signature"] else { return false }
        let (path, query) = SigV4.canonical(url)
        let canonical = [request.method, path, query, names.map { "\($0):\(request.headers[$0] ?? "")\n" }.joined(),
                         names.joined(separator: ";"), payload].joined(separator: "\n")
        return signer.signature(canonical, day: String(time.prefix(8)), time: time) == signature
            && (payload == "UNSIGNED-PAYLOAD" || payload == SigV4.sha256(request.body))
    }

    private func respond(_ status: Int, _ body: String = "", data: Data? = nil, headers: [String: String] = [:]) -> Data {
        let content = data ?? Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Error")\r\nContent-Length: \(content.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + content
    }

    private func handle(_ request: Request) -> Data {
        guard verify(request) else {
            rejected.withLock { $0 += 1 }
            return respond(403, "<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message></Error>")
        }
        guard let components = URLComponents(string: "http://x" + request.target) else { return respond(400) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = String(components.path.dropFirst())
        let bucket = String(path.prefix { $0 != "/" })
        let key = String(path.dropFirst(bucket.count).dropFirst())
        let id = bucket + "/" + key
        switch request.method {
        case "GET" where key.isEmpty:
            let prefix = bucket + "/" + (query["prefix"] ?? "")
            let found = objects.withLock { $0.filter { $0.key.hasPrefix(prefix) } }.sorted { $0.key < $1.key }
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>\(bucket)</Name><IsTruncated>false</IsTruncated>"
            for (name, data) in found {
                xml += "<Contents><Key>\(name.dropFirst(bucket.count + 1))</Key><LastModified>2026-11-24T10:00:00.000Z</LastModified><Size>\(data.count)</Size></Contents>"
            }
            return respond(200, xml + "</ListBucketResult>")
        case "POST" where query["uploads"] != nil:
            let upload = UUID().uuidString
            uploads.withLock { $0[upload] = (id, [:]) }
            return respond(200, "<InitiateMultipartUploadResult><Key>\(key)</Key><UploadId>\(upload)</UploadId></InitiateMultipartUploadResult>")
        case "PUT" where query["uploadId"] != nil:
            guard let number = Int(query["partNumber"] ?? ""), let upload = query["uploadId"],
                  uploads.withLock({ $0[upload] != nil }) else { return respond(404, "<Error><Code>NoSuchUpload</Code></Error>") }
            uploads.withLock { $0[upload]?.parts[number] = request.body }
            parts.withLock { $0 += 1 }
            return respond(200, headers: ["ETag": "\"\(SigV4.sha256(request.body).prefix(32))\""])
        case "POST" where query["uploadId"] != nil:
            guard let upload = query["uploadId"], let started = uploads.withLock({ $0[upload] }) else {
                return respond(404, "<Error><Code>NoSuchUpload</Code></Error>")
            }
            var whole = Data()
            let leaves = XMLLeaves.parse(request.body)
            let numbers = leaves.filter { $0.name == "PartNumber" }.compactMap { Int($0.text) }
            let tags = leaves.filter { $0.name == "ETag" }.map(\.text)
            for (number, tag) in zip(numbers, tags) {
                guard let part = started.parts[number], tag == "\"\(SigV4.sha256(part).prefix(32))\"" else {
                    return respond(400, "<Error><Code>InvalidPart</Code></Error>")
                }
                whole.append(part)
            }
            objects.withLock { $0[started.id] = whole }
            uploads.withLock { $0[upload] = nil }
            return respond(200, "<CompleteMultipartUploadResult><Key>\(key)</Key></CompleteMultipartUploadResult>")
        case "DELETE" where query["uploadId"] != nil:
            uploads.withLock { $0[query["uploadId"] ?? ""] = nil }
            return respond(204)
        case "PUT":
            objects.withLock { $0[id] = request.body }
            return respond(200)
        case "GET":
            guard let data = objects.withLock({ $0[id] }) else { return respond(404, "<Error><Code>NoSuchKey</Code></Error>") }
            if let range = request.headers["range"], range.hasPrefix("bytes=") {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard let start = bounds.first, start < data.count else {
                    return respond(416, headers: ["Content-Range": "bytes */\(data.count)"])
                }
                let end = min(bounds.count > 1 ? bounds[1] : data.count - 1, data.count - 1)
                return respond(206, data: data.subdata(in: start..<(end + 1)), headers: ["Content-Range": "bytes \(start)-\(end)/\(data.count)"])
            }
            return respond(200, data: data)
        case "DELETE":
            objects.withLock { $0[id] = nil }
            return respond(204)
        default:
            return respond(400)
        }
    }
}

extension OneFileTests {
    static func waitFor(_ upload: CloudPack) -> CloudPack.Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<CloudPack.Outcome?>(nil)
        upload.start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }!
    }

    static func cloudTests(_ fixture: Fixture, _ c: Checks) {
        c.section("Cloud: signing requests (Amazon's own examples)")
        let example = SigV4(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        func signature(_ address: String, range: String? = nil) -> String {
            var request = URLRequest(url: URL(string: address)!)
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            example.sign(&request, payloadHash: SigV4.emptyHash, date: date)
            return request.value(forHTTPHeaderField: "Authorization") ?? ""
        }
        let get = signature("https://examplebucket.s3.amazonaws.com/test.txt", range: "bytes=0-9")
        c.expect(get == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
                 "GET Object, with a range: \(get)")
        c.expect(signature("https://examplebucket.s3.amazonaws.com/?lifecycle").hasSuffix("Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"),
                 "GET Bucket Lifecycle (a query without a value)")
        c.expect(signature("https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J").hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"),
                 "GET Bucket (listing)")
        let presigned = example.presign(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, expires: 86_400, date: date)
        c.expect(presigned.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
                 "a presigned link: \(presigned.absoluteString)")
        c.expect(SigV4.encode("Photos 2026/naïve+plus.tar.gz", keepSlash: true) == "Photos%202026/na%C3%AFve%2Bplus.tar.gz", "keys are encoded as S3 wants")

        c.section("Cloud: Google sign-in (RFC 7636's example)")
        c.expect(GoogleDrive.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                 "the code challenge is the verifier's SHA-256")
        c.expect(CloudPack.pieceSize(for: nil) == 16 << 20, "pieces of 16 MB")
        var huge = Packer.Totals()
        huge.archiveBytes = 1 << 40
        c.expect(CloudPack.pieceSize(for: huge) * 9_000 >= 1 << 40, "big enough that 10,000 hold a 1 TB archive")

        let server = FakeS3()
        guard server.start() else {
            c.fail("couldn't start the test S3")
            return
        }
        defer { server.stop() }
        let signer = SigV4(accessKey: server.accessKey, secretKey: server.secretKey, region: server.region)
        let bucket = S3Bucket(endpoint: server.endpoint, bucket: "test-bucket", pathStyle: true, signer: signer)
        let place = CloudPlace.s3(bucket, prefix: "OneFile/")
        let fm = FileManager.default
        let base = fixture.base + "/cloud"
        let tree = base + "/Tree"
        makeTree(tree)

        c.section("Cloud: packing to S3, sent as it's packed")
        let upload = CloudPack(source: URL(fileURLWithPath: tree), target: place.target("Tree.tar.gz"),
                               options: Packer.Options(leaveOut: [".DS_Store"], method: .gzip), pieceFloor: 1 << 20)
        guard case .finished(let summary, let item) = waitFor(upload) else {
            c.fail("packing to the cloud didn't finish")
            return
        }
        c.expect(item.key == "OneFile/Tree.tar.gz" && item.size == summary.archiveBytes
                 && server.objects.withLock({ $0["test-bucket/OneFile/Tree.tar.gz"]?.count }) == Int(item.size),
                 "the archive is in the bucket, whole")
        c.expect(server.parts.withLock { $0 } >= 8, "sent in \(server.parts.withLock { $0 }) pieces")
        c.expect(server.rejected.withLock { $0 } == 0, "every request was signed right")
        c.expect(server.pendingUploads == 0, "nothing left half sent")
        let temporary = (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []
        c.expect(!temporary.contains { $0.hasPrefix("OneFile upload") }, "and nothing left on the disk")

        let listed = (try? Cloud.archives(in: place).get()) ?? []
        c.expect(listed.map(\.name) == ["Tree.tar.gz"] && listed.first?.size == item.size, "listed: \(listed.map(\.name))")

        c.section("Cloud: reading straight from it")
        let address = Cloud.open(item, in: place)
        guard case .success(let input) = InputFile.open(address, password: nil),
              case .success(let format) = ArchiveFormat.detect(input, name: item.name),
              let index = ArchiveIndex.read(input, format: format) else {
            c.fail("couldn't read the index from the cloud")
            return
        }
        c.expect(index.entries.filter { $0.kind == .file }.count == 61, "the index, read with a few range requests")
        if let big = index.entries.first(where: { $0.path == "Tree/big.bin" }) {
            let out = base + "/taken"
            try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            let extractor = Extractor(archive: address, index: index, format: format, chosen: [big], destination: URL(fileURLWithPath: out))
            let taken = Locked<Extractor.Outcome?>(nil)
            let finished = DispatchSemaphore(value: 0)
            extractor.start { outcome in
                taken.withLock { $0 = outcome }
                finished.signal()
            }
            finished.wait()
            if case .finished(let result) = taken.withLock({ $0 })! {
                c.expect(result.files == 1 && result.mismatched == 0 && fm.contentsEqual(atPath: out + "/big.bin", andPath: tree + "/big.bin"),
                         "one file taken out of it, checked against its SHA-256")
            } else {
                c.fail("taking one file out of the cloud failed")
            }
        }
        let unpacked = base + "/unpacked"
        try? fm.createDirectory(atPath: unpacked, withIntermediateDirectories: true)
        if case .finished = wait(Unpacker(source: .file(address), destination: URL(fileURLWithPath: unpacked))) {
            c.expect(compare(tree, unpacked + "/Tree", contents: true)?.identical == true, "unpacked straight from the cloud, byte for byte")
        } else {
            c.fail("unpacking from the cloud failed")
        }

        c.section("Cloud: a link anyone can open")
        let link = bucket.link(item.key, days: 7)
        c.expect(link.query?.contains("X-Amz-Expires=604800") == true, "good for 7 days")
        if case .success(let objects) = Remote.objects(for: link) {
            c.expect(objects.first?.size == item.size, "its size, from the link alone")
        } else {
            c.fail("couldn't open the link")
        }
        let fromLink = base + "/from-link"
        try? fm.createDirectory(atPath: fromLink, withIntermediateDirectories: true)
        if case .finished = wait(Unpacker(source: .file(link), destination: URL(fileURLWithPath: fromLink))) {
            c.expect(compare(tree, fromLink + "/Tree", contents: true)?.identical == true, "unpacked from the link")
        } else {
            c.fail("unpacking from the link failed")
        }

        c.section("Cloud: a .tar.zst, read straight from it")
        if case .finished(_, let zstdItem) = waitFor(CloudPack(source: URL(fileURLWithPath: tree), target: place.target("Tree.tar.zst"),
                                                               options: Packer.Options(leaveOut: [".DS_Store"], method: .zstd),
                                                               pieceFloor: 1 << 20)) {
            let zstdAddress = Cloud.open(zstdItem, in: place)
            if case .success(let input) = InputFile.open(zstdAddress, password: nil),
               case .success(let format) = ArchiveFormat.detect(input, name: zstdItem.name),
               let index = ArchiveIndex.read(input, format: format),
               let big = index.entries.first(where: { $0.path == "Tree/big.bin" }) {
                c.expect(format == .zstd && index.blocks.count >= 2, "the index, with \(index.blocks.count) frames mapped")
                let out = base + "/zst-taken"
                try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
                let extractor = Extractor(archive: zstdAddress, index: index, format: format, chosen: [big],
                                          destination: URL(fileURLWithPath: out))
                let taken = Locked<Extractor.Outcome?>(nil)
                let finished = DispatchSemaphore(value: 0)
                extractor.start { outcome in
                    taken.withLock { $0 = outcome }
                    finished.signal()
                }
                finished.wait()
                if case .finished(let result) = taken.withLock({ $0 })! {
                    c.expect(result.mismatched == 0 && fm.contentsEqual(atPath: out + "/big.bin", andPath: tree + "/big.bin"),
                             "one file taken out of it")
                } else {
                    c.fail("taking one file out of a .tar.zst in the cloud failed")
                }
            } else {
                c.fail("couldn't read the .tar.zst's index from the cloud")
            }
            let zstdUnpacked = base + "/zst-unpacked"
            try? fm.createDirectory(atPath: zstdUnpacked, withIntermediateDirectories: true)
            if case .finished(let summary) = wait(Unpacker(source: .file(zstdAddress), destination: URL(fileURLWithPath: zstdUnpacked))) {
                c.expect(summary.parallel && compare(tree, zstdUnpacked + "/Tree", contents: true)?.identical == true,
                         "unpacked straight from the cloud on every core, byte for byte")
            } else {
                c.fail("unpacking a .tar.zst from the cloud failed")
            }
        } else {
            c.fail("packing a .tar.zst to the cloud didn't finish")
        }

        c.section("Cloud: locked, stopped, refused")
        var locked = Packer.Options(leaveOut: [".DS_Store"], method: .gzip)
        locked.password = "cloudy"
        locked.ageWorkFactor = 10
        if case .finished(_, let lockedItem) = waitFor(CloudPack(source: URL(fileURLWithPath: tree), target: place.target("Tree.tar.gz.age"),
                                                                 options: locked, pieceFloor: 1 << 20)) {
            let out = base + "/locked"
            try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            let address = Cloud.open(lockedItem, in: place)
            if case .finished = wait(Unpacker(source: .file(address), destination: URL(fileURLWithPath: out), password: "cloudy")) {
                c.expect(compare(tree, out + "/Tree", contents: true)?.identical == true, "a locked archive, sent and unpacked")
            } else {
                c.fail("unpacking the locked archive failed")
            }
        } else {
            c.fail("packing a locked archive to the cloud failed")
        }
        let stopping = CloudPack(source: URL(fileURLWithPath: tree), target: place.target("Stopped.tar.gz"),
                                 options: Packer.Options(leaveOut: [], method: .xz), pieceFloor: 1 << 20)
        let stopped = Locked<CloudPack.Outcome?>(nil)
        let done = DispatchSemaphore(value: 0)
        stopping.start { outcome in
            stopped.withLock { $0 = outcome }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        stopping.cancel()
        done.wait()
        if case .stopped = stopped.withLock({ $0 })! {
            c.expect(server.objects.withLock { $0["test-bucket/OneFile/Stopped.tar.gz"] } == nil && server.pendingUploads == 0,
                     "stopped: nothing in the bucket, and the upload is taken back")
        } else {
            c.expect(server.pendingUploads == 0, "finished before it could be stopped (it's small), and nothing's left half sent")
        }
        let wrong = S3Bucket(endpoint: server.endpoint, bucket: "test-bucket", pathStyle: true,
                             signer: SigV4(accessKey: server.accessKey, secretKey: "not the secret", region: server.region))
        if case .failure(let error) = wrong.list(prefix: "") {
            c.expect(error.message.contains("SignatureDoesNotMatch"), "a wrong secret key is told: \(error.message)")
        } else {
            c.fail("a wrong secret key was let in")
        }

        guard ProcessInfo.processInfo.environment["ONEFILE_CLI"] != nil else { return }
        c.section("onefile and the cloud")
        let environment = ["AWS_ACCESS_KEY_ID": server.accessKey, "AWS_SECRET_ACCESS_KEY": server.secretKey,
                           "AWS_REGION": server.region, "AWS_ENDPOINT_URL": server.endpoint.absoluteString]
        var run = onefile(["pack", tree, "--to", "s3://test-bucket/cli/", "--link"], environment: environment)
        c.expect(run.status == 0 && run.output.contains("sent “Tree.tar.gz”") && run.output.contains("X-Amz-Signature="),
                 "packs to s3://, and gives a link: \(run.output)\(run.errors)")
        run = onefile(["cloud", "files", "s3://test-bucket/cli"], environment: environment)
        c.expect(run.status == 0 && run.output.contains("Tree.tar.gz"), "lists what's there: \(run.output)\(run.errors)")
        run = onefile(["list", "s3://test-bucket/cli/Tree.tar.gz"], environment: environment)
        c.expect(run.status == 0 && run.output.contains("Tree/f0/sub0/file-0.txt"), "lists what's in it, from the cloud")
        run = onefile(["unpack", "s3://test-bucket/cli/Tree.tar.gz", "--to", base + "/cli-unpacked"], environment: environment)
        c.expect(run.status == 0 && compare(tree, base + "/cli-unpacked/Tree", contents: true)?.identical == true,
                 "unpacks from the cloud: \(run.errors)")
        run = onefile(["link", "s3://test-bucket/cli/Tree.tar.gz", "--days", "2"], environment: environment)
        let shared = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        c.expect(run.status == 0 && shared.contains("X-Amz-Expires=172800"), "a link for 2 days")
        run = onefile(["check", shared])
        c.expect(run.status == 0 && run.output.contains("match their SHA-256"), "checked from the link, without signing in: \(run.errors)")
        run = onefile(["cloud", "delete", "s3://test-bucket/cli/Tree.tar.gz", "--yes"], environment: environment)
        c.expect(run.status == 0 && server.objects.withLock { $0["test-bucket/cli/Tree.tar.gz"] } == nil, "deletes it")
        run = onefile(["unpack", "s3://test-bucket/cli/Tree.tar.gz"], environment: environment)
        c.expect(run.status == 1, "then it isn't there")
    }
}
