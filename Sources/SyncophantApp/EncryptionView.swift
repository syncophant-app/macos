import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import CoreKit

/// Encryption setup state (unlock method, recovery key, passphrase). Owned by the Encryption screen.
///
/// The result is an rclone crypt password handed to the connect flow (`ConnectFlowState.encryptionPassphrase`).
/// Crypt has to start on an empty folder, so this window never converts an existing storage.
@MainActor @Observable
final class EncryptionFlowState {
    enum Method: Equatable { case recoveryKey, passphrase, existing }

    var step = 0
    var method = Method.recoveryKey
    var recoveryKey = ""
    var passphrase = ""
    var existing = ""
    var reveal = false
    var confirm = ""
    var done = false
    var showScrambled = true
    var toast: String?
    var error: String?
    /// Name of the storage being added. The connect flow sets it before opening this window; nil means the
    /// window was opened on its own, and the result waits for the next storage the person adds.
    var storageName: String?

    var secret: String {
        switch method {
        case .recoveryKey: recoveryKey
        case .passphrase: passphrase
        case .existing: RecoveryKey.canonical(existing) ?? existing
        }
    }

    var confirmMatches: Bool {
        switch method {
        case .recoveryKey:
            guard let last = recoveryKey.split(separator: "-").last else { return false }
            return RecoveryKey.normalize(confirm) == Array(last)
        case .passphrase: return !passphrase.isEmpty && confirm == passphrase
        case .existing: return false
        }
    }

    func reset() {
        step = 0; method = .recoveryKey; recoveryKey = ""; passphrase = ""; existing = ""; reveal = false
        confirm = ""; done = false; showScrambled = true; toast = nil; error = nil; storageName = nil
    }
}

/// End-to-end encryption window: choose how to unlock, get a recovery key or passphrase, prove it once.
struct EncryptionSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var flow: EncryptionFlowState { app.encryptionUI }
    private var strength: PassphraseStrength { PassphraseStrength.evaluate(flow.passphrase) }
    private var storageLabel: String { flow.storageName ?? "your storage" }

    var body: some View {
        VStack(spacing: 0) {
            StepDots(count: 3, current: flow.done ? 2 : flow.step, tint: .purple)
                .frame(height: 30)
            HStack(alignment: .top, spacing: 24) {
                ZStack(alignment: .topLeading) { stepContent }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                ServerPreviewCard(showScrambled: Binding(get: { flow.showScrambled }, set: { flow.showScrambled = $0 }))
                    .frame(width: 270)
            }
            .padding(.horizontal, 48)
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
        .onDisappear { flow.reset() }
    }

    // MARK: Steps

    @ViewBuilder private var stepContent: some View {
        Group {
            switch (flow.step, flow.method) {
            case (0, _): choose
            case (1, .recoveryKey): recoveryKeyStep
            case (1, .passphrase): passphraseStep
            case (1, .existing): existingStep
            default: confirmStep
            }
        }
        .id("\(flow.step)-\(flow.method)")
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(flow.storageName.map { "Only you can read what is on \($0)" } ?? "Only you can read what you store",
                    "Files are locked on this Mac before they leave it. Your provider, or anyone who gets into the storage, sees scrambled names and contents.")
            if flow.storageName == nil, let current = app.active, current.encryptionEnabled != true {
                Label {
                    Text("Files already on \(current.name) stay as they are. Encryption starts with an empty folder, so you add it as a new storage after this step.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.one, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            SectionLabel("How do you want to unlock it on a new Mac?")
            VStack(spacing: 10) {
                methodCard(.recoveryKey, symbol: "key.fill", tone: .purple, title: "Recovery key and Keychain", recommended: true,
                           detail: "Nothing to remember day to day. This Mac unlocks itself; a printed recovery key opens it anywhere else.")
                methodCard(.passphrase, symbol: "keyboard", tone: .accent, title: "A passphrase I choose", recommended: false,
                           detail: "You type it once on each Mac. Good if you already live in a password manager.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unlock method")
            Button("I Already Have a Recovery Key or Passphrase") { pick(.existing); advance() }
                .buttonStyle(.link).font(.system(size: 12))
        }
    }

    private func methodCard(_ method: EncryptionFlowState.Method, symbol: String, tone: Tone, title: String, recommended: Bool, detail: String) -> some View {
        let selected = flow.method == method
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { pick(method) } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tone.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if recommended {
                            Text("Recommended").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Tone.green.text)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(Tone.green.soft, in: Capsule())
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(shape)
            .background(selected ? Color.accentColor.opacity(0.16) : Fill.one, in: shape)
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .motion(Motion.snappy, value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var recoveryKeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Your recovery key", "This Mac unlocks itself with the Keychain. Keep this key somewhere safe for a new Mac, or if this one is lost.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(flow.recoveryKey.split(separator: "-").enumerated()), id: \.offset) { i, group in
                    Text(group)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced)).tracking(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .rowEntrance(i)
                }
            }
            .contentCard(radius: 16, padding: 18)
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery key")
            .accessibilityValue(flow.recoveryKey.split(separator: "-").joined(separator: ", "))
            HStack(spacing: 8) {
                Button("Save Recovery Sheet…", systemImage: "arrow.down.doc") { saveSheet() }
                Button("Copy") { copySecret(flow.recoveryKey) }
                Button("Print…") { printSheet() }
            }
            .buttonStyle(.glass)
            Label("The key stays in this Mac’s Keychain only. Other Macs need the sheet.", systemImage: "lock.laptopcomputer")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var passphraseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Choose a passphrase", "Long beats clever. Four random words are stronger than a short password with symbols.")
            heroField {
                Image(systemName: "lock").foregroundStyle(.tertiary)
                Group {
                    if flow.reveal { TextField("At least four words", text: Bindable(flow).passphrase) }
                    else { SecureField("At least four words", text: Bindable(flow).passphrase) }
                }
                .textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                .accessibilityLabel("Passphrase")
                Button { flow.reveal.toggle() } label: { Image(systemName: flow.reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(flow.reveal ? "Hide passphrase" : "Show passphrase")
            }
            StrengthMeter(strength: strength)
            HStack(spacing: 8) {
                Button("Suggest Four Words", systemImage: "arrow.triangle.2.circlepath") {
                    flow.passphrase = PassphraseWords.suggest(); flow.reveal = true
                }
                Button("Copy") { copySecret(flow.passphrase) }.disabled(flow.passphrase.isEmpty)
            }
            .buttonStyle(.glass)
            Label {
                Text("If you forget it, nobody can open these files. Not Syncophant, not your provider. Store it in your password manager now.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.orange.text) }
            .font(.system(size: 12.5))
            .statusCard(.orange, radius: 14, padding: 12)
        }
        .onAppear { focused = true }
    }

    private var existingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Enter your key", "Type the recovery key from your sheet, or your passphrase. Connect the same storage and folder afterwards to open your files.")
            heroField {
                Image(systemName: "key").foregroundStyle(.tertiary)
                SecureField("Recovery key or passphrase", text: Bindable(flow).existing)
                    .textFieldStyle(.plain).font(.system(size: 17, design: .monospaced)).focused($focused)
                    .accessibilityLabel("Recovery key or passphrase")
                if RecoveryKey.canonical(flow.existing) != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.green.color)
                        .accessibilityLabel("Looks like a recovery key")
                }
            }
            Text("Recovery keys can be typed with or without dashes; O and I read as 0 and 1.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if flow.done { successCard }
        }
        .onAppear { focused = true }
    }

    private var confirmStep: some View {
        let isKey = flow.method == .recoveryKey
        return VStack(alignment: .leading, spacing: 14) {
            heading(isKey ? "Check you saved it" : "Type it once more",
                    isKey ? "Type the last group of your recovery key. This replaces two tick boxes with one real check."
                          : "From memory, if you can. It confirms you can type it on another Mac.")
            heroField(ring: flow.confirmMatches ? Tone.green.color : nil) {
                Group {
                    if isKey { TextField("Last 4 characters", text: Bindable(flow).confirm) }
                    else { SecureField("Your passphrase", text: Bindable(flow).confirm) }
                }
                .textFieldStyle(.plain).font(.system(size: 17, design: .monospaced)).focused($focused)
                .disabled(flow.done)
                .accessibilityLabel(isKey ? "Last group of the recovery key" : "Passphrase again")
                if flow.confirmMatches {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Tone.green.color)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Matches")
                }
            }
            .motion(Motion.bouncy, value: flow.confirmMatches)
            if flow.done { successCard }
        }
        .onAppear { focused = true }
    }

    private var successCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .symbolEffect(.bounce, value: flow.done)
            VStack(alignment: .leading, spacing: 2) {
                Text("Encryption is ready").font(.system(size: 14, weight: .semibold))
                Text(flow.storageName.map { "Finish connecting \($0). Everything in it is locked before it leaves this Mac." }
                     ?? "Add a storage with an empty folder. Everything in it is locked before it leaves this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .statusCard(.green, radius: 16, padding: 16)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func heroField<Content: View>(ring: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 12) { content() }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Fill.one, in: shape)
            .overlay(shape.strokeBorder(ring ?? Color(nsColor: .separatorColor), lineWidth: ring == nil ? 0.5 : 1.5))
            .motion(Motion.snappy, value: ring == nil)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let toast = flow.toast {
                Text(toast).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tone.green.text)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else if let error = flow.error {
                Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Tone.red.text).lineLimit(2)
            }
            Spacer()
            if flow.done {
                if flow.storageName == nil {
                    Button("Done") { dismiss() }.buttonStyle(.glass)
                    Button("Add Storage") { app.open(.addStorage); dismiss() }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                if flow.step == 0 {
                    Button("Not Now") { app.connectUI.encryptionPassphrase = nil; dismiss() }.buttonStyle(.glass)
                } else {
                    Button("Back") { go(to: flow.step == 1 || flow.method == .existing ? 0 : flow.step - 1) }.buttonStyle(.glass)
                }
                primaryButton
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
        .motion(Motion.smooth, value: flow.toast)
    }

    @ViewBuilder private var primaryButton: some View {
        if flow.step == 2 || flow.method == .existing && flow.step == 1 {
            Button(flow.method == .existing ? "Use This Key" : "Turn On Encryption") { finish() }
                .buttonStyle(.glassProminent).tint(.purple)
                .frame(minWidth: 140)
                .disabled(flow.method == .existing ? flow.existing.count < 8 : !flow.confirmMatches)
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Continue") { advance() }
                .buttonStyle(.glassProminent)
                .frame(minWidth: 140)
                .disabled(flow.step == 1 && flow.method == .passphrase && strength.segments < 3)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private func pick(_ method: EncryptionFlowState.Method) {
        withAnimation(Motion.resolve(Motion.snappy)) { flow.method = method }
    }

    private func go(to step: Int) {
        flow.confirm = ""; flow.error = nil
        withAnimation(Motion.resolve(Motion.smooth)) { flow.step = step }
    }

    private func advance() {
        if flow.step == 0, flow.method == .recoveryKey, flow.recoveryKey.isEmpty {
            do { flow.recoveryKey = try RecoveryKey.generate() } catch { flow.error = message(for: error); return }
        }
        go(to: flow.step + 1)
    }

    private func finish() {
        guard flow.method == .existing || flow.confirmMatches else { return }
        app.connectUI.encryptionPassphrase = flow.secret
        withAnimation(Motion.resolve(Motion.bouncy)) { flow.done = true }
    }

    private func say(_ text: String) {
        flow.toast = text
        Task { try? await Task.sleep(for: .seconds(2.6)); if flow.toast == text { flow.toast = nil } }
    }

    private func copySecret(_ text: String) {
        SecretClipboard.copy(text)
        say("Copied. Clears from the clipboard in 60 s.")
    }

    private func saveSheet() {
        guard let data = RecoverySheet.pdf(key: flow.recoveryKey, storage: flow.storageName) else { flow.error = "The recovery sheet could not be made."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Syncophant Recovery Sheet.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]); say("Saved \(url.lastPathComponent)") }
        catch { flow.error = message(for: error) }
    }

    private func printSheet() {
        guard let data = RecoverySheet.pdf(key: flow.recoveryKey, storage: flow.storageName),
              let operation = PDFDocument(data: data)?.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: false)
        else { flow.error = "The recovery sheet could not be printed."; return }
        operation.run()
    }
}

/// Puts a secret on the clipboard, marks it concealed for clipboard managers, and clears it after 60 s if
/// nothing else was copied since.
@MainActor enum SecretClipboard {
    static func copy(_ text: String, clearAfter seconds: Double = 60) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }
}

// MARK: - What the server sees

/// Five rows from the folder open in Files, as names or as an illustration of what crypt stores.
private struct ServerPreviewCard: View {
    @Environment(AppModel.self) private var app
    @Binding var showScrambled: Bool

    private var rows: [RemoteEntry] {
        guard let browser = app.browser else { return [] }
        let nodes = app.currentFolder == "/" ? browser.roots : (browser.find(path: app.currentFolder)?.children ?? browser.roots)
        return nodes.prefix(5).map(\.item.entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What the server sees").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(showScrambled ? "Encrypted" : "Not encrypted") {
                    withAnimation(Motion.resolve(Motion.snappy)) { showScrambled.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(showScrambled ? Color.white : Color.primary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(showScrambled ? Color.purple : Fill.two, in: Capsule())
                .accessibilityLabel("Show scrambled names")
                .accessibilityValue(showScrambled ? "On" : "Off")
            }
            if rows.isEmpty {
                Text("Open a folder in Files to preview your own file names here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(rows) { row($0) }
                }
                if showScrambled {
                    Text("Illustration: real scrambled names come from your key. Sizes are exact.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                fact(true, "Names and contents hidden")
                fact(true, "XSalsa20-Poly1305 for contents, AES-256 for names; the key never leaves this Mac")
                fact(false, "Sizes and change times still visible")
                fact(false, "How many files and folders, and how they nest")
                fact(true, "Other apps on the storage see only scrambled files")
            }
        }
        .contentCard(radius: 16, padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the server sees")
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 13))
                .foregroundStyle(showScrambled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(entry.isDirectory ? Color.accentColor : Color.secondary))
                .frame(width: 16)
            Text(showScrambled ? CryptPreview.illustrativeName(entry.name) : entry.name)
                .font(.system(size: 12, design: showScrambled ? .monospaced : .default))
                .foregroundStyle(showScrambled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isDirectory ? "folder" : Format.bytes(showScrambled ? CryptPreview.encryptedSize(entry.size) : entry.size))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(Motion.resolve(Motion.smooth), value: showScrambled)
    }

    private func fact(_ hidden: Bool, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: hidden ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(hidden ? Color.green : Color.secondary)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .accessibilityLabel((hidden ? "Hidden: " : "Visible: ") + text)
    }
}

// MARK: - Recovery sheet

/// A one-page PDF with the key, storage name, date and how to use it. Drawn in light colours for paper.
@MainActor enum RecoverySheet {
    static func pdf(key: String, storage: String?) -> Data? {
        let renderer = ImageRenderer(content: RecoverySheetPage(key: key, storage: storage, date: .now)
            .frame(width: 612, height: 792).environment(\.colorScheme, .light))
        let data = NSMutableData()
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil); draw(context); context.endPDFPage(); context.closePDF()
            ok = true
        }
        return ok ? data as Data : nil
    }
}

private struct RecoverySheetPage: View {
    let key: String
    let storage: String?
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Syncophant Recovery Sheet").font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage: \(storage ?? "the encrypted storage you add next")")
                Text("Created: \(date.formatted(date: .long, time: .shortened))")
            }
            .font(.system(size: 13))
            Text(key)
                .font(.system(size: 24, weight: .semibold, design: .monospaced)).tracking(2)
                .padding(18)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text("To open your files on a new Mac").font(.system(size: 15, weight: .semibold))
                Text("1. Install Syncophant and choose Add Storage.")
                Text("2. In the Encryption window, choose I Already Have a Recovery Key or Passphrase, and type the key above. Dashes and case don’t matter; O and I read as 0 and 1.")
                Text("3. Connect the same storage and folder.")
            }
            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Without Syncophant").font(.system(size: 15, weight: .semibold))
                Text("The files use rclone crypt. rclone can read them with this key, exactly as printed, as the password; standard file name encryption, encrypted directory names, base32 encoding, and no second password.")
            }
            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("Anyone with this key and access to the storage can read your files. Keep this sheet private and safe. Nobody, including Syncophant, can recover it for you.")
                .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(.black)
        .padding(54)
        .background(Color.white)
    }
}
