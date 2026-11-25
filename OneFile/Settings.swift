import SwiftUI
import AppKit

/// OneFile's settings (⌘,), kept in the defaults.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    /// Let other apps use the disks first, and run at a lower priority.
    @Published var gentle: Bool {
        didSet {
            UserDefaults.standard.set(gentle, forKey: Work.gentleKey)
            Work.applyDiskPriority()
        }
    }

    /// Pause packing, unpacking and copying while the Mac runs on its battery.
    @Published var pauseOnBattery: Bool {
        didSet { UserDefaults.standard.set(pauseOnBattery, forKey: Work.pauseOnBatteryKey) }
    }

    init() {
        gentle = Work.gentle
        pauseOnBattery = Work.pauseOnBattery
        refreshCommand()
    }

    // MARK: The onefile command

    /// Where Terminal finds it: a link to the one inside the app.
    static let commandLink = "/usr/local/bin/onefile"

    /// The onefile command inside the app (build.sh puts it there).
    let commandPath: String? = {
        let path = Bundle.main.bundlePath + "/Contents/Helpers/onefile"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// /usr/local/bin/onefile is a link to this app's command.
    @Published private(set) var commandInstalled = false
    @Published private(set) var commandMessage: String?

    func refreshCommand() {
        guard let commandPath else { return }
        commandInstalled = (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.commandLink)) == commandPath
    }

    /// Links /usr/local/bin/onefile to the command in the app. macOS asks for an administrator's
    /// password: /usr/local/bin belongs to the system.
    func installCommand() {
        guard let commandPath else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.commandLink), (try? fm.destinationOfSymbolicLink(atPath: Self.commandLink)) == nil {
            commandMessage = "There's another onefile in /usr/local/bin already: OneFile leaves it be."
            return
        }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = "mkdir -p /usr/local/bin && ln -sfh \(quoted(commandPath)) \(quoted(Self.commandLink))"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        refreshCommand()
        if commandInstalled {
            commandMessage = "Installed. In Terminal, type onefile help."
        } else if (error?[NSAppleScript.errorNumber] as? Int) == -128 {
            commandMessage = nil
        } else {
            commandMessage = "Couldn't install it: \(error?[NSAppleScript.errorMessage] as? String ?? "macOS said no")."
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var backups = BackupsModel.shared

    var body: some View {
        Form {
            Section("While working") {
                Toggle(isOn: $model.gentle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work gently")
                        Text("Other apps get the disks first, and OneFile runs at a lower priority: slower, but the Mac stays responsive. The disk priority changes at once; the rest from the next job.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if ThisMac.hasBattery() {
                    Toggle(isOn: $model.pauseOnBattery) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pause on battery")
                            Text("Packing, unpacking, copying and backing up pause when the Mac goes onto its battery, and carry on when it's back on power.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Section("Backups") {
                Toggle(isOn: Binding(get: { backups.background }, set: { backups.setBackground($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Back up even when OneFile isn't open")
                        Text("A small background task looks each time a drive is plugged in (and each hour, for daily and weekly backups) and runs the backups that are due. macOS lists it in Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(model.commandPath == nil)
                if backups.rules.isEmpty {
                    Text("To set one up, pick a drive in Drives, then Add a Folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backups.rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(rule.sourceName) → “\(rule.driveName)”")
                                Text((rule.lastRun.map { "Last: \(BackupsModel.when($0))" } ?? "Not backed up yet")
                                     + (backups.isPluggedIn(rule) ? " · plugged in now" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { backups.remove(rule) }
                                .controlSize(.small)
                        }
                    }
                }
                if let problem = backups.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CloudSettingsSection(model: .shared)
            Section("In Terminal") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("The onefile command")
                        Spacer()
                        Button(model.commandInstalled ? "Installed" : "Install…") { model.installCommand() }
                            .disabled(model.commandInstalled || model.commandPath == nil)
                    }
                    Text("Packs, unpacks, copies, compares and the rest from Terminal and scripts (onefile help says how). Installing puts a link to it in /usr/local/bin: macOS asks for your password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = model.commandMessage {
                        Text(message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}
