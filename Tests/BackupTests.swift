import Foundation

/// Backing folders up to drives when they're plugged in: what's due, running one, and the onefile
/// command's backup. The backups file is kept in the test folder (ONEFILE_SUPPORT_FOLDER), never
/// in the real one, and the background agent is never installed.
extension OneFileTests {
    static func backupTests(_ fixture: Fixture, _ c: Checks) {
        setenv("ONEFILE_SUPPORT_FOLDER", fixture.base + "/support", 1)
        defer { unsetenv("ONEFILE_SUPPORT_FOLDER") }

        c.section("Backups: what's due")
        let now = Date()
        let drive = BackupDrive(mountPath: "/Volumes/Travel", name: "Travel", id: "DRIVE-1", plugIn: "100-7")
        let other = BackupDrive(mountPath: "/Volumes/Other", name: "Other", id: "DRIVE-2", plugIn: "100-9")
        var rule = BackupRule(source: "/Users/me/Documents", driveID: "DRIVE-1", driveName: "Travel", folder: "Backups")
        func due(_ rule: BackupRule, _ drives: [BackupDrive]) -> Bool { !Backups.due([rule], drives: drives, now: now).isEmpty }
        c.expect(due(rule, [drive]), "never backed up, drive plugged in: due")
        c.expect(!due(rule, [other]), "its drive isn't plugged in: not due")
        rule.lastRun = now.addingTimeInterval(-60)
        rule.lastPlugIn = "100-7"
        c.expect(!due(rule, [drive]), "every time it's plugged in: not again while it stays plugged in")
        c.expect(due(rule, [BackupDrive(mountPath: "/Volumes/Travel", name: "Travel", id: "DRIVE-1", plugIn: "100-8")]),
                 "plugged in again: due")
        rule.every = .day
        rule.lastRun = now.addingTimeInterval(-3_600)
        c.expect(!due(rule, [drive]), "once a day: not an hour later")
        rule.lastRun = now.addingTimeInterval(-21 * 3_600)
        c.expect(due(rule, [drive]), "once a day: due 21 hours later, plugged in all along")
        rule.every = .week
        c.expect(!due(rule, [drive]), "once a week: not 21 hours later")
        rule.enabled = false
        rule.lastRun = nil
        c.expect(!due(rule, [drive]), "turned off: never due")
        var network = BackupRule(source: "/Users/me/Documents", driveID: "name:NAS", driveName: "NAS", folder: "")
        let nas = BackupDrive(mountPath: "/Volumes/NAS", name: "NAS", id: "name:NAS", plugIn: nil)
        network.lastRun = now.addingTimeInterval(-600)
        c.expect(!due(network, [nas]), "a network drive: not again within the hour")
        network.lastRun = now.addingTimeInterval(-4_000)
        c.expect(due(network, [nas]), "a network drive: due after an hour")

        c.section("Backups: the file they're kept in")
        BackupStore.change { $0 = [rule, network] }
        let loaded = BackupStore.load()
        c.expect(loaded.count == 2 && loaded[0].id == rule.id && loaded[0].every == .week && !loaded[0].enabled
                 && loaded[1].driveID == "name:NAS", "saved and read back")
        BackupStore.change { $0.removeAll() }
        c.expect(BackupStore.load().isEmpty, "removed")
        let agent = BackupAgent.plist(command: "/Applications/OneFile.app/Contents/Helpers/onefile")
        c.expect((agent["ProgramArguments"] as? [String]) == ["/Applications/OneFile.app/Contents/Helpers/onefile", "backup", "--due"]
                 && agent["StartOnMount"] as? Bool == true && agent["StartInterval"] as? Int == 3_600,
                 "the background agent runs onefile backup --due when a drive is mounted, and hourly")

        c.section("Backups: locks")
        do {
            if let held = FileLock("Test.lock") {
                c.expect(FileLock("Test.lock") == nil && FileLock.isHeld("Test.lock"), "a lock held can't be taken again")
                withExtendedLifetime(held) {}
            } else {
                c.fail("couldn't take a lock")
            }
        }
        c.expect(!FileLock.isHeld("Test.lock"), "let go when its holder goes")

        guard let image = ProcessInfo.processInfo.environment["ONEFILE_TEST_APFS"] else {
            print("  (Skipped running backups: no disk image to back up to.)")
            return
        }

        c.section("Backups: to a drive")
        let fm = FileManager.default
        let source = fixture.base + "/backup-source/Documents"
        makeTree(source)
        guard let mounted = Backups.drive(at: image) else {
            c.fail("couldn't tell which drive the disk image is")
            return
        }
        c.expect(!mounted.id.hasPrefix("name:") && mounted.plugIn != nil, "a drive has a volume UUID and a plug-in mark: \(mounted)")
        c.expect(Backups.drives().contains { $0.id == mounted.id }, "it's among the drives plugged in")
        switch Backups.rule(backingUp: URL(fileURLWithPath: fixture.base), to: URL(fileURLWithPath: fixture.base + "/inside")) {
        case .success: c.fail("a backup to the Mac's own disk was set up")
        case .failure(let error): c.expect(error.message.contains("own disk"), "not to the Mac's own disk: \(error.message)")
        }
        let made: BackupRule
        switch Backups.rule(backingUp: URL(fileURLWithPath: source), to: URL(fileURLWithPath: image + "/Backups/Mac")) {
        case .success(let value): made = value
        case .failure(let error):
            c.fail("couldn't set one up: \(error.message)")
            return
        }
        c.expect(made.driveID == mounted.id && made.folder == "Backups/Mac" && made.placeText == "Backups/Mac/Documents",
                 "set up for a folder that isn't there yet: \(made.folder)")
        BackupStore.change { $0 = [made] }
        guard case .finished(let first)? = Backups.runHere(made, on: mounted) else {
            c.fail("the first backup didn't finish")
            return
        }
        let backup = image + "/Backups/Mac/Documents"
        c.expect(first.files == 62 && compare(source, backup, contents: true)?.identical == true, "the first backup copies everything")
        var stored = BackupStore.load()[0]
        c.expect(stored.lastRun != nil && stored.lastPlugIn == mounted.plugIn && !stored.lastFailed
                 && stored.lastResult?.hasPrefix("Copied 62 files") == true, "and notes it: \(stored.lastResult ?? "")")
        c.expect(Backups.due(BackupStore.load(), drives: [mounted]).isEmpty, "then it isn't due while the drive stays plugged in")

        try? "changed\n".write(toFile: source + "/f0/sub0/file-0.txt", atomically: false, encoding: .utf8)
        try? fm.removeItem(atPath: source + "/f1/sub1/file-1.txt")
        guard case .finished(let second)? = Backups.runHere(stored, on: mounted) else {
            c.fail("the second backup didn't finish")
            return
        }
        c.expect(second.files == 1 && second.unchanged == 60, "the next copies only what changed: \(second.files) copied, \(second.unchanged) unchanged")
        c.expect((try? String(contentsOfFile: backup + "/f0/sub0/file-0.txt", encoding: .utf8)) == "changed\n", "the changed file")
        c.expect(fm.fileExists(atPath: backup + "/f1/sub1/file-1.txt"), "and nothing on the drive is deleted")

        do {
            let lock = FileLock(Backups.lockName(stored))
            c.expect(Backups.runHere(stored, on: mounted) == nil, "a backup running elsewhere isn't run twice")
            withExtendedLifetime(lock) {}
        }

        try? fm.moveItem(atPath: source, toPath: source + " moved")
        stored = BackupStore.load()[0]
        if case .failed(let message, _)? = Backups.runHere(stored, on: mounted) {
            c.expect(message.contains("isn't where it was"), "a folder that's gone: \(message)")
            c.expect(BackupStore.load()[0].lastFailed, "noted as failed")
        } else {
            c.fail("a folder that's gone was backed up")
        }
        try? fm.moveItem(atPath: source + " moved", toPath: source)

        guard ProcessInfo.processInfo.environment["ONEFILE_CLI"] != nil else { return }
        c.section("onefile backup")
        BackupStore.change { $0.removeAll() }
        var run = onefile(["backup", "list"])
        c.expect(run.status == 0 && run.output.contains("No backups"), "none set up")
        run = onefile(["backup", "add", source, image + "/Backups/CLI", "--every", "day", "--verify"])
        c.expect(run.status == 0 && run.output.contains("Backups/CLI/Documents"), "sets one up: \(run.output)\(run.errors)")
        run = onefile(["backup", "add", source, image + "/Backups/CLI"])
        c.expect(run.status == 1 && run.errors.contains("already"), "not the same one twice")
        run = onefile(["backup", "add", source, fixture.base + "/elsewhere"])
        c.expect(run.status == 1, "not to the Mac's own disk")
        run = onefile(["backup", "list"])
        c.expect(run.status == 0 && run.output.contains("1. " + source) && run.output.contains("Once a day")
                 && run.output.contains("plugged in now"), "lists it: \(run.output)")
        run = onefile(["backup", "--due"])
        c.expect(run.status == 0 && run.output.contains("Backing up") && run.output.contains("Copied 61 files"),
                 "--due runs what's due: \(run.output)")
        run = onefile(["backup", "--due"])
        c.expect(run.status == 0 && run.output.isEmpty, "and then nothing, once a day: \(run.output)")
        run = onefile(["backup"])
        c.expect(run.status == 0 && run.output.contains("Up to date"), "backup on its own runs it anyway: \(run.output)")
        do {
            let held = FileLock(Backups.appLockName)
            BackupStore.change { rules in rules[0].lastRun = nil }
            run = onefile(["backup", "--due"])
            c.expect(run.status == 0 && run.output.isEmpty, "--due leaves backups to the app while it's open")
            withExtendedLifetime(held) {}
        }
        run = onefile(["backup", "remove", "1"])
        c.expect(run.status == 0 && BackupStore.load().isEmpty && fm.fileExists(atPath: image + "/Backups/CLI/Documents"),
                 "removed, and what's on the drive stays")
        run = onefile(["backup", "remove", "1"])
        c.expect(run.status == 1, "there's nothing to remove")
    }
}
