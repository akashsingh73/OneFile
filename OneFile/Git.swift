import Foundation

/// What Git leaves out of a project (its `.gitignore` files, and Git's own excludes): build
/// output, dependencies, caches. Leaving those out packs or copies a project as a clean checkout
/// would have it, plus any new files that aren't ignored.
enum GitIgnore {
    /// A `git` that won't ask to install anything (macOS's own `/usr/bin/git` offers to install the
    /// Command Line Tools when they're missing).
    static let git: String? = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// What Git ignores in `folder`, as paths starting with its real path, as packing and copying
    /// walk it (a wholly ignored folder is one path). Nil if `folder` isn't in a Git project (or
    /// there's no Git).
    static func ignored(in given: String) -> [String]? {
        guard let git else { return nil }
        let folder = Copier.realPath(given)
        let inside = run(git, ["-C", folder, "rev-parse", "--is-inside-work-tree"])
        guard inside.status == 0, String(decoding: inside.output, as: UTF8.self).hasPrefix("true") else { return nil }
        // Paths come relative to `folder`, NUL-separated, folders ending in "/".
        let listed = run(git, ["-C", folder, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        guard listed.status == 0 else { return nil }
        return listed.output.split(separator: 0).compactMap { bytes in
            var path = String(decoding: bytes, as: UTF8.self)
            while path.hasSuffix("/") { path.removeLast() }
            return path.isEmpty ? nil : folder + "/" + path
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: [UInt8]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, [])
        }
        // Read before waiting: a full pipe would otherwise stop git for good.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, [UInt8](data))
    }
}
