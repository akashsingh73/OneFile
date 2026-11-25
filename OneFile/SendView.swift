import SwiftUI
import AppKit

/// Send: the folder on the left, Macs nearby on the right.
struct SendScreen: View {
    @ObservedObject var pack: PackModel
    @ObservedObject var model: SendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                FolderCard(model: pack)
                FlowStream(mode: flowMode)
                PeersCard(model: model)
            }
            .frame(height: 214)
            SendPanel(pack: pack, model: model)
                .id(model.stageKey)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .frame(minHeight: 330, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: model.stageKey)
    }

    private var flowMode: FlowStream.Mode {
        switch model.stage {
        case .sending: .flowing(FlowStream.intensity(filesPerSecond: model.meter.filesPerSecond))
        case .connecting, .waiting: .flowing(0.05)
        case .finished: .done
        default: pack.source == nil || model.selectedPeer == nil ? .faint : .ready
        }
    }
}

/// Macs nearby that are ready to receive, to pick one; or the one it's going to.
struct PeersCard: View {
    @ObservedObject var model: SendModel

    var body: some View {
        VStack(spacing: 8) {
            if model.isBusy || model.summary != nil {
                Spacer(minLength: 0)
                Radar(symbol: ThisMac.symbol(selectedKind), active: model.isBusy, size: 96)
                Text(model.peerName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(busyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            } else if model.peers.isEmpty {
                Spacer(minLength: 0)
                switch model.browseStatus {
                case .denied:
                    Image(systemName: "network.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.orange)
                    Text("Can't look for Macs")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Allow OneFile in Privacy & Security › Local Network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") { model.openLocalNetworkSettings() }
                        .controlSize(.small)
                default:
                    Radar(symbol: "magnifyingglass", active: true, size: 92)
                    Text("Looking for Macs…")
                        .font(.system(size: 14, weight: .semibold))
                    Text("On the other Mac, open OneFile and click Receive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
                addressButton
            } else {
                HStack {
                    Text("Macs nearby")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    ProgressView().controlSize(.mini)
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.peers) { peer in
                            PeerRow(peer: peer, selected: model.selectedID == peer.id) { model.select(peer) }
                        }
                    }
                }
                .scrollIndicators(.never)
                addressButton
            }
        }
        .padding(.horizontal, 2)
        .cardStyle()
        .popover(isPresented: $model.showingAddress, arrowEdge: .bottom) {
            AddressPopover(model: model)
        }
    }

    private var addressButton: some View {
        Button("Connect by address…") { model.showingAddress = true }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(model.isBusy)
    }

    private var selectedKind: String {
        model.selectedPeer?.kind ?? "desktop"
    }

    private var busyText: String {
        switch model.stage {
        case .connecting: "Connecting…"
        case .waiting: "Waiting for an answer…"
        case .sending: "Unpacking as it arrives"
        case .finished(let summary): "Has “\(summary.savedAs ?? summary.pack.output?.lastPathComponent ?? "it")” now"
        default: ""
        }
    }
}

extension SendModel {
    var summary: SendSession.Summary? {
        if case .finished(let summary) = stage { return summary }
        return nil
    }
}

struct PeerRow: View {
    let peer: Peer
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: ThisMac.symbol(peer.kind))
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(peer.id.hasPrefix("address:") ? "By address" : "Ready to receive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.teal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.teal.opacity(0.12)) : AnyShapeStyle(Color.primary.opacity(0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Brand.teal.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AddressPopover: View {
    @ObservedObject var model: SendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect by address")
                .font(.headline)
            Text("If the other Mac doesn't show up (a different network, say), type the address its Receive screen shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("192.168.1.20", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addAddress() }
                Button("Add") { model.addAddress() }
                    .disabled(Peer.manual(model.address) == nil)
            }
            Divider()
            Text("Far away, or not a Mac with OneFile? Pack it to the cloud, and send the link.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Pack to the Cloud…") {
                model.showingAddress = false
                AppModel.shared.mode = .pack
                if let account = CloudModel.shared.accounts.first {
                    PackModel.shared.packToCloud(account)
                } else {
                    CloudModel.shared.startAdding(in: .main)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct SendPanel: View {
    @ObservedObject var pack: PackModel
    @ObservedObject var model: SendModel

    var body: some View {
        switch model.stage {
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                if pack.showsSuggestions {
                    SuggestionsBox(model: pack)
                    Spacer(minLength: 14)
                }
                MethodPicker(model: pack, subtitle: "compressing pays off on slow networks")
                Spacer(minLength: 16)
                LeaveOutRow(model: pack)
                Spacer(minLength: 18)
                VStack(spacing: 8) {
                    Button(model.sendButtonTitle) { model.send() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSend)
                    Label("Straight to the other Mac, end-to-end encrypted, and unpacked there as it arrives: no file in between.",
                          systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        case .connecting(let peer):
            PairingPanel(title: "Connecting to “\(peer)”…", code: nil,
                         message: "Making an encrypted connection.", confirm: nil, cancel: model.stop)
        case .waiting(let peer, let code):
            SenderCodePanel(model: model, peer: peer, code: code)
        case .sending(let peer, _):
            WorkPanel(
                percent: model.percentText,
                chip: ("\((model.method ?? pack.method).title) · encrypted", "lock.fill"),
                eta: model.etaText,
                bars: [.init(label: "Packed and sent", fraction: model.sentFraction),
                       .init(label: "Unpacked on “\(peer)”", fraction: model.fraction)],
                tiles: [
                    .init(label: "Files", value: Format.count(model.progress.files),
                          detail: "\(Format.count(model.remote.files)) there"),
                    .init(label: "Data", value: Format.bytes(model.progress.bytes),
                          detail: model.progress.totals.map { "of \(Format.bytes($0.bytes))" } ?? ""),
                    .init(label: "Speed", value: model.meter.speedText, detail: model.meter.filesText),
                    .init(label: "Time", value: model.timeValue, detail: "elapsed"),
                ],
                history: model.meter.history,
                lineSymbol: "lock.fill",
                line: model.wireText,
                current: model.progress.current,
                warning: model.progress.problemCount > 0
                    ? "\(Format.items(Int64(model.progress.problemCount))) couldn't be read" : nil,
                stop: model.stop)
        case .finished(let summary):
            SendFinished(model: model, summary: summary)
        case .declined(let reason):
            MessagePanel(symbol: "hand.raised.fill", tint: .orange, title: "Not accepted", message: reason, done: model.done)
        case .failed(let message):
            MessagePanel(symbol: "xmark.octagon.fill", tint: .red, title: "Couldn't send it", message: message, done: model.done)
        case .stopped:
            MessagePanel(symbol: "stop.circle.fill", tint: .gray, title: "Stopped",
                         message: "Sending stopped; the other Mac deleted what had arrived.", done: model.done)
        }
    }
}

/// The code, for the person sending to compare with the other Mac's, and confirm.
struct SenderCodePanel: View {
    @ObservedObject var model: SendModel
    let peer: String
    let code: String

    var body: some View {
        PairingPanel(title: title, code: code, message: message,
                     confirm: model.confirmed ? nil : { model.confirm() },
                     cancel: { model.stop() })
    }

    private var title: String {
        if model.confirmed { return "Waiting for “\(peer)” to accept" }
        if model.otherAccepted { return "“\(peer)” accepted. Does it show this code?" }
        return "Does “\(peer)” show this code?"
    }

    private var message: String {
        var message = model.confirmed ? "Nothing is sent until “\(peer)” accepts too."
            : "Both Macs must show the same code. If they don't, something is between the two Macs (or it isn't the Mac you meant): cancel."
        if let method = model.method, method != PackModel.shared.method {
            message += " It goes as \(method.title): the OneFile on “\(peer)” is older, and can't unpack \(PackModel.shared.method.title)."
        }
        return message
    }
}

/// Connecting, then the code both Macs show while the other decides.
struct PairingPanel: View {
    let title: String
    let code: String?
    let message: String
    /// "Codes Match, Send", while it's needed.
    let confirm: (() -> Void)?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            if let code {
                CodeView(code: code, digitSize: 34)
                Label("End-to-end encrypted (X25519 and AES-GCM)", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .controlSize(.regular)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if let confirm {
                    Button("Codes Match, Send", action: confirm)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: confirm == nil ? 220 : .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SendFinished: View {
    @ObservedObject var model: SendModel
    let summary: SendSession.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DoneHeader(title: "Sent to “\(summary.peer)” in \(Format.duration(summary.seconds))",
                       detail: "\(Format.count(summary.pack.files)) files and \(Format.count(summary.pack.folders)) folders · \(Format.bytes(summary.pack.bytes)), unpacked there as “\(summary.savedAs ?? "it")”")
            HighlightRow(items: [
                .init(value: Format.count(Int64(Double(summary.pack.files) / max(summary.seconds, 0.001))), label: "files a second"),
                .init(value: "\(Format.bytes(Int64(Double(summary.pack.tarBytes) / max(summary.seconds, 0.001))))/s", label: "end to end"),
                .init(value: Format.bytes(summary.sentBytes), label: "over the network"),
            ])
            NotesList(notes: summary.pack.rebuildable > 0
                      ? ["\(Format.count(summary.pack.rebuildable)) rebuildable folders (like node_modules) weren't sent."] : [],
                      problemCount: summary.pack.problemCount,
                      problemText: "\(Format.items(Int64(summary.pack.problemCount))) couldn't be read, so \(summary.pack.problemCount == 1 ? "it wasn't" : "they weren't") sent.")
            Spacer(minLength: 0)
            Button("Send Another") { model.done() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}
