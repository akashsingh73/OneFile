import Foundation

/// The `onefile` command, run as the program it is (test.sh builds it and says where, in
/// ONEFILE_CLI). Nothing here moves anything to the Trash: that's for people, not tests.
extension OneFileTests {
    struct CommandRun {
        let status: Int32
        let output: String
        let errors: String
    }

    /// Runs `onefile` with these arguments, nothing on standard input, and ONEFILE_PASSWORD set
    /// (or not); standard output goes to `outputFile` when there is one.
    static func onefile(_ arguments: [String], password: String? = nil, outputFile: String? = nil,
                        environment extra: [String: String] = [:]) -> CommandRun {
        guard let tool = ProcessInfo.processInfo.environment["ONEFILE_CLI"] else { return CommandRun(status: -1, output: "", errors: "") }
        let folder = FileManager.default.temporaryDirectory
        let out = outputFile.map(URL.init(fileURLWithPath:)) ?? folder.appendingPathComponent("OneFileCLI-\(UUID().uuidString).out")
        let err = folder.appendingPathComponent("OneFileCLI-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer {
            if outputFile == nil { try? FileManager.default.removeItem(at: out) }
            try? FileManager.default.removeItem(at: err)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ONEFILE_PASSWORD"] = password
        for (name, value) in extra { environment[name] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try? FileHandle(forWritingTo: out)
        process.standardError = try? FileHandle(forWritingTo: err)
        do {
            try process.run()
        } catch {
            return CommandRun(status: -1, output: "", errors: "\(error)")
        }
        process.waitUntilExit()
        let output = outputFile == nil ? (try? String(contentsOf: out, encoding: .utf8)) ?? "" : ""
        let errors = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        return CommandRun(status: process.terminationStatus, output: output, errors: errors)
    }

    static func cliTests(_ fixture: Fixture, _ c: Checks) {
        guard ProcessInfo.processInfo.environment["ONEFILE_CLI"] != nil else {
            c.section("The onefile command")
            print("  (Skipped: test.sh builds it and sets ONEFILE_CLI.)")
            return
        }
        let fm = FileManager.default
        // The folders are reached through a symbolic link, as /tmp is for /private/tmp: nothing
        // above the folder being packed or copied should get in the way.
        let real = fixture.base + "/cli-real"
        let base = fixture.base + "/cli"
        try? fm.createDirectory(atPath: real, withIntermediateDirectories: true)
        symlink(real, base)
        let tree = base + "/Tree"
        makeTree(tree)
        let out = base + "/out"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)

        c.section("onefile: asking it things")
        var run = onefile(["version"])
        c.expect(run.status == 0 && run.output.contains(OneFileVersion.current), "version: \(run.output)")
        run = onefile([])
        c.expect(run.status == 2 && run.output.contains("Usage:"), "no command shows how it's used, exit status 2")
        run = onefile(["help"])
        c.expect(run.status == 0 && run.output.contains("onefile pack FOLDER"), "help")
        run = onefile(["pack", tree, "--quick"])
        c.expect(run.status == 2 && run.errors.contains("--quick"), "an option it doesn't take: \(run.errors)")
        run = onefile(["pack", tree, "--method", "fast"])
        c.expect(run.status == 2, "a method it doesn't know")
        run = onefile(["frobnicate"])
        c.expect(run.status == 2, "a command it doesn't know")
        run = onefile(["pack", base + "/nothing-here"])
        c.expect(run.status == 1 && run.errors.contains("isn't a folder"), "a folder that isn't there: \(run.errors)")

        c.section("onefile pack, list, extract, check, unpack")
        run = onefile(["pack", tree, "--to", out])
        let archive = out + "/Tree.tar.gz"
        c.expect(run.status == 0 && fm.fileExists(atPath: archive), "packs into the folder given: \(run.output)\(run.errors)")
        c.expect(run.output.contains("Packed 62 files"), "says what it packed: \(run.output)")
        run = onefile(["list", archive])
        c.expect(run.status == 0 && run.output.contains("Tree/f0/sub0/file-0.txt") && run.output.contains("Tree/link -> f0"),
                 "lists what's inside")
        c.expect(run.output.contains("62 files"), "and how much: \(run.output.split(separator: "\n").last ?? "")")
        let taken = base + "/taken"
        run = onefile(["extract", archive, "f1", "*file-7.txt", "--to", taken])
        c.expect(run.status == 0, "takes out a folder and a pattern: \(run.output)\(run.errors)")
        c.expect((try? String(contentsOfFile: taken + "/file-7.txt", encoding: .utf8)) == "file 7\n", "the file the pattern matched")
        c.expect((try? fm.contentsOfDirectory(atPath: taken + "/f1"))?.count == 3, "the folder, with all that's in it")
        run = onefile(["extract", archive, "not/there.txt", "--to", taken])
        c.expect(run.status == 1 && run.errors.contains("not/there.txt"), "says when nothing has that name")
        run = onefile(["check", archive])
        c.expect(run.status == 0 && run.output.contains("match their SHA-256"), "checks every file: \(run.output)")
        let unpacked = base + "/unpacked"
        run = onefile(["unpack", archive, "--to", unpacked])
        c.expect(run.status == 0, "unpacks into a folder it makes: \(run.output)\(run.errors)")
        c.expect(compare(tree, unpacked + "/Tree", contents: true)?.identical == true, "what's unpacked is the same, byte for byte")
        run = onefile(["list", base + "/Tree/big.bin"])
        c.expect(run.status == 1, "a file that isn't an archive: \(run.errors)")

        c.section("onefile pack --method efficient (zstd)")
        run = onefile(["pack", tree, "--to", out, "--method", "efficient"])
        let zst = out + "/Tree.tar.zst"
        c.expect(run.status == 0 && fm.fileExists(atPath: zst), "packs a .tar.zst: \(run.output)\(run.errors)")
        run = onefile(["list", zst])
        c.expect(run.status == 0 && run.output.contains("Tree/f0/sub0/file-0.txt") && run.output.contains("62 files"),
                 "lists what's inside")
        run = onefile(["check", zst])
        c.expect(run.status == 0 && run.output.contains("match their SHA-256"), "checks every file: \(run.output)")
        run = onefile(["extract", zst, "big.bin", "--to", base + "/zst-big"])
        c.expect(run.status == 0 && fm.contentsEqual(atPath: base + "/zst-big/big.bin", andPath: tree + "/big.bin"), "takes one file out")
        run = onefile(["unpack", zst, "--to", base + "/zst-unpacked"])
        c.expect(run.status == 0 && compare(tree, base + "/zst-unpacked/Tree", contents: true)?.identical == true,
                 "unpacks it, byte for byte: \(run.errors)")
        if let zstd = homebrew("zstd") {
            let tested = self.run(zstd, ["-t", zst])
            c.expect(tested.status == 0, "zstd -t says it's sound: \(tested.errors)")
        }

        c.section("onefile pack to a pipe")
        let piped = out + "/piped.tar"
        run = onefile(["pack", tree, "--to", "-", "--method", "fastest"], outputFile: piped)
        c.expect(run.status == 0 && run.errors.contains("Packed 62 files"), "writes the archive to standard output, and says so on standard error")
        let listed = self.run("/usr/bin/tar", ["-tf", piped])
        c.expect(listed.status == 0 && listed.output.contains("Tree/big.bin"), "macOS's tar reads it")

        c.section("onefile pack, split and locked")
        run = onefile(["pack", tree, "--to", out + "/Locked", "--split", "3MB", "--lock"], password: "open sesame")
        let parts = ((try? fm.contentsOfDirectory(atPath: out)) ?? []).filter { $0.hasPrefix("Locked.tar.gz.age.") }.sorted()
        c.expect(run.status == 0 && parts.count >= 3 && parts.first == "Locked.tar.gz.age.001",
                 "parts of 3 MB, locked: \(parts) \(run.errors)")
        run = onefile(["unpack", out + "/Locked.tar.gz.age.002", "--to", base + "/wrong"], password: "open sesame!")
        c.expect(run.status == 1 && run.errors.contains("password"), "the wrong password doesn't open it: \(run.errors)")
        run = onefile(["unpack", out + "/Locked.tar.gz.age.002", "--to", base + "/locked"], password: "open sesame")
        c.expect(run.status == 0 && compare(tree, base + "/locked/Tree", contents: true)?.identical == true,
                 "the right one does, from any part: \(run.errors)")
        run = onefile(["extract", out + "/Locked.tar.gz.age.001", "big.bin", "--to", base + "/locked-big"], password: "open sesame")
        c.expect(run.status == 0 && fm.contentsEqual(atPath: base + "/locked-big/big.bin", andPath: tree + "/big.bin"),
                 "one file out of a locked, split archive")

        c.section("onefile copy and compare")
        let copies = base + "/copies"
        try? fm.createDirectory(atPath: copies, withIntermediateDirectories: true)
        run = onefile(["copy", tree, copies, "--verify"])
        c.expect(run.status == 0, "copies: \(run.output)\(run.errors)")
        run = onefile(["compare", tree, copies + "/Tree", "--contents"])
        c.expect(run.status == 0 && run.output.contains("The same"), "the copy is the same: \(run.output)")
        try? "changed\n".write(toFile: tree + "/f1/sub1/file-1.txt", atomically: false, encoding: .utf8)
        try? fm.removeItem(atPath: tree + "/f2/sub2/file-2.txt")
        run = onefile(["compare", tree, copies + "/Tree"])
        c.expect(run.status == 3 && run.output.contains("only in the second: f2/sub2/file-2.txt")
                 && run.output.contains("f1/sub1/file-1.txt"), "finds what changed, exit status 3: \(run.output)")
        run = onefile(["copy", tree, copies, "--mirror"])
        c.expect(run.status == 0 && run.output.contains("there already") && run.output.contains("f2/sub2/file-2.txt")
                 && run.output.contains("--yes"), "copies only what changed, and lists what the original no longer has: \(run.output)")
        c.expect(fm.fileExists(atPath: copies + "/Tree/f2/sub2/file-2.txt"), "without moving it to the Trash, unasked")
        c.expect((try? String(contentsOfFile: copies + "/Tree/f1/sub1/file-1.txt", encoding: .utf8)) == "changed\n", "the changed file is copied")
        run = onefile(["copy", tree, tree + "/f0"])
        c.expect(run.status == 1 && run.errors.contains("inside"), "not into itself: \(run.errors)")

        c.section("onefile delete")
        run = onefile(["delete", copies + "/Tree"])
        c.expect(run.status == 1 && run.errors.contains("--yes") && fm.fileExists(atPath: copies + "/Tree"),
                 "won't delete without asking, and can't ask here")
        run = onefile(["delete", copies + "/Tree", "--yes"])
        c.expect(run.status == 0 && !fm.fileExists(atPath: copies + "/Tree"), "deletes with --yes: \(run.output)\(run.errors)")
        run = onefile(["delete", NSHomeDirectory(), "--yes"])
        c.expect(run.status == 1 && fm.fileExists(atPath: NSHomeDirectory()), "refuses the home folder: \(run.errors)")

        if let git = GitIgnore.git {
            c.section("onefile pack --git-ignore")
            let project = base + "/Project"
            try? fm.createDirectory(atPath: project + "/build", withIntermediateDirectories: true)
            try? "build/\n".write(toFile: project + "/.gitignore", atomically: false, encoding: .utf8)
            try? "code\n".write(toFile: project + "/main.swift", atomically: false, encoding: .utf8)
            try? "output\n".write(toFile: project + "/build/app", atomically: false, encoding: .utf8)
            _ = self.run(git, ["-C", project, "init", "-q"])
            run = onefile(["pack", project, "--to", out, "--git-ignore", "--method", "fastest"])
            let names = self.run("/usr/bin/tar", ["-tf", out + "/Project.tar"]).output
            c.expect(run.status == 0 && names.contains("Project/main.swift") && !names.contains("build"),
                     "leaves out what Git ignores: \(names.split(separator: "\n"))")
            run = onefile(["pack", tree, "--to", out + "/NoGit", "--git-ignore"])
            c.expect(run.status == 1 && run.errors.contains("Git"), "says so when Git doesn't keep the folder")
        }
    }
}
