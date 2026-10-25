import SwiftUI
import CoreKit
import HetznerKit

/// Connect Hetzner Storage Box: token → choose box → plan → setting up → done. With one API token Syncophant
/// creates a sub-account, turns on SSH and snapshots, installs a key for this Mac, tests a folder and adds it to Finder.
struct ConnectHetznerView: View {
    enum Stage: Int { case token, pick, plan, run, done }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow = ConnectModel()
    @State private var stage: Stage = .token
    @State private var jumpWhenValid = false

    var body: some View {
        VStack(spacing: 0) {
            StepDots(count: 3, current: min(stage.rawValue, 2)).padding(.top, 2).padding(.bottom, 4)
            Group {
                switch stage {
                case .token: HetznerTokenStep(flow: flow)
                case .pick: HetznerPickStep(flow: flow)
                case .plan: HetznerPlanStep(flow: flow)
                case .run: HetznerRunStep(flow: flow)
                case .done: HetznerDoneStep(flow: flow, close: { dismiss() })
                }
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(stage)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .opacity))
            footer
        }
        .animation(Motion.resolve(Motion.smooth, reduceMotion: reduceMotion), value: stage)
        .setupWindow()
        .task(id: app.connectUI.handoffID) { take() }
        .task(id: flow.token) {
            flow.tokenState = .idle
            guard ConnectModel.looksLikeToken(flow.token.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await flow.validateToken(model: app)
            if jumpWhenValid, case .valid = flow.tokenState, stage == .token { jumpWhenValid = false; stage = .pick }
        }
        .onChange(of: flow.allDone) { _, done in
            guard done else { return }
            Task { try? await Task.sleep(for: .milliseconds(500)); stage = .done }
        }
    }

    private func take() {
        flow.choice = .hetzner
        if flow.steps.isEmpty { flow.color = AvatarColor.allCases[app.connections.count % AvatarColor.allCases.count] }
        if let h = app.connectUI.take(), h.kind == .hetzner, h.isToken, !h.text.isEmpty {
            guard stage == .token else { return }
            jumpWhenValid = true
            flow.token = h.text
        } else if flow.token.isEmpty, !app.isDemo {
            flow.token = HetznerToken.load() ?? ""
        }
    }

    // MARK: Footer

    private var footer: some View {
        SetupFooter {
            KeychainNote(text: note)
            Spacer()
            switch stage {
            case .token:
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Continue") { stage = .pick }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .frame(minWidth: 120).disabled(!tokenValid)
            case .pick:
                Button("Back") { stage = .token }.buttonStyle(.glass)
                Button("Continue") { stage = .plan }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .frame(minWidth: 120)
                    .disabled(flow.selectedBoxValue?.isReady != true || flow.friendlyName.trimmingCharacters(in: .whitespaces).isEmpty)
            case .plan:
                Button("Back") { stage = .pick }.buttonStyle(.glass)
                Button("Set Up This Mac") { flow.begin(model: app); stage = .run }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .frame(minWidth: 120).disabled(!flow.planValid || app.isDemo)
            case .run:
                if flow.failed, !flow.running, !flow.steps.contains(where: { $0.state == .done }) {
                    Button("Back") { flow.reset(); stage = .plan }.buttonStyle(.glass)
                }
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            case .done:
                Button("Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
            }
        }
    }

    private var tokenValid: Bool { if case .valid = flow.tokenState { true } else { false } }

    private var note: String {
        switch stage {
        case .token: "The token is saved in your Keychain, never in a file"
        case .plan: "You can undo all of this from Settings › Storage"
        default: "Nothing leaves this Mac except calls to Hetzner and your box"
        }
    }
}

// MARK: - Token

private struct HetznerTokenStep: View {
    @Bindable var flow: ConnectModel
    @State private var reveal = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                HeroIcon(symbol: "key.fill", color: .red)
                Text("Let Syncophant set up your Storage Box").font(.system(size: 24, weight: .bold)).tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                Text("With a Hetzner API token it can create a private sub-account, switch on SSH and snapshots, and add a key for this Mac. You will not need a password.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).lineSpacing(2)
                    .frame(maxWidth: 520)
            }
            .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                FieldBox(height: 54, focused: focused, tint: valid ? .green : nil) {
                    Image(systemName: "lock").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Group {
                        if reveal { TextField("Hetzner API token", text: $flow.token, prompt: Text("Paste a Read and Write token")) }
                        else { SecureField("Hetzner API token", text: $flow.token, prompt: Text("Paste a Read and Write token")) }
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .focused($focused)
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(reveal ? "Hide token" : "Show token")
                    switch flow.tokenState {
                    case .checking: ProgressView().controlSize(.small).accessibilityLabel("Checking with Hetzner")
                    case .valid: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity)).accessibilityLabel("Token works")
                    case .invalid: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(.red).accessibilityHidden(true)
                    case .idle: EmptyView()
                    }
                }
                .motion(Motion.bouncy, value: valid)
                Text(message).font(.system(size: 12)).foregroundStyle(messageColor).padding(.leading, 4)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Where to get a token").font(.system(size: 12.5, weight: .semibold))
                HStack(alignment: .top, spacing: 10) {
                    howTo(1, "Open Hetzner Console and pick the project with your Storage Box.")
                    howTo(2, "Go to Security, then API tokens, and choose Generate API token.")
                    howTo(3, "Choose Read and Write, copy the token and paste it here.")
                }
            }
            .contentCard(radius: 16, padding: 14)
        }
        .onAppear { focused = flow.token.isEmpty }
    }

    private var valid: Bool { if case .valid = flow.tokenState { true } else { false } }

    private var message: String {
        switch flow.tokenState {
        case .idle: "Needs Read and Write permission. Syncophant sends it only to api.hetzner.com."
        case .checking: "Checking with Hetzner…"
        case .valid(let n): n == 1 ? "Works. Found 1 Storage Box." : "Works. Found \(n) Storage Boxes."
        case .invalid(let reason): reason
        }
    }
    private var messageColor: Color {
        switch flow.tokenState { case .valid: Palette.verified; case .invalid: Palette.failure; default: .secondary }
    }

    private func howTo(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11.5, weight: .bold)).frame(width: 22, height: 22).background(Fill.two, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Choose box

private struct HetznerPickStep: View {
    @Bindable var flow: ConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Which Storage Box?").font(.system(size: 22, weight: .bold)).tracking(-0.4).accessibilityAddTraits(.isHeader)
                Text(flow.boxes.count == 1 ? "One box on this Hetzner account. Check it is the one this Mac should use."
                     : "\(flow.boxes.count) boxes on this Hetzner account. Pick the one this Mac should use.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(flow.boxes) { card($0) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 330)
            .accessibilityLabel("Storage Boxes")
            nameRow
        }
    }

    private func card(_ box: StorageBox) -> some View {
        let on = flow.selectedBox == box.id
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { flow.pick(box) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let used = box.diskUsage, let quota = box.diskQuota, quota > 0 {
                        let fraction = min(1, Double(used) / Double(quota))
                        ProgressRing(progress: fraction, size: 52, lineWidth: 5, showsLabel: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Space used")
                            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(box.name).font(.system(size: 15, weight: .semibold))
                        Text(box.server.isEmpty ? "Hetzner is still preparing this box" : box.server)
                            .font(.system(size: 11.5, design: box.server.isEmpty ? .default : .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Circle().strokeBorder(on ? Color.accentColor : Color.secondary, lineWidth: 1.5)
                        .background(Circle().fill(on ? Color.accentColor : .clear))
                        .overlay(Circle().fill(.white).frame(width: 8, height: 8).opacity(on ? 1 : 0))
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) { ForEach(chips(box), id: \.self) { chip($0) } }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.16) : Fill.one, in: shape)
            .overlay(shape.strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!box.isReady)
        .opacity(box.isReady ? 1 : 0.55)
        .motion(Motion.snappy, value: on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func chips(_ box: StorageBox) -> [String] {
        var list: [String] = []
        if let t = box.typeName { list.append(t.uppercased()) }
        if let l = box.locationName { list.append(l) }
        if let n = flow.snapshotCounts[box.id] { list.append(n == 1 ? "1 snapshot" : "\(n) snapshots") }
        if let used = box.diskUsage, let quota = box.diskQuota, quota > 0 { list.append("\(Format.bytes(used)) of \(Format.bytes(quota))") }
        if !box.isReady { list.append("Not ready yet") }
        return list
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Fill.two, in: Capsule())
            .lineLimit(1)
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldBox(height: 40) {
                FieldLabel("Call it").fixedSize()
                TextField("Name on this Mac", text: $flow.friendlyName, prompt: Text("Studio Box"))
                Text("Shown in Finder and the menu bar").font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize()
            }
            HStack(spacing: 10) {
                FieldLabel("Color")
                ForEach(AvatarColor.allCases) { c in
                    Button { flow.color = c } label: {
                        Circle().fill(c.color.gradient).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary.opacity(flow.color == c ? 0.9 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.name)
                    .accessibilityAddTraits(flow.color == c ? [.isSelected] : [])
                }
                Spacer()
                StorageAvatar(name: flow.friendlyName, color: flow.color, size: 26)
            }
            .motion(Motion.snappy, value: flow.color)
        }
    }
}

// MARK: - Plan

private struct HetznerPlanStep: View {
    @Bindable var flow: ConnectModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Here is the plan").font(.system(size: 22, weight: .bold)).tracking(-0.4).accessibilityAddTraits(.isHeader)
                    Text("Change anything you like. Nothing happens until you press Set Up This Mac.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    row("checkmark.shield.fill", .green, "Give this Mac its own sub-account",
                        "It can only see one folder. Revoke it from Hetzner any time without touching the rest.", $flow.plan.subaccount)
                    row("key.fill", .accentColor, "Sign in with a key made for this Mac",
                        "Turns on SSH and stores the private key in your Keychain. No password to type.", $flow.plan.key)
                    row("clock.arrow.circlepath", .purple, "Show snapshots in Time Travel",
                        "Makes the snapshot folder visible so you can browse old versions.", $flow.plan.snapshots)
                    row("checkmark", .teal, "Prove it works with a 1 MB test",
                        "Uploads, reads back and compares a small file, then deletes it.", $flow.plan.test)
                    folderRow
                    if !flow.plan.subaccount { passwordRow.transition(.opacity) }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            }
            ReachDiagram(flow: flow).frame(width: 250)
        }
        .motion(Motion.smooth, value: flow.plan)
    }

    private func row(_ symbol: String, _ color: Color, _ title: String, _ detail: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            KindIcon(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: on).toggleStyle(.switch).labelsHidden().tint(.green)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var folderRow: some View {
        HStack(spacing: 12) {
            KindIcon(symbol: "folder.fill", color: .accentColor, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder on the box").font(.system(size: 13, weight: .medium))
                Text(flow.folderValid ? "\(StorageBoxPath.sftpRoot)/\(flow.folder)" : "Letters, numbers, dots, dashes and / only")
                    .font(.system(size: 11.5, design: flow.folderValid ? .monospaced : .default))
                    .foregroundStyle(flow.folderValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.failure))
            }
            Spacer(minLength: 8)
            FieldBox(height: 30) { TextField("Folder name", text: $flow.folder).font(.system(size: 12.5, design: .monospaced)) }
                .frame(width: 170)
        }
        .padding(.vertical, 10)
    }

    private var passwordRow: some View {
        HStack(spacing: 12) {
            KindIcon(symbol: "lock.fill", color: .orange, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Main account password").font(.system(size: 13, weight: .medium))
                Text(flow.plan.key ? "Used once to add this Mac’s key." : "Saved in your Keychain.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            FieldBox(height: 30) { SecureField("Main account password", text: $flow.mainPassword) }.frame(width: 170)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

/// This Mac → sub-account (or main account) → the one reachable folder; the rest of the box striped out of reach.
private struct ReachDiagram: View {
    var flow: ConnectModel

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel("This Mac can reach").padding(.bottom, 12)
            Image(systemName: "laptopcomputer").font(.system(size: 20)).frame(width: 44, height: 44)
                .background(Fill.two, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text("This Mac").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 4)
            connector
            Label(flow.plan.subaccount ? (flow.plan.key ? "Sub-account, its own key" : "Sub-account") : "Main account",
                  systemImage: flow.plan.subaccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
            connector
            VStack(spacing: 6) {
                Text(flow.friendlyName.isEmpty ? "Storage Box" : flow.friendlyName).font(.system(size: 12.5, weight: .semibold))
                VStack(spacing: 4) {
                    Text("Everything else on the box").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(6)
                        .background {
                            if flow.plan.subaccount { Stripes().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
                            else { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.16)) }
                        }
                    Text("/" + flow.folder).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(6)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(12)
            .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(flow.plan.subaccount ? "Striped areas stay out of reach. If this Mac is lost, revoke one sub-account."
                 : "This Mac could see the whole box. A sub-account is safer.")
                .font(.system(size: 11)).foregroundStyle(flow.plan.subaccount ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.caution))
                .multilineTextAlignment(.center).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("What this Mac will reach")
        .accessibilityValue(flow.plan.subaccount ? "Only the folder \(flow.folder), through its own sub-account" : "The whole box, through the main account")
    }

    private var connector: some View {
        Rectangle().fill(Fill.three).frame(width: 1.5, height: 18).padding(.vertical, 4)
    }
}

/// Diagonal hatching for "out of reach".
private struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 12
            }
            context.stroke(path, with: .color(.primary.opacity(0.08)), lineWidth: 6)
        }
    }
}

// MARK: - Setting up

private struct HetznerRunStep: View {
    @Environment(AppModel.self) private var app
    var flow: ConnectModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressRing(progress: flow.progress, state: flow.allDone ? .done : (flow.failed ? .paused : .running), size: 120, showsLabel: true)
            Text("Setting up \(flow.displayName)").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) { ForEach(flow.steps) { CheckRow(step: $0, height: 40) } }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if flow.steps.contains(where: { $0.kind == .hostKey && $0.state == .awaitingApproval }) { HostKeyCard(flow: flow) }
                    if flow.finderStepFailed {
                        Text("Saved. The storage works inside Syncophant; adding it to Finder did not finish. Try again to continue.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if flow.failed, !flow.running {
                        Button("Try Again") { flow.retry(model: app) }.buttonStyle(.glass).frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 6)
        .motion(Motion.smooth, value: flow.steps)
    }
}

// MARK: - Done

private struct HetznerDoneStep: View {
    @Environment(AppModel.self) private var app
    var flow: ConnectModel
    var close: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                .frame(width: 96, height: 96).background(Color.green.gradient, in: Circle())
                .shadow(color: .green.opacity(0.4), radius: 20, y: 14)
                .scaleEffect(shown ? 1 : 0.4).opacity(shown ? 1 : 0)
                .accessibilityHidden(true)
            Text(flow.mounted ? "\(flow.displayName) is in Finder" : "\(flow.displayName) is ready")
                .font(.system(size: 26, weight: .bold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
            Text("Look under Locations in the Finder sidebar. Files stay on the box until you open them. The menu bar icon shows what is happening.")
                .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button("Encrypt This Storage…") { app.open(.encryption); close() }.buttonStyle(.glass)
                Button("Open in Finder") { app.openInFinder(); close() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!flow.mounted)
            }
            .controlSize(.large)
            .padding(.top, 4)
            HStack(spacing: 18) {
                if flow.steps.contains(where: { $0.kind == .preflight && $0.state == .done }) {
                    Label("1 MB test passed both ways", systemImage: "checkmark.circle.fill")
                }
                if flow.steps.contains(where: { $0.kind == .snapshots && $0.state == .done }),
                   let id = flow.selectedBox, let n = flow.snapshotCounts[id], n > 0 {
                    Label(n == 1 ? "1 snapshot ready in Time Travel" : "\(n) snapshots ready in Time Travel", systemImage: "clock.arrow.circlepath")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .symbolRenderingMode(.multicolor)
            .padding(.top, 10)
        }
        .padding(.top, 30)
        .onAppear { withAnimation(Motion.resolve(Motion.bouncy)) { shown = true } }
    }
}
