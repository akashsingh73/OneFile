import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the window is for right now, and what's going on in each part.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Mode: String, CaseIterable, Identifiable {
        case pack, unpack, copy, send, receive

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pack: "Pack"
            case .unpack: "Unpack"
            case .copy: "Copy"
            case .send: "Send"
            case .receive: "Receive"
            }
        }

        var symbol: String {
            switch self {
            case .pack: "shippingbox.fill"
            case .unpack: "archivebox.fill"
            case .copy: "externaldrive.fill"
            case .send: "paperplane.fill"
            case .receive: "tray.and.arrow.down.fill"
            }
        }

        var tagline: String {
            switch self {
            case .pack: "Millions of files into one file, fast."
            case .unpack: "One file back into a folder, on every core."
            case .copy: "To another drive, many files at once."
            case .send: "Straight to another Mac, encrypted."
            case .receive: "From another Mac, as it's packed."
            }
        }

        var verb: String {
            switch self {
            case .pack: "packing"
            case .unpack: "unpacking"
            case .copy: "copying"
            case .send: "sending"
            case .receive: "receiving"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .pack: "1"
            case .unpack: "2"
            case .copy: "3"
            case .send: "4"
            case .receive: "5"
            }
        }
    }

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            modeChanged()
        }
    }

    private var dockTimer: Timer?

    init() {
        mode = UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init(rawValue:)) ?? .pack
    }

    /// Call once the window is up: starts what the first mode needs.
    func start() {
        modeChanged()
    }

    private func modeChanged() {
        // Other Macs can find this one only while Receive shows (or a folder is arriving).
        ReceiveModel.shared.setActive(mode == .receive)
        SendModel.shared.setBrowsing(mode == .send)
    }

    func isBusy(_ mode: Mode) -> Bool {
        switch mode {
        case .pack: PackModel.shared.isPacking
        case .unpack: UnpackModel.shared.isUnpacking
        case .copy: CopyModel.shared.isCopying
        case .send: SendModel.shared.isBusy
        case .receive: ReceiveModel.shared.isBusy
        }
    }

    var anythingBusy: Bool { Mode.allCases.contains { isBusy($0) } }

    // MARK: Opening things from Finder

    static let archiveTypes: [UTType] = [
        UTType("public.tar-archive"), UTType("org.gnu.gnu-zip-archive"), UTType("org.gnu.gnu-zip-tar-archive"),
        UTType("org.tukaani.xz-archive"), UTType("org.tukaani.tar-xz-archive"),
    ].compactMap { $0 }

    /// Folders and tar files dropped on the Dock icon, opened with OneFile, or sent from Finder's
    /// Services menu. A folder is packed (or sent or copied, if that's asked for or showing); a
    /// file is unpacked.
    func open(_ urls: [URL], as wanted: Mode? = nil) {
        guard let url = urls.first else { return }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        if isFolder.boolValue {
            let showing = wanted ?? mode
            let target: Mode = showing == .send || showing == .copy ? showing : .pack
            if PackModel.shared.setSource(url) { mode = target }
        } else if UnpackModel.shared.setArchive(url) {
            mode = .unpack
        }
        NSApp.activate()
    }

    // MARK: Quitting

    /// Asked when quitting: whatever is going on stops (and its unfinished work goes) only if the
    /// person agrees.
    func confirmQuit() -> Bool {
        let busy = Mode.allCases.filter { isBusy($0) }
        guard !busy.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = busy.count == 1 ? "Stop \(busy[0].verb) and quit?" : "Stop everything and quit?"
        alert.informativeText = busy == [.copy]
            ? "What's copied so far stays: copying again picks up where it stopped."
            : "What isn't finished is deleted\(busy.contains(.copy) ? " (a copy's progress stays, to pick up later)" : "")."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Going")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        PackModel.shared.stopForQuit()
        UnpackModel.shared.stopForQuit()
        CopyModel.shared.stopForQuit()
        SendModel.shared.stop()
        ReceiveModel.shared.stop()
        // Give them a moment to clean up.
        let deadline = Date().addingTimeInterval(3)
        while anythingBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return true
    }

    // MARK: Progress on the Dock icon

    /// Called when something starts or stops.
    func activityChanged() {
        if anythingBusy {
            if dockTimer == nil {
                let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated { AppModel.shared.updateDock() }
                }
                RunLoop.main.add(timer, forMode: .common)
                dockTimer = timer
            }
            updateDock()
        } else {
            dockTimer?.invalidate()
            dockTimer = nil
            DockProgress.hide()
        }
    }

    private func updateDock() {
        let fractions: [Double?] = [
            PackModel.shared.isPacking ? PackModel.shared.fraction : nil,
            UnpackModel.shared.isUnpacking ? UnpackModel.shared.fraction : nil,
            CopyModel.shared.isCopying ? CopyModel.shared.fraction : nil,
            SendModel.shared.isBusy ? SendModel.shared.fraction : nil,
            ReceiveModel.shared.isBusy ? ReceiveModel.shared.fraction : nil,
        ]
        let active = fractions.compactMap { $0 }
        guard anythingBusy else {
            DockProgress.hide()
            return
        }
        DockProgress.show(active.isEmpty ? nil : active.min())
    }
}

/// Speed over the last few seconds, and its history for the chart.
struct RateMeter {
    private var samples: [(time: TimeInterval, bytes: Int64, files: Int64)] = []
    private(set) var bytesPerSecond: Double = 0
    private(set) var filesPerSecond: Double = 0
    private(set) var history: [Double] = []
    private var lastHistory: TimeInterval = 0

    mutating func reset() {
        self = RateMeter()
    }

    mutating func add(bytes: Int64, files: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, bytes, files))
        while let first = samples.first, now - first.time > 3 { samples.removeFirst() }
        if let first = samples.first, now - first.time >= 0.4 {
            let seconds = now - first.time
            bytesPerSecond = max(0, Double(bytes - first.bytes) / seconds)
            filesPerSecond = max(0, Double(files - first.files) / seconds)
        }
        if now - lastHistory >= 0.25 {
            lastHistory = now
            history.append(bytesPerSecond)
            if history.count > 160 { history.removeFirst(history.count - 160) }
        }
    }

    var speedText: String { bytesPerSecond > 0 ? "\(Format.bytes(Int64(bytesPerSecond)))/s" : "–" }
    var filesText: String { filesPerSecond > 0 ? "\(Format.count(Int64(filesPerSecond))) files/s" : "" }
}

/// A progress bar drawn on OneFile's Dock icon while something's going on.
@MainActor
enum DockProgress {
    private static var view: DockProgressView?

    static func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        if view == nil {
            let made = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            view = made
            tile.contentView = made
        }
        view?.fraction = fraction
        tile.display()
    }

    static func hide() {
        guard view != nil else { return }
        view = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

final class DockProgressView: NSView {
    var fraction: Double?

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let track = NSRect(x: bounds.width * 0.14, y: bounds.height * 0.08, width: bounds.width * 0.72,
                           height: bounds.height * 0.10)
        let radius = track.height / 2
        NSColor(calibratedWhite: 0.08, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2).fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let filled: NSRect
        if let fraction {
            filled = NSRect(x: track.minX, y: track.minY, width: max(track.height, track.width * min(max(fraction, 0), 1)),
                            height: track.height)
        } else {
            // Not known yet: a stretch that glides back and forth.
            let time = Date().timeIntervalSinceReferenceDate
            let width = track.width * 0.3
            filled = NSRect(x: track.minX + (track.width - width) * (sin(time * 2) + 1) / 2, y: track.minY,
                            width: width, height: track.height)
        }
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.70, blue: 0.88, alpha: 1),
                                  ending: NSColor(srgbRed: 0.10, green: 0.30, blue: 0.72, alpha: 1))
        gradient?.draw(in: NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius), angle: 0)
    }
}
