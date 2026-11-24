import AppKit
import SwiftUI
import Network

/// The Receive side: letting other Macs find this one, and unpacking what they send as it arrives.
@MainActor
final class ReceiveModel: ObservableObject {
    static let shared = ReceiveModel()

    enum Stage {
        case off
        case waiting
        case offered(Wire.Offer, code: String, peer: String, kind: String)
        case receiving(Wire.Offer, peer: String)
        case finished(ReceiveSession.Summary)
        case failed(String)
        case stopped
    }

    @Published private(set) var stage: Stage = .off
    @Published private(set) var status: Advertiser.Status = .starting
    @Published private(set) var destination: URL
    @Published private(set) var room: PackModel.Room?
    @Published private(set) var progress = Unpacker.Progress()
    @Published private(set) var meter = RateMeter()
    @Published private(set) var addresses: [String] = []
    @Published private(set) var finishedAt: Date?
    /// Something that happened while waiting (a sender gave up, say).
    @Published private(set) var notice: String?
    @Published var showingProblems = false

    private var advertiser: Advertiser?
    private var session: ReceiveSession?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var active = false
    private static let folderKey = "receiveFolder"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        if let saved, FileManager.default.fileExists(atPath: saved.path) {
            destination = saved
        } else {
            destination = downloads
        }
    }

    var isBusy: Bool {
        if case .receiving = stage { return true }
        return false
    }

    var isOffered: Bool {
        if case .offered = stage { return true }
        return false
    }

    // MARK: Being found

    func setActive(_ on: Bool) {
        active = on
        if on {
            startListening()
        } else if session == nil {
            stopListening()
        }
    }

    private func startListening() {
        refreshRoom()
        addresses = ThisMac.addresses()
        if case .off = stage { stage = .waiting }
        guard advertiser == nil else { return }
        let advertiser = Advertiser(onConnection: { connection in
            onMain { ReceiveModel.shared.incoming(connection) }
        }, onStatus: { status in
            onMain { ReceiveModel.shared.status = status }
        })
        self.advertiser = advertiser
        status = .starting
        advertiser.start()
    }

    private func stopListening() {
        advertiser?.stop()
        advertiser = nil
        if case .waiting = stage { stage = .off }
    }

    private func incoming(_ connection: NWConnection) {
        // One at a time: another Mac trying meanwhile is turned away.
        guard session == nil, active else {
            connection.cancel()
            return
        }
        notice = nil
        let session = ReceiveSession(connection: connection, me: ThisMac.identity) { event in
            onMain { ReceiveModel.shared.handle(event) }
        }
        self.session = session
        session.start()
    }

    private func handle(_ event: ReceiveSession.Event) {
        switch event {
        case .offer(let offer, let code, let peer, let kind):
            stage = .offered(offer, code: code, peer: peer, kind: kind)
            if AppModel.shared.mode != .receive { AppModel.shared.mode = .receive }
            NSApp.requestUserAttention(.criticalRequest)
        case .started:
            if case .offered(let offer, _, let peer, _) = stage { stage = .receiving(offer, peer: peer) }
            progress = Unpacker.Progress()
            meter.reset()
            finishedAt = nil
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Receiving a folder from another Mac")
            let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
                MainActor.assumeIsolated { ReceiveModel.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            AppModel.shared.activityChanged()
        case .finished(let summary):
            end(.finished(summary))
        case .failed(let message):
            end(.failed(message))
        case .stopped:
            end(.stopped)
        case .dismissed(let reason):
            // Declined here (already back to waiting), or the sender gave up before an answer.
            let wasOffered = isOffered
            session = nil
            if wasOffered {
                stage = active ? .waiting : .off
                notice = reason
            }
            if !active { stopListening() }
        }
    }

    func accept() {
        guard isOffered else { return }
        refreshRoom()
        session?.accept(into: destination)
    }

    func decline() {
        guard isOffered else { return }
        session?.decline()
        stage = .waiting
    }

    func stop() {
        session?.cancel()
    }

    private func tick() {
        guard let session, let progress = session.progress() else { return }
        self.progress = progress
        meter.add(bytes: progress.bytes, files: progress.files)
    }

    private func end(_ final: Stage) {
        timer?.invalidate()
        timer = nil
        if let progress = session?.progress() { self.progress = progress }
        session = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        stage = final
        if case .finished = final { finishedAt = Date() }
        refreshRoom()
        AppModel.shared.activityChanged()
        if !active { stopListening() }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Back to waiting for the next one.
    func done() {
        stage = active ? .waiting : .off
        notice = nil
    }

    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Receive Into"
        panel.prompt = "Choose"
        panel.message = "Folders from other Macs go here, each under a name not already taken."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        refreshRoom()
    }

    private func refreshRoom() {
        room = PackModel.Room(folder: destination)
    }

    var summary: ReceiveSession.Summary? {
        if case .finished(let summary) = stage { return summary }
        return nil
    }

    func showInFinder() {
        guard let output = summary?.unpack.output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    // MARK: What the window says

    var stageKey: Int {
        switch stage {
        case .off, .waiting: 0
        case .offered: 1
        case .receiving: 2
        case .finished: 3
        case .failed: 4
        case .stopped: 5
        }
    }

    var statusText: String {
        switch status {
        case .starting: return "Getting ready…"
        case .ready: return "Ready to receive"
        case .denied: return "Can't be found"
        case .failed: return "Can't be found"
        }
    }

    var addressText: String? {
        guard case .ready(let port) = status, let first = addresses.first else { return nil }
        return port == Nearby.port ? first : "\(first):\(port)"
    }

    var offer: Wire.Offer? {
        switch stage {
        case .offered(let offer, _, _, _), .receiving(let offer, _): offer
        default: nil
        }
    }

    var fraction: Double? {
        guard let total = progress.total, total > 0 else { return nil }
        if progress.finishing { return 1 }
        return min(1, Double(progress.processed) / Double(total))
    }

    var percentText: String {
        if progress.cleaning { return "Stopping…" }
        guard let fraction else { return "Receiving…" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var etaText: String {
        if progress.cleaning { return "Deleting what arrived…" }
        if progress.finishing { return "Setting dates and links…" }
        guard let total = progress.total, let fraction, fraction > 0.01, meter.bytesPerSecond > 0 else {
            return "Working out the time left…"
        }
        let left = Double(total - progress.processed) / meter.bytesPerSecond
        return "About \(Format.duration(max(left, 0))) left"
    }

    var timeValue: String {
        Format.clock(Date().timeIntervalSince(progress.started))
    }
}
