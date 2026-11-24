import Foundation
import Network
import CryptoKit

// MARK: - The wire

/// How two OneFiles talk. Every message is a frame: a kind (1 byte), a length (4 bytes, big-endian)
/// and that many bytes.
///
/// 1. The sender says hello, with a commitment to its key (a SHA-256 of it); the receiver replies
///    with its key; the sender reveals its key, and the receiver checks it against the commitment.
///    Both now share a secret (X25519) that nobody watching can work out.
/// 2. From that secret and everything said so far, both work out a 6-digit code and show it. Someone
///    in the middle would have to pick their keys before seeing the real ones (the commitment makes
///    sure), so their codes would differ: the person accepting checks both Macs show the same code.
/// 3. Everything after is encrypted with AES-GCM, a key for each direction: the offer (what's coming),
///    the answer, then the tar stream in blocks (compressed as the method says, and encrypted on
///    every core), its end, and the receiver's progress and result. Each block's number is part of
///    its nonce, so a block dropped, repeated or moved fails to decrypt.
enum Wire {
    static let service = "_onefile._tcp"
    static let version = 1
    static let largestFrame = 64 << 20

    enum Kind: UInt8, Sendable {
        case hello = 0x01, welcome = 0x02, reveal = 0x03
        case offer = 0x10, answer = 0x11
        case data = 0x20, totals = 0x21, end = 0x22
        case status = 0x30, result = 0x31
        case cancel = 0x7F
    }

    struct Hello: Codable, Sendable {
        var version: Int
        var name: String
        var kind: String
        var commitment: Data
    }

    struct Welcome: Codable, Sendable {
        var version: Int
        var name: String
        var kind: String
        var key: Data
    }

    struct Reveal: Codable, Sendable {
        var key: Data
    }

    /// What the sender wants to send.
    struct Offer: Codable, Sendable {
        var name: String
        var files: Int64
        var folders: Int64
        var bytes: Int64
        var tarBytes: Int64
        /// The numbers are from a finished count (else they're what's been counted so far).
        var counted: Bool
        var method: String
    }

    struct Answer: Codable, Sendable {
        var accepted: Bool
        var reason: String?
    }

    struct Totals: Codable, Sendable {
        var files: Int64
        var folders: Int64
        var bytes: Int64
        var tarBytes: Int64
    }

    struct End: Codable, Sendable {
        var files: Int64
        var folders: Int64
        var bytes: Int64
        var tarBytes: Int64
        var blocks: Int
    }

    /// The receiver's progress.
    struct Status: Codable, Sendable {
        var processed: Int64
        var files: Int64
        var bytes: Int64
    }

    struct Result: Codable, Sendable {
        var ok: Bool
        var message: String?
        var files: Int64
        var folders: Int64
        var bytes: Int64
        /// What it's called there.
        var name: String?
    }

    struct Cancel: Codable, Sendable {
        var reason: String
    }

    static func frame(_ kind: Kind, _ body: Data) -> Data {
        var data = Data(capacity: body.count + 5)
        data.append(kind.rawValue)
        let length = UInt32(body.count)
        data.append(contentsOf: [UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                                 UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
        data.append(body)
        return data
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Encryption

/// The keys both sides worked out, and the nonces: a direction byte, a space byte (control
/// messages or data blocks), then a counter. AES-GCM, so every frame is checked as it's opened.
final class Sealer: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: UInt8
    private let receiveDirection: UInt8
    private let lock = NSLock()
    private var controlSent: UInt64 = 0
    private var controlReceived: UInt64 = 0

    private static let controlSpace: UInt8 = 0x43
    private static let dataSpace: UInt8 = 0x44

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey, sender: Bool) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        sendDirection = sender ? 0x53 : 0x52
        receiveDirection = sender ? 0x52 : 0x53
    }

    private static func nonce(_ direction: UInt8, _ space: UInt8, _ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = direction
        bytes[1] = space
        for index in 0..<8 { bytes[4 + index] = UInt8(truncatingIfNeeded: counter >> UInt64(56 - 8 * index)) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// A data block's frame body: how many tar bytes it holds (in the clear, but authenticated),
    /// then the encrypted block and its tag.
    func sealData(_ block: Data, holds: Int, index: Int) -> Data? {
        let count = Self.bigEndian(UInt32(holds))
        guard let box = try? AES.GCM.seal(block, using: sendKey, nonce: Self.nonce(sendDirection, Self.dataSpace, UInt64(index)),
                                          authenticating: [Wire.Kind.data.rawValue] + count) else { return nil }
        var body = Data(capacity: 4 + box.ciphertext.count + 16)
        body.append(contentsOf: count)
        body.append(box.ciphertext)
        body.append(box.tag)
        return body
    }

    /// How many tar bytes a data frame's body holds (before opening it).
    static func holds(_ body: Data) -> Int? {
        guard body.count >= 20 else { return nil }
        let start = body.startIndex
        return Int(body[start]) << 24 | Int(body[start + 1]) << 16 | Int(body[start + 2]) << 8 | Int(body[start + 3])
    }

    func openData(_ body: Data, index: Int) -> Data? {
        guard body.count >= 20 else { return nil }
        let start = body.startIndex
        let count = Array(body[start..<(start + 4)])
        guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(receiveDirection, Self.dataSpace, UInt64(index)),
                                               ciphertext: body[(start + 4)..<(body.endIndex - 16)],
                                               tag: body[(body.endIndex - 16)...]) else { return nil }
        return try? AES.GCM.open(box, using: receiveKey, authenticating: [Wire.Kind.data.rawValue] + count)
    }

    /// Seals a control message: call in the order they're sent (`Link.sendControl` does).
    func sealControl(_ kind: Wire.Kind, _ plaintext: Data) -> Data? {
        lock.lock()
        let counter = controlSent
        controlSent += 1
        lock.unlock()
        guard let box = try? AES.GCM.seal(plaintext, using: sendKey, nonce: Self.nonce(sendDirection, Self.controlSpace, counter),
                                          authenticating: [kind.rawValue]) else { return nil }
        return box.ciphertext + box.tag
    }

    /// Opens control messages in the order they arrive. Reader thread only.
    func openControl(_ kind: Wire.Kind, _ body: Data) -> Data? {
        guard body.count >= 16 else { return nil }
        let counter = controlReceived
        controlReceived += 1
        guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(receiveDirection, Self.controlSpace, counter),
                                               ciphertext: body[body.startIndex..<(body.endIndex - 16)],
                                               tag: body[(body.endIndex - 16)...]) else { return nil }
        return try? AES.GCM.open(box, using: receiveKey, authenticating: [kind.rawValue])
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }
}

/// The outcome of the handshake: the keys, the code to compare, and who's on the other end.
struct Handshake: Sendable {
    let sealer: Sealer
    let code: String
    let peerName: String
    let peerKind: String
}

enum HandshakeError: Error {
    case failed(String)
}

extension Handshake {
    static let lost = "The other Mac didn't answer as OneFile does."

    static func asSender(_ link: Link, me: ThisMac.Identity) -> Result<Handshake, HandshakeError> {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let mine = key.publicKey.rawRepresentation
        let hello = Wire.encode(Wire.Hello(version: Wire.version, name: me.name, kind: me.kind,
                                           commitment: Data(SHA256.hash(data: mine))))
        guard link.send(Wire.frame(.hello, hello)) else { return .failure(.failed(link.failure ?? lost)) }
        guard let (kind, welcomeBytes) = link.readFrame(), kind == .welcome,
              let welcome = Wire.decode(Wire.Welcome.self, welcomeBytes) else {
            return .failure(.failed(link.failure ?? lost))
        }
        guard welcome.version == Wire.version else {
            return .failure(.failed("“\(welcome.name)” has a different version of OneFile. Update both Macs to the same version."))
        }
        let reveal = Wire.encode(Wire.Reveal(key: mine))
        guard link.send(Wire.frame(.reveal, reveal)) else { return .failure(.failed(link.failure ?? lost)) }
        return derive(key, theirs: welcome.key, transcript: hello + welcomeBytes + reveal, sender: true,
                      peerName: welcome.name, peerKind: welcome.kind)
    }

    static func asReceiver(_ link: Link, me: ThisMac.Identity) -> Result<Handshake, HandshakeError> {
        guard let (kind, helloBytes) = link.readFrame(), kind == .hello,
              let hello = Wire.decode(Wire.Hello.self, helloBytes) else {
            return .failure(.failed(link.failure ?? lost))
        }
        guard hello.version == Wire.version else {
            return .failure(.failed("“\(hello.name)” has a different version of OneFile. Update both Macs to the same version."))
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let welcome = Wire.encode(Wire.Welcome(version: Wire.version, name: me.name, kind: me.kind,
                                               key: key.publicKey.rawRepresentation))
        guard link.send(Wire.frame(.welcome, welcome)) else { return .failure(.failed(link.failure ?? lost)) }
        guard let (next, revealBytes) = link.readFrame(), next == .reveal,
              let reveal = Wire.decode(Wire.Reveal.self, revealBytes) else {
            return .failure(.failed(link.failure ?? lost))
        }
        guard Data(SHA256.hash(data: reveal.key)) == hello.commitment else {
            return .failure(.failed("The other Mac's key isn't the one it promised: something between the two Macs may be interfering. Nothing was sent."))
        }
        return derive(key, theirs: reveal.key, transcript: helloBytes + welcome + revealBytes, sender: false,
                      peerName: hello.name, peerKind: hello.kind)
    }

    private static func derive(_ key: Curve25519.KeyAgreement.PrivateKey, theirs: Data, transcript: Data, sender: Bool,
                               peerName: String, peerKind: String) -> Result<Handshake, HandshakeError> {
        guard let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
              let shared = try? key.sharedSecretFromKeyAgreement(with: theirKey) else {
            return .failure(.failed("The other Mac sent a key that doesn't work."))
        }
        let salt = Data(SHA256.hash(data: transcript))
        func derived(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        let toReceiver = derived("OneFile 1: sender to receiver")
        let toSender = derived("OneFile 1: receiver to sender")
        let mac = HMAC<SHA256>.authenticationCode(for: Data("OneFile 1: code".utf8), using: derived("OneFile 1: code key"))
        let number = Data(mac).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let code = String(format: "%03d %03d", number / 1_000, number % 1_000)
        let sealer = Sealer(sendKey: sender ? toReceiver : toSender, receiveKey: sender ? toSender : toReceiver,
                            sender: sender)
        return .success(Handshake(sealer: sealer, code: code, peerName: peerName, peerKind: peerKind))
    }
}

// MARK: - A connection, as blocking calls

/// An `NWConnection` used from threads of its own: `open`, `send` and `readFrame` wait. At most a
/// few frames are on their way at once, so a slow network slows the sender down rather than
/// filling memory.
final class Link: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "OneFile.link", qos: .userInitiated)
    private static let inFlight = 12
    private let sendSlots = DispatchSemaphore(value: Link.inFlight)
    private let state = Locked<(failure: String?, ready: Bool)>((nil, false))
    private let controlLock = NSLock()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    var failure: String? { state.withLock { $0.failure } }

    func fail(_ message: String) {
        state.withLock { if $0.failure == nil { $0.failure = message } }
    }

    /// Starts the connection and waits until it's ready (or `timeout` passes). Nil, or what's wrong.
    func open(timeout: Double) -> String? {
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let first = self.state.withLock { s -> Bool in
                    defer { s.ready = true }
                    return !s.ready
                }
                if first { ready.signal() }
            case .failed(let error):
                fail(Self.describe(error))
                ready.signal()
            case .cancelled:
                fail("The connection was closed.")
                ready.signal()
            case .waiting(let error):
                // Can't connect for now (no route, refused): don't wait for it to change.
                if !self.state.withLock({ $0.ready }) {
                    fail(Self.describe(error))
                    ready.signal()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            fail("The other Mac didn't answer in time.")
        }
        if let failure {
            connection.cancel()
            return failure
        }
        return nil
    }

    /// Sends a frame (waiting while too many are on their way). False if the connection failed.
    @discardableResult
    func send(_ frame: Data) -> Bool {
        sendSlots.wait()
        guard failure == nil else {
            sendSlots.signal()
            return false
        }
        connection.send(content: frame, completion: .contentProcessed { [self] error in
            if let error { fail(Self.describe(error)) }
            sendSlots.signal()
        })
        return true
    }

    /// Seals and sends a control message, in order with other control messages.
    @discardableResult
    func sendControl<T: Encodable>(_ kind: Wire.Kind, _ message: T, _ sealer: Sealer) -> Bool {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard let sealed = sealer.sealControl(kind, Wire.encode(message)) else { return false }
        return send(Wire.frame(kind, sealed))
    }

    /// Waits until everything sent so far has gone (or `timeout` passes).
    func drain(timeout: Double = 10) {
        let deadline = DispatchTime.now() + timeout
        var taken = 0
        while taken < Link.inFlight, sendSlots.wait(timeout: deadline) == .success { taken += 1 }
        for _ in 0..<taken { sendSlots.signal() }
    }

    /// Exactly `count` bytes, or nil if the connection ended first.
    func receive(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        let done = DispatchSemaphore(value: 0)
        let box = Locked<Data?>(nil)
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, isComplete, error in
            if let error {
                fail(Self.describe(error))
            } else if let data, data.count == count {
                box.withLock { $0 = data }
            } else if isComplete || data != nil {
                fail("The other Mac closed the connection.")
            }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 }
    }

    /// The next frame, or nil when the connection ends.
    func readFrame() -> (Wire.Kind, Data)? {
        guard let head = receive(5) else { return nil }
        let bytes = [UInt8](head)
        let length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
        guard let kind = Wire.Kind(rawValue: bytes[0]), length <= Wire.largestFrame else {
            fail("The other Mac sent something OneFile doesn't understand.")
            connection.cancel()
            return nil
        }
        guard let body = receive(length) else { return nil }
        return (kind, body)
    }

    func close() {
        connection.cancel()
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "The other Mac isn't accepting connections (is OneFile open there, on Receive?)."
            case .ECONNRESET, .EPIPE: return "The connection to the other Mac was lost."
            case .ETIMEDOUT: return "The other Mac stopped answering."
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN: return "The other Mac can't be reached from here."
            default: return "The connection failed: \(code)."
            }
        case .dns(let code):
            if code == -65570 { return Nearby.deniedMessage }
            return "Couldn't find the other Mac on the network."
        default:
            return "The connection failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sending

/// Sends a folder to another Mac: connects, agrees keys, offers the folder, and once the person
/// here has confirmed the codes match (`confirm`) and the other Mac has accepted, packs it straight
/// into the connection (no file in between) while the other Mac unpacks it. Both sides confirming
/// is what keeps a Mac pretending to be the one picked from getting anything.
final class SendSession: PackStream, @unchecked Sendable {
    enum Event: Sendable {
        case connecting
        /// Connected: the code both Macs show, while waiting for both sides to confirm it.
        case code(String, peer: String)
        /// The other Mac accepted; it's waiting for the person here to confirm the code.
        case answered
        case accepted
        case declined(String)
        case finished(Summary)
        case failed(String)
        case stopped
    }

    struct Summary: Sendable {
        var peer: String
        /// What it's called on the other Mac.
        var savedAs: String?
        var pack: Packer.Summary
        /// Bytes sent over the network (compressed and encrypted).
        var sentBytes: Int64
        var seconds: Double
    }

    /// How far the other Mac has got.
    struct Remote: Sendable {
        var processed: Int64 = 0
        var files: Int64 = 0
        var bytes: Int64 = 0
    }

    let endpoint: NWEndpoint
    let peerName: String
    let source: URL
    let options: Packer.Options
    let totals: Packer.Totals?
    private let me: ThisMac.Identity
    private let onEvent: @Sendable (Event) -> Void

    private struct State {
        var stopped = false
        var link: Link?
        var sealer: Sealer?
        var packer: Packer?
        var answer: Wire.Answer?
        var confirmed = false
        var result: Wire.Result?
        var remoteCancel: String?
        var remote = Remote()
        var sentTotals = false
        var lost = false
    }

    private let state = Locked(State())
    /// Something changed while deciding: an answer, a confirmation, a cancel, the connection.
    private let changed = DispatchSemaphore(value: 0)
    private let resulted = DispatchSemaphore(value: 0)

    init(endpoint: NWEndpoint, peerName: String, source: URL, options: Packer.Options, totals: Packer.Totals?,
         me: ThisMac.Identity, onEvent: @escaping @Sendable (Event) -> Void) {
        self.endpoint = endpoint
        self.peerName = peerName
        self.source = source
        self.options = options
        self.totals = totals
        self.me = me
        self.onEvent = onEvent
    }

    func start() {
        let thread = Thread { [self] in onEvent(run()) }
        thread.name = "OneFile sender"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() {
        let (link, sealer, packer) = state.withLock { s -> (Link?, Sealer?, Packer?) in
            s.stopped = true
            return (s.link, s.sealer, s.packer)
        }
        if let packer {
            packer.cancel()
            // If the network is stuck, sending can't notice: closing the connection unblocks it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { link?.close() }
        } else {
            if let link, let sealer { link.sendControl(.cancel, Wire.Cancel(reason: "\(me.name) stopped."), sealer) }
            link?.close()
        }
        changed.signal()
        resulted.signal()
    }

    /// The person here says both Macs show the same code.
    func confirm() {
        state.withLock { $0.confirmed = true }
        changed.signal()
    }

    func packerProgress() -> Packer.Progress? {
        state.withLock { $0.packer }?.progress()
    }

    func remote() -> Remote {
        state.withLock { $0.remote }
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func run() -> Event {
        let started = Date()
        onEvent(.connecting)
        let link = Link(NWConnection(to: endpoint, using: Nearby.parameters()))
        state.withLock { $0.link = link }
        if isStopped { return .stopped }
        if let error = link.open(timeout: 15) {
            return isStopped ? .stopped : .failed("Couldn't connect to “\(peerName)”: \(error)")
        }
        defer { link.close() }
        let handshake: Handshake
        switch Handshake.asSender(link, me: me) {
        case .failure(.failed(let message)): return isStopped ? .stopped : .failed(message)
        case .success(let done): handshake = done
        }
        let sealer = handshake.sealer
        state.withLock { $0.sealer = sealer }
        onEvent(.code(handshake.code, peer: handshake.peerName))

        // Listen for the answer, the other Mac's progress, and its result.
        let reader = Thread { [self] in read(link, sealer) }
        reader.name = "OneFile sender's reader"
        reader.start()

        let counted = totals ?? Packer.Totals()
        let offer = Wire.Offer(name: source.lastPathComponent, files: counted.files, folders: counted.folders,
                               bytes: counted.bytes, tarBytes: counted.archiveBytes, counted: totals != nil,
                               method: options.method.rawValue)
        guard link.sendControl(.offer, offer, sealer) else { return .failed(link.failure ?? "The connection was lost.") }
        // Nothing goes until both sides have confirmed: the other Mac accepts, the person here
        // confirms the codes match (in either order).
        var told = false
        while true {
            changed.wait()
            if isStopped { return .stopped }
            let (answer, confirmed, gone) = state.withLock { ($0.answer, $0.confirmed, $0.remoteCancel ?? ($0.lost ? "" : nil)) }
            if let answer, !answer.accepted { return .declined(answer.reason ?? "“\(handshake.peerName)” said no.") }
            if let gone {
                return .failed(gone.isEmpty ? link.failure ?? "The connection to “\(handshake.peerName)” was lost." : gone)
            }
            if answer?.accepted == true && confirmed { break }
            if answer?.accepted == true && !told {
                told = true
                onEvent(.answered)
            }
        }
        onEvent(.accepted)

        let packer = Packer(source: source, target: .stream(self), options: options, knownTotals: totals)
        let finished = DispatchSemaphore(value: 0)
        let outcome = Locked<Packer.Outcome?>(nil)
        let stoppedFirst = state.withLock { s -> Bool in
            s.packer = packer
            return s.stopped
        }
        if stoppedFirst { return .stopped }
        let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        ticker.schedule(deadline: .now() + 0.5, repeating: 0.5)
        ticker.setEventHandler { [self] in sendTotalsIfCounted(packer, link, sealer) }
        ticker.resume()
        packer.start { result in
            outcome.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()
        ticker.cancel()

        switch outcome.withLock({ $0 })! {
        case .stopped:
            link.sendControl(.cancel, Wire.Cancel(reason: "\(me.name) stopped sending."), sealer)
            link.drain(timeout: 2)
            return .stopped
        case .failed(let message):
            if let reason = state.withLock({ $0.remoteCancel }) { return .failed(reason) }
            link.sendControl(.cancel, Wire.Cancel(reason: "\(me.name) couldn't go on: \(message)"), sealer)
            link.drain(timeout: 2)
            return .failed(message)
        case .finished(let summary):
            let end = Wire.End(files: summary.files, folders: summary.folders, bytes: summary.bytes,
                               tarBytes: summary.tarBytes, blocks: 0)
            guard link.sendControl(.end, end, sealer) else { return .failed(link.failure ?? "The connection was lost.") }
            // Wait for the other Mac to finish unpacking.
            resulted.wait()
            if isStopped {
                link.sendControl(.cancel, Wire.Cancel(reason: "\(me.name) stopped."), sealer)
                link.drain(timeout: 2)
                return .stopped
            }
            guard let result = state.withLock({ $0.result }) else {
                return .failed(state.withLock { $0.remoteCancel } ?? "The connection to “\(handshake.peerName)” was lost before it finished.")
            }
            guard result.ok else { return .failed(result.message ?? "“\(handshake.peerName)” couldn't unpack it.") }
            return .finished(Summary(peer: handshake.peerName, savedAs: result.name, pack: summary,
                                     sentBytes: summary.archiveBytes, seconds: Date().timeIntervalSince(started)))
        }
    }

    private func sendTotalsIfCounted(_ packer: Packer, _ link: Link, _ sealer: Sealer) {
        guard let totals = packer.progress().totals else { return }
        let first = state.withLock { s -> Bool in
            defer { s.sentTotals = true }
            return !s.sentTotals
        }
        guard first, self.totals == nil else { return }
        link.sendControl(.totals, Wire.Totals(files: totals.files, folders: totals.folders, bytes: totals.bytes,
                                              tarBytes: totals.archiveBytes), sealer)
    }

    private func read(_ link: Link, _ sealer: Sealer) {
        while let (kind, body) = link.readFrame() {
            guard let plain = sealer.openControl(kind, body) else {
                link.fail("A message from the other Mac didn't decrypt: the connection may have been tampered with.")
                break
            }
            switch kind {
            case .answer:
                state.withLock { $0.answer = Wire.decode(Wire.Answer.self, plain) }
                changed.signal()
            case .status:
                if let status = Wire.decode(Wire.Status.self, plain) {
                    state.withLock { $0.remote = Remote(processed: status.processed, files: status.files, bytes: status.bytes) }
                }
            case .result:
                state.withLock { $0.result = Wire.decode(Wire.Result.self, plain) }
                resulted.signal()
                return
            case .cancel:
                let reason = Wire.decode(Wire.Cancel.self, plain)?.reason ?? "The other Mac stopped."
                let packer = state.withLock { s -> Packer? in
                    s.remoteCancel = reason
                    return s.packer
                }
                packer?.cancel()
                changed.signal()
                resulted.signal()
                return
            default:
                break
            }
        }
        // The connection ended.
        let packer = state.withLock { s -> Packer? in
            s.lost = true
            return s.packer
        }
        packer?.cancel()
        changed.signal()
        resulted.signal()
    }

    // MARK: PackStream

    func frame(_ block: Data, holding count: Int, index: Int) -> Data? {
        guard let sealer = state.withLock({ $0.sealer }),
              let body = sealer.sealData(block, holds: count, index: index) else { return nil }
        return Wire.frame(.data, body)
    }

    func send(_ frame: Data) -> Bool {
        guard let link = state.withLock({ $0.link }) else { return false }
        return link.send(frame)
    }

    var failureMessage: String? {
        state.withLock { $0.remoteCancel } ?? state.withLock({ $0.link })?.failure
    }
}

// MARK: - Receiving

/// Receives a folder from another Mac: agrees keys, shows the offer and its code, and once accepted
/// unpacks the stream as it arrives (decrypting and decompressing on every core).
final class ReceiveSession: @unchecked Sendable {
    enum Event: Sendable {
        /// Someone wants to send: accept or decline.
        case offer(Wire.Offer, code: String, peer: String, kind: String)
        case started
        case finished(Summary)
        case failed(String)
        case stopped
        /// Declined, or the sender went away before it was accepted.
        case dismissed(String?)
    }

    struct Summary: Sendable {
        var peer: String
        var unpack: Unpacker.Summary
        var seconds: Double
    }

    let connection: NWConnection
    private let me: ThisMac.Identity
    private let onEvent: @Sendable (Event) -> Void

    private struct State {
        var stopped = false
        var link: Link?
        var sealer: Sealer?
        var decision: URL??
        var unpacker: Unpacker?
        var pipeline: OrderedPipeline?
        var method = PackMethod.plain
        var remoteCancel: String?
        var ended = false
        var peer = ""
    }

    private let state = Locked(State())
    private let decided = DispatchSemaphore(value: 0)

    init(connection: NWConnection, me: ThisMac.Identity, onEvent: @escaping @Sendable (Event) -> Void) {
        self.connection = connection
        self.me = me
        self.onEvent = onEvent
    }

    func start() {
        let thread = Thread { [self] in
            if let event = run() { onEvent(event) }
        }
        thread.name = "OneFile receiver"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Yes: unpack it into a new folder in `destination`.
    func accept(into destination: URL) {
        state.withLock { if $0.decision == nil { $0.decision = .some(destination) } }
        decided.signal()
    }

    func decline() {
        state.withLock { if $0.decision == nil { $0.decision = .some(nil) } }
        decided.signal()
    }

    func cancel() {
        let unpacker = state.withLock { s -> Unpacker? in
            s.stopped = true
            return s.unpacker
        }
        if let unpacker {
            unpacker.cancel()
        } else {
            state.withLock { $0.link }?.close()
        }
        decided.signal()
    }

    func progress() -> Unpacker.Progress? {
        state.withLock { $0.unpacker }?.progress()
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private func run() -> Event? {
        let started = Date()
        let link = Link(connection)
        state.withLock { $0.link = link }
        if let error = link.open(timeout: 10) { return .dismissed(error) }
        defer { link.close() }
        let handshake: Handshake
        switch Handshake.asReceiver(link, me: me) {
        case .failure(.failed(let message)): return .dismissed(message)
        case .success(let done): handshake = done
        }
        let sealer = handshake.sealer
        state.withLock {
            $0.sealer = sealer
            $0.peer = handshake.peerName
        }
        guard let (kind, body) = link.readFrame(), kind == .offer, let plain = sealer.openControl(kind, body),
              let offer = Wire.decode(Wire.Offer.self, plain) else {
            return .dismissed(link.failure)
        }
        let method = PackMethod(rawValue: offer.method) ?? .plain
        state.withLock { $0.method = method }

        // From here on, frames are read on a thread of their own: the sender may give up while
        // the person here is still deciding.
        let reader = Thread { [self] in read(link, sealer) }
        reader.name = "OneFile receiver's reader"
        reader.qualityOfService = .userInitiated
        reader.start()

        onEvent(.offer(offer, code: handshake.code, peer: handshake.peerName, kind: handshake.peerKind))
        decided.wait()
        let decision = state.withLock { $0.decision }
        if let reason = state.withLock({ $0.remoteCancel }) { return .dismissed(reason) }
        guard !isStopped, let choice = decision, let destination = choice else {
            link.sendControl(.answer, Wire.Answer(accepted: false, reason: "\(me.name) said no."), sealer)
            link.drain(timeout: 2)
            return .dismissed(nil)
        }

        // Yes: unpack the stream as it comes. (The name came from the other Mac: made safe first.)
        let pipeline = OrderedPipeline(slots: ArchiveDecoder.decoders + 4)
        let unpacker = Unpacker(source: .stream(pipeline, name: ThisMac.safeName(offer.name)), destination: destination)
        unpacker.setTotal(offer.tarBytes > 0 ? offer.tarBytes : nil)
        let stoppedFirst = state.withLock { s -> Bool in
            s.pipeline = pipeline
            s.unpacker = unpacker
            return s.stopped || s.remoteCancel != nil
        }
        if stoppedFirst {
            pipeline.stop()
            return .stopped
        }
        guard link.sendControl(.answer, Wire.Answer(accepted: true, reason: nil), sealer) else {
            return .failed(link.failure ?? "The connection was lost.")
        }
        onEvent(.started)

        let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        ticker.schedule(deadline: .now() + 0.25, repeating: 0.25)
        ticker.setEventHandler {
            let progress = unpacker.progress()
            link.sendControl(.status, Wire.Status(processed: progress.processed, files: progress.files,
                                                  bytes: progress.bytes), sealer)
        }
        ticker.resume()

        let finished = DispatchSemaphore(value: 0)
        let outcome = Locked<Unpacker.Outcome?>(nil)
        unpacker.start { result in
            outcome.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()
        ticker.cancel()

        let (remoteCancel, ended) = state.withLock { ($0.remoteCancel, $0.ended) }
        switch outcome.withLock({ $0 })! {
        case .finished(let summary) where ended:
            let result = Wire.Result(ok: true, message: nil, files: summary.files, folders: summary.folders,
                                     bytes: summary.bytes, name: summary.output?.lastPathComponent)
            link.sendControl(.result, result, sealer)
            link.drain()
            return .finished(Summary(peer: handshake.peerName, unpack: summary, seconds: Date().timeIntervalSince(started)))
        case .finished:
            return .failed(link.failure ?? "The connection to “\(handshake.peerName)” was lost before everything arrived. What arrived has been deleted.")
        case .stopped:
            if let remoteCancel { return .failed(remoteCancel + " What arrived has been deleted.") }
            if link.failure != nil {
                return .failed("The connection to “\(handshake.peerName)” was lost. What arrived has been deleted.")
            }
            link.sendControl(.cancel, Wire.Cancel(reason: "\(me.name) stopped receiving."), sealer)
            link.drain(timeout: 2)
            return .stopped
        case .failed(let message):
            if let remoteCancel { return .failed(remoteCancel + " What arrived has been deleted.") }
            link.sendControl(.result, Wire.Result(ok: false, message: "\(me.name) couldn't unpack it: \(message)",
                                                  files: 0, folders: 0, bytes: 0, name: nil), sealer)
            link.drain(timeout: 2)
            return .failed(message)
        }
    }

    private func read(_ link: Link, _ sealer: Sealer) {
        var index = 0
        var arrived: Int64 = 0
        while let (kind, body) = link.readFrame() {
            if kind == .data {
                guard let pipeline = state.withLock({ $0.pipeline }), let holds = Sealer.holds(body) else { break }
                let method = state.withLock { $0.method }
                let number = index
                index += 1
                arrived += Int64(holds)
                let reached = arrived
                let accepted = pipeline.submit {
                    guard let plain = sealer.openData(body, index: number) else {
                        return .failure(DecodeError(message: "A piece of the stream didn't decrypt: the connection may have been tampered with."))
                    }
                    guard let chunk = plain.withUnsafeBytes({ ArchiveDecoder.decodeBlock($0, holds: holds, method: method) }) else {
                        return .failure(DecodeError(message: "A piece of the stream didn't decompress."))
                    }
                    chunk.inputEnd = reached
                    return .success(chunk)
                }
                if !accepted { break }
                continue
            }
            guard let plain = sealer.openControl(kind, body) else {
                link.fail("A message from the other Mac didn't decrypt: the connection may have been tampered with.")
                break
            }
            switch kind {
            case .totals:
                if let totals = Wire.decode(Wire.Totals.self, plain) {
                    state.withLock { $0.unpacker }?.setTotal(totals.tarBytes)
                }
            case .end:
                let pipeline = state.withLock { s -> OrderedPipeline? in
                    s.ended = true
                    return s.pipeline
                }
                pipeline?.finish()
            case .cancel:
                let reason = Wire.decode(Wire.Cancel.self, plain)?.reason ?? "The other Mac stopped."
                let (unpacker, pipeline) = state.withLock { s -> (Unpacker?, OrderedPipeline?) in
                    s.remoteCancel = reason
                    return (s.unpacker, s.pipeline)
                }
                unpacker?.cancel()
                pipeline?.stop()
                decided.signal()
                return
            default:
                break
            }
        }
        // The connection ended (or something went wrong): unless everything arrived, stop.
        let (ended, unpacker, pipeline) = state.withLock { s -> (Bool, Unpacker?, OrderedPipeline?) in
            if !s.ended && s.remoteCancel == nil && s.unpacker == nil {
                s.remoteCancel = "\(s.peer.isEmpty ? "The other Mac" : "“\(s.peer)”") went away."
            }
            return (s.ended, s.unpacker, s.pipeline)
        }
        if !ended {
            unpacker?.cancel()
            pipeline?.stop()
        }
        decided.signal()
    }
}
