import AppKit
import SwiftUI
import Network

/// The Send side: Macs nearby, and sending the folder (chosen in `PackModel`) to one of them.
@MainActor
final class SendModel: ObservableObject {
    static let shared = SendModel()

    enum Stage {
        case ready
        case connecting(String)
        /// Connected: waiting for the other Mac to accept, both showing this code.
        case waiting(String, code: String)
        case sending(String, code: String)
        case finished(SendSession.Summary)
        case declined(String)
        case failed(String)
        case stopped
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var browseStatus: PeerBrowser.Status = .searching
    @Published var selectedID: String?
    @Published private(set) var stage: Stage = .ready {
        // The folder side locks while sending: let its views know.
        willSet { PackModel.shared.objectWillChange.send() }
    }
    @Published private(set) var progress = Packer.Progress()
    @Published private(set) var remote = SendSession.Remote()
    @Published private(set) var meter = RateMeter()
    @Published private(set) var finishedAt: Date?
    /// The person here confirmed both Macs show the same code.
    @Published private(set) var confirmed = false
    /// The other Mac accepted.
    @Published private(set) var otherAccepted = false
    @Published var address = ""
    @Published var showingAddress = false

    private var found: [Peer] = []
    private var typed: [Peer] = []
    private var browser: PeerBrowser?
    private var session: SendSession?
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    var isBusy: Bool {
        switch stage {
        case .connecting, .waiting, .sending: true
        default: false
        }
    }

    var selectedPeer: Peer? { peers.first { $0.id == selectedID } }

    var canSend: Bool {
        let pack = PackModel.shared
        return pack.source != nil && selectedPeer != nil && !isBusy && !pack.isPacking && !pack.countFailed
    }

    // MARK: Finding Macs

    func setBrowsing(_ on: Bool) {
        if on {
            guard browser == nil else { return }
            let browser = PeerBrowser(onPeers: { peers in
                onMain { SendModel.shared.found(peers) }
            }, onStatus: { status in
                onMain { SendModel.shared.browseStatus = status }
            })
            self.browser = browser
            browseStatus = .searching
            browser.start()
        } else if !isBusy {
            browser?.stop()
            browser = nil
        }
    }

    /// The Macs the browser found.
    func found(_ peers: [Peer]) {
        found = peers
        merge()
        if selectedPeer == nil && self.peers.count == 1 { selectedID = self.peers[0].id }
    }

    private func merge() {
        peers = found + typed.filter { manual in !found.contains { $0.name == manual.name } }
        if let selectedID, !peers.contains(where: { $0.id == selectedID }), !isBusy { self.selectedID = nil }
    }

    /// A Mac typed in by its address.
    func addAddress() {
        guard let peer = Peer.manual(address) else { return }
        typed.removeAll { $0.id == peer.id }
        typed.append(peer)
        merge()
        selectedID = peer.id
        address = ""
        showingAddress = false
    }

    func select(_ peer: Peer) {
        guard !isBusy else { return }
        selectedID = peer.id
        if case .ready = stage {} else { stage = .ready }
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sending

    func send() {
        if case .waiting = stage {
            confirm()
            return
        }
        guard canSend, let peer = selectedPeer, let source = PackModel.shared.source else { return }
        let pack = PackModel.shared
        let session = SendSession(endpoint: peer.endpoint, peerName: peer.name, source: source, options: pack.options,
                                  totals: pack.knownTotals, me: ThisMac.identity) { event in
            onMain { SendModel.shared.handle(event) }
        }
        self.session = session
        progress = Packer.Progress()
        remote = SendSession.Remote()
        meter.reset()
        finishedAt = nil
        confirmed = false
        otherAccepted = false
        stage = .connecting(peer.name)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Sending a folder to another Mac")
        AppModel.shared.activityChanged()
        session.start()
    }

    func stop() {
        session?.cancel()
    }

    /// Both Macs show the same code: go ahead (once the other Mac accepts too).
    func confirm() {
        guard case .waiting = stage, !confirmed else { return }
        confirmed = true
        session?.confirm()
    }

    private func handle(_ event: SendSession.Event) {
        switch event {
        case .connecting:
            break
        case .code(let code, let peer):
            stage = .waiting(peer, code: code)
        case .answered:
            otherAccepted = true
        case .accepted:
            if case .waiting(let peer, let code) = stage { stage = .sending(peer, code: code) }
            let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
                MainActor.assumeIsolated { SendModel.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        case .declined(let reason):
            end(.declined(reason))
        case .finished(let summary):
            end(.finished(summary))
        case .failed(let message):
            end(.failed(message))
        case .stopped:
            end(.stopped)
        }
    }

    private func tick() {
        guard let session else { return }
        if let packed = session.packerProgress() { progress = packed }
        remote = session.remote()
        meter.add(bytes: progress.processed, files: progress.files)
    }

    private func end(_ final: Stage) {
        timer?.invalidate()
        timer = nil
        if let session {
            if let packed = session.packerProgress() { progress = packed }
            remote = session.remote()
        }
        session = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        stage = final
        if case .finished = final { finishedAt = Date() }
        AppModel.shared.activityChanged()
        if AppModel.shared.mode != .send { setBrowsing(false) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func done() {
        stage = .ready
    }

    // MARK: What the window says

    var stageKey: Int {
        switch stage {
        case .ready: 0
        case .connecting: 1
        case .waiting: 2
        case .sending: 3
        case .finished: 4
        case .declined: 5
        case .failed: 6
        case .stopped: 7
        }
    }

    var peerName: String {
        switch stage {
        case .connecting(let name), .waiting(let name, _), .sending(let name, _): name
        case .finished(let summary): summary.peer
        default: selectedPeer?.name ?? ""
        }
    }

    var sendButtonTitle: String {
        guard let peer = selectedPeer else { return "Choose a Mac to Send To" }
        if case .counted(let totals) = PackModel.shared.count, totals.files > 0 {
            return "Send \(Format.count(totals.files)) \(totals.files == 1 ? "File" : "Files") to \(peer.name)"
        }
        return "Send to \(peer.name)"
    }

    private var total: Int64? {
        if let totals = progress.totals, totals.archiveBytes > 0 { return totals.archiveBytes }
        return nil
    }

    /// Unpacked on the other Mac: done means it's there.
    var fraction: Double? {
        guard let total else { return nil }
        return min(1, Double(remote.processed) / Double(total))
    }

    var sentFraction: Double? {
        guard let total else { return nil }
        return min(1, Double(progress.processed) / Double(total))
    }

    var percentText: String {
        guard let fraction else { return "Sending…" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var etaText: String {
        guard let total, let fraction, fraction > 0.01, meter.bytesPerSecond > 0 else { return "Working out the time left…" }
        let left = Double(total - remote.processed) / meter.bytesPerSecond
        return "About \(Format.duration(left)) left"
    }

    var wireText: String {
        let method = PackModel.shared.method
        guard progress.outputBytes > 0 else { return "Encrypted with AES-GCM · starting…" }
        var text = "\(Format.bytes(progress.outputBytes)) sent, encrypted"
        if method != .plain, progress.processed > 0 {
            let times = Double(progress.processed) / Double(progress.outputBytes)
            text += times < 1.05 ? " · barely smaller" : String(format: " · %.1f× smaller on the wire", times)
        }
        return text
    }

    var timeValue: String {
        Format.clock(Date().timeIntervalSince(progress.started))
    }
}
