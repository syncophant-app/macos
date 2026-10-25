import SwiftUI
import CoreKit

/// Settings › Privacy: a map of every host in the local contact ledger, then the optional connections.
struct PrivacySettings: View {
    @Environment(AppModel.self) private var app
    @State private var tokenSaved = false
    @State private var savedLog: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every place Syncophant talks to").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Counted on this Mac").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            NetworkMap(nodes: nodes)
            Text("No analytics, no crash reporting, no account. If a new destination ever appears here, it is a bug.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Text("Includes the Finder drive. Storage activity is counted at most once a minute per host. Never sent anywhere.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Clear History") { app.clearContactHistory() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(app.contacts.isEmpty)
            }
        }
        .contentCard(radius: 16, padding: 16)
        .task {
            // The Finder extension writes the same ledger, so re-read it while this tab is open.
            while !Task.isCancelled {
                app.reloadContacts()
                tokenSaved = app.hasHetznerToken
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }

        SettingsGroup {
            SettingsToggle(title: "Check GitHub for updates",
                           detail: "Once a day. Sends only the request itself. Off until you turn it on.",
                           isOn: Binding(get: { app.settings.updateChecks }, set: { app.setUpdateChecks($0) }))
                .disabled(app.isDemo)
            SettingsRow(title: "Hetzner API token",
                        detail: tokenSaved ? "In your Keychain. Used for snapshots, sharing and space used." : "None saved on this Mac.") {
                if tokenSaved {
                    Button("Forget Token") { app.forgetHetznerToken(); tokenSaved = app.hasHetznerToken }
                        .buttonStyle(.glass).controlSize(.small)
                        .foregroundStyle(Palette.failure)
                }
            }
            SettingsRow(title: "Diagnostics",
                        detail: "Saves a log with host and user names removed, for you to read or attach to a GitHub issue. Never sent.") {
                Button(savedLog == nil ? "Save Log…" : "Saved to Downloads") {
                    if let url = app.exportDiagnostics() {
                        savedLog = url
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.glass).controlSize(.small)
            }
        }
    }

    // MARK: Nodes from the real ledger

    private var feedHost: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap { URL(string: $0)?.host() } ?? "github.com"
    }

    private var nodes: [NetworkMap.Node] {
        let updatesOn = app.settings.updateChecks
        var list: [NetworkMap.Node] = app.contacts.map { contact in
            let storage = app.connections.first { $0.host == contact.host || $0.endpoint?.host() == contact.host }
            let isUpdate = contact.purpose.localizedCaseInsensitiveContains("update")
            let title = storage?.name
                ?? (contact.host == "api.hetzner.com" ? "Hetzner API"
                    : isUpdate ? (contact.purpose.localizedCaseInsensitiveContains("download") ? "Update downloads" : "Update checks")
                    : contact.purpose.components(separatedBy: " · ").first ?? contact.host)
            return .init(id: contact.host, title: title,
                         detail: "\(contact.host) · \(contact.count)× · last \(Format.ago(contact.lastContacted))",
                         tone: storage != nil ? .accent : contact.host == "api.hetzner.com" ? .purple : .neutral,
                         dimmed: isUpdate && !updatesOn,
                         live: Date().timeIntervalSince(contact.lastContacted) < 120 && !(isUpdate && !updatesOn))
        }
        if !list.contains(where: { $0.id == feedHost }) {
            list.append(.init(id: feedHost, title: "Update checks",
                              detail: updatesOn ? "\(feedHost) · once a day · not contacted yet" : "Off · never contacted",
                              tone: .neutral, dimmed: !updatesOn, live: false))
        }
        return list
    }
}

/// "This Mac" on the left, a curved line to each destination on the right. Lines whose host was used in the
/// last two minutes carry flowing dashes; the loop stops with Reduce Motion or when the tab is not on screen.
struct NetworkMap: View {
    struct Node: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let tone: Tone
        let dimmed: Bool
        let live: Bool
    }

    let nodes: [Node]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false
    private let nodeHeight: CGFloat = 40, gap: CGFloat = 12

    var body: some View {
        let height = max(120, CGFloat(nodes.count) * (nodeHeight + gap) - gap)
        let animate = onScreen && !reduceMotion && nodes.contains(where: \.live)
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 30, weight: .regular))
                    .frame(width: 90, height: 76)
                    .background(Fill.two, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("This Mac").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .offset(y: 10)
            .frame(height: height)

            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { context in
                let phase = animate ? -context.date.timeIntervalSinceReferenceDate * 8.3 : 0
                Canvas { g, size in
                    for (i, node) in nodes.enumerated() {
                        let y = CGFloat(i) * (nodeHeight + gap) + nodeHeight / 2
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addCurve(to: CGPoint(x: size.width, y: y),
                                      control1: CGPoint(x: size.width * 0.5, y: size.height / 2),
                                      control2: CGPoint(x: size.width * 0.5, y: y))
                        let color: Color = node.dimmed ? Fill.three : node.tone.color.opacity(node.live ? 1 : 0.5)
                        g.stroke(path, with: .color(color),
                                 style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [4, 6], dashPhase: node.live ? phase : 0))
                    }
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: gap) {
                ForEach(nodes) { node in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.title).font(.system(size: 12.5, weight: .semibold))
                        Text(node.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 230, height: nodeHeight, alignment: .leading)
                    .background(node.dimmed ? Fill.one : node.tone.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(node.dimmed ? 0.5 : 1)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(node.dimmed ? "Off" : node.live ? "In use now" : "")
                }
            }
        }
        .padding(.vertical, 6)
        .motion(Motion.smooth, value: nodes)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network map")
    }
}
