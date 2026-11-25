import Foundation
import CryptoKit
import CommonCrypto

/// Locking a file with a password, in the age format (age-encryption.org/v1): the archive opens in
/// OneFile, or anywhere with the free `age` tool (`age -d file.tar.gz.age > file.tar.gz`), on
/// Windows, Linux and Macs.
///
/// A random file key encrypts the data with ChaCha20-Poly1305, 64 KB at a time, each piece with
/// its own number (so pieces can't be moved, dropped or added), on every core. The file key is
/// itself encrypted with a key worked out from the password with scrypt (2^18 rounds: about a
/// second, and costly to guess at), and the header is authenticated with an HMAC.
enum Age {
    static let intro = "age-encryption.org/v1"
    static let chunk = 64 << 10
    static let tagSize = 16
    /// scrypt's work factor, as a power of two: age's own for passwords.
    static let workFactor = 18

    // MARK: Writing a header

    /// A new file key and the header that locks it with `password`.
    static func header(password: String, workFactor: Int = Age.workFactor) -> (fileKey: [UInt8], header: [UInt8])? {
        let fileKey = random(16)
        let salt = random(16)
        guard let wrapKey = wrappingKey(password, salt: salt, workFactor: workFactor),
              let wrapped = try? ChaChaPoly.seal(fileKey, using: SymmetricKey(data: wrapKey),
                                                 nonce: ChaChaPoly.Nonce(data: [UInt8](repeating: 0, count: 12))) else { return nil }
        var text = intro + "\n"
        text += "-> scrypt \(base64(salt)) \(workFactor)\n"
        text += wrapLines(base64(Array(wrapped.ciphertext) + Array(wrapped.tag))) + "\n"
        text += "---"
        let mac = headerMAC(fileKey: fileKey, Array(text.utf8))
        text += " \(base64(mac))\n"
        return (fileKey, Array(text.utf8))
    }

    /// The key that wraps the file key, from the password: scrypt with age's salt.
    static func wrappingKey(_ password: String, salt: [UInt8], workFactor: Int) -> [UInt8]? {
        guard workFactor >= 1, workFactor <= 22 else { return nil }
        return Scrypt.derive(password: Array(password.utf8), salt: Array("age-encryption.org/v1/scrypt".utf8) + salt,
                             n: 1 << workFactor, r: 8, p: 1, length: 32)
    }

    static func headerMAC(fileKey: [UInt8], _ header: [UInt8]) -> [UInt8] {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey), salt: Data(),
                                         info: Data("header".utf8), outputByteCount: 32)
        return Array(HMAC<SHA256>.authenticationCode(for: header, using: key))
    }

    static func payloadKey(fileKey: [UInt8], nonce: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey), salt: nonce,
                               info: Data("payload".utf8), outputByteCount: 32)
    }

    /// The nonce of piece `index`: its number (big-endian, 11 bytes), then 1 for the last piece.
    static func nonce(_ index: Int64, last: Bool) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var value = UInt64(index)
        for position in stride(from: 10, through: 3, by: -1) {
            bytes[position] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        bytes[11] = last ? 1 : 0
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    // MARK: Reading a header

    enum OpenError: Error, Equatable {
        case notAge, wrongPassword, damaged, unsupported(String)
    }

    /// The file key, if `password` opens the header at the start of `bytes`; and where the header
    /// ends (the payload's nonce follows).
    static func open(_ bytes: [UInt8], password: String) -> Result<(fileKey: [UInt8], headerEnd: Int), OpenError> {
        guard bytes.starts(with: Array((intro + "\n").utf8)) else { return .failure(.notAge) }
        // Lines until "--- MAC".
        var lines: [(text: String, end: Int)] = []
        var start = 0
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            lines.append((String(decoding: bytes[start..<newline], as: UTF8.self), newline + 1))
            if bytes[start...].starts(with: Array("---".utf8)) { break }
            start = newline + 1
            if lines.count > 200 { return .failure(.damaged) }
        }
        guard let last = lines.last, last.text.hasPrefix("--- ") else { return .failure(.damaged) }
        var stanzas: [(arguments: [String], body: [UInt8])] = []
        var index = 1
        while index < lines.count - 1 {
            let line = lines[index].text
            guard line.hasPrefix("-> ") else { return .failure(.damaged) }
            let arguments = line.dropFirst(3).split(separator: " ").map(String.init)
            index += 1
            var body = ""
            while index < lines.count - 1 {
                let piece = lines[index].text
                body += piece
                index += 1
                if piece.count < 64 { break }
            }
            guard let decoded = unbase64(body) else { return .failure(.damaged) }
            stanzas.append((arguments, decoded))
        }
        guard let scrypt = stanzas.first(where: { $0.arguments.first == "scrypt" }) else {
            return .failure(.unsupported("It's locked for someone's age key, not with a password."))
        }
        guard stanzas.count == 1, scrypt.arguments.count == 3, let salt = unbase64(scrypt.arguments[1]), salt.count == 16,
              let factor = Int(scrypt.arguments[2]), factor >= 1, factor <= 22, scrypt.body.count == 32 else {
            return .failure(.damaged)
        }
        guard let wrapKey = wrappingKey(password, salt: salt, workFactor: factor),
              let box = try? ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: [UInt8](repeating: 0, count: 12)),
                                                   ciphertext: scrypt.body.prefix(16), tag: scrypt.body.suffix(16)),
              let fileKey = try? ChaChaPoly.open(box, using: SymmetricKey(data: wrapKey)) else {
            return .failure(.wrongPassword)
        }
        // The header's MAC covers it up to and including "---".
        let macStart = lines[lines.count - 2].end
        let macCovered = Array(bytes[0..<(macStart + 3)])
        guard let mac = unbase64(String(last.text.dropFirst(4))),
              mac == headerMAC(fileKey: Array(fileKey), macCovered) else { return .failure(.damaged) }
        return .success((Array(fileKey), last.end))
    }

    // MARK: Helpers

    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        return bytes
    }

    /// Standard base64 without padding, as age writes it.
    static func base64(_ bytes: [UInt8]) -> String {
        var text = Data(bytes).base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    static func unbase64(_ text: String) -> [UInt8]? {
        guard !text.contains("=") else { return nil }
        var padded = text
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded).map(Array.init)
    }

    /// Lines of 64 characters; a body that's a whole number of lines ends with an empty one.
    static func wrapLines(_ text: String) -> String {
        var lines: [String] = []
        var rest = Substring(text)
        while rest.count >= 64 {
            lines.append(String(rest.prefix(64)))
            rest = rest.dropFirst(64)
        }
        lines.append(String(rest))
        return lines.joined(separator: "\n")
    }
}

/// Encrypts a stream in the age format as it's written: the header and the payload's nonce, then
/// 64 KB pieces, 64 at a time on every core. The last piece is kept back until `finish`, as it's
/// marked as the last.
final class AgeWriter {
    private let key: SymmetricKey
    private var pending: [UInt8] = []
    private var index: Int64 = 0
    private let output: ([UInt8]) -> Bool
    private var started = false
    private let header: [UInt8]

    init?(password: String, workFactor: Int = Age.workFactor, output: @escaping ([UInt8]) -> Bool) {
        guard let made = Age.header(password: password, workFactor: workFactor) else { return nil }
        let nonce = Age.random(16)
        key = Age.payloadKey(fileKey: made.fileKey, nonce: nonce)
        header = made.header + nonce
        self.output = output
        pending.reserveCapacity(Age.chunk * 65)
    }

    func append(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard writeHeader() else { return false }
        pending.append(contentsOf: bytes)
        // Whole pieces go once there are plenty, keeping at least a byte back for the last one.
        let ready = (pending.count - 1) / Age.chunk
        guard ready >= 64 else { return true }
        return seal(pieces: ready, last: false)
    }

    func finish() -> Bool {
        guard writeHeader() else { return false }
        let whole = pending.isEmpty ? 0 : (pending.count - 1) / Age.chunk
        if whole > 0 { guard seal(pieces: whole, last: false) else { return false } }
        // The last piece, short (or empty, for an empty payload), marked as the last.
        let tail = pending
        pending = []
        guard let sealed = try? ChaChaPoly.seal(tail, using: key, nonce: Age.nonce(index, last: true)) else { return false }
        index += 1
        return output(Array(sealed.ciphertext) + Array(sealed.tag))
    }

    private func writeHeader() -> Bool {
        guard !started else { return true }
        started = true
        return output(header)
    }

    /// Encrypts the first `pieces` whole pieces waiting, all at once, and writes them in order.
    private func seal(pieces: Int, last: Bool) -> Bool {
        let size = Age.chunk
        var out = [UInt8](repeating: 0, count: pieces * (size + Age.tagSize))
        let first = index
        let key = self.key
        let failed = Locked(false)
        pending.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { result in
                let source = SharedPointer(UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: UInt8.self)))
                let target = SharedPointer(result.baseAddress!.assumingMemoryBound(to: UInt8.self))
                DispatchQueue.concurrentPerform(iterations: pieces) { piece in
                    let plain = UnsafeRawBufferPointer(start: source.pointer + piece * size, count: size)
                    guard let sealed = try? ChaChaPoly.seal(plain, using: key, nonce: Age.nonce(first + Int64(piece), last: false)) else {
                        failed.withLock { $0 = true }
                        return
                    }
                    let at = target.pointer + piece * (size + Age.tagSize)
                    sealed.ciphertext.copyBytes(to: at, count: size)
                    sealed.tag.copyBytes(to: at + size, count: Age.tagSize)
                }
            }
        }
        guard !failed.withLock({ $0 }) else { return false }
        index += Int64(pieces)
        pending.removeFirst(pieces * size)
        return output(out)
    }
}

/// Reads the payload of an age file (unlocked) at any offset: the pieces holding the bytes asked
/// for are decrypted, and checked, on the way.
struct AgeReader: Sendable {
    let key: SymmetricKey
    /// Where the first piece starts in the file (after the header and nonce).
    let start: Int64
    /// The payload's length, decrypted.
    let size: Int64
    let pieces: Int64

    init?(fileKey: [UInt8], headerEnd: Int, nonce: [UInt8], fileSize: Int64) {
        key = Age.payloadKey(fileKey: fileKey, nonce: nonce)
        start = Int64(headerEnd + 16)
        let sealed = fileSize - start
        let piece = Int64(Age.chunk + Age.tagSize)
        guard sealed >= Int64(Age.tagSize) else { return nil }
        pieces = (sealed + piece - 1) / piece
        size = sealed - pieces * Int64(Age.tagSize)
    }

    /// Decrypts piece `index` from its sealed bytes. Nil if it's been changed (or it's the wrong one).
    func open(_ index: Int64, _ sealed: UnsafeRawBufferPointer) -> [UInt8]? {
        guard sealed.count >= Age.tagSize,
              let box = try? ChaChaPoly.SealedBox(nonce: Age.nonce(index, last: index == pieces - 1),
                                                   ciphertext: UnsafeRawBufferPointer(rebasing: sealed.dropLast(Age.tagSize)),
                                                   tag: UnsafeRawBufferPointer(rebasing: sealed.suffix(Age.tagSize))),
              let plain = try? ChaChaPoly.open(box, using: key) else { return nil }
        return Array(plain)
    }
}

/// scrypt (RFC 7914), for age's password key: memory-hard, so guessing passwords is slow even with
/// special hardware. N = 2^18, r = 8 takes 256 MB and about a second.
enum Scrypt {
    static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8]? {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0 else { return nil }
        let blockWords = 32 * r
        var b = pbkdf2(password, salt, length: p * 128 * r)
        guard b.count == p * 128 * r else { return nil }
        var words = [UInt32](repeating: 0, count: p * blockWords)
        b.withUnsafeBytes { raw in
            for i in 0..<words.count { words[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }
        let v = UnsafeMutablePointer<UInt32>.allocate(capacity: n * blockWords)
        let x = UnsafeMutablePointer<UInt32>.allocate(capacity: blockWords)
        let y = UnsafeMutablePointer<UInt32>.allocate(capacity: blockWords)
        let t = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        defer {
            v.deallocate()
            x.deallocate()
            y.deallocate()
            t.deallocate()
        }
        for block in 0..<p {
            words.withUnsafeMutableBufferPointer { all in
                let start = all.baseAddress! + block * blockWords
                x.update(from: start, count: blockWords)
                for i in 0..<n {
                    (v + i * blockWords).update(from: x, count: blockWords)
                    blockMix(x, y, t, r)
                }
                for _ in 0..<n {
                    let j = Int(x[(2 * r - 1) * 16]) & (n - 1)
                    let vj = v + j * blockWords
                    for k in 0..<blockWords { x[k] ^= vj[k] }
                    blockMix(x, y, t, r)
                }
                start.update(from: x, count: blockWords)
            }
        }
        b = words.flatMap { word in withUnsafeBytes(of: word.littleEndian) { Array($0) } }
        return pbkdf2(password, b, length: length)
    }

    private static func pbkdf2(_ password: [UInt8], _ salt: [UInt8], length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 pw.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1, &out, length)
        }
        return status == kCCSuccess ? out : []
    }

    /// BlockMix with Salsa20/8, in place in `b` (2r blocks of 16 words), using `y` and `t` as room.
    @inline(__always)
    private static func blockMix(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>,
                                 _ t: UnsafeMutablePointer<UInt32>, _ r: Int) {
        t.update(from: b + (2 * r - 1) * 16, count: 16)
        for i in 0..<(2 * r) {
            let block = b + i * 16
            for k in 0..<16 { t[k] ^= block[k] }
            salsa8(t)
            // Even blocks to the first half, odd to the second.
            (y + (i % 2 == 0 ? i / 2 : r + i / 2) * 16).update(from: t, count: 16)
        }
        b.update(from: y, count: 32 * r)
    }

    @inline(__always)
    private static func salsa8(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        @inline(__always) func rotl(_ a: UInt32, _ n: UInt32) -> UInt32 { (a << n) | (a >> (32 - n)) }
        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7); x8 ^= rotl(x4 &+ x0, 9); x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7); x13 ^= rotl(x9 &+ x5, 9); x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9); x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9); x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7); x2 ^= rotl(x1 &+ x0, 9); x3 ^= rotl(x2 &+ x1, 13); x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7); x7 ^= rotl(x6 &+ x5, 9); x4 ^= rotl(x7 &+ x6, 13); x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9); x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9); x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }
        b[0] &+= x0; b[1] &+= x1; b[2] &+= x2; b[3] &+= x3; b[4] &+= x4; b[5] &+= x5; b[6] &+= x6; b[7] &+= x7
        b[8] &+= x8; b[9] &+= x9; b[10] &+= x10; b[11] &+= x11; b[12] &+= x12; b[13] &+= x13; b[14] &+= x14; b[15] &+= x15
    }
}
