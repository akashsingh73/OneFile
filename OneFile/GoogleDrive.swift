import Foundation
import CryptoKit
import Network

/// Google Drive, through its API: signing in (in the browser, with the person's own Google Cloud
/// client: OneFile has none of its own to hand out), sending archives in pieces, reading them with
/// range requests, and sharing links. OneFile sees only the files it makes itself (the
/// drive.file permission), never the rest of the Drive.
final class GoogleDrive: @unchecked Sendable {
    /// Where the API is (another place only for the tests).
    static let api = ProcessInfo.processInfo.environment["ONEFILE_GOOGLE_API"] ?? "https://www.googleapis.com"
    static let tokenURL = ProcessInfo.processInfo.environment["ONEFILE_GOOGLE_TOKEN"] ?? "https://oauth2.googleapis.com/token"
    static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let scope = "https://www.googleapis.com/auth/drive.file"

    let clientID: String
    let clientSecret: String
    let refreshToken: String
    private let token = Locked<(value: String, expires: Date)?>(nil)

    init(clientID: String, clientSecret: String, refreshToken: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
    }

    // MARK: Signing in

    static func base64url<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// PKCE (RFC 7636): the challenge sent first is the SHA-256 of the verifier sent last, so a
    /// code caught on the way is no use to anyone else.
    static func challenge(_ verifier: String) -> String { base64url(SHA256.hash(data: Data(verifier.utf8))) }

    static func randomText(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64url((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func form(_ fields: [(String, String)]) -> Data {
        Data(fields.map { SigV4.encode($0.0) + "=" + SigV4.encode($0.1) }.joined(separator: "&").utf8)
    }

    /// Signs in with Google in the browser and returns the refresh token to keep. Google sends the
    /// browser back to OneFile on this Mac (127.0.0.1) with a code, which is swapped for tokens.
    /// Waits up to five minutes. Not on the main thread.
    static func signIn(clientID: String, clientSecret: String) -> Result<String, CloudError> {
        let verifier = randomText(48)
        let state = randomText(16)
        let redirect = LoopbackRedirect()
        guard let port = redirect.start() else { return .failure(CloudError(message: "Couldn't listen for Google's answer on this Mac.")) }
        defer { redirect.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"
        var components = URLComponents(string: authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { return .failure(CloudError(message: "Couldn't make the sign-in address.")) }
        openInBrowser(url)
        guard let query = redirect.wait(timeout: 300) else {
            return .failure(CloudError(message: "Google didn't send the browser back within five minutes."))
        }
        guard query["state"] == state else { return .failure(CloudError(message: "Google's answer didn't match the request.")) }
        guard let code = query["code"] else {
            return .failure(CloudError(message: "Google said no: \(query["error"] ?? "no reason given")."))
        }
        let body = form([("code", code), ("client_id", clientID), ("client_secret", clientSecret),
                         ("redirect_uri", redirectURI), ("grant_type", "authorization_code"), ("code_verifier", verifier)])
        switch tokens(body) {
        case .failure(let error): return .failure(error)
        case .success(let answer):
            guard let refresh = answer["refresh_token"] as? String else {
                return .failure(CloudError(message: "Google didn't give OneFile a lasting sign-in."))
            }
            return .success(refresh)
        }
    }

    static func openInBrowser(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    /// Asks Google's token endpoint; its answer as JSON.
    static func tokens(_ body: Data) -> Result<[String: Any], CloudError> {
        guard let url = URL(string: tokenURL) else { return .failure(CloudError(message: "No token address.")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        switch HTTP.send(request, body: body) {
        case .failure(let error): return .failure(CloudError(message: error.message))
        case .success(let response):
            let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
            guard response.status == 200 else {
                let reason = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "\(response.status)"
                return .failure(CloudError(message: "Google didn't sign OneFile in: \(reason)."))
            }
            return .success(json)
        }
    }

    /// A token for requests, renewed when it's about to run out.
    func accessToken() -> Result<String, CloudError> {
        if let current = token.withLock({ $0 }), current.expires > Date().addingTimeInterval(60) { return .success(current.value) }
        let body = Self.form([("client_id", clientID), ("client_secret", clientSecret), ("refresh_token", refreshToken),
                              ("grant_type", "refresh_token")])
        switch Self.tokens(body) {
        case .failure(let error): return .failure(error)
        case .success(let answer):
            guard let value = answer["access_token"] as? String else { return .failure(CloudError(message: "Google gave no token.")) }
            let seconds = (answer["expires_in"] as? Double) ?? Double(answer["expires_in"] as? Int ?? 3_600)
            token.withLock { $0 = (value, Date().addingTimeInterval(seconds)) }
            return .success(value)
        }
    }

    func authorize(_ request: inout URLRequest) {
        if case .success(let value) = accessToken() { request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization") }
    }

    // MARK: Requests

    func send(_ method: String, _ path: String, query: [(String, String)] = [], json: [String: Any]? = nil,
              body: Data? = nil, headers: [String: String] = [:]) -> Result<HTTP.Response, CloudError> {
        var components = URLComponents(string: Self.api + path)
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components?.url else { return .failure(CloudError(message: "Couldn't make the address.")) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        var payload = body
        if let json {
            payload = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        switch HTTP.send(request, body: payload, prepare: { [self] in authorize(&$0) }) {
        case .success(let response): return .success(response)
        case .failure(let error): return .failure(CloudError(message: error.message))
        }
    }

    static func problem(_ response: HTTP.Response, doing what: String) -> CloudError {
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        return CloudError(message: "Couldn't \(what) (\(response.status))" + (message.map { ": \($0)" } ?? "") + ".")
    }

    static func item(_ json: [String: Any]) -> CloudItem? {
        guard let id = json["id"] as? String else { return nil }
        let size = (json["size"] as? String).flatMap { Int64($0) } ?? (json["size"] as? Int64) ?? 0
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CloudItem(key: id, name: json["name"] as? String ?? id, size: size,
                         modified: (json["modifiedTime"] as? String).flatMap { dates.date(from: $0) })
    }

    /// The folder OneFile keeps archives in (made the first time).
    func folder(named name: String) -> Result<String, CloudError> {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let query = "name = '\(escaped)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        switch send("GET", "/drive/v3/files", query: [("q", query), ("fields", "files(id,name)"), ("spaces", "drive")]) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard response.status == 200 else { return .failure(Self.problem(response, doing: "find the folder “\(name)”")) }
            let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            if let found = (json?["files"] as? [[String: Any]])?.first?["id"] as? String { return .success(found) }
        }
        switch send("POST", "/drive/v3/files", query: [("fields", "id")],
                    json: ["name": name, "mimeType": "application/vnd.google-apps.folder"]) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            guard response.status == 200, let id = json?["id"] as? String else {
                return .failure(Self.problem(response, doing: "make the folder “\(name)”"))
            }
            return .success(id)
        }
    }

    func list(folderID: String) -> Result<[CloudItem], CloudError> {
        var items: [CloudItem] = []
        var page: String?
        repeat {
            var query = [("q", "'\(folderID)' in parents and trashed = false"),
                         ("fields", "nextPageToken,files(id,name,size,modifiedTime)"), ("pageSize", "1000")]
            if let page { query.append(("pageToken", page)) }
            switch send("GET", "/drive/v3/files", query: query) {
            case .failure(let error): return .failure(error)
            case .success(let response):
                guard response.status == 200 else { return .failure(Self.problem(response, doing: "list the folder")) }
                let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                items += ((json?["files"] as? [[String: Any]]) ?? []).compactMap(Self.item)
                page = json?["nextPageToken"] as? String
            }
        } while page != nil
        return .success(items)
    }

    /// Starts sending a file: the address its pieces go to.
    func startUpload(name: String, folderID: String) -> Result<URL, CloudError> {
        switch send("POST", "/upload/drive/v3/files", query: [("uploadType", "resumable"), ("fields", "id,name,size,modifiedTime")],
                    json: ["name": name, "parents": [folderID]], headers: ["X-Upload-Content-Type": "application/octet-stream"]) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard response.status == 200, let location = response.headers["location"], let url = URL(string: location) else {
                return .failure(Self.problem(response, doing: "start sending “\(name)”"))
            }
            return .success(url)
        }
    }

    /// Sends the piece at `offset`, in order. With `total` (the last piece), the file is done: what
    /// Drive made of it.
    func uploadPiece(_ session: URL, offset: Int64, _ data: Data, total: Int64?) -> Result<CloudItem?, CloudError> {
        var request = URLRequest(url: session)
        request.httpMethod = "PUT"
        let end = offset + Int64(data.count) - 1
        request.setValue("bytes \(offset)-\(end)/\(total.map(String.init) ?? "*")", forHTTPHeaderField: "Content-Range")
        switch HTTP.send(request, body: data, prepare: { [self] in authorize(&$0) }) {
        case .failure(let error): return .failure(CloudError(message: error.message))
        case .success(let response):
            if response.status == 308 { return .success(nil) }
            guard response.status == 200 || response.status == 201 else {
                return .failure(Self.problem(response, doing: "send a piece"))
            }
            let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
            return .success(Self.item(json))
        }
    }

    func cancelUpload(_ session: URL) {
        var request = URLRequest(url: session)
        request.httpMethod = "DELETE"
        _ = HTTP.send(request, attempts: 1)
    }

    /// The file, to read with range requests.
    func object(_ item: CloudItem) -> RemoteObject {
        let url = URL(string: Self.api + "/drive/v3/files/\(item.key)?alt=media") ?? URL(fileURLWithPath: "/")
        return RemoteObject(url: url, size: item.size, authorize: { [self] in authorize(&$0) })
    }

    /// Lets anyone with the link see the file, and the link.
    func share(_ item: CloudItem) -> Result<URL, CloudError> {
        switch send("POST", "/drive/v3/files/\(item.key)/permissions", json: ["role": "reader", "type": "anyone"]) {
        case .failure(let error): return .failure(error)
        case .success(let response):
            guard response.status == 200 else { return .failure(Self.problem(response, doing: "share it")) }
            return .success(URL(string: "https://drive.google.com/file/d/\(item.key)/view?usp=sharing")!)
        }
    }

    func delete(_ item: CloudItem) -> Result<Void, CloudError> {
        switch send("DELETE", "/drive/v3/files/\(item.key)") {
        case .failure(let error): return .failure(error)
        case .success(let response):
            return response.status == 204 || response.status == 200 ? .success(()) : .failure(Self.problem(response, doing: "delete it"))
        }
    }
}

/// Listens on 127.0.0.1 for the browser coming back from signing in, once.
final class LoopbackRedirect: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "OneFile.signIn")
    private let arrived = DispatchSemaphore(value: 0)
    private let query = Locked<[String: String]?>(nil)

    /// Starts listening; the port.
    func start() -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                var fields: [String: String] = [:]
                for item in URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? [] { fields[item.name] = item.value ?? "" }
                let page = "<!doctype html><meta charset=utf-8><title>OneFile</title><body style=\"font: 15px -apple-system; padding: 40px\">"
                    + (fields["code"] != nil ? "Signed in. You can close this tab and go back to OneFile." : "Not signed in. Go back to OneFile to try again.")
                let answer = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
                // Browsers also ask for a favicon: only the answer with a code or an error counts.
                if fields["code"] != nil || fields["error"] != nil {
                    query.withLock { $0 = fields }
                    arrived.signal()
                }
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue
    }

    func wait(timeout: TimeInterval) -> [String: String]? {
        guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
        return query.withLock { $0 }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
