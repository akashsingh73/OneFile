import Foundation

/// OneFile's version, for the app (build.sh reads it from here) and the `onefile` command.
enum OneFileVersion {
    static let current = "3.0"
    /// Goes up with every build that's handed out.
    static let build = "5"
}
