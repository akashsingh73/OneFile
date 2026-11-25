import Foundation

/// `onefile`: OneFile's engine for Terminal and scripts. It's built from the same files as the app,
/// less the ones that draw windows (build.sh leaves out every file that imports SwiftUI or AppKit).
enum Command {
    static let usage = """
        onefile \(OneFileVersion.current): move folders of millions of files, fast.

        Usage:
          onefile pack FOLDER [--to FILE|FOLDER|-|CLOUD] [--method METHOD] [--split SIZE]
                              [--lock] [--leave-out NAMES] [--git-ignore] [--link]
          onefile unpack ARCHIVE [--to FOLDER]
          onefile copy FOLDER INTO-FOLDER [--new] [--verify] [--mirror] [--yes]
                              [--leave-out NAMES] [--git-ignore]
          onefile list ARCHIVE
          onefile extract ARCHIVE PATH... [--to FOLDER]
          onefile check ARCHIVE
          onefile compare FOLDER FOLDER [--contents] [--leave-out NAMES]
          onefile speedtest FOLDER
          onefile delete FOLDER [--yes]
          onefile backup [--due] | list | add FOLDER DRIVE-FOLDER [--every plug-in|day|week]
                              [--verify] [--git-ignore] [--leave-out NAMES] | remove NUMBER
                              | background on|off
          onefile cloud list | add NAME --service SERVICE ... | remove NAME | files CLOUD
                              | delete CLOUD-ARCHIVE [--yes]
          onefile link CLOUD-ARCHIVE [--days N]

        pack       Packs a folder into one tar file. METHOD is fastest (not compressed), balanced
                   (the default: gzip, on every core), efficient (zstd, on every core: smaller
                   than balanced and quicker, but it opens only where OneFile or zstd is) or
                   smallest (xz). --to - writes it to standard output, for a pipe. --split makes
                   parts of SIZE (like 4GB or 500MB), for a FAT32 drive or an upload limit.
                   --lock asks for a password (the age format).
        unpack     Unpacks a tar file into a folder of its name: from any of its parts, locked,
                   or on the internet (read as it goes, nothing downloaded first).
        copy       Copies a folder into another, on another drive say, many files at a time.
                   Stopped, the same command picks up where it was. If a copy is there already,
                   only what's new or changed is copied (--new makes another beside it).
                   --verify reads every file back from the drive and checks it. --mirror moves
                   what the original no longer has to the Trash (asking first, unless --yes).
        list       Lists what's in an archive packed by OneFile 3 (from its index), at once.
        extract    Takes files or folders out of an archive packed by OneFile 3, reading only
                   their part of it. PATH is as list shows it, or a pattern like '*.csv'.
        check      Checks every file in an archive packed by OneFile 3 against its SHA-256.
        compare    Compares two folders: names, sizes and dates, or with --contents every byte.
        speedtest  Measures a drive with many small files, and with one big one.
        delete     Deletes a folder for good, many files at a time (asking first, unless --yes).
        backup     Backs folders up to drives when they're plugged in (set up here or in the app's
                   Drives). With nothing after it, runs every backup to the drives plugged in now;
                   --due runs only those that are due (what the background task runs). "add" sets
                   one up: the folder goes inside DRIVE-FOLDER, updated like copy does, and
                   nothing on the drive is deleted. "background on" runs them when a drive is
                   plugged in even when OneFile isn't open.
        cloud      Accounts for packing to the cloud and unpacking from it. SERVICE is aws, r2, b2,
                   gcs, wasabi or other (S3-compatible: --bucket, --key-id, and --region,
                   --endpoint or --account as the service needs; the secret key is asked for), or
                   google-drive (--client-id of your own Google Cloud client; its secret is asked
                   for, then you sign in in the browser). --folder is where archives go
                   (OneFile, unless you say).
        link       A link to download an archive in the cloud: signed for --days (at most 7) at an
                   S3 service, shared with anyone who has it in Google Drive.

        ARCHIVE is a file, a link (https://…), or an archive in the cloud. CLOUD is cloud:NAME
        (an account), cloud:NAME/FILE, or s3://BUCKET/KEY with AWS_ACCESS_KEY_ID,
        AWS_SECRET_ACCESS_KEY and AWS_REGION (and AWS_ENDPOINT_URL for a service other than
        Amazon's) set. Packing to the cloud sends the archive as it's packed; --link prints a
        link to it after.

        NAMES are names or patterns separated by commas, like ".DS_Store,*.tmp" (the default is
        .DS_Store). --git-ignore leaves out what Git ignores, in a folder Git keeps.
        A locked archive asks for its password, or takes it from ONEFILE_PASSWORD.

        onefile follows OneFile's Work gently setting.

        Exit status: 0 done; 1 it failed, or some files couldn't be read or written; 2 wrong
        arguments; 3 compare found differences; 130 stopped with Control-C.

        """

    static func main(_ words: [String]) -> Int32 {
        Packer.stopDownloadingCloudFiles()
        // OneFile's Work gently setting holds here too.
        if let app = UserDefaults(suiteName: "local.onefile.app") {
            UserDefaults.standard.register(defaults: [Work.gentleKey: app.bool(forKey: Work.gentleKey)])
        }
        // A closed pipe (onefile pack X --to - | head) is an error to report, not a reason to die.
        signal(SIGPIPE, SIG_IGN)
        guard let command = words.first else {
            print(usage, terminator: "")
            return 2
        }
        let arguments = Arguments(Array(words.dropFirst()))
        if arguments.flags.contains("help") && command != "help" {
            print(usage, terminator: "")
            return 0
        }
        switch command {
        case "pack": return pack(arguments)
        case "unpack": return unpack(arguments)
        case "copy": return copy(arguments)
        case "list": return list(arguments)
        case "extract": return extract(arguments)
        case "check": return check(arguments)
        case "compare": return compare(arguments)
        case "speedtest": return speedtest(arguments)
        case "delete": return delete(arguments)
        case "backup": return backup(arguments)
        case "cloud": return cloud(arguments)
        case "link": return link(arguments)
        case "version", "--version":
            print("onefile \(OneFileVersion.current)")
            return 0
        case "help", "--help", "-h":
            print(usage, terminator: "")
            return 0
        default:
            usageError("there's no command “\(command)”")
        }
    }

    // MARK: Pack

    static func pack(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: ["lock", "git-ignore", "link"], options: ["to", "method", "split", "leave-out"])
        guard arguments.positional.count == 1 else { usageError("pack takes one folder") }
        let source = path(arguments.positional[0])
        guard isFolder(source) else { fail("“\(source.path)” isn't a folder.") }

        let method: PackMethod
        switch arguments.options["method"]?.lowercased() ?? "balanced" {
        case "fastest", "plain", "tar", "none": method = .plain
        case "balanced", "gzip", "gz": method = .gzip
        case "efficient", "zstd", "zst": method = .zstd
        case "smallest", "xz": method = .xz
        default: usageError("--method is fastest, balanced, efficient or smallest")
        }
        var options = Packer.Options(leaveOut: WalkRules.parse(arguments.options["leave-out"] ?? ".DS_Store"), method: method)
        if let split = arguments.options["split"] {
            guard let size = bytes(split), size >= 1_000_000 else { usageError("--split needs a size of 1MB or more, like 4GB") }
            options.splitSize = size
        }
        if arguments.flags.contains("git-ignore") {
            guard let ignored = GitIgnore.ignored(in: source.path) else {
                fail("Git doesn't keep “\(source.lastPathComponent)” (or Git isn't installed), so there's nothing it ignores.")
            }
            options.excluded = Set(ignored)
        }

        if let to = arguments.options["to"], let cloud = cloudPlace(to) {
            if options.splitSize != nil { usageError("--split is for files: the cloud takes an archive whole") }
            if arguments.flags.contains("lock") { options.password = password("Password: ", twice: true) }
            return packToCloud(source, cloud, options: options, link: arguments.flags.contains("link"))
        }
        if arguments.flags.contains("link") { usageError("--link is for packing to the cloud") }

        let toOutput = arguments.options["to"] == "-"
        if toOutput {
            guard isatty(STDOUT_FILENO) == 0 else { fail("That would write the archive to the terminal: send it to a file or a pipe.") }
            if options.splitSize != nil || arguments.flags.contains("lock") {
                usageError("--split and --lock need a file to write, not -")
            }
            reportToStandardError.withLock { $0 = true }
        }
        if arguments.flags.contains("lock") { options.password = password("Password: ", twice: true) }

        let packer: Packer
        if toOutput {
            packer = Packer(source: source, target: .stream(StandardOutput()), options: options)
        } else {
            let fileExtension = method.fileExtension + (options.password == nil ? "" : ".age")
            var destination = source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + "." + fileExtension)
            if let to = arguments.options["to"] {
                let target = path(to)
                if isFolder(target) {
                    destination = target.appendingPathComponent(source.lastPathComponent + "." + fileExtension)
                } else {
                    // The method's extension, whatever was typed ("backup" makes "backup.tar.gz").
                    let named = ArchiveName.with(target, method: method)
                    destination = options.password == nil ? named
                        : named.deletingLastPathComponent().appendingPathComponent(named.lastPathComponent + ".age")
                }
            }
            packer = Packer(source: source, destination: destination, replaceExisting: false, options: options)
        }

        let outcome = run(packer.start, stop: { packer.cancel() }) {
            let progress = packer.progress()
            if progress.finishing { return "Making sure it's all on the disk…" }
            var line = "Packing"
            if let totals = progress.totals, totals.archiveBytes > 0 {
                line += " \(min(99, Int(Double(progress.processed) / Double(totals.archiveBytes) * 100)))%"
            }
            line += ": \(Format.count(progress.files))"
            if let totals = progress.totals { line += " of \(Format.count(totals.files))" }
            return line + " files, \(size(progress.bytes))"
        }
        switch outcome {
        case .finished(let summary):
            var line = "Packed \(files(summary.files)) (\(size(summary.bytes)))"
            if let output = summary.output {
                line += " into \(output.path)"
                if summary.parts.count > 1 { line += " and \(summary.parts.count - 1) more parts" }
            }
            report(line + ": \(size(summary.archiveBytes)), in \(Format.duration(summary.seconds)).")
            var notes: [String] = []
            if summary.leftOut > 0 { notes.append("\(Format.items(summary.leftOut)) left out (\(arguments.options["leave-out"] ?? ".DS_Store"))") }
            if summary.gitIgnored > 0 { notes.append("\(Format.items(summary.gitIgnored)) left out because Git ignores them") }
            if summary.cloudOnly > 0 { notes.append("\(files(summary.cloudOnly)) only in the cloud weren't packed (download them first)") }
            if summary.otherDisks > 0 { notes.append("\(Format.count(summary.otherDisks)) other disks mounted inside were left out") }
            if summary.changed > 0 { notes.append("\(files(summary.changed)) changed while they were packed") }
            for note in notes { report("  " + note + ".") }
            problems(summary.problems, count: summary.problemCount, verb: "couldn't be read")
            return summary.problemCount > 0 ? 1 : 0
        case .stopped:
            report("Stopped. Nothing was left behind.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    // MARK: Unpack

    static func unpack(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: [], options: ["to"])
        guard arguments.positional.count == 1 else { usageError("unpack takes one archive") }
        let file = archiveURL(arguments.positional[0])
        let folder = arguments.options["to"].map(path)
            ?? (Remote.isRemote(file) ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath) : file.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { fail("Couldn't make the folder “\(folder.path)”.") }
        }
        let unpacker = Unpacker(source: .file(file), destination: folder, password: password(opening: file))
        let outcome = run(unpacker.start, stop: { unpacker.cancel() }) {
            let progress = unpacker.progress()
            if progress.cleaning { return "Stopping: deleting what was unpacked…" }
            if progress.finishing { return "Setting folders' dates…" }
            var line = "Unpacking"
            if let total = progress.total, total > 0 {
                line += " \(min(99, Int(Double(progress.processed) / Double(total) * 100)))%"
            }
            return line + ": \(Format.count(progress.files)) files, \(size(progress.bytes))"
        }
        switch outcome {
        case .finished(let summary):
            let place = summary.output?.path ?? folder.path
            if summary.single {
                report("Unpacked \(place) (\(size(summary.bytes))) in \(Format.duration(summary.seconds)).")
            } else {
                report("Unpacked \(files(summary.files)) (\(size(summary.bytes))) into \(place) in \(Format.duration(summary.seconds)).")
            }
            if summary.refused > 0 {
                report("  \(Format.count(summary.refused)) entries were refused: their paths led outside the folder.")
            }
            problems(summary.problems, count: summary.problemCount, verb: "couldn't be unpacked")
            return summary.problemCount > 0 ? 1 : 0
        case .stopped:
            report("Stopped. What was unpacked is deleted.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    // MARK: Copy

    static func copy(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: ["new", "verify", "mirror", "yes", "git-ignore"], options: ["leave-out"])
        guard arguments.positional.count == 2 else { usageError("copy takes a folder, and the folder it goes into") }
        let source = path(arguments.positional[0])
        let into = path(arguments.positional[1])
        guard isFolder(source) else { fail("“\(source.path)” isn't a folder.") }
        guard isFolder(into) else { fail("“\(into.path)” isn't a folder: copy takes the folder the copy goes into.") }
        if let problem = Copier.problem(copying: source, into: into) { fail(problem) }

        var options = Copier.Options(leaveOut: WalkRules.parse(arguments.options["leave-out"] ?? ".DS_Store"))
        options.verify = arguments.flags.contains("verify")
        options.mirror = arguments.flags.contains("mirror")
        if arguments.flags.contains("git-ignore") {
            guard let ignored = GitIgnore.ignored(in: source.path) else {
                fail("Git doesn't keep “\(source.lastPathComponent)” (or Git isn't installed), so there's nothing it ignores.")
            }
            options.excluded = Set(ignored)
        }
        let target: Copier.Target
        switch Copier.existing(for: source, name: source.lastPathComponent, in: into) {
        case .folder(let existing) where !arguments.flags.contains("new"):
            if Copier.realPath(existing.path) == Copier.realPath(source.path) { fail("That's the folder itself.") }
            report("“\(existing.path)” is there already: copying only what's new or changed.")
            target = .update(existing)
        case .stopped(let partial):
            report("Picking up the copy that stopped, in “\(partial.lastPathComponent)”.")
            target = .new(folder: into, name: source.lastPathComponent)
        default:
            target = .new(folder: into, name: source.lastPathComponent)
        }

        let copier = Copier(source: source, target: target, options: options)
        let outcome = run(copier.start, stop: { copier.cancel() }) { copyStatus(copier) }
        switch outcome {
        case .finished(let summary):
            var line: String
            if summary.files == 0 && summary.unchanged > 0 {
                line = "Nothing new to copy to \(summary.destination.path): all \(files(summary.unchanged)) were there already, unchanged"
            } else {
                line = (summary.plan.clone ? "Cloned " : "Copied ") + "\(files(summary.files)) (\(size(summary.bytes))) to \(summary.destination.path) in \(Format.duration(summary.seconds))"
                if summary.savingSeconds >= 0.5 {
                    line += " (\(Format.duration(summary.savingSeconds)) of it making sure it's on the drive)"
                }
            }
            report(line + ".")
            if summary.plan.clone && summary.files > 0 { report("  Clones on the same drive: they take no extra space until they're changed.") }
            if summary.unchanged > 0 && summary.files > 0 { report("  \(files(summary.unchanged)) were there already, unchanged.") }
            if summary.leftOut > 0 { report("  \(Format.items(summary.leftOut)) left out (\(arguments.options["leave-out"] ?? ".DS_Store")).") }
            if summary.gitIgnored > 0 { report("  \(Format.items(summary.gitIgnored)) left out because Git ignores them.") }
            if summary.cloudOnly > 0 { report("  \(files(summary.cloudOnly)) only in the cloud weren't copied (download them first).") }
            var status: Int32 = summary.problemCount > 0 ? 1 : 0
            if options.verify {
                if summary.mismatched > 0 {
                    report("  \(files(summary.mismatched)) read back from the drive don't match the originals: copy again.")
                    status = 1
                } else if summary.verified > 0 {
                    report("  All \(files(summary.verified)) copied were read back from the drive: they match.")
                } else if summary.plan.clone && summary.files > 0 {
                    report("  Nothing to read back: clones share the originals' data.")
                }
            }
            problems(summary.problems, count: summary.problemCount, verb: "couldn't be copied")
            if !summary.extras.isEmpty { status = max(status, mirror(summary, yes: arguments.flags.contains("yes"))) }
            return status
        case .stopped(let partial):
            if let partial {
                report("Stopped. What's copied is in “\(partial.path)”: the same command picks up there.")
            } else {
                report("Stopped.")
            }
            return 130
        case .failed(let message, _):
            fail(message)
        }
    }

    /// How a copy (or a backup) is going, in a line.
    static func copyStatus(_ copier: Copier) -> String {
        let progress = copier.progress()
        if progress.verifying { return "Checking on the drive: \(Format.count(progress.verified)) of \(Format.count(progress.toVerify)) files" }
        if progress.saving { return "Making sure it's all on the drive…" }
        if progress.finishing { return "Setting folders' dates…" }
        var line = "Copying"
        if let totals = progress.totals, totals.bytes > 0 {
            line += " \(min(99, Int(Double(progress.bytes + progress.unchangedBytes) / Double(totals.bytes) * 100)))%"
        }
        line += ": \(Format.count(progress.files + progress.unchanged))"
        if let totals = progress.totals { line += " of \(Format.count(totals.files))" }
        return line + " files, \(size(progress.bytes))"
    }

    /// The copy has things the original doesn't any more: moves them to the Trash, once asked.
    static func mirror(_ summary: Copier.Summary, yes: Bool) -> Int32 {
        let extras = summary.extras
        report("The copy has \(Format.items(Int64(extras.count))) that the original no longer has:")
        for extra in extras.prefix(20) { report("  " + extra.path + (extra.isFolder ? "/" : "")) }
        if extras.count > 20 { report("  and \(Format.count(Int64(extras.count - 20))) more") }
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                report("Add --yes to move them to the Trash.")
                return 0
            }
            guard confirm("Move them to the Trash?") else { return 0 }
        }
        var failed = 0
        for extra in extras {
            do {
                try FileManager.default.trashItem(at: summary.destination.appendingPathComponent(extra.path), resultingItemURL: nil)
            } catch {
                failed += 1
            }
        }
        if failed == 0 {
            report("Moved them to the Trash: the copy matches the original.")
            return 0
        }
        report("\(Format.items(Int64(failed))) couldn't be moved to the Trash (a network drive may have none).")
        return 1
    }

    // MARK: Archives packed by OneFile

    /// An archive's index, its format, and the password that opened it; or a reason to stop.
    static func openIndex(_ text: String) -> (file: URL, index: ArchiveIndex, format: ArchiveFormat, password: String?) {
        let file = archiveURL(text)
        let secret = password(opening: file)
        let input: InputFile
        switch InputFile.open(file, password: secret) {
        case .success(let opened): input = opened
        case .failure(let error): fail(error.message)
        }
        let format: ArchiveFormat
        switch ArchiveFormat.detect(input, name: file.lastPathComponent) {
        case .success(let detected): format = detected
        case .failure(let error): fail(error.message)
        }
        guard let index = ArchiveIndex.read(input, format: format) else {
            fail("“\(file.lastPathComponent)” has no index: it wasn't packed by OneFile 3. Unpack it instead.")
        }
        return (file, index, format, secret)
    }

    static func list(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: [])
        guard arguments.positional.count == 1 else { usageError("list takes one file") }
        let index = openIndex(arguments.positional[0]).index
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var files: Int64 = 0, folders: Int64 = 0, total: Int64 = 0
        var out = ""
        for entry in index.entries {
            let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.modified)))
            var size = ""
            switch entry.kind {
            case .file:
                files += 1
                total += entry.size
                size = entry.size == 0 ? "0 bytes" : Format.bytes(entry.size)
            case .folder: folders += 1
            default: files += 1
            }
            out += date + "  " + String(repeating: " ", count: max(0, 9 - size.count)) + size + "  " + entry.path
            switch entry.kind {
            case .symlink: out += " -> " + entry.link
            case .hardLink: out += " (the same file as " + entry.link + ")"
            default: break
            }
            out += "\n"
            if out.utf8.count > 1 << 16 {
                FileHandle.standardOutput.write(Data(out.utf8))
                out = ""
            }
        }
        FileHandle.standardOutput.write(Data(out.utf8))
        print("\(Command.files(files)) (\(size(total))) in \(Format.count(folders)) \(folders == 1 ? "folder" : "folders").")
        return 0
    }

    static func extract(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: [], options: ["to"])
        guard arguments.positional.count >= 2 else { usageError("extract takes a file, and what to take out of it") }
        let (file, index, format, secret) = openIndex(arguments.positional[0])
        func trimmed(_ path: String) -> String { path.hasSuffix("/") ? String(path.dropLast()) : path }
        /// "data/run.csv" for "Research/data/run.csv": a path without the archive's top folder.
        func belowTop(_ path: String) -> String { String(path.drop { $0 != "/" }.dropFirst()) }
        var chosen: [ArchiveIndex.Entry] = []
        for typed in arguments.positional.dropFirst() {
            let wanted = trimmed(typed)
            var found: [ArchiveIndex.Entry] = []
            if wanted.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                found = index.entries.filter {
                    fnmatch(wanted, trimmed($0.path), 0) == 0 || fnmatch(wanted, belowTop(trimmed($0.path)), 0) == 0
                }
            } else if let exact = index.entries.first(where: { trimmed($0.path) == wanted }) {
                found = [exact]
            } else if let below = index.entries.first(where: { belowTop(trimmed($0.path)) == wanted }) {
                found = [below]
            }
            guard !found.isEmpty else { fail("Nothing in “\(file.lastPathComponent)” is called “\(wanted)” (onefile list shows what's there).") }
            chosen += found
        }
        let folder = arguments.options["to"].map(path) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if !FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { fail("Couldn't make the folder “\(folder.path)”.") }
        }
        let extractor = Extractor(archive: file, index: index, format: format, chosen: chosen, destination: folder, password: secret)
        let outcome = run(extractor.start, stop: { extractor.cancel() }) {
            let progress = extractor.progress()
            return "Taking out: \(Format.count(progress.files)) files, \(size(progress.bytes))"
        }
        switch outcome {
        case .finished(let summary):
            let names = summary.made.map(\.lastPathComponent).joined(separator: ", ")
            report("Took out \(files(summary.files)) (\(size(summary.bytes))) into \(folder.path): \(names).")
            if summary.mismatched > 0 { report("  \(files(summary.mismatched)) don't match their SHA-256: the archive is damaged.") }
            problems(summary.problems, count: summary.problems.count, verb: "couldn't be taken out")
            return summary.problems.isEmpty && summary.mismatched == 0 ? 0 : 1
        case .stopped:
            report("Stopped.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    static func check(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: [])
        guard arguments.positional.count == 1 else { usageError("check takes one file") }
        let (file, index, format, secret) = openIndex(arguments.positional[0])
        let checker = ArchiveChecker(archive: file, index: index, format: format, password: secret)
        let outcome = run(checker.start, stop: { checker.cancel() }) {
            "Checking: \(Int(checker.fraction * 100))%"
        }
        switch outcome {
        case .finished(let summary):
            if summary.mismatched.isEmpty {
                report("All \(files(summary.checked)) match their SHA-256 (checked in \(Format.duration(summary.seconds))).")
                return 0
            }
            report("\(files(Int64(summary.mismatched.count))) don't match their SHA-256: the archive is damaged.")
            for path in summary.mismatched.prefix(50) { report("  " + path) }
            if summary.mismatched.count > 50 { report("  and \(Format.count(Int64(summary.mismatched.count - 50))) more") }
            return 1
        case .stopped:
            report("Stopped.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    // MARK: Folders and drives

    static func compare(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: ["contents"], options: ["leave-out"])
        guard arguments.positional.count == 2 else { usageError("compare takes two folders") }
        let first = path(arguments.positional[0]), second = path(arguments.positional[1])
        for folder in [first, second] where !isFolder(folder) { fail("“\(folder.path)” isn't a folder.") }
        var options = Comparer.Options(contents: arguments.flags.contains("contents"))
        if let leaveOut = arguments.options["leave-out"] { options.leaveOut = WalkRules.parse(leaveOut) }
        let comparer = Comparer(first: first, second: second, options: options)
        let thorough = options.contents
        let outcome = run(comparer.start, stop: { comparer.cancel() }) {
            let progress = comparer.progress()
            return "Comparing: \(Format.count(progress.compared)) items" + (thorough ? ", \(size(progress.bytesRead)) read" : "")
        }
        switch outcome {
        case .finished(let summary):
            for item in summary.items {
                let what: String
                switch item.difference {
                case .onlyFirst: what = "only in the first"
                case .onlySecond: what = "only in the second"
                case .kind: what = "a file on one side, a folder on the other"
                case .size: what = "different size"
                case .date: what = "different date"
                case .contents: what = "different contents"
                case .link: what = "the link points elsewhere"
                }
                print("\(what): \(item.path)\(item.isFolder ? "/" : "")")
            }
            let differences = summary.onlyFirst + summary.onlySecond + summary.different
            if differences > Int64(summary.items.count) {
                print("and \(Format.count(differences - Int64(summary.items.count))) more")
            }
            for problem in summary.problems { error("couldn't compare \(problem.path): \(problem.message)") }
            if summary.identical {
                print("The same: \(Format.items(summary.same)), \(summary.contents ? "every byte" : "names, sizes and dates") compared.")
                return 0
            }
            print("\(Format.count(summary.same)) the same, \(Format.count(summary.different)) different, "
                  + "\(Format.count(summary.onlyFirst)) only in the first, \(Format.count(summary.onlySecond)) only in the second.")
            return differences > 0 ? 3 : 1
        case .stopped:
            report("Stopped.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    static func speedtest(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: [])
        guard arguments.positional.count == 1 else { usageError("speedtest takes a folder on the drive to test") }
        let place = path(arguments.positional[0])
        guard isFolder(place) else { fail("“\(place.path)” isn't a folder.") }
        let drive = Drive.of(place.path)
        if let drive { report("Testing “\(drive.name)” (\(drive.kindText))…") }
        let test = SpeedTest(place: place)
        let outcome = run(test.start, stop: { test.cancel() }) { test.progress().step }
        switch outcome {
        case .finished(let result):
            report("Small files (\(Format.count(Int64(result.smallFiles))) of 4 KB): \(Format.count(Int64(result.smallWrite))) a second written, \(Format.count(Int64(result.smallRead))) read.")
            report("One big file (\(Format.bytes(result.bigBytes))): \(Format.bytes(Int64(result.bigWrite)))/s written, \(Format.bytes(Int64(result.bigRead)))/s read.")
            report("A 4 KB file takes \(Format.bytes(result.spacePerSmallFile)) on it.")
            if let drive { for line in SpeedTest.advice(result, drive: drive) { report(line) } }
            return 0
        case .stopped:
            report("Stopped. The test's files are deleted.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    static func delete(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: ["yes"])
        guard arguments.positional.count == 1 else { usageError("delete takes one folder") }
        let folder = path(arguments.positional[0])
        if let refusal = Deleter.refusal(folder) { fail(refusal) }
        if !arguments.flags.contains("yes") {
            guard isatty(STDIN_FILENO) != 0 else { fail("Add --yes to delete without being asked.") }
            if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("Counting…".utf8)) }
            let count = Deleter.count(folder) { false }
            if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
            guard let count else { fail("Couldn't count what's in “\(folder.path)”.") }
            guard confirm("Delete “\(folder.path)” for good: \(Format.items(count.items)), \(size(count.bytes))? It can't be undone.") else {
                return 1
            }
        }
        let deleter = Deleter(folder: folder)
        let outcome = run(deleter.start, stop: { deleter.cancel() }) {
            "Deleting: \(Format.count(deleter.progress().deleted)) items"
        }
        switch outcome {
        case .finished(let summary):
            report("Deleted \(Format.items(summary.deleted)) (\(size(summary.bytes))) in \(Format.duration(summary.seconds)).")
            problems(summary.problems, count: summary.problemCount, verb: "couldn't be deleted")
            return summary.problemCount > 0 ? 1 : 0
        case .stopped(let deleted):
            report("Stopped, after deleting \(Format.items(deleted)).")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    // MARK: Backups

    static func backup(_ arguments: Arguments) -> Int32 {
        switch arguments.positional.first {
        case nil:
            arguments.allow(flags: ["due"])
            return arguments.flags.contains("due") ? backupDue() : backupNow()
        case "list":
            arguments.allow(flags: [])
            return backupList()
        case "add":
            arguments.allow(flags: ["verify", "git-ignore"], options: ["every", "leave-out"])
            return backupAdd(arguments)
        case "remove":
            arguments.allow(flags: [])
            guard arguments.positional.count == 2, let number = Int(arguments.positional[1]) else {
                usageError("backup remove takes the number onefile backup list gives")
            }
            let rules = BackupStore.load()
            guard number >= 1 && number <= rules.count else { fail("There's no backup \(number): onefile backup list shows them.") }
            let rule = rules[number - 1]
            BackupStore.change { $0.removeAll { $0.id == rule.id } }
            report("Stopped backing up \(rule.source) to “\(rule.driveName)”. What's on the drive stays.")
            return 0
        case "background":
            arguments.allow(flags: [])
            guard arguments.positional.count == 2, ["on", "off"].contains(arguments.positional[1]) else {
                usageError("backup background takes on or off")
            }
            if arguments.positional[1] == "off" {
                BackupAgent.uninstall()
                report("Backups run only while OneFile is open (or with onefile backup).")
                return 0
            }
            guard let executable = Bundle.main.executablePath else { fail("Couldn't tell where onefile is.") }
            if let failure = BackupAgent.install(command: Copier.realPath(executable)) { fail(failure) }
            report("Backups run when a drive is plugged in, even when OneFile isn't open. What they did goes in \(Format.path(BackupAgent.logURL)).")
            return 0
        default:
            usageError("backup takes list, add, remove or background, or nothing to back up now")
        }
    }

    /// Every backup to the drives plugged in now, due or not.
    static func backupNow() -> Int32 {
        let rules = BackupStore.load().filter(\.enabled)
        let drives = Backups.drives()
        let plugged = rules.compactMap { rule in drives.first { $0.id == rule.driveID }.map { (rule, $0) } }
        guard !plugged.isEmpty else {
            report(rules.isEmpty ? "No backups are set up. onefile backup add FOLDER DRIVE-FOLDER sets one up."
                                 : "None of the drives backed up to is plugged in.")
            return 0
        }
        var status: Int32 = 0
        for (rule, drive) in plugged {
            report("\(rule.sourceName) → “\(drive.name)”: \(rule.placeText)")
            guard let lock = FileLock(Backups.lockName(rule)) else {
                report("  It's being backed up already (in OneFile, or in the background).")
                continue
            }
            let copier: Copier
            switch Backups.copier(for: rule, on: drive) {
            case .success(let made): copier = made
            case .failure(let error):
                Backups.record(rule, on: drive, failure: error.message)
                report("  " + error.message)
                status = 1
                continue
            }
            let outcome = run(copier.start, stop: { copier.cancel() }) { copyStatus(copier) }
            Backups.record(rule, on: drive, outcome)
            withExtendedLifetime(lock) {}
            let (text, failed) = Backups.describe(outcome)
            report("  " + text)
            if case .stopped = outcome { return 130 }
            if failed { status = 1 }
        }
        return status
    }

    /// The backups that are due, one after another: what the background task runs when a drive is
    /// plugged in. Nothing while OneFile is open: it backs drives up itself, with progress.
    static func backupDue() -> Int32 {
        if FileLock.isHeld(Backups.appLockName) { return 0 }
        let due = Backups.due(BackupStore.load(), drives: Backups.drives())
        guard !due.isEmpty else { return 0 }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Backing up folders to a drive")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func log(_ line: String) { print(stamp.string(from: Date()) + "  " + line) }
        var status: Int32 = 0
        for (rule, drive) in due {
            log("Backing up \(rule.source) to “\(drive.name)”: \(rule.placeText)")
            Work.jobStarted()
            let outcome = Backups.runHere(rule, on: drive)
            Work.jobEnded()
            guard let outcome else {
                log("  It's being backed up already.")
                continue
            }
            let (text, failed) = Backups.describe(outcome)
            log("  " + text)
            if failed { status = 1 }
        }
        return status
    }

    static func backupList() -> Int32 {
        let rules = BackupStore.load()
        guard !rules.isEmpty else {
            report("No backups are set up. onefile backup add FOLDER DRIVE-FOLDER sets one up (or Drives, in the app).")
            return 0
        }
        let drives = Backups.drives()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for (index, rule) in rules.enumerated() {
            let plugged = drives.contains { $0.id == rule.driveID }
            report("\(index + 1). \(rule.source) → “\(rule.driveName)”: \(rule.placeText)")
            var details = [rule.every.title]
            if !rule.enabled { details.append("off") }
            if rule.verify { details.append("read back to check") }
            if rule.gitIgnore { details.append("leaving out what Git ignores") }
            if plugged { details.append("plugged in now") }
            report("   " + details.joined(separator: ", "))
            if let last = rule.lastRun {
                report("   \(rule.lastFailed ? "Last (failed)" : "Last"): \(formatter.string(from: last)): \(rule.lastResult ?? "")")
            }
        }
        report(BackupAgent.isInstalled ? "They run when a drive is plugged in, even when OneFile isn't open."
                                       : "They run while OneFile is open (onefile backup background on: even when it isn't).")
        return 0
    }

    static func backupAdd(_ arguments: Arguments) -> Int32 {
        guard arguments.positional.count == 3 else {
            usageError("backup add takes the folder to back up, and the folder on a drive it goes in")
        }
        let source = path(arguments.positional[1])
        guard isFolder(source) else { fail("“\(source.path)” isn't a folder.") }
        var rule: BackupRule
        switch Backups.rule(backingUp: source, to: path(arguments.positional[2])) {
        case .success(let made): rule = made
        case .failure(let error): fail(error.message)
        }
        switch arguments.options["every"]?.lowercased() {
        case nil, "plug-in", "plugin", "plugged-in": rule.every = .plugIn
        case "day", "daily": rule.every = .day
        case "week", "weekly": rule.every = .week
        default: usageError("--every is plug-in, day or week")
        }
        rule.verify = arguments.flags.contains("verify")
        rule.gitIgnore = arguments.flags.contains("git-ignore")
        if let leaveOut = arguments.options["leave-out"] { rule.leaveOut = leaveOut }
        if BackupStore.load().contains(where: { $0.source == rule.source && $0.driveID == rule.driveID }) {
            fail("\(rule.source) is backed up to “\(rule.driveName)” already.")
        }
        BackupStore.change { $0.append(rule) }
        report("Backing up \(rule.source) to “\(rule.driveName)”: \(rule.placeText), \(rule.every.title.lowercased()).")
        report("onefile backup runs it now" + (BackupAgent.isInstalled ? "." : "; onefile backup background on runs it when the drive is plugged in."))
        return 0
    }

    // MARK: The cloud

    /// A place in the cloud named on the command line, and the rest of the address: "cloud:NAME/…"
    /// (an account set up with onefile cloud add) or "s3://BUCKET/…" (keys from the environment).
    static func cloudPlace(_ text: String) -> (place: CloudPlace, rest: String, label: String)? {
        if text.hasPrefix("cloud:") {
            let body = text.dropFirst(6)
            let name = String(body.prefix { $0 != "/" })
            let rest = String(body.dropFirst(name.count).drop { $0 == "/" })
            guard let account = CloudStore.named(name) else { fail("There's no cloud account called “\(name)” (onefile cloud list shows them).") }
            switch Cloud.connect(account) {
            case .success(let place): return (place, rest, account.name)
            case .failure(let error): fail(error.message)
            }
        }
        if text.hasPrefix("s3://") {
            let body = text.dropFirst(5)
            let bucket = String(body.prefix { $0 != "/" })
            let rest = String(body.dropFirst(bucket.count).drop { $0 == "/" })
            guard !bucket.isEmpty else { usageError("s3:// needs a bucket: s3://BUCKET/KEY") }
            switch Cloud.environmentBucket(bucket) {
            case .success(let found): return (.s3(found, prefix: ""), rest, "s3://\(bucket)")
            case .failure(let error): fail(error.message)
            }
        }
        return nil
    }

    /// The archive at `rest` in a place (and what's around it, for a split archive's parts).
    static func cloudItem(_ place: CloudPlace, _ rest: String) -> (item: CloudItem, around: [CloudItem]) {
        let listed: Result<[CloudItem], CloudError>
        let wanted: (CloudItem) -> Bool
        switch place {
        case .s3(let bucket, let prefix):
            let key = prefix + rest
            let stem = SplitParts.isPartName(key) ? String(key.dropLast(3)) : key
            listed = bucket.list(prefix: stem)
            wanted = { $0.key == key }
        case .drive(let drive, let folderID):
            listed = drive.list(folderID: folderID)
            wanted = { $0.name == rest }
        }
        switch listed {
        case .failure(let error): fail(error.message)
        case .success(let items):
            guard let item = items.first(where: wanted) else { fail("There's no “\(rest)” there (onefile cloud files shows what is).") }
            return (item, items)
        }
    }

    /// The archive named on the command line, as an address to open: a file, a link, or an archive
    /// in the cloud.
    static func archiveURL(_ text: String) -> URL {
        if text.hasPrefix("https://") || text.hasPrefix("http://") {
            guard let url = URL(string: text) else { usageError("“\(text)” isn't a link") }
            return url
        }
        if let (place, rest, _) = cloudPlace(text) {
            guard !rest.isEmpty else { usageError("name the archive: \(text)/NAME.tar.gz") }
            let (item, around) = cloudItem(place, rest)
            return Cloud.open(item, in: place, among: around)
        }
        return path(text)
    }

    static func packToCloud(_ source: URL, _ cloud: (place: CloudPlace, rest: String, label: String),
                            options: Packer.Options, link: Bool) -> Int32 {
        let fileExtension = options.method.fileExtension + (options.password == nil ? "" : ".age")
        let defaultName = source.lastPathComponent + "." + fileExtension
        var name = cloud.rest.isEmpty || cloud.rest.hasSuffix("/") ? cloud.rest + defaultName : cloud.rest
        if !name.hasSuffix("." + fileExtension) {
            // The method's extension, whatever was typed.
            let named = ArchiveName.with(URL(fileURLWithPath: "/" + name), method: options.method).path.dropFirst()
            name = String(named) + (options.password == nil ? "" : ".age")
        }
        let target: CloudTarget
        switch cloud.place {
        case .s3(let bucket, let prefix): target = .s3(bucket, key: prefix + name)
        case .drive(let drive, let folderID): target = .drive(drive, folderID: folderID, name: (name as NSString).lastPathComponent)
        }
        let upload = CloudPack(source: source, target: target, options: options)
        let outcome = run(upload.start, stop: { upload.cancel() }) {
            let progress = upload.progress()
            if progress.packed { return "Sending: \(size(progress.sent)) of \(size(progress.packing.outputBytes))" }
            var line = "Packing"
            if let totals = progress.packing.totals, totals.archiveBytes > 0 {
                line += " \(min(99, Int(Double(progress.packing.processed) / Double(totals.archiveBytes) * 100)))%"
            }
            return line + ": \(Format.count(progress.packing.files)) files, \(size(progress.packing.bytes)); \(size(progress.sent)) sent"
        }
        switch outcome {
        case .finished(let summary, let item):
            report("Packed \(files(summary.files)) (\(size(summary.bytes))) and sent “\(item.name)” (\(size(item.size))) to \(cloud.label) in \(Format.duration(summary.seconds > 0 ? summary.seconds : 0)).")
            problems(summary.problems, count: summary.problemCount, verb: "couldn't be read")
            if link {
                switch Cloud.link(item, in: cloud.place) {
                case .success(let url): report(url.absoluteString)
                case .failure(let failure): error(failure.message)
                }
            }
            return summary.problemCount > 0 ? 1 : 0
        case .stopped:
            report("Stopped. Nothing was left behind, here or in the cloud.")
            return 130
        case .failed(let message):
            fail(message)
        }
    }

    static func link(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: [], options: ["days"])
        guard arguments.positional.count == 1, let cloud = cloudPlace(arguments.positional[0]), !cloud.rest.isEmpty else {
            usageError("link takes an archive in the cloud: cloud:NAME/FILE or s3://BUCKET/KEY")
        }
        let days = Int(arguments.options["days"] ?? "7") ?? 7
        let (item, _) = cloudItem(cloud.place, cloud.rest)
        switch Cloud.link(item, in: cloud.place, days: days) {
        case .success(let url):
            print(url.absoluteString)
            return 0
        case .failure(let failure):
            fail(failure.message)
        }
    }

    static func cloud(_ arguments: Arguments) -> Int32 {
        switch arguments.positional.first {
        case "list", nil:
            arguments.allow(flags: [])
            let accounts = CloudStore.load()
            if accounts.isEmpty { report("No cloud accounts yet: onefile cloud add NAME --service … adds one.") }
            for account in accounts { report("\(account.name): \(account.kindText), \(account.placeText)") }
            return 0
        case "add":
            return cloudAdd(arguments)
        case "remove":
            arguments.allow(flags: [])
            guard arguments.positional.count == 2, let account = CloudStore.named(arguments.positional[1]) else {
                usageError("cloud remove takes the name of an account (onefile cloud list shows them)")
            }
            for name in [account.secretName, account.clientSecretName, account.refreshName] { Keychain.delete(name) }
            CloudStore.change { $0.removeAll { $0.id == account.id } }
            report("Removed “\(account.name)”. What's in the cloud stays.")
            return 0
        case "files":
            arguments.allow(flags: [])
            guard arguments.positional.count == 2, let cloud = cloudPlace(arguments.positional[1]) else {
                usageError("cloud files takes cloud:NAME or s3://BUCKET/FOLDER")
            }
            var place = cloud.place
            if case .s3(let bucket, let prefix) = place, !cloud.rest.isEmpty { place = .s3(bucket, prefix: prefix + Cloud.prefix(cloud.rest)) }
            switch Cloud.archives(in: place) {
            case .failure(let failure): fail(failure.message)
            case .success(let items):
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                for item in items {
                    let date = item.modified.map { formatter.string(from: $0) } ?? "                "
                    let shown = size(item.size)
                    print(date + "  " + String(repeating: " ", count: max(0, 9 - shown.count)) + shown + "  " + item.name)
                }
                if items.isEmpty { report("No archives there yet.") }
                return 0
            }
        case "delete":
            arguments.allow(flags: ["yes"])
            guard arguments.positional.count == 2, let cloud = cloudPlace(arguments.positional[1]), !cloud.rest.isEmpty else {
                usageError("cloud delete takes an archive in the cloud")
            }
            let (item, _) = cloudItem(cloud.place, cloud.rest)
            if !arguments.flags.contains("yes") {
                guard isatty(STDIN_FILENO) != 0 else { fail("Add --yes to delete without being asked.") }
                guard confirm("Delete “\(item.name)” (\(size(item.size))) from \(cloud.label) for good?") else { return 1 }
            }
            switch Cloud.delete(item, in: cloud.place) {
            case .success:
                report("Deleted “\(item.name)”.")
                return 0
            case .failure(let failure):
                fail(failure.message)
            }
        default:
            usageError("cloud takes list, add, remove, files or delete")
        }
    }

    static func cloudAdd(_ arguments: Arguments) -> Int32 {
        arguments.allow(flags: ["path-style"], options: ["service", "bucket", "region", "endpoint", "account", "folder", "key-id", "client-id"])
        guard arguments.positional.count == 2 else { usageError("cloud add takes a name for the account") }
        let name = arguments.positional[1]
        guard !name.contains("/"), !name.contains(":") else { usageError("an account's name can't have / or : in it") }
        if CloudStore.named(name) != nil { fail("There's an account called “\(name)” already.") }
        var account = CloudAccount(name: name)
        if let folder = arguments.options["folder"] { account.folder = folder }
        let secret = ProcessInfo.processInfo.environment["ONEFILE_CLOUD_SECRET"]
        switch arguments.options["service"]?.lowercased() ?? "aws" {
        case "google-drive", "googledrive", "drive", "gdrive":
            guard let clientID = arguments.options["client-id"] else {
                usageError("Google Drive needs --client-id: make a Desktop app client in Google Cloud Console, under Credentials")
            }
            account.kind = .googleDrive
            account.clientID = clientID
            let clientSecret = secret ?? password("Client secret: ", twice: false)
            report("Sign in to Google in the browser that opens…")
            switch GoogleDrive.signIn(clientID: clientID, clientSecret: clientSecret) {
            case .failure(let failure): fail(failure.message)
            case .success(let refresh):
                Keychain.set(clientSecret, for: account.clientSecretName)
                Keychain.set(refresh, for: account.refreshName)
            }
        case let service:
            guard let chosen = S3Service(rawValue: service) else { usageError("--service is aws, r2, b2, gcs, wasabi, other or google-drive") }
            guard let bucket = arguments.options["bucket"], let keyID = arguments.options["key-id"] else {
                usageError("an S3 account needs --bucket and --key-id")
            }
            account.bucket = bucket
            account.keyID = keyID
            account.region = arguments.options["region"] ?? chosen.regionHint
            account.endpoint = arguments.options["endpoint"] ?? chosen.endpoint(region: account.region, account: arguments.options["account"] ?? "")
            guard URL(string: account.endpoint)?.host != nil, !account.endpoint.contains("ACCOUNT_ID") else {
                usageError(chosen == .r2 ? "R2 needs --account (your Cloudflare account ID)" : "this service needs --endpoint")
            }
            account.pathStyle = arguments.flags.contains("path-style") || chosen.pathStyle
            Keychain.set(secret ?? password("Secret key: ", twice: false), for: account.secretName)
        }
        // Try it before keeping it.
        switch Cloud.connect(account) {
        case .failure(let failure):
            for secretName in [account.secretName, account.clientSecretName, account.refreshName] { Keychain.delete(secretName) }
            fail(failure.message)
        case .success(let place):
            if case .failure(let failure) = Cloud.archives(in: place) {
                for secretName in [account.secretName, account.clientSecretName, account.refreshName] { Keychain.delete(secretName) }
                fail(failure.message)
            }
        }
        CloudStore.change { $0.append(account) }
        report("Added “\(name)”: \(account.kindText), \(account.placeText). Pack to it with --to cloud:\(name).")
        return 0
    }

    // MARK: Running a job

    /// Starts a job, shows how it's going on the terminal (one line of standard error, written over
    /// and over) until it's done, and returns how it ended. Control-C stops it the job's own way.
    static func run<Outcome: Sendable>(_ start: (@escaping @Sendable (Outcome) -> Void) -> Void,
                                       stop: @escaping @Sendable () -> Void, status: () -> String) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Outcome?>(nil)
        Interrupt.onControlC(stop)
        Work.jobStarted()
        defer { Work.jobEnded() }
        start { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        let live = isatty(STDERR_FILENO) != 0
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if live { FileHandle.standardError.write(Data(("\r\u{1B}[K" + status()).utf8)) }
        }
        if live { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        Interrupt.onControlC(nil)
        return result.withLock { $0 }!
    }

    // MARK: Small things

    /// Packing to standard output, what's said goes to standard error instead.
    static let reportToStandardError = Locked(false)

    static func report(_ line: String) {
        if reportToStandardError.withLock({ $0 }) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        } else {
            print(line)
        }
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data(("onefile: " + message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        error(message)
        exit(1)
    }

    static func usageError(_ message: String) -> Never {
        error(message + " (onefile help shows how it's used)")
        exit(2)
    }

    static func problems(_ list: [Problem], count: Int, verb: String) {
        guard count > 0 else { return }
        error("\(Format.items(Int64(count))) \(verb):")
        for problem in list.prefix(20) { error("  \(problem.path): \(problem.message)") }
        if count > 20 { error("  and \(Format.count(Int64(count - 20))) more") }
    }

    /// "1 file", "2,500 files".
    static func files(_ count: Int64) -> String {
        "\(Format.count(count)) \(count == 1 ? "file" : "files")"
    }

    /// A size, as Finder gives it ("0 bytes" rather than "Zero KB").
    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 bytes" : Format.bytes(bytes)
    }

    static func path(_ text: String) -> URL {
        URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    /// "4GB", "500MB", "1.5 G", or bytes. Decimal units, as Finder counts.
    static func bytes(_ text: String) -> Int64? {
        let upper = text.uppercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3),
                                         ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
        for (unit, factor) in units where upper.hasSuffix(unit) {
            guard let number = Double(upper.dropLast(unit.count)), number > 0 else { return nil }
            return Int64(number * factor)
        }
        return Int64(upper)
    }

    /// Asks on the terminal; yes only for "y" or "yes".
    static func confirm(_ question: String) -> Bool {
        FileHandle.standardError.write(Data((question + " [y/N] ").utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    /// The password for a locked archive (nil if it isn't locked).
    static func password(opening file: URL) -> String? {
        let input: InputFile
        if Remote.isRemote(file) {
            switch Remote.objects(for: file) {
            case .success(let objects): input = InputFile(remote: RemoteFile(objects))
            case .failure(let error): fail(error.message)
            }
        } else {
            let parts = SplitParts.parts(of: file)?.map(\.path) ?? [file.path]
            guard let local = InputFile(paths: parts) else {
                fail("Couldn't open “\(file.path)”: \(Packer.message(errno)).")
            }
            input = local
        }
        return input.isLocked ? password("Password for “\(file.lastPathComponent)”: ", twice: false) : nil
    }

    /// A password typed without showing it, or ONEFILE_PASSWORD.
    static func password(_ prompt: String, twice: Bool) -> String {
        if let given = ProcessInfo.processInfo.environment["ONEFILE_PASSWORD"], !given.isEmpty { return given }
        func ask(_ prompt: String) -> String {
            var buffer = [CChar](repeating: 0, count: 1_024)
            guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                fail("A password is needed: type it in Terminal, or set ONEFILE_PASSWORD.")
            }
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        let first = ask(prompt)
        guard !first.isEmpty else { fail("No password was typed.") }
        if twice && ask("Again, to be sure: ") != first { fail("The two passwords aren't the same.") }
        return first
    }
}

/// What's after the command: "--name value" or "--name=value" options, "--name" flags, the rest in order.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    /// Options that take a value.
    static let valued: Set<String> = ["to", "method", "split", "leave-out", "every", "days", "service", "bucket", "region",
                                      "endpoint", "account", "folder", "key-id", "client-id"]

    init(_ list: [String]) {
        var rest = list[...]
        while let argument = rest.popFirst() {
            if argument == "--" {
                positional += rest
                break
            }
            if argument == "-h" {
                flags.insert("help")
            } else if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[..<equals])] = String(name[name.index(after: equals)...])
                } else if Self.valued.contains(name) {
                    guard let value = rest.popFirst() else { Command.usageError("--\(name) needs a value") }
                    options[name] = value
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
        }
    }

    /// Stops if there's an option the command doesn't take (a typo, say).
    func allow(flags allowed: Set<String>, options allowedOptions: Set<String> = []) {
        for flag in flags.subtracting(allowed).subtracting(["help"]).sorted() {
            Command.usageError("there's no --\(flag) for this command")
        }
        for name in options.keys.sorted() where !allowedOptions.contains(name) {
            Command.usageError("there's no --\(name) for this command")
        }
    }
}

/// Packing to standard output: the archive's blocks, in order, to a pipe.
final class StandardOutput: PackStream {
    private let failure = Locked<String?>(nil)

    func frame(_ block: Data, holding count: Int, index: Int) -> Data? { block }

    func send(_ frame: Data) -> Bool {
        let sent = frame.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(STDOUT_FILENO, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
        if !sent {
            let message = errno == EPIPE ? "The pipe it was going into closed." : "Couldn't write: \(Packer.message(errno))."
            failure.withLock { $0 = message }
        }
        return sent
    }

    var failureMessage: String? { failure.withLock { $0 } }
}

/// Control-C stops the running job its own way (a pack deletes its unfinished file; a copy keeps
/// what's copied, to pick up later). Pressed again, or with nothing running, it quits at once.
enum Interrupt {
    private static let state = Locked<(stop: (@Sendable () -> Void)?, pressed: Bool)>((nil, false))
    nonisolated(unsafe) private static var source: DispatchSourceSignal?
    private static let installed: Void = {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            let stop = Interrupt.state.withLock { state -> (@Sendable () -> Void)? in
                guard let stop = state.stop, !state.pressed else { return nil }
                state.pressed = true
                return stop
            }
            guard let stop else {
                FileHandle.standardError.write(Data("\n".utf8))
                exit(130)
            }
            let clear = isatty(STDERR_FILENO) != 0 ? "\r\u{1B}[K" : ""
            FileHandle.standardError.write(Data((clear + "Stopping… (Control-C again quits at once)\n").utf8))
            stop()
        }
        source.resume()
        Interrupt.source = source
    }()

    static func onControlC(_ stop: (@Sendable () -> Void)?) {
        _ = installed
        state.withLock { $0 = (stop, false) }
    }
}

exit(Command.main(Array(CommandLine.arguments.dropFirst())))
