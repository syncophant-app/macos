import SwiftUI
import AppKit
import CoreKit

/// Share window state (access, expiry, protocols, creating). Owned by the Share screen.
///
/// A Hetzner folder becomes its own sub-account with the chosen access and protocols; an S3 file becomes an
/// expiring presigned link. Nothing is created until the person presses Create.
@MainActor @Observable
final class ShareFlowState {
    enum Access: Equatable { case view, edit }
    enum Expiry: Int, CaseIterable, Identifiable {
        case day = 1, week = 7, month = 30, never = 0
        var id: Int { rawValue }
        var label: String { switch self { case .day: "1 day"; case .week: "7 days"; case .month: "30 days"; case .never: "No end" } }
        var end: Date? { self == .never ? nil : Date().addingTimeInterval(Double(rawValue) * 86_400) }
    }
    enum Phase: Equatable { case form, working(step: Int), done }
    enum Result {
        case account(StorageShare, password: String)
        case link(URL, expires: Date)
    }

    var access = Access.view
    var expiry = Expiry.week
    var protocols: Set<ShareProtocol> = [.webdav]
    var phase = Phase.form
    var token = ""
    var result: Result?
    var showPassword = false
    var error: String?
    var toast: String?
    var stopping: StorageShare?
    var stoppingIDs: Set<UUID> = []
    @ObservationIgnored var expiryTask: Task<Void, Never>?

    /// Back to the defaults (view only, 7 days, WebDAV) and forget anything secret.
    func reset() {
        access = .view; expiry = .week; protocols = [.webdav]; phase = .form; token = ""
        result = nil; showPassword = false; error = nil; toast = nil; stopping = nil
    }
}

/// Share a folder window: who can do what, for how long, over which protocols; then a ready-to-send invitation.
struct ShareFolderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var flow: ShareFlowState { app.shareUI }
    private var connection: StorageConnection? { app.active }
    private var isS3: Bool { connection?.provider == .s3 }
    private var canCreate: Bool {
        guard let c = connection, c.encryptionEnabled != true, let item = app.sharingItem, !app.isDemo else { return false }
        return (c.provider == .s3 && !item.isDirectory) || (c.provider == .hetzner && item.isDirectory)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    if let item = app.sharingItem {
                        header(item)
                        if canCreate { main(item) } else { unavailable }
                    } else {
                        ContentUnavailableView("Nothing selected", systemImage: "square.and.arrow.up",
                                               description: Text("Select a folder in Files, then choose Share."))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                ShareSideColumn(isS3: isS3)
                    .frame(width: 280)
            }
            .padding(.horizontal, 44)
            .padding(.top, 8)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 820, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onExitCommand { dismiss() }
        .onAppear {
            if isS3, flow.expiry.rawValue == 0 || flow.expiry.rawValue > 7 { flow.expiry = .week }
            app.startShareExpiryMonitor()
        }
        .onDisappear { flow.reset(); app.sharingItem = nil }
    }

    // MARK: Header

    private func header(_ item: FileNode) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 40))
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 52, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Share “\(item.displayName)”").font(.system(size: 22, weight: .bold)).tracking(-0.4).lineLimit(1)
                Text(meta(item)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Only what is known: the item count of a listed folder, a file's size, and where it lives.
    private func meta(_ item: FileNode) -> String {
        var parts: [String] = []
        if item.isDirectory, let children = item.children { parts.append(children.count == 1 ? "1 item" : "\(children.count) items") }
        if !item.isDirectory { parts.append(Format.bytes(item.item.entry.size)) }
        let parents = item.path.split(separator: "/").dropLast().map(String.init)
        parts.append(([connection?.name ?? "Storage"] + parents).joined(separator: " › "))
        return parts.joined(separator: " · ")
    }

    // MARK: Phases

    @ViewBuilder private func main(_ item: FileNode) -> some View {
        Group {
            switch flow.phase {
            case .form: form
            case .working(let step):
                if isS3 { ProgressView("Creating link…").controlSize(.small).padding(.vertical, 8) } else { checklist(item, step: step) }
            case .done: ready(item)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        if let error = flow.error {
            Label { Text(error).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tone.red.text)
            }
            .font(.system(size: 12.5))
            .statusCard(.red, radius: 14, padding: 12)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("They can")
                if isS3 {
                    Label("View and download. Anyone with the link can download this file; no login needed.", systemImage: "eye")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        accessCard(.view, symbol: "eye", tone: .accent, title: "View and download",
                                   detail: "Read-only. They can’t change or delete anything.")
                        accessCard(.edit, symbol: "pencil", tone: .orange, title: "Add and edit",
                                   detail: "They can upload and change files. Deletions land in Time Travel.")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Access")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("For")
                Picker("For", selection: Bindable(flow).expiry) {
                    ForEach(isS3 ? [.day, .week] : ShareFlowState.Expiry.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(expiryNote).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !isS3 {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("They open it with")
                    HStack(spacing: 8) { chip(.webdav) }
                    HStack(spacing: 8) { chip(.sftp); chip(.smb) }
                }
                if !app.hasHetznerToken {
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("Hetzner API token", text: Bindable(flow).token)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 11).frame(height: 34)
                            .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("Needed once to create the account. It goes only to api.hetzner.com and stays in your Keychain.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var expiryNote: String {
        if isS3 { return "Stops working on \(endText(flow.expiry.end ?? .now)). S3 links last at most 7 days and can’t be stopped early." }
        guard let end = flow.expiry.end else { return "Stays until you stop it here or in Hetzner Console." }
        return "Stops on \(endText(end)).\(flow.expiry == .day ? "" : " You get a notification the day before.")"
    }

    private func endText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
    }

    private func accessCard(_ access: ShareFlowState.Access, symbol: String, tone: Tone, title: String, detail: String) -> some View {
        let selected = flow.access == access
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { withAnimation(Motion.resolve(Motion.snappy)) { flow.access = access } } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tone.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(shape)
            .background(selected ? Color.accentColor.opacity(0.16) : Fill.one, in: shape)
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func chip(_ p: ShareProtocol) -> some View {
        let on = flow.protocols.contains(p)
        return Button {
            withAnimation(Motion.resolve(Motion.snappy)) {
                if on { if flow.protocols.count > 1 { flow.protocols.remove(p) } } else { flow.protocols.insert(p) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white).opacity(on ? 1 : 0)
                    .frame(width: 20, height: 20)
                    .background(on ? Color.green : Fill.three, in: Circle())
                Text(p.label).font(.system(size: 12.5, weight: .semibold))
                Text(p.hint).font(.system(size: 12.5)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 8).padding(.trailing, 12).frame(height: 34)
            .background(on ? Fill.two : Fill.one, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.label), \(p.hint)")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint(on && flow.protocols.count == 1 ? "At least one must stay on" : "")
    }

    private func checklist(_ item: FileNode, step: Int) -> some View {
        let names = ShareProtocol.allCases.filter(flow.protocols.contains).map(\.label)
        let protocolText = ListFormatter.localizedString(byJoining: names)
        let labels = ["Generating a strong password",
                      "Creating an account limited to “\(item.displayName)”",
                      "Checking \(protocolText) is on, \(flow.access == .view ? "read-only" : "read and write")"]
        return VStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    Group {
                        if i < step {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Color.green)
                                .transition(.scale.combined(with: .opacity))
                        } else if i == step {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 10, height: 10)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(labels[i]).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                .opacity(i <= step ? 1 : 0.5)
                .accessibilityElement(children: .combine)
                .accessibilityValue(i < step ? "Done" : i == step ? "Working" : "Waiting")
            }
        }
        .motion(Motion.bouncy, value: step)
        .contentCard(radius: 16, padding: 8)
        .accessibilityLabel("Creating share")
    }

    @ViewBuilder private func ready(_ item: FileNode) -> some View {
        if let result = flow.result {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Color.green, in: Circle())
                        .symbolEffect(.bounce, value: flow.phase)
                    Text("Ready to send").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(summary(result)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    switch result {
                    case .account(let share, let password):
                        let primary = share.openWith.first ?? .sftp
                        valueRow("Address", share.address(primary)) { copyPlain(share.address(primary), "Address copied") }
                        valueRow("User", share.username) { copyPlain(share.username, "User copied") }
                        valueRow("Password", flow.showPassword ? password : String(repeating: "•", count: 16), secret: true) {
                            SecretClipboard.copy(password); say("Password copied. Clears in 60 s.")
                        }
                    case .link(let url, _):
                        valueRow("Link", url.absoluteString) { copyPlain(url.absoluteString, "Link copied") }
                    }
                }
                HStack(spacing: 8) {
                    Button { copyInvitation(item, result) } label: { Text("Copy Invitation").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    Button { mail(item, result) } label: { Text("Mail…").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass)
                    Button("Share Again") { flow.result = nil; flow.showPassword = false; withAnimation(Motion.resolve(Motion.smooth)) { flow.phase = .form } }
                        .buttonStyle(.glass)
                }
                if let toast = flow.toast {
                    Text(toast).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tone.green.text)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(16)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .motion(Motion.smooth, value: flow.toast)
        }
    }

    private func valueRow(_ label: String, _ value: String, secret: Bool = false, copy: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
                .accessibilityValue(secret && !flow.showPassword ? "Hidden" : value)
            if secret {
                Button(flow.showPassword ? "Hide" : "Show") { flow.showPassword.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            Button("Copy", action: copy)
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Copy \(label.lowercased())")
        }
        .padding(.horizontal, 11).frame(height: 38)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var unavailable: some View {
        ContentUnavailableView("Can’t share this item", systemImage: "square.and.arrow.up.trianglebadge.exclamationmark",
                               description: Text(connection?.encryptionEnabled == true
                                                 ? "This storage is encrypted on this Mac. A share would hand out unreadable files, so sharing is off."
                                                 : "Sharing works for a folder on a Hetzner Storage Box, or for one file on S3-compatible storage."))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Close") { dismiss() }.buttonStyle(.glass)
            Spacer()
            if flow.phase == .form, canCreate {
                Button(isS3 ? "Create Link" : "Create Share") { create() }
                    .buttonStyle(.glassProminent)
                    .frame(minWidth: 140)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isS3 && !app.hasHetznerToken && flow.token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
    }

    // MARK: Actions

    private func create() {
        guard let item = app.sharingItem else { return }
        flow.error = nil
        let path = item.path, expiry = flow.expiry
        if isS3 {
            withAnimation(Motion.resolve(Motion.smooth)) { flow.phase = .working(step: 0) }
            Task {
                do {
                    let seconds = expiry.rawValue * 86_400
                    let url = try await app.createPresignedURL(path: path, expires: seconds)
                    flow.result = .link(url, expires: Date().addingTimeInterval(Double(seconds)))
                    withAnimation(Motion.resolve(Motion.bouncy)) { flow.phase = .done }
                } catch { fail(error) }
            }
            return
        }
        let token = flow.token, readOnly = flow.access == .view, protocols = flow.protocols
        withAnimation(Motion.resolve(Motion.smooth)) { flow.phase = .working(step: 0) }
        Task {
            do {
                let (share, password) = try await app.createShare(path: path, token: token, readOnly: readOnly, protocols: protocols,
                                                                  expiresAt: expiry.end) { step in
                    withAnimation(Motion.resolve(Motion.smooth)) { flow.phase = .working(step: step) }
                }
                withAnimation(Motion.resolve(Motion.smooth)) { flow.phase = .working(step: 3) }
                try? await Task.sleep(for: .milliseconds(450))
                flow.token = ""
                flow.result = .account(share, password: password)
                withAnimation(Motion.resolve(Motion.bouncy)) { flow.phase = .done }
            } catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        flow.error = message(for: error)
        withAnimation(Motion.resolve(Motion.smooth)) { flow.phase = .form }
    }

    private func summary(_ result: ShareFlowState.Result) -> String {
        switch result {
        case .account(let share, _):
            let end = share.expiresAt.map { "ends in \(ShareTime.left(until: $0, from: share.createdAt))" } ?? "no end"
            return "\(share.isReadOnly ? "View only" : "Can edit") · \(end)"
        case .link(_, let expires): return "View only · ends in \(ShareTime.left(until: expires, from: .now))"
        }
    }

    private func invitation(_ item: FileNode, _ result: ShareFlowState.Result) -> String {
        switch result {
        case .account(let share, let password):
            let access = share.isReadOnly ? "view and download" : "add and edit"
            let until = share.expiresAt.map { " until \(endText($0))" } ?? ""
            var lines = ["I’ve shared the folder “\(item.displayName)” with you. You can \(access)\(until).", ""]
            lines += share.openWith.map { "\($0.label): \(share.address($0))" }
            lines += ["User: \(share.username)", "Password: \(password)"]
            if share.openWith.contains(.webdav) { lines += ["", "On a Mac, choose Go › Connect to Server in Finder and enter the WebDAV address."] }
            return lines.joined(separator: "\n")
        case .link(let url, let expires):
            return "Here’s “\(item.displayName)”. The link works until \(endText(expires)):\n\n\(url.absoluteString)"
        }
    }

    private func copyInvitation(_ item: FileNode, _ result: ShareFlowState.Result) {
        SecretClipboard.copy(invitation(item, result))
        say("Invitation copied with the address, user, password and end date. Clears in 60 s.")
    }

    private func mail(_ item: FileNode, _ result: ShareFlowState.Result) {
        guard let service = NSSharingService(named: .composeEmail) else { say("Mail isn’t available on this Mac."); return }
        service.subject = item.isDirectory ? "Shared folder “\(item.displayName)”" : "Shared file “\(item.displayName)”"
        service.perform(withItems: [invitation(item, result)])
    }

    private func copyPlain(_ text: String, _ toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        say(toast)
    }

    private func say(_ text: String) {
        flow.toast = text
        Task { try? await Task.sleep(for: .seconds(2.6)); if flow.toast == text { flow.toast = nil } }
    }
}

/// "3 days left", "5 hours left": rounded so a fresh 7-day share reads 7 days.
enum ShareTime {
    static func left(until end: Date, from now: Date) -> String {
        let seconds = end.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 86_400 { let h = max(1, Int((seconds / 3600).rounded())); return h == 1 ? "1 hour" : "\(h) hours" }
        let d = Int((seconds / 86_400).rounded())
        return d == 1 ? "1 day" : "\(d) days"
    }
}

// MARK: - Active shares

/// "Shared from <storage>": every active share with its time left and a Stop button, plus the expiry rule.
private struct ShareSideColumn: View {
    @Environment(AppModel.self) private var app
    let isS3: Bool

    private var flow: ShareFlowState { app.shareUI }
    private var shares: [StorageShare] { app.storageShares.filter { $0.connectionID == app.active?.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isS3 ? "Links from \(app.active?.name ?? "this storage")" : "Shared from \(app.active?.name ?? "this storage")")
                    .font(.system(size: 13, weight: .semibold))
                if isS3 {
                    Text("Links aren’t kept, so they can’t be listed or stopped early. Each one stops working at its end date.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if shares.isEmpty {
                    Text("Nothing shared yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(spacing: 8) {
                            ForEach(shares) { row($0, now: context.date) }
                        }
                    }
                }
            }
            .contentCard(radius: 16, padding: 14)
            if !isS3 {
                Label {
                    Text("Each share is its own Hetzner sub-account locked to one folder. Stopping a share deletes it on the spot. Expiry is enforced by this Mac, so it happens the next time Syncophant runs after the end date.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "info.circle").foregroundStyle(.tertiary) }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(12)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .motion(Motion.smooth, value: shares.map(\.id))
        .confirmationDialog("Stop sharing “\(flow.stopping?.name ?? "")”?",
                            isPresented: Binding(get: { flow.stopping != nil }, set: { if !$0 { flow.stopping = nil } }),
                            titleVisibility: .visible) {
            Button("Stop Sharing", role: .destructive) { if let s = flow.stopping { stop(s) } }
        } message: {
            Text("This deletes its account on your Storage Box now. Whoever has the password loses access at once. Your files are not touched.")
        }
    }

    private func row(_ share: StorageShare, now: Date) -> some View {
        let (progress, tint, left) = ring(share, now: now)
        let access = share.isReadOnly ? "View" : "Edit"
        let protocols = share.openWith.map(\.label).joined(separator: ", ")
        let busy = flow.stoppingIDs.contains(share.id)
        return HStack(spacing: 10) {
            ProgressRing(progress: progress, size: 30, lineWidth: 3.5, tint: tint)
                .accessibilityLabel("Time left")
                .accessibilityValue(share.expiresAt == nil ? "Does not expire" : left)
            VStack(alignment: .leading, spacing: 1) {
                Text(share.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(access) · \(left) · \(protocols)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
            } else {
                Button { flow.stopping = share } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Tone.red.text)
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop sharing")
                .accessibilityLabel("Stop sharing \(share.name)")
            }
        }
        .padding(8)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(x: 30)).combined(with: .scale(scale: 0.96))))
        .accessibilityElement(children: .contain)
    }

    /// Full green ring with no end; otherwise the share of its lifetime left, orange in the last three days.
    private func ring(_ share: StorageShare, now: Date) -> (Double, Color, String) {
        guard let end = share.expiresAt else { return (1, .green, "no end") }
        let total = max(1, end.timeIntervalSince(share.createdAt)), remaining = end.timeIntervalSince(now)
        let left = remaining <= 0 ? "ending now" : "\(ShareTime.left(until: end, from: now)) left"
        return (max(0, remaining / total), remaining <= 3 * 86_400 ? .orange : .accentColor, left)
    }

    private func stop(_ share: StorageShare) {
        flow.stoppingIDs.insert(share.id)
        Task {
            defer { flow.stoppingIDs.remove(share.id) }
            do {
                try await app.revokeShare(share)
                app.say("“\(share.name)” is no longer shared.")
            } catch { flow.error = "Still shared: \(message(for: error))" }
        }
    }
}
