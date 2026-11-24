import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The folder side (shared by Pack and Send: the folder, what's in it, the method, what to leave
/// out), and packing it into a file.
@MainActor
final class PackModel: ObservableObject {
    static let shared = PackModel()

    enum Stage {
        case ready
        case packing
        case finished(Packer.Summary)
        case failed(String)
        case stopped
    }

    /// What's in the folder, counted as soon as it's chosen.
    enum Count {
        case none
        case counting(Packer.Totals)
        case counted(Packer.Totals)
        case failed(String)
    }

    /// Where a file goes: the disk's free space and kind.
    struct Room {
        var free: Int64?
        var volume: String
        var isFAT: Bool

        init(folder: URL) {
            free = Packer.freeSpace(folder.path)
            volume = Packer.volumeName(folder.path)
            isFAT = Packer.isFAT(folder.path)
        }
    }

    /// A kind of rebuildable folder found in the folder, and whether it's being left out.
    struct Suggestion: Identifiable {
        let rule: RebuildableRule
        let totals: RebuildableTotals
        let leftOut: Bool
        var id: Int16 { rule.id }
    }

    @Published private(set) var source: URL?
    /// The drive the folder is on.
    @Published private(set) var sourceDrive: Drive?
    @Published private(set) var destination: URL?
    @Published private(set) var count: Count = .none
    @Published private(set) var insights: FolderInsights?
    @Published private(set) var stage: Stage = .ready
    @Published private(set) var progress = Packer.Progress()
    @Published private(set) var meter = RateMeter()
    @Published private(set) var room: Room?
    @Published private(set) var finishedAt: Date?
    @Published var showingProblems = false
    /// A folder is being dragged over the window. (Here rather than in the view's `@State`:
    /// `@State` is a macro, and the Command Line Tools don't ship the plugin it needs.)
    @Published var isDropTarget = false
    @Published var leaveOut: String {
        didSet { leaveOutChanged() }
    }
    /// What's being typed next to the Leave out tags.
    @Published var leaveOutDraft = ""
    /// How to compress, if at all.
    @Published private(set) var method: PackMethod
    /// How big each method's file would be, and how fast: nil until the sample is measured.
    @Published private(set) var estimates: Estimates?
    /// Kinds of rebuildable folders being left out (`Rebuildable` rule ids).
    @Published private(set) var skipRebuildable: Set<Int16>

    /// The folder picked in the Save panel, kept for the next folder packed.
    private var chosenFolder: URL?
    /// The name (without extension) typed in the Save panel, for this folder.
    private var chosenName: String?
    /// The exact file the person confirmed in the Save panel, so replacing it is fine.
    private var confirmedDestination: URL?
    /// The person picked a method; until then, OneFile follows its recommendation.
    private var methodChosen: Bool
    private var packer: Packer?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var countFlag: StopFlag?
    private var countedRules: [String] = []
    private var countedSkips: Set<Int16> = []
    private var recount: Task<Void, Never>?
    /// How big each rebuildable kind was the last time it was counted in, for when it's left out.
    private var knownRebuildable: [Int16: RebuildableTotals] = [:]

    private static let leaveOutKey = "leaveOut"
    private static let methodKey = "method"
    private static let rebuildableKey = "skipRebuildable"

    init() {
        let defaults = UserDefaults.standard
        leaveOut = defaults.string(forKey: Self.leaveOutKey) ?? ".DS_Store"
        let saved = defaults.string(forKey: Self.methodKey).flatMap(PackMethod.init(rawValue:))
        method = saved ?? .plain
        methodChosen = saved != nil
        skipRebuildable = Set((defaults.array(forKey: Self.rebuildableKey) as? [Int] ?? []).map(Int16.init))
    }

    /// Replacing an existing file is fine only if it's the one confirmed in the Save panel.
    private var replaceExisting: Bool { destination != nil && destination == confirmedDestination }

    var isPacking: Bool {
        if case .packing = stage { return true }
        return false
    }

    /// The folder can't change while it's being packed, sent or copied.
    var isLocked: Bool { isPacking || SendModel.shared.isBusy || CopyModel.shared.isCopying }

    var canPack: Bool {
        source != nil && destination != nil && !isLocked && !warningStopsPacking
    }

    /// The options packing (or sending) uses.
    var options: Packer.Options {
        Packer.Options(leaveOut: WalkRules.parse(leaveOut), method: method, skipRebuildable: skipRebuildable)
    }

    /// The counted totals, if they're for the options in use now.
    var knownTotals: Packer.Totals? {
        if case .counted(let totals) = count, countedRules == WalkRules.parse(leaveOut), countedSkips == skipRebuildable {
            return totals
        }
        return nil
    }

    // MARK: Choosing

    func chooseSource() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = source?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(url)
    }

    /// Takes a folder chosen or dropped on the window. False if it isn't a folder that can be packed.
    @discardableResult
    func setSource(_ url: URL) -> Bool {
        guard !isLocked else { return false }
        var isFolder: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              isFolder.boolValue, url.path != "/" else { return false }
        let folder = url.standardizedFileURL
        if folder != source {
            knownRebuildable = [:]
            insights = nil
        }
        source = folder
        sourceDrive = Drive.of(folder.path)
        stage = .ready
        chosenName = nil
        confirmedDestination = nil
        destination = defaultDestination(for: folder)
        refreshRoom()
        startCount()
        return true
    }

    func chooseDestination() {
        guard !isLocked, let source else { return }
        let panel = NSSavePanel()
        panel.title = "Save the Packed File"
        panel.prompt = "Choose"
        panel.message = "Choose where to save the one file. An external drive is fine."
        panel.nameFieldStringValue = destination?.lastPathComponent ?? source.lastPathComponent + "." + method.fileExtension
        panel.directoryURL = destination?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenFolder = url.deletingLastPathComponent()
        chosenName = ArchiveName.split(url.lastPathComponent).base
        // The extension always matches the method. If that changed the name, the Save panel's
        // question about replacing was about another file, so this one isn't replaced.
        let fixed = ArchiveName.with(url, method: method)
        confirmedDestination = fixed == url ? url : nil
        destination = defaultDestination(for: source)
        refreshRoom()
    }

    /// Saves the packed file in `folder` (Copy's destination, when packing is the faster way there).
    func saveIn(_ folder: URL) {
        guard !isLocked else { return }
        chosenFolder = folder
        confirmedDestination = nil
        if let source { destination = defaultDestination(for: source) }
        stage = .ready
        refreshRoom()
    }

    /// Next to the folder (or in the folder picked last time), named after it (or as typed in the
    /// Save panel), with the method's extension, under a name not yet taken.
    private func defaultDestination(for source: URL) -> URL {
        let fm = FileManager.default
        var folder = chosenFolder ?? source.deletingLastPathComponent()
        if !fm.isWritableFile(atPath: folder.path) {
            folder = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        let first = folder.appendingPathComponent((chosenName ?? source.lastPathComponent) + "." + method.fileExtension)
        if first == confirmedDestination { return first }
        var candidate = first
        var number = 2
        while fm.fileExists(atPath: candidate.path) || fm.fileExists(atPath: candidate.path + ".part") {
            candidate = ArchiveName.numbered(first, number)
            number += 1
        }
        return candidate
    }

    /// Picks a method (the person's choice from now on).
    func choose(_ new: PackMethod) {
        guard !isLocked else { return }
        methodChosen = true
        UserDefaults.standard.set(new.rawValue, forKey: Self.methodKey)
        setMethod(new)
    }

    private func setMethod(_ new: PackMethod) {
        guard new != method else { return }
        method = new
        if let source, case .ready = stage { destination = defaultDestination(for: source) }
    }

    private func refreshRoom() {
        room = destination.map { Room(folder: $0.deletingLastPathComponent()) }
    }

    // MARK: Counting what's in the folder

    private func leaveOutChanged() {
        UserDefaults.standard.set(leaveOut, forKey: Self.leaveOutKey)
        recount?.cancel()
        recount = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, WalkRules.parse(self.leaveOut) != self.countedRules else { return }
            self.startCount()
        }
    }

    /// Leaves out (or packs again) a kind of rebuildable folder.
    func toggleRebuildable(_ id: Int16) {
        guard !isLocked else { return }
        if skipRebuildable.contains(id) { skipRebuildable.remove(id) } else { skipRebuildable.insert(id) }
        UserDefaults.standard.set(skipRebuildable.map(Int.init), forKey: Self.rebuildableKey)
        startCount()
    }

    private func startCount() {
        countFlag?.set()
        guard let source else {
            count = .none
            return
        }
        let flag = StopFlag()
        countFlag = flag
        let rules = WalkRules.parse(leaveOut)
        let skips = skipRebuildable
        countedRules = rules
        countedSkips = skips
        count = .counting(Packer.Totals())
        estimates = nil
        DispatchQueue.global(qos: .userInitiated).async {
            switch Packer.root(for: source) {
            case .failure(let error):
                let message = error.message
                onMain { PackModel.shared.counted(.failed(message), insights: nil, flag: flag) }
            case .success(let root):
                var lastReport = DispatchTime.now().uptimeNanoseconds
                let result = Packer.count(root, rules: WalkRules(leaveOut: rules, device: root.entry.device,
                                                                 skipRebuildable: skips),
                                          stopped: { flag.isSet }, progress: { partial in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now - lastReport > 150_000_000 else { return }
                    lastReport = now
                    onMain { PackModel.shared.counted(.counting(partial), insights: nil, flag: flag) }
                })
                guard let result else { return }
                let totals = result.totals
                let insights = result.insights
                onMain { PackModel.shared.counted(.counted(totals), insights: insights, flag: flag) }
                // Then how well it compresses, from a sample: well under a second.
                let estimates = Estimator.estimate(totals, samples: result.samples)
                guard !flag.isSet else { return }
                onMain { PackModel.shared.estimated(estimates, flag: flag) }
            }
        }
    }

    private func counted(_ result: Count, insights: FolderInsights?, flag: StopFlag) {
        guard flag === countFlag, !flag.isSet else { return }
        count = result
        if case .counted = result {
            self.insights = insights
            for suggestion in insights?.suggestions ?? [] { knownRebuildable[suggestion.rule.id] = suggestion.totals }
        } else {
            estimates = nil
            if case .failed = result { self.insights = nil }
        }
    }

    private func estimated(_ result: Estimates, flag: StopFlag) {
        guard flag === countFlag, !flag.isSet else { return }
        estimates = result
        if !methodChosen { setMethod(result.recommended) }
    }

    // MARK: Packing

    func pack() {
        guard canPack, let source, let destination else { return }
        let known = knownTotals
        // If counting isn't done, the packer counts for itself, alongside the packing.
        if known == nil { countFlag?.set() }

        let packer = Packer(source: source, destination: destination, replaceExisting: replaceExisting,
                            options: options, knownTotals: known)
        self.packer = packer
        progress = packer.progress()
        meter.reset()
        finishedAt = nil
        stage = .packing
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Packing a folder into one file")
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { PackModel.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        AppModel.shared.activityChanged()
        packer.start { outcome in
            onMain { PackModel.shared.finish(outcome) }
        }
    }

    func stop() {
        packer?.cancel()
    }

    /// Quitting: stops, and deletes the unfinished file right away.
    func stopForQuit() {
        guard let packer else { return }
        packer.cancel()
        if let part = packer.partPath { unlink(part) }
    }

    private func tick() {
        guard let packer else { return }
        progress = packer.progress()
        meter.add(bytes: progress.processed, files: progress.files)
    }

    private func finish(_ outcome: Packer.Outcome) {
        timer?.invalidate()
        timer = nil
        if let packer { progress = packer.progress() }
        packer = nil
        // Packing started before counting finished, so the packer counted: show its count.
        if case .counted = count {} else if let totals = progress.totals {
            count = .counted(totals)
            countedRules = WalkRules.parse(leaveOut)
            countedSkips = skipRebuildable
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        switch outcome {
        case .finished(let summary):
            stage = .finished(summary)
            finishedAt = Date()
        case .stopped: stage = .stopped
        case .failed(let message): stage = .failed(message)
        }
        AppModel.shared.activityChanged()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Back to the start, with the same folder, ready to pack it again or pick another.
    func done() {
        stage = .ready
        confirmedDestination = nil
        if let source { destination = defaultDestination(for: source) }
        refreshRoom()
    }

    func showInFinder() {
        guard case .finished(let summary) = stage, let output = summary.output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    func copyProblems() {
        guard case .finished(let summary) = stage else { return }
        Problems.copy(summary.problems)
    }

    // MARK: Leave out, as tags

    /// The names and patterns to leave out, one tag each.
    var leaveOutItems: [String] { WalkRules.parse(leaveOut) }

    /// Adds what's typed in the field next to the tags (several at once if separated by commas).
    func addLeaveOut() {
        let items = leaveOutItems
        let new = WalkRules.parse(leaveOutDraft).filter { !items.contains($0) }
        leaveOutDraft = ""
        guard !new.isEmpty else { return }
        leaveOut = (items + new).joined(separator: ", ")
    }

    func removeLeaveOut(_ item: String) {
        leaveOut = leaveOutItems.filter { $0 != item }.joined(separator: ", ")
    }

    // MARK: Suggestions

    /// Rebuildable folders found (or being left out), the biggest first.
    var suggestions: [Suggestion] {
        var list: [Suggestion] = []
        for found in insights?.suggestions ?? [] where !skipRebuildable.contains(found.rule.id) {
            list.append(Suggestion(rule: found.rule, totals: found.totals, leftOut: false))
        }
        for id in skipRebuildable {
            if let rule = Rebuildable.rule(id), let totals = knownRebuildable[id] {
                list.append(Suggestion(rule: rule, totals: totals, leftOut: true))
            }
        }
        return list.sorted { $0.totals.files > $1.totals.files }
    }

    /// Worth showing: they're a good part of the folder, or some are being left out.
    var showsSuggestions: Bool {
        guard case .counted(let totals) = count else { return false }
        let list = suggestions
        if list.contains(where: \.leftOut) { return true }
        let files = list.reduce(Int64(0)) { $0 + $1.totals.files }
        return files >= 200 || (totals.files > 0 && Double(files) / Double(totals.files) >= 0.1 && files >= 20)
    }

    var suggestionHeadline: String {
        let list = suggestions
        let included = list.filter { !$0.leftOut }.reduce(Int64(0)) { $0 + $1.totals.files }
        let leftOut = list.filter(\.leftOut).reduce(Int64(0)) { $0 + $1.totals.files }
        if included == 0 {
            return "Leaving out \(Format.count(leftOut)) files that can be rebuilt"
        }
        guard case .counted(let totals) = count, totals.files > 0 else { return "Some of these files can be rebuilt" }
        let share = Double(included) / Double(totals.files)
        if share >= 0.995 { return "Nearly all these files can be rebuilt" }
        return "\(share.formatted(.percent.precision(.fractionLength(0)))) of these files can be rebuilt on the other side"
    }

    // MARK: What the window says

    /// For animating between stages.
    var stageKey: Int {
        switch stage {
        case .ready: 0
        case .packing: 1
        case .finished: 2
        case .failed: 3
        case .stopped: 4
        }
    }

    var summary: Packer.Summary? {
        if case .finished(let summary) = stage { return summary }
        return nil
    }

    var isCounting: Bool {
        if case .counting = count { return true }
        return false
    }

    var countFailed: Bool {
        if case .failed = count { return true }
        return false
    }

    /// "in ~/Projects", or on another drive, "in “Backups” on “Travel SSD”".
    var sourceFolderLine: String {
        guard let source else { return "" }
        let parent = source.deletingLastPathComponent()
        if let drive = sourceDrive, !drive.isStartup {
            if Copier.realPath(parent.path) == Copier.realPath(drive.mountPath) { return "on “\(drive.name)”" }
            return "in “\(parent.lastPathComponent)” on “\(drive.name)”"
        }
        return "in " + Format.path(parent)
    }

    var sourceCountText: String {
        switch count {
        case .none: return ""
        case .counting(let totals): return "Counting… \(Format.count(totals.files)) files"
        case .counted(let totals): return "\(Format.count(totals.files)) files · \(Format.bytes(totals.bytes))"
        case .failed(let message): return message
        }
    }

    /// The tar file: where it will go, or where it went.
    var shownDestination: URL? { summary?.output ?? destination }

    var destinationSizeText: String? {
        if let summary { return Format.bytes(summary.archiveBytes) }
        guard let size = expectedSize(method) else {
            if case .counted = count { return "Estimating the size…" }
            return nil
        }
        return "About \(Format.bytes(size))"
    }

    /// The file's size for `method`: exact enough for no compression, an estimate otherwise.
    func expectedSize(_ method: PackMethod) -> Int64? {
        guard case .counted(let totals) = count else { return nil }
        if method == .plain { return totals.archiveBytes }
        return estimates?.bytes[method]
    }

    var destinationRoomText: String? {
        guard summary == nil, let room, let free = room.free else { return nil }
        return "\(Format.bytes(free)) free on “\(room.volume)”"
    }

    var destinationWarning: String? {
        guard let room, summary == nil, let size = expectedSize(method) else { return nil }
        let maybe = method == .plain ? "" : "May not fit: "
        if room.isFAT && size >= 4 << 30 {
            return maybe + "this drive is FAT32, which can't hold a file of 4 GB or more. Pick another place, or format it as exFAT."
        }
        if let free = room.free, size > free {
            return maybe + "it needs about \(Format.bytes(size)), and \(Format.bytes(free)) is free here."
        }
        return nil
    }

    /// Without compression the size is known, so a warning means it can't work. Compressed, it's an
    /// estimate: say so, but let the person try.
    var warningStopsPacking: Bool { method == .plain && destinationWarning != nil }

    // MARK: Methods

    func isRecommended(_ method: PackMethod) -> Bool { estimates?.recommended == method }

    func methodSizeText(_ method: PackMethod) -> String {
        guard let size = expectedSize(method) else {
            if case .counted = count { return "Estimating…" }
            return "–"
        }
        return (method == .plain ? "" : "≈ ") + Format.bytes(size)
    }

    func methodDetailText(_ method: PackMethod) -> String {
        guard case .counted(let totals) = count else { return method == .plain ? "Same size as the folder" : " " }
        if method == .plain { return "Same size as the folder" }
        guard let estimates, let size = estimates.bytes[method] else { return " " }
        let times = Double(totals.archiveBytes) / Double(max(size, 1))
        let smaller = times < 1.1 ? "Barely smaller" : String(format: "%.1f× smaller", times)
        guard let seconds = estimates.seconds(for: method, tarBytes: totals.archiveBytes) else { return smaller }
        return "\(smaller) · ~\(Format.duration(seconds))"
    }

    /// Why OneFile recommends what it does, for this folder.
    var recommendationReason: String? {
        estimates.map { "Recommended for this folder: it \($0.reason)." }
    }

    var packButtonTitle: String {
        if case .counted(let totals) = count, totals.files > 0 {
            return "Pack \(Format.count(totals.files)) \(totals.files == 1 ? "File" : "Files")"
        }
        return "Pack"
    }

    /// How far along, once the folder has been counted.
    var fraction: Double? {
        guard let totals = progress.totals, totals.archiveBytes > 0 else { return nil }
        return min(1, Double(progress.processed) / Double(totals.archiveBytes))
    }

    /// How much of the folder has been read into the tar stream (ahead of `fraction` while
    /// compressing).
    var readFraction: Double? {
        guard let totals = progress.totals, totals.archiveBytes > 0 else { return nil }
        return min(1, Double(progress.written) / Double(totals.archiveBytes))
    }

    var percentText: String {
        guard let fraction else { return "Packing…" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var etaText: String {
        if progress.finishing { return "Saving to the disk…" }
        guard let totals = progress.totals else { return "Counting what's left…" }
        guard let fraction, fraction > 0.01, meter.bytesPerSecond > 0 else { return "Working out the time left…" }
        let left = Double(totals.archiveBytes - progress.processed) / meter.bytesPerSecond
        return "About \(Format.duration(left)) left"
    }

    var filesDetail: String {
        if let totals = progress.totals { return "of \(Format.count(totals.files))" }
        return "\(Format.count(progress.counted.files)) counted"
    }

    var dataDetail: String {
        progress.totals.map { "of \(Format.bytes($0.bytes))" } ?? ""
    }

    /// The file being written, and how big it is so far.
    var outputText: String {
        let name = destination?.lastPathComponent ?? ""
        guard progress.outputBytes > 0 else {
            return method == .plain ? "\(name) · starting…" : "\(name) · compressing the first pieces…"
        }
        var text = "\(name) · \(Format.bytes(progress.outputBytes)) so far"
        if method != .plain, progress.outputBytes > 0, progress.processed > 0 {
            let times = Double(progress.processed) / Double(progress.outputBytes)
            text += times < 1.05 ? ", barely smaller" : String(format: ", %.1f× smaller", times)
        }
        return text
    }

    var timeValue: String {
        Format.clock(Date().timeIntervalSince(progress.started))
    }
}

/// Copying a list of problems.
enum Problems {
    static func copy(_ problems: [Problem]) {
        let text = problems.map { "\($0.path)\t\($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
