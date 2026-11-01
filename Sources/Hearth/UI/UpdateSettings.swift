import SwiftUI
import AppKit

struct UpdateSettings: View {
    let checker: UpdateChecker
    private let copied = State(initialValue: false)

    var body: some View {
        Form {
            Section("Hearth IDE") {
                LabeledContent("Installed version") {
                    Text(checker.installed.label).textSelection(.enabled).lineLimit(2)
                }
                if checker.installed.release == nil {
                    Text("Local development build. A release may be older than this build; no update is suggested automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let version = checker.result?.latest {
                    LabeledContent("Published release") { Text(version.description).textSelection(.enabled) }
                }
            }
            Section("Update check") {
                Toggle("Check for updates when the app starts", isOn: Binding(get: { checker.automaticChecks }, set: { checker.automaticChecks = $0 }))
                HStack {
                    Button("Check for updates now") { Task { await checker.check() } }
                        .disabled(checker.checking)
                    if checker.checking { ProgressView().controlSize(.small) }
                }
                status
                if let date = checker.lastCheckedAt {
                    LabeledContent("Last check") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                Text("The app only reads the version file of the latest GitHub release – no account, no token. Without a network connection your work and sandboxes are unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Installation") {
                if let message = checker.installMessage {
                    Label(message, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                }
                Button("What’s new in this version?") { UpdateInstallFlow.showInstalledNotes(checker) }
                    .disabled(checker.installed.release == nil)
                HStack {
                    Button {
                        UpdateInstallFlow.confirmAndQuit(checker)
                    } label: { Label(checker.result.map { "Update to \($0.latest.description)" } ?? "Update now", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!checker.canInstall)
                    Link("Download ZIP only", destination: UpdateService.downloadURL(for: checker.result?.latest))
                        .font(.caption)
                }
                Text("“Update” quits Hearth IDE normally (unsaved files and running sessions are asked about as usual), then runs the installer with SHA-256 verification and starts the new version. If the update fails, the previous version opens again. Log: ~/Library/Logs/Hearth IDE/update.log")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Or by hand in the Terminal:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(UpdateService.installerCommand).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(UpdateService.installerCommand, forType: .string)
                        copied.wrappedValue = true
                    } label: { Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy install command")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        if checker.checking {
            Text("Checking the release version…").foregroundStyle(.secondary)
        } else if let error = checker.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let result = checker.result {
            switch result.relation {
            case .updateAvailable:
                Label("Version \(result.latest.description) is available.", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            case .current:
                Label("You are using the latest release.", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .ahead:
                Label("The installed version is newer than the published release.", systemImage: "info.circle")
            case .development:
                Text("Release \(result.latest.description) is published. This development build cannot be compared with it reliably.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No check result since the app started.").foregroundStyle(.secondary)
        }
    }
}

/// Nonmodal, dismissible notice; safe to display while work is running or the
/// welcome sheet is open. Downloads are always fixed vendor URLs, not feed input.
struct UpdateNoticeBar: View {
    let checker: UpdateChecker
    var compact = false

    var body: some View {
        if let message = checker.installMessage, !compact {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: message.hasPrefix("Hearth IDE wurde") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(message.hasPrefix("Hearth IDE wurde") ? Color.green : Color.orange)
                    Text(message).font(.callout).lineLimit(2)
                    Spacer(minLength: 4)
                    if message.hasPrefix("Hearth IDE wurde") {
                        Button("What’s new?") { UpdateInstallFlow.showInstalledNotes(checker) }.controlSize(.small)
                    }
                    Button { checker.installMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Hide notice")
                }
                .padding(10).background(Color.secondary.opacity(0.08))
                Divider()
            }
        }
        if let version = checker.notice {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Hearth IDE \(version.description) is available.").font(.callout)
                    Spacer(minLength: 4)
                    Button("Update now") { UpdateInstallFlow.confirmAndQuit(checker) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    if !compact {
                        Link("Download only", destination: UpdateService.downloadURL(for: version)).font(.caption)
                    }
                    Button { checker.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Hide this notice for this version")
                        .accessibilityLabel("Hide update notice")
                }
                .padding(10).background(Color.accentColor.opacity(0.07))
                Divider()
            }
        }
    }
}

/// Confirm (with release notes), then quit through the normal termination path; the
/// installer helper is launched only once termination is actually happening.
@MainActor
enum UpdateInstallFlow {
    /// Set by the app: closes sheets such as the welcome dialog that would block quitting.
    static var prepareForQuit: (() -> Void)?

    static func confirmAndQuit(_ checker: UpdateChecker) {
        guard checker.canInstall, let version = checker.result?.latest else { return }
        Task { @MainActor in
            let markdown = await checker.service.changelog()
            let sections = markdown.map { ReleaseNotes.between(ReleaseNotes.parse($0), installed: checker.installed.release, latest: version) } ?? []
            let alert = NSAlert()
            alert.messageText = String(localized: "Update Hearth IDE to \(version.description)?")
            alert.informativeText = String(localized: "The app quits, the update is installed (SHA-256 verified) and the new version starts automatically. Sessions are kept and can be resumed.")
            alert.accessoryView = notesView(sections, emptyText: markdown == nil
                ? String(localized: "The release notes could not be loaded.")
                : String(localized: "There are no release notes for this version."))
            alert.addButton(withTitle: String(localized: "Quit and update"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            checker.installOnQuit = true
            prepareForQuit?()
            // An open sheet (e.g. the welcome dialog) blocks termination: close it first,
            // then quit once AppKit has finished dismissing it.
            var hadSheet = false
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet); hadSheet = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (hadSheet ? 0.4 : 0)) { NSApp.terminate(nil) }
        }
    }

    /// String(localized: "What’s new?") for the installed version (after an update).
    static func showInstalledNotes(_ checker: UpdateChecker) {
        Task { @MainActor in
            let markdown = await checker.service.changelog()
            let all = markdown.map(ReleaseNotes.parse) ?? []
            let sections = checker.installed.release.map { v in all.filter { $0.version == v } } ?? Array(all.prefix(1))
            let alert = NSAlert()
            alert.messageText = String(localized: "New in Hearth IDE \(checker.installed.label)")
            alert.informativeText = ""
            alert.accessoryView = notesView(sections, emptyText: markdown == nil ? String(localized: "The release notes could not be loaded.") : String(localized: "No release notes for this version."))
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Scrollable, read-only notes; inline Markdown only (no HTML/images).
    static func notesView(_ sections: [ReleaseNotes.Section], emptyText: String) -> NSView {
        let text = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        if sections.isEmpty {
            text.append(NSAttributedString(string: emptyText, attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for (index, section) in sections.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: "Version " + section.title + "\n",
                                           attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            for item in section.items {
                let inline = (try? NSAttributedString(AttributedString(markdown: item, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))))
                    ?? NSAttributedString(string: item)
                let line = NSMutableAttributedString(string: "•  ", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
                let content = NSMutableAttributedString(attributedString: inline)
                content.addAttributes([.font: body, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: content.length))
                line.append(content)
                line.append(NSAttributedString(string: "\n"))
                let style = NSMutableParagraphStyle()
                style.headIndent = 14
                style.paragraphSpacing = 3
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                text.append(line)
            }
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.autoresizingMask = [.width]
        view.textStorage?.setAttributedString(text)
        scroll.documentView = view
        let used = view.layoutManager.map { lm -> CGFloat in
            lm.ensureLayout(for: view.textContainer!)
            return lm.usedRect(for: view.textContainer!).height + 16
        } ?? 220
        scroll.frame.size.height = min(260, max(60, used))
        return scroll
    }
}
