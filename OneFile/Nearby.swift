import Foundation
import Network
import IOKit.ps
import SystemConfiguration

// MARK: - This Mac

enum ThisMac {
    struct Identity: Sendable {
        /// The computer's name, as in System Settings › General › Sharing.
        let name: String
        /// "laptop" or "desktop", for the icon other Macs show.
        let kind: String
        /// This run of OneFile, so it can leave itself out of the Macs it finds.
        let instance: String
    }

    static let identity = Identity(name: computerName(), kind: hasBattery() ? "laptop" : "desktop",
                                   instance: UUID().uuidString)

    /// The computer's name; or the name set with `defaults write local.onefile.app displayName …`.
    static func computerName() -> String {
        let chosen = ProcessInfo.processInfo.environment["ONEFILE_NAME"] ?? UserDefaults.standard.string(forKey: "displayName")
        if let chosen, !chosen.isEmpty { return chosen }
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    static func hasBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
    }

    static func symbol(_ kind: String) -> String {
        kind == "laptop" ? "laptopcomputer" : "desktopcomputer"
    }

    /// This Mac's addresses on its networks (Wi-Fi, Ethernet, Thunderbolt Bridge), for connecting by
    /// hand when finding each other doesn't work.
    static func addresses() -> [String] {
        if let shown = ProcessInfo.processInfo.environment["ONEFILE_ADDRESS"] { return [shown] }
        var found: [(interface: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = item.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let interface = String(cString: item.ifa_name)
            guard interface.hasPrefix("en") || interface.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append((interface, text))
        }
        return found.sorted { $0.interface < $1.interface }.map(\.address)
    }

    /// A name another Mac sent, made safe to use as a file name here.
    static func safeName(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.filter { $0 != "\0" && $0 != "/" && $0 != ":" }.map(Character.init))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "Received" }
        return String(cleaned.prefix(200))
    }
}

// MARK: - Finding other Macs

/// Another Mac running OneFile, ready to receive.
struct Peer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    let endpoint: NWEndpoint

    /// A Mac typed in by address ("192.168.1.20", or "imac.local:52525").
    static func manual(_ text: String) -> Peer? {
        var host = text.trimmingCharacters(in: .whitespaces)
        var port = Nearby.port
        if let colon = host.lastIndex(of: ":"), !host.contains("]"), host.filter({ $0 == ":" }).count == 1,
           let number = UInt16(host[host.index(after: colon)...]) {
            port = number
            host = String(host[..<colon])
        }
        guard !host.isEmpty, !host.contains(" "), let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return Peer(id: "address:\(host):\(port)", name: host, kind: "desktop",
                    endpoint: .hostPort(host: NWEndpoint.Host(host), port: endpointPort))
    }
}

enum Nearby {
    /// The port OneFile listens on when it can (else any free one).
    static let port: UInt16 = 52_525

    /// Whether to look for and announce Macs with Bonjour. (Off with ONEFILE_NO_BONJOUR=1, for
    /// tests: then Macs connect only by address.)
    static let bonjour = ProcessInfo.processInfo.environment["ONEFILE_NO_BONJOUR"] == nil

    static let deniedMessage = "OneFile isn't allowed to look for Macs on your network. Turn it on in System Settings › Privacy & Security › Local Network."

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 4
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    static func isDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }
}

/// Looks for Macs that are ready to receive (OneFile open on Receive), for as long as it runs.
final class PeerBrowser: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case searching
        case denied
        case failed(String)
    }

    private let browser = Locked<NWBrowser?>(nil)
    private let queue = DispatchQueue(label: "OneFile.browser")
    private let onPeers: @Sendable ([Peer]) -> Void
    private let onStatus: @Sendable (Status) -> Void

    init(onPeers: @escaping @Sendable ([Peer]) -> Void, onStatus: @escaping @Sendable (Status) -> Void) {
        self.onPeers = onPeers
        self.onStatus = onStatus
    }

    func start() {
        stop()
        guard Nearby.bonjour else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.service, domain: nil), using: Nearby.parameters())
        let onStatus = self.onStatus
        let onPeers = self.onPeers
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onStatus(.searching)
            case .waiting(let error), .failed(let error):
                onStatus(Nearby.isDenied(error) ? .denied : .failed(Link.describe(error)))
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let me = ThisMac.identity.instance
            var seen = Set<String>()
            var peers: [Peer] = []
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                var id = name
                var kind = "desktop"
                if case .bonjour(let record) = result.metadata {
                    if let value = record["id"] { id = value }
                    if let value = record["kind"] { kind = value }
                }
                guard id != me, seen.insert(id).inserted else { continue }
                peers.append(Peer(id: id, name: name, kind: kind, endpoint: result.endpoint))
            }
            onPeers(peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        self.browser.withLock { $0 = browser }
        browser.start(queue: queue)
    }

    func stop() {
        browser.withLock { browser in
            browser?.cancel()
            browser = nil
        }
    }
}

/// Lets other Macs find this one and connect to it, while it's on.
final class Advertiser: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case denied
        case failed(String)
    }

    private let listener = Locked<NWListener?>(nil)
    private let queue = DispatchQueue(label: "OneFile.listener")
    private let onConnection: @Sendable (NWConnection) -> Void
    private let onStatus: @Sendable (Status) -> Void

    init(onConnection: @escaping @Sendable (NWConnection) -> Void, onStatus: @escaping @Sendable (Status) -> Void) {
        self.onConnection = onConnection
        self.onStatus = onStatus
    }

    /// Starts listening, on OneFile's own port if it's free (so it can be typed in), else any.
    /// `advertise` false only listens, without telling the network (for tests).
    func start(advertise: Bool = true) {
        stop()
        onStatus(.starting)
        listen(on: NWEndpoint.Port(rawValue: Nearby.port)!, fallback: true, advertise: advertise)
    }

    private func listen(on port: NWEndpoint.Port, fallback: Bool, advertise: Bool) {
        guard let listener = try? NWListener(using: Nearby.parameters(), on: port) else {
            if fallback {
                listen(on: .any, fallback: false, advertise: advertise)
            } else {
                onStatus(.failed("Couldn't start listening for other Macs."))
            }
            return
        }
        if advertise && Nearby.bonjour {
            let me = ThisMac.identity
            let record = NWTXTRecord(["id": me.instance, "kind": me.kind, "v": String(Wire.version)])
            listener.service = NWListener.Service(name: me.name, type: Wire.service, domain: nil, txtRecord: record)
        }
        let onStatus = self.onStatus
        let onConnection = self.onConnection
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                onStatus(.ready(port: listener?.port?.rawValue ?? 0))
            case .failed(let error):
                listener?.cancel()
                if fallback, let self {
                    self.listen(on: .any, fallback: false, advertise: advertise)
                } else {
                    onStatus(Nearby.isDenied(error) ? .denied : .failed(Link.describe(error)))
                }
            case .waiting(let error):
                if Nearby.isDenied(error) { onStatus(.denied) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in onConnection(connection) }
        self.listener.withLock { $0 = listener }
        listener.start(queue: queue)
    }

    func stop() {
        listener.withLock { listener in
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
        }
    }
}
