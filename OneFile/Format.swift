import Foundation

/// Numbers, sizes, times and paths as the window shows them.
enum Format {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// A drive's block size, as drives give it: "128 KB", "4 KB", "1 MB".
    static func block(_ size: Int64) -> String {
        size >= 1 << 20 && size % (1 << 20) == 0 ? "\(size >> 20) MB" : "\(size >> 10) KB"
    }

    static func count(_ number: Int64) -> String {
        number.formatted()
    }

    /// "1 item", "2,500 items".
    static func items(_ number: Int64) -> String {
        "\(count(number)) \(number == 1 ? "item" : "items")"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1f s", max(seconds, 0)) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3_600 { return "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3_600) h \((whole % 3_600) / 60) min"
    }

    /// "0:42", "12:05", "1:02:33".
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        let hours = whole / 3_600, minutes = (whole % 3_600) / 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }

    /// A folder's path with the home folder as "~".
    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Runs `work` on the main thread, in order with other such calls.
func onMain(_ work: @escaping @Sendable @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { work() }
    }
}
