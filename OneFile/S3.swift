import Foundation
import CryptoKit

struct CloudError: Error, Sendable {
    let message: String
}

/// Amazon's request signing (Signature Version 4), as every S3-compatible service takes it:
/// Amazon S3, Cloudflare R2, Backblaze B2, Google Cloud Storage (with HMAC keys), Wasabi, MinIO.
struct SigV4: Sendable {
    let accessKey: String
    let secretKey: String
    let region: String
    var service = "s3"

    /// SHA-256 of nothing: the payload hash of a request without a body.
    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var text = ""
        for byte in bytes {
            text.append(String(format: "%02x", byte))
        }
        return text
    }

    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// "20130524" and "20130524T000000Z".
    static func stamps(_ date: Date) -> (day: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let time = formatter.string(from: date)
        return (String(time.prefix(8)), time)
    }

    /// Percent-encoded as SigV4 wants: everything but A–Z, a–z, 0–9, "-", ".", "_" and "~" (and "/"
    /// in a path).
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(UnicodeScalar(byte))
            case UInt8(ascii: "/") where keepSlash:
                out.append("/")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// The path and the query of `url` as they're signed: the path encoded once, the query's
    /// names and values encoded and sorted.
    static func canonical(_ url: URL) -> (path: String, query: String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let raw = components?.percentEncodedPath ?? ""
        let path = encode(raw.removingPercentEncoding ?? raw, keepSlash: true)
        let items = (components?.percentEncodedQueryItems ?? []).map { item -> (String, String) in
            let value = item.value ?? ""
            return (encode(item.name.removingPercentEncoding ?? item.name), encode(value.removingPercentEncoding ?? value))
        }
        let query = items.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        return (path.isEmpty ? "/" : path, query)
    }

    /// The Host header: the host, and the port if it isn't the scheme's own.
    static func host(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, !(url.scheme == "https" && port == 443) && !(url.scheme == "http" && port == 80) {
            return "\(host):\(port)"
        }
        return host
    }

    func signingKey(_ day: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return key
    }

    func signature(_ canonicalRequest: String, day: String, time: String) -> String {
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", time, scope, Self.sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signingKey(day)))
    }

    /// Signs a request: adds x-amz-date, x-amz-content-sha256 and Authorization. The host, a
    /// Range, a Content-Type and any x-amz- headers are signed.
    func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        guard let url = request.url else { return }
        let (day, time) = Self.stamps(date)
        request.setValue(time, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var headers: [(String, String)] = [("host", Self.host(url))]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower.hasPrefix("x-amz-") || lower == "range" || lower == "content-type" || lower == "content-md5" {
                headers.append((lower, value.trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.sort { $0.0 < $1.0 }
        let signed = headers.map(\.0).joined(separator: ";")
        let (path, query) = Self.canonical(url)
        let canonical = [request.httpMethod ?? "GET", path, query, headers.map { "\($0.0):\($0.1)\n" }.joined(),
                         signed, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(signature(canonical, day: day, time: time))",
                         forHTTPHeaderField: "Authorization")
    }

    /// A link anyone can open until it runs out (S3 allows up to 7 days).
    func presign(_ url: URL, method: String = "GET", expires seconds: Int, date: Date = Date()) -> URL {
        let (day, time) = Self.stamps(date)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.percentEncodedQueryItems ?? []
        items += [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(accessKey)/\(scope)"), ("X-Amz-Date", time),
                  ("X-Amz-Expires", "\(seconds)"), ("X-Amz-SignedHeaders", "host")]
            .map { URLQueryItem(name: $0.0, value: Self.encode($0.1)) }
        components.percentEncodedQueryItems = items
        guard let unsigned = components.url else { return url }
        let (path, query) = Self.canonical(unsigned)
        let canonical = [method, path, query, "host:\(Self.host(url))\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        items.append(URLQueryItem(name: "X-Amz-Signature", value: signature(canonical, day: day, time: time)))
        components.percentEncodedQueryItems = items
        return components.url ?? url
    }
}

/// What's in a folder in the cloud: an archive (or a part of one).
struct CloudItem: Sendable, Identifiable, Hashable {
    var id: String { key }
    /// The S3 key, or the Google Drive file's ID.
    let key: String
    let name: String
    let size: Int64
    let modified: Date?
}

/// A bucket at an S3-compatible service.
struct S3Bucket: Sendable {
    let endpoint: URL
    let bucket: String
    /// "endpoint/bucket/key" rather than "bucket.endpoint/key" (MinIO, R2, B2 and Google take
    /// both or only this; Amazon prefers the other).
    let pathStyle: Bool
    let signer: SigV4

    func url(_ key: String, query: [(String, String?)] = []) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return endpoint }
        let encodedKey = SigV4.encode(key, keepSlash: true)
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        if pathStyle {
            components.percentEncodedPath = base + "/" + SigV4.encode(bucket) + (key.isEmpty ? "" : "/" + encodedKey)
        } else {
            components.host = bucket + "." + (components.host ?? "")
            components.percentEncodedPath = base + "/" + encodedKey
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { name, value in
                value.map { SigV4.encode(name) + "=" + SigV4.encode($0) } ?? SigV4.encode(name)
            }.joined(separator: "&")
        }
        return components.url ?? endpoint
    }

    /// Sends a signed request (signed afresh for each try).
    func send(_ method: String, _ key: String, query: [(String, String?)] = [], body: Data? = nil,
              headers: [String: String] = [:]) -> Result<HTTP.Response, CloudError> {
        var request = URLRequest(url: url(key, query: query))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let hash = body.map { SigV4.sha256($0) } ?? SigV4.emptyHash
        let signer = self.signer
        switch HTTP.send(request, body: body, prepare: { signer.sign(&$0, payloadHash: hash) }) {
        case .success(let response): return .success(response)
        case .failure(let error): return .failure(CloudError(message: error.message))
        }
    }

    /// The service's own words for what went wrong.
    static func problem(_ response: HTTP.Response, doing what: String) -> CloudError {
        let leaves = XMLLeaves.parse(response.body)
        let code = leaves.first { $0.name == "Code" }?.text
        let message = leaves.first { $0.name == "Message" }?.text
        var text = "Couldn't \(what) (\(response.status)"
        if let code { text += " \(code)" }
        text += ")"
        if let message, !message.isEmpty { text += ": \(message)" }
        return CloudError(message: text + (text.hasSuffix(".") ? "" : "."))
    }

    /// Everything whose key starts with `prefix`.
    func list(prefix: String) -> Result<[CloudItem], CloudError> {
        var items: [CloudItem] = []
        var token: String?
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        repeat {
            var query: [(String, String?)] = [("list-type", "2"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let response: HTTP.Response
            switch send("GET", "", query: query) {
            case .success(let answer): response = answer
            case .failure(let error): return .failure(error)
            }
            guard response.status == 200 else { return .failure(Self.problem(response, doing: "list “\(bucket)”")) }
            token = nil
            var key: String?, size: Int64 = 0, modified: Date?
            func add() {
                if let key { items.append(CloudItem(key: key, name: (key as NSString).lastPathComponent, size: size, modified: modified)) }
                key = nil
                size = 0
                modified = nil
            }
            for leaf in XMLLeaves.parse(response.body) {
                switch (leaf.parent, leaf.name) {
                case ("Contents", "Key"):
                    add()
                    key = leaf.text
                case ("Contents", "Size"): size = Int64(leaf.text) ?? 0
                case ("Contents", "LastModified"):
                    modified = dates.date(from: leaf.text) ?? ISO8601DateFormatter().date(from: leaf.text)
                case (_, "NextContinuationToken"): token = leaf.text
                default: break
                }
            }
            add()
        } while token != nil
        return .success(items)
    }

    func startUpload(_ key: String) -> Result<String, CloudError> {
        switch send("POST", key, query: [("uploads", nil)], headers: ["Content-Type": "application/octet-stream"]) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard response.status == 200, let id = XMLLeaves.parse(response.body).first(where: { $0.name == "UploadId" })?.text else {
                return .failure(Self.problem(response, doing: "start sending to “\(bucket)”"))
            }
            return .success(id)
        }
    }

    /// Sends part `number` (from 1); its ETag.
    func uploadPart(_ key: String, uploadID: String, number: Int, body: Data) -> Result<String, CloudError> {
        switch send("PUT", key, query: [("partNumber", "\(number)"), ("uploadId", uploadID)], body: body) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard response.status == 200, let tag = response.headers["etag"] else {
                return .failure(Self.problem(response, doing: "send part \(number)"))
            }
            return .success(tag)
        }
    }

    func finishUpload(_ key: String, uploadID: String, tags: [String]) -> Result<Void, CloudError> {
        var xml = "<CompleteMultipartUpload>"
        for (index, tag) in tags.enumerated() {
            let escaped = tag.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            xml += "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(escaped)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        switch send("POST", key, query: [("uploadId", uploadID)], body: Data(xml.utf8), headers: ["Content-Type": "application/xml"]) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            // A 200 can still carry an error, in its body.
            guard response.status == 200, !XMLLeaves.parse(response.body).contains(where: { $0.name == "Code" }) else {
                return .failure(Self.problem(response, doing: "finish sending “\((key as NSString).lastPathComponent)”"))
            }
            return .success(())
        }
    }

    func abortUpload(_ key: String, uploadID: String) {
        _ = send("DELETE", key, query: [("uploadId", uploadID)])
    }

    func delete(_ key: String) -> Result<Void, CloudError> {
        switch send("DELETE", key) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            return response.status == 204 || response.status == 200 ? .success(()) : .failure(Self.problem(response, doing: "delete it"))
        }
    }

    /// The archive, to read with range requests (each one signed as it goes).
    func object(_ item: CloudItem) -> RemoteObject {
        let signer = self.signer
        return RemoteObject(url: url(item.key), size: item.size, authorize: { signer.sign(&$0, payloadHash: SigV4.emptyHash) })
    }

    /// A link anyone can download it with, for `days` (at most 7).
    func link(_ key: String, days: Int) -> URL {
        signer.presign(url(key), expires: max(1, min(days, 7)) * 86_400)
    }
}

/// A small reader for the XML that S3 answers with: each element's text, with its parent's name.
final class XMLLeaves: NSObject, XMLParserDelegate {
    struct Leaf {
        let parent: String
        let name: String
        let text: String
    }

    private var leaves: [Leaf] = []
    private var stack: [String] = []
    private var text = ""

    static func parse(_ data: Data) -> [Leaf] {
        guard !data.isEmpty else { return [] }
        let reader = XMLLeaves()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.leaves
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        stack.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        leaves.append(Leaf(parent: stack.last ?? "", name: elementName, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        text = ""
    }
}
