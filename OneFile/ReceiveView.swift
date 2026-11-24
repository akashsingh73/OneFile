import SwiftUI
import AppKit

/// Receive: this Mac, ready to be found, on the left; where folders go on the right.
struct ReceiveScreen: View {
    @ObservedObject var model: ReceiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                BeaconCard(model: model)
                FlowStream(mode: flowMode)
                ReceiveFolderCard(model: model)
            }
            .frame(height: 214)
            ReceivePanel(model: model)
                .id(model.stageKey)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .frame(minHeight: 330, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: model.stageKey)
        .sheet(isPresented: $model.showingProblems) {
            ProblemsSheet(title: "Not unpacked", problems: model.summary?.unpack.problems ?? [],
                          count: model.summary?.unpack.problemCount ?? 0) { model.showingProblems = false }
        }
    }

    private var flowMode: FlowStream.Mode {
        switch model.stage {
        case .receiving: .flowing(FlowStream.intensity(filesPerSecond: model.meter.filesPerSecond))
        case .offered: .flowing(0.05)
        case .finished: .done
        default: .ready
        }
    }
}

/// This Mac, as other Macs see it.
struct BeaconCard: View {
    @ObservedObject var model: ReceiveModel

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Radar(symbol: ThisMac.symbol(ThisMac.identity.kind), active: listening, size: 100)
            Text(ThisMac.identity.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            switch model.status {
            case .denied:
                Text("Other Macs can't find this one")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open Settings") { SendModel.shared.openLocalNetworkSettings() }
                    .controlSize(.small)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            default:
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let address = model.addressText {
                    Text("or by address: \(address)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    private var listening: Bool {
        if case .ready = model.status { return true }
        return false
    }

    private var statusLine: String {
        switch model.stage {
        case .offered(_, _, let peer, _): "“\(peer)” wants to send"
        case .receiving(_, let peer): "Receiving from “\(peer)”"
        default: model.statusText
        }
    }
}

/// Where received folders go.
struct ReceiveFolderCard: View {
    @ObservedObject var model: ReceiveModel

    var body: some View {
        let output = model.summary?.unpack.output
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: (output ?? model.destination).path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 50, height: 50)
                if output != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .green)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(1))
                        .offset(x: 6, y: 4)
                }
            }
            Text(output?.lastPathComponent ?? model.offer.map { ThisMac.safeName($0.name) } ?? model.destination.lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("in " + Format.path(output?.deletingLastPathComponent() ?? (model.offer != nil ? model.destination : model.destination.deletingLastPathComponent())))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let unpack = model.summary?.unpack {
                Text("\(Format.count(unpack.files)) files · \(Format.bytes(unpack.bytes))")
                    .font(.callout)
                    .monospacedDigit()
            } else {
                Text(model.offer == nil ? "Folders from other Macs go here" : "A new folder: nothing is replaced")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let room = model.room, let free = room.free {
                Text("\(Format.bytes(free)) free on “\(room.volume)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button("Change…") { model.chooseDestination() }
                .controlSize(.small)
                .disabled(model.isBusy)
        }
        .cardStyle()
    }
}

struct ReceivePanel: View {
    @ObservedObject var model: ReceiveModel

    var body: some View {
        switch model.stage {
        case .off, .waiting:
            VStack(alignment: .leading, spacing: 0) {
                if let notice = model.notice {
                    InfoLine(symbol: "info.circle.fill", text: notice, tint: .orange)
                        .padding(.bottom, 12)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("How it works")
                        .font(.callout.weight(.semibold))
                    Step(number: 1, title: "On the other Mac, open OneFile and click Send",
                         detail: "Choose the folder, then pick “\(ThisMac.identity.name)” from the Macs nearby.")
                    Step(number: 2, title: "Compare the codes",
                         detail: "Both Macs show the same 6-digit code. Confirm on both only if they match: then it's going to the right Mac, and no one else can listen in.")
                    Step(number: 3, title: "It unpacks here as it arrives",
                         detail: "Packed there and unpacked here at the same time, end-to-end encrypted, with no file in between.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
                Spacer(minLength: 14)
                InfoLine(symbol: "eye.slash.fill", text: "This Mac can be found only while this screen is open, and nothing arrives unless you accept it.")
            }
        case .offered(let offer, let code, let peer, let kind):
            OfferPanel(model: model, offer: offer, code: code, peer: peer, kind: kind)
        case .receiving(_, let peer):
            WorkPanel(
                percent: model.percentText,
                chip: ("From “\(peer)” · encrypted", "lock.fill"),
                eta: model.etaText,
                bars: [.init(label: nil, fraction: model.fraction)],
                tiles: [
                    .init(label: "Files", value: Format.count(model.progress.files),
                          detail: model.offer.map { $0.counted ? "of \(Format.count($0.files))" : "" } ?? ""),
                    .init(label: "Data", value: Format.bytes(model.progress.bytes),
                          detail: model.offer.map { $0.counted ? "of \(Format.bytes($0.bytes))" : "" } ?? ""),
                    .init(label: "Speed", value: model.meter.speedText, detail: model.meter.filesText),
                    .init(label: "Time", value: model.timeValue, detail: "elapsed"),
                ],
                history: model.meter.history,
                lineSymbol: "folder.fill",
                line: "Into \(Format.path(model.destination)) · \(Format.count(model.progress.folders)) folders made",
                current: model.progress.current,
                warning: model.progress.problemCount > 0
                    ? "\(Format.items(Int64(model.progress.problemCount))) couldn't be unpacked" : nil,
                stop: model.stop)
        case .finished(let summary):
            ReceiveFinished(model: model, summary: summary)
        case .failed(let message):
            MessagePanel(symbol: "xmark.octagon.fill", tint: .red, title: "Couldn't receive it", message: message,
                         done: model.done)
        case .stopped:
            MessagePanel(symbol: "stop.circle.fill", tint: .gray, title: "Stopped",
                         message: "What had arrived has been deleted.", done: model.done)
        }
    }
}

/// Someone wants to send: what, from whom, the code, and Accept or Decline.
struct OfferPanel: View {
    @ObservedObject var model: ReceiveModel
    let offer: Wire.Offer
    let code: String
    let peer: String
    let kind: String

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: ThisMac.symbol(kind))
                    .font(.system(size: 26))
                    .foregroundStyle(Brand.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(peer)” wants to send you “\(ThisMac.safeName(offer.name))”")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                    Text(sizeLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                CodeView(code: code, digitSize: 34)
                Text("Accept only if “\(peer)” shows this same code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("End-to-end encrypted (X25519 and AES-GCM)", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
            Text("It goes into \(Format.path(model.destination)), in a new folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Decline") { model.decline() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { model.accept() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var sizeLine: String {
        let method = PackMethod(rawValue: offer.method) ?? .plain
        let how = method == .plain ? "uncompressed" : "compressed with \(method.format) on the way"
        if offer.counted {
            return "\(Format.count(offer.files)) files and \(Format.count(offer.folders)) folders · \(Format.bytes(offer.bytes)) · \(how)"
        }
        return "Still counting what's in it · \(how)"
    }
}

/// A numbered step.
struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Brand.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ReceiveFinished: View {
    @ObservedObject var model: ReceiveModel
    let summary: ReceiveSession.Summary

    var body: some View {
        let unpack = summary.unpack
        VStack(alignment: .leading, spacing: 14) {
            DoneHeader(title: "Received from “\(summary.peer)” in \(Format.duration(summary.seconds))",
                       detail: "\(Format.count(unpack.files)) files and \(Format.count(unpack.folders)) folders · \(Format.bytes(unpack.bytes)), as “\(unpack.output?.lastPathComponent ?? "")”")
            HighlightRow(items: [
                .init(value: Format.count(Int64(Double(unpack.files) / max(summary.seconds, 0.001))), label: "files a second"),
                .init(value: "\(Format.bytes(Int64(Double(unpack.bytes) / max(summary.seconds, 0.001))))/s", label: "end to end"),
                .init(value: "AES-GCM", label: "every block checked"),
            ])
            NotesList(notes: unpack.links > 0 ? ["\(Format.count(unpack.links)) links made, all inside the folder."] : [],
                      problemCount: unpack.problemCount,
                      problemText: "\(Format.items(Int64(unpack.problemCount))) couldn't be unpacked.") {
                model.showingProblems = true
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Show in Finder") { model.showInFinder() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Receive Another") { model.done() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
