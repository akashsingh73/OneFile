import SwiftUI
import AppKit

@main
struct OneFileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        Window("OneFile", id: "main") {
            ContentView(app: app, pack: .shared, unpack: .shared, copy: .shared, send: .shared, receive: .shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { OneFileCommands(app: app) }
    }
}

struct OneFileCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Choose a Folder…") {
                if app.mode == .unpack || app.mode == .receive { app.mode = .pack }
                PackModel.shared.chooseSource()
            }
            .keyboardShortcut("o")
            Button("Choose a File to Unpack…") {
                app.mode = .unpack
                UnpackModel.shared.chooseArchive()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button(goTitle) { go() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Stop") { stop() }
                .keyboardShortcut(".")
        }
        CommandGroup(before: .toolbar) {
            ForEach(AppModel.Mode.allCases) { mode in
                Button(mode.title) { app.mode = mode }
                    .keyboardShortcut(mode.shortcut)
            }
            Divider()
        }
    }

    private var goTitle: String {
        switch app.mode {
        case .pack: "Pack"
        case .unpack: "Unpack"
        case .copy: "Copy"
        case .send: "Send"
        case .receive: "Accept"
        }
    }

    @MainActor
    private func go() {
        switch app.mode {
        case .pack: PackModel.shared.pack()
        case .unpack: UnpackModel.shared.unpack()
        case .copy: CopyModel.shared.copy()
        case .send: SendModel.shared.send()
        case .receive: ReceiveModel.shared.accept()
        }
    }

    @MainActor
    private func stop() {
        switch app.mode {
        case .pack: PackModel.shared.stop()
        case .unpack: UnpackModel.shared.stop()
        case .copy: CopyModel.shared.stop()
        case .send: SendModel.shared.stop()
        case .receive: ReceiveModel.shared.stop()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Packer.stopDownloadingCloudFiles()
        _ = Unpacker.umaskBits
        MainActor.assumeIsolated {
            NSApp.servicesProvider = ServiceProvider.shared
            NSUpdateDynamicServices()
            AppModel.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Folders and tar files dropped on OneFile's icon, opened with it, or `open -a OneFile …`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.open(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.confirmQuit() } ? .terminateNow : .terminateCancel
    }
}

/// Finder's Services menu (Control-click a folder or a tar file): Pack, Send or Unpack with OneFile.
final class ServiceProvider: NSObject {
    @MainActor static let shared = ServiceProvider()

    @objc func packWithOneFile(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        open(pasteboard, as: .pack)
    }

    @objc func sendWithOneFile(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        open(pasteboard, as: .send)
    }

    @objc func unpackWithOneFile(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        open(pasteboard, as: .unpack)
    }

    private func open(_ pasteboard: NSPasteboard, as mode: AppModel.Mode) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        MainActor.assumeIsolated { AppModel.shared.open(urls, as: mode) }
    }
}
