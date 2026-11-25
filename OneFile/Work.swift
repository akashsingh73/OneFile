import Foundation
import IOKit.ps

/// How hard OneFile works: flat out (the default), or gently, leaving the disks and the cores to
/// whatever else the Mac is doing.
enum Work {
    static let gentleKey = "workGently"
    static let pauseOnBatteryKey = "pauseOnBattery"

    static var gentle: Bool { UserDefaults.standard.bool(forKey: gentleKey) }
    static var pauseOnBattery: Bool { UserDefaults.standard.bool(forKey: pauseOnBatteryKey) }

    /// For a job's threads, read when it starts.
    static var qos: QualityOfService { gentle ? .utility : .userInitiated }
    static var dispatchQoS: DispatchQoS { gentle ? .utility : .userInitiated }

    private static let running = Locked(0)

    /// A job started or ended: the disk priority follows (it's the whole app's).
    static func jobStarted() {
        running.withLock { $0 += 1 }
        applyDiskPriority()
    }

    static func jobEnded() {
        running.withLock { $0 = max(0, $0 - 1) }
        applyDiskPriority()
    }

    /// While a job runs gently, OneFile's reads and writes wait for everyone else's, the way Time
    /// Machine's do. (Also called when the setting changes.)
    static func applyDiskPriority() {
        let busy = running.withLock { $0 > 0 }
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, busy && gentle ? IOPOL_THROTTLE : IOPOL_DEFAULT)
    }
}

/// Lets a job be paused between files, and resumed. Its threads call `wait()` where stopping
/// for a while is safe.
final class PauseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var released = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused && !released
    }

    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// The job is ending: nothing waits any more.
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    /// Waits while paused.
    func wait() {
        condition.lock()
        while paused && !released { condition.wait() }
        condition.unlock()
    }
}

/// Watches whether the Mac runs on its battery, to pause work while it does (when asked to).
@MainActor
final class PowerWatcher {
    static let shared = PowerWatcher()

    private(set) var onBattery = false
    private var source: CFRunLoopSource?

    /// Called when the Mac goes onto its battery or back onto power.
    var changed: [@MainActor (Bool) -> Void] = []

    func start() {
        guard source == nil, ThisMac.hasBattery() else { return }
        onBattery = Self.readOnBattery()
        let made = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerWatcher.shared.check() }
        }, nil)?.takeRetainedValue()
        if let made {
            CFRunLoopAddSource(CFRunLoopGetMain(), made, .defaultMode)
            source = made
        }
    }

    private func check() {
        let now = Self.readOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        for handler in changed { handler(now) }
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
