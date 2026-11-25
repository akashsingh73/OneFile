import AppKit
import SwiftUI

/// Cloud accounts (set up in Settings), and browsing what's in one (Unpack's From the Cloud).
@MainActor
final class CloudModel: ObservableObject {
    static let shared = CloudModel()

    @Published private(set) var accounts: [CloudAccount] = CloudStore.load()

    func reload() { accounts = CloudStore.load() }

    // MARK: Adding an account

    enum Service: Hashable {
        case s3(S3Service)
        case googleDrive

        var title: String {
            switch self {
            case .s3(let service): service.title
            case .googleDrive: "Google Drive"
            }
        }
    }

    /// Where the sheet for adding an account shows: Settings, or the main window (from Pack).
    enum Place {
        case settings, main
    }

    @Published var adding: Place?
    @Published var draftService = Service.s3(.aws)
    @Published var draftName = ""
    @Published var draftBucket = ""
    @Published var draftRegion = ""
    @Published var draftAccountID = ""
    @Published var draftEndpoint = ""
    @Published var draftKeyID = ""
    @Published var draftSecret = ""
    @Published var draftFolder = "OneFile"
    @Published var draftClientID = ""
    @Published var draftClientSecret = ""
    @Published private(set) var trying = false
    @Published private(set) var addProblem: String?

    func startAdding(in place: Place) {
        draftService = .s3(.aws)
        draftName = ""
        draftBucket = ""
        draftRegion = ""
        draftAccountID = ""
        draftEndpoint = ""
        draftKeyID = ""
        draftSecret = ""
        draftFolder = "OneFile"
        draftClientID = ""
        draftClientSecret = ""
        addProblem = nil
        adding = place
    }

    func cancelAdding() {
        guard !trying else { return }
        adding = nil
    }

    /// Whether the sheet shows in `place`, for a binding.
    func isAdding(_ place: Place) -> Binding<Bool> {
        Binding(get: { CloudModel.shared.adding == place },
                set: { if !$0 && CloudModel.shared.adding == place { CloudModel.shared.adding = nil } })
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canAdd: Bool {
        let name = trimmed(draftName)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"),
              !accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        switch draftService {
        case .googleDrive:
            return !trimmed(draftClientID).isEmpty && !trimmed(draftClientSecret).isEmpty
        case .s3(let service):
            guard !trimmed(draftBucket).isEmpty, !trimmed(draftKeyID).isEmpty, !draftSecret.isEmpty else { return false }
            if service == .r2 { return !trimmed(draftAccountID).isEmpty }
            if service == .other { return URL(string: trimmed(draftEndpoint))?.host != nil }
            return true
        }
    }

    /// Why the name won't do, if it won't.
    var nameProblem: String? {
        let name = trimmed(draftName)
        if name.contains("/") || name.contains(":") { return "A name can't have / or : in it." }
        if accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return "There's an account with that name." }
        return nil
    }

    /// Tries the account (Google: signs in, in the browser, first) and keeps it if it works.
    func add() {
        guard canAdd, !trying else { return }
        var account = CloudAccount(name: trimmed(draftName))
        account.folder = trimmed(draftFolder)
        var secrets: [(String, String)] = []
        let clientSecret = trimmed(draftClientSecret)
        switch draftService {
        case .googleDrive:
            account.kind = .googleDrive
            account.clientID = trimmed(draftClientID)
            secrets.append((account.clientSecretName, clientSecret))
        case .s3(let service):
            account.bucket = trimmed(draftBucket)
            account.keyID = trimmed(draftKeyID)
            account.region = trimmed(draftRegion).isEmpty ? service.regionHint : trimmed(draftRegion)
            account.endpoint = service == .other ? trimmed(draftEndpoint) : service.endpoint(region: account.region, account: trimmed(draftAccountID))
            account.pathStyle = service.pathStyle
            secrets.append((account.secretName, draftSecret))
        }
        trying = true
        addProblem = nil
        let made = account
        let keep = secrets
        DispatchQueue.global(qos: .userInitiated).async {
            if made.kind == .googleDrive {
                switch GoogleDrive.signIn(clientID: made.clientID, clientSecret: clientSecret) {
                case .failure(let error):
                    onMain { CloudModel.shared.added(made, .failure(error)) }
                    return
                case .success(let refresh):
                    Keychain.set(refresh, for: made.refreshName)
                }
            }
            for (name, secret) in keep { Keychain.set(secret, for: name) }
            let result = Cloud.connect(made).flatMap { place in Cloud.archives(in: place).map { _ in () } }
            onMain { CloudModel.shared.added(made, result) }
        }
    }

    private func added(_ account: CloudAccount, _ result: Result<Void, CloudError>) {
        trying = false
        switch result {
        case .success:
            CloudStore.change { $0.append(account) }
            reload()
            let place = adding
            adding = nil
            // Added from Pack: pack to it.
            if place == .main { PackModel.shared.packToCloud(account) }
        case .failure(let error):
            for name in [account.secretName, account.clientSecretName, account.refreshName] { Keychain.delete(name) }
            addProblem = error.message
        }
    }

    func remove(_ account: CloudAccount) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(account.name)”?"
        alert.informativeText = "OneFile forgets the account and its keys. What's in the cloud stays."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for name in [account.secretName, account.clientSecretName, account.refreshName] { Keychain.delete(name) }
        CloudStore.change { $0.removeAll { $0.id == account.id } }
        reload()
        if browsingAccount?.id == account.id { browsingAccount = accounts.first }
    }

    // MARK: Browsing

    @Published var browsing = false
    @Published var browsingAccount: CloudAccount?
    @Published private(set) var items: [CloudItem] = []
    @Published private(set) var loading = false
    @Published private(set) var browseProblem: String?
    @Published var selection: CloudItem.ID?
    @Published private(set) var note: String?
    private var place: CloudPlace?
    private var loadedFor: UUID?

    func browse() {
        reload()
        if browsingAccount == nil || !accounts.contains(where: { $0.id == browsingAccount?.id }) { browsingAccount = accounts.first }
        note = nil
        browsing = true
        load()
    }

    func load() {
        guard let account = browsingAccount else { return }
        loading = true
        browseProblem = nil
        items = []
        selection = nil
        place = nil
        loadedFor = account.id
        DispatchQueue.global(qos: .userInitiated).async {
            let connected = Cloud.connect(account)
            let listed = connected.flatMap { Cloud.archives(in: $0) }
            onMain {
                let model = CloudModel.shared
                guard model.loadedFor == account.id else { return }
                model.loading = false
                switch listed {
                case .success(let items):
                    model.place = try? connected.get()
                    model.items = items
                case .failure(let error):
                    model.browseProblem = error.message
                }
            }
        }
    }

    var selectedItem: CloudItem? { items.first { $0.id == selection } }

    func openSelected() {
        guard let item = selectedItem, let place, let account = browsingAccount else { return }
        let url = Cloud.open(item, in: place, among: items)
        browsing = false
        UnpackModel.shared.openRemote(url, label: "in “\(account.name)”")
    }

    func copyLink() {
        guard let item = selectedItem, let place else { return }
        note = "Making a link…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Cloud.link(item, in: place)
            onMain {
                let model = CloudModel.shared
                switch result {
                case .success(let url):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    if case .drive = place {
                        model.note = "Copied a link to “\(item.name)”: anyone with it can download it."
                    } else {
                        model.note = "Copied a link to “\(item.name)”: anyone with it can download it for 7 days."
                    }
                case .failure(let error):
                    model.note = error.message
                }
            }
        }
    }

    func deleteSelected() {
        guard let item = selectedItem, let place, let account = browsingAccount else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(item.name)” from “\(account.name)”?"
        alert.informativeText = "It's deleted from the cloud for good (\(Format.bytes(item.size)))."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Cloud.delete(item, in: place)
            onMain {
                let model = CloudModel.shared
                if case .failure(let error) = result { model.note = error.message } else { model.load() }
            }
        }
    }

    // MARK: Links

    @Published var openingLink = false
    @Published var linkDraft = ""

    func openLink() {
        let text = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        openingLink = false
        UnpackModel.shared.openRemote(url, label: "at " + (url.host ?? "a link"))
    }
}

/// Settings › Cloud: the accounts, and adding one.
struct CloudSettingsSection: View {
    @ObservedObject var model: CloudModel

    var body: some View {
        Section("Cloud") {
            if model.accounts.isEmpty {
                Text("Pack straight to Amazon S3, Cloudflare R2, Backblaze B2, Google Cloud Storage, Wasabi or Google Drive, and unpack from them, without the whole archive ever on the disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                        Text("\(account.kindText) · \(account.placeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { model.remove(account) }
                        .controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Add an Account…") { model.startAdding(in: .settings) }
            }
        }
        .sheet(isPresented: model.isAdding(.settings)) { AddCloudAccountSheet(model: model) }
    }
}

struct AddCloudAccountSheet: View {
    @ObservedObject var model: CloudModel

    private var isDrive: Bool { model.draftService == .googleDrive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a Cloud Account")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Form {
                Picker("Service", selection: $model.draftService) {
                    ForEach(S3Service.allCases) { Text($0.title).tag(CloudModel.Service.s3($0)) }
                    Divider()
                    Text("Google Drive").tag(CloudModel.Service.googleDrive)
                }
                TextField("Name", text: $model.draftName, prompt: Text(isDrive ? "My Drive" : "Backups bucket"))
                if let problem = model.nameProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                if case .s3(let service) = model.draftService {
                    TextField("Bucket", text: $model.draftBucket, prompt: Text("my-bucket"))
                    if service == .r2 {
                        TextField("Account ID", text: $model.draftAccountID, prompt: Text("From the R2 overview"))
                    }
                    if service == .other {
                        TextField("Endpoint", text: $model.draftEndpoint, prompt: Text("https://s3.example.com"))
                    }
                    if service != .r2 && service != .gcs {
                        TextField("Region", text: $model.draftRegion, prompt: Text(service.regionHint))
                    }
                    TextField("Access key ID", text: $model.draftKeyID)
                    SecureField("Secret key", text: $model.draftSecret)
                    Text(Self.help(service))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Client ID", text: $model.draftClientID, prompt: Text("….apps.googleusercontent.com"))
                    SecureField("Client secret", text: $model.draftClientSecret)
                    Text("Google Drive needs a Google Cloud client of your own (OneFile has none to hand out): in Google Cloud Console, make a project, turn on the Google Drive API, and under Credentials make an OAuth client ID of the kind Desktop app. OneFile sees only the files it makes itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Folder", text: $model.draftFolder, prompt: Text("OneFile"))
            }
            .formStyle(.grouped)
            .disabled(model.trying)
            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.addProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if model.trying {
                        ProgressView().controlSize(.small)
                        Text(isDrive ? "Finish signing in, in the browser…" : "Trying it…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { model.cancelAdding() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.trying)
                    Button(isDrive ? "Sign In with Google…" : "Add") { model.add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdd || model.trying)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 470)
    }

    static func help(_ service: S3Service) -> String {
        switch service {
        case .aws: "An access key (IAM) allowed to list, read and write the bucket."
        case .r2: "An R2 API token's access key ID and secret (R2 › Manage API tokens)."
        case .b2: "An application key's keyID and applicationKey. The region is in the bucket's endpoint: s3.REGION.backblazeb2.com."
        case .gcs: "An HMAC key: Cloud Storage › Settings › Interoperability."
        case .wasabi: "An access key from Wasabi's console."
        case .other: "Any service that speaks S3: MinIO, Ceph, DigitalOcean Spaces, iDrive e2 and others."
        }
    }
}

/// Unpack › From the Cloud: what's in an account, to open, link to or delete.
struct CloudBrowserSheet: View {
    @ObservedObject var model: CloudModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open from the Cloud")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $model.browsingAccount) {
                    ForEach(model.accounts) { account in
                        Text(account.name).tag(Optional(account))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: model.browsingAccount) { _, _ in model.load() }
            }
            Group {
                if model.accounts.isEmpty {
                    MessageText(text: "No cloud accounts yet: add one in Settings (⌘,), under Cloud.")
                } else if model.loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking in “\(model.browsingAccount?.name ?? "")”…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let problem = model.browseProblem {
                    MessageText(text: problem, warning: true)
                } else if model.items.isEmpty {
                    MessageText(text: "No archives in \(model.browsingAccount?.placeText ?? "it") yet. Pack one there: in Pack, Change… where it goes.")
                } else {
                    Table(model.items, selection: $model.selection) {
                        TableColumn("Name", value: \.name)
                        TableColumn("Size") { item in Text(Format.bytes(item.size)).monospacedDigit() }
                            .width(90)
                        TableColumn("Date") { item in Text(item.modified.map { BackupsModel.when($0) } ?? "") }
                            .width(150)
                    }
                    .contextMenu(forSelectionType: CloudItem.ID.self) { _ in
                        Button("Open") { model.openSelected() }
                        Button("Copy Link") { model.copyLink() }
                        Divider()
                        Button("Delete…") { model.deleteSelected() }
                    } primaryAction: { _ in
                        model.openSelected()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = model.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Copy Link") { model.copyLink() }
                    .disabled(model.selectedItem == nil)
                Button("Delete…") { model.deleteSelected() }
                    .disabled(model.selectedItem == nil)
                Spacer()
                Button("Cancel") { model.browsing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { model.openSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedItem == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

/// Unpack › Open a Link: an archive at a web address, read straight from there.
struct OpenLinkSheet: View {
    @ObservedObject var model: CloudModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a Link")
                .font(.title3.weight(.semibold))
            Text("A link to a .tar, .tar.gz, .tar.zst, .tar.xz or locked archive (one OneFile made, or any other). It's read straight from there: unpacking downloads it as it goes, and for OneFile's own archives, looking inside or taking one file out reads only what's needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $model.linkDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.openLink() }
            HStack {
                Spacer()
                Button("Cancel") { model.openingLink = false }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { model.openLink() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(model.linkDraft.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http")))
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct MessageText: View {
    let text: String
    var warning = false

    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "cloud")
            .font(.callout)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
