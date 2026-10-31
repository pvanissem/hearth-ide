import SwiftUI
import AppKit

struct UpdateSettings: View {
    let checker: UpdateChecker
    private let copied = State(initialValue: false)

    var body: some View {
        Form {
            Section("Hearth IDE") {
                LabeledContent("Installierte Version") {
                    Text(checker.installed.label).textSelection(.enabled).lineLimit(2)
                }
                if checker.installed.release == nil {
                    Text("Lokaler Entwicklungsbuild. Ein Release kann älter als dieser Build sein; es wird kein automatischer Update-Vorschlag erzeugt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let version = checker.result?.latest {
                    LabeledContent("Veröffentlichtes Release") { Text(version.description).textSelection(.enabled) }
                }
            }
            Section("Update-Prüfung") {
                Toggle("Beim App-Start nach Updates suchen", isOn: Binding(get: { checker.automaticChecks }, set: { checker.automaticChecks = $0 }))
                HStack {
                    Button("Jetzt nach Updates suchen") { Task { await checker.check() } }
                        .disabled(checker.checking)
                    if checker.checking { ProgressView().controlSize(.small) }
                }
                status
                if let date = checker.lastCheckedAt {
                    LabeledContent("Letzte Prüfung") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                Text("Die App liest nur die Versionsdatei von GitLab Pages – ohne GitLab-Token. Bei fehlendem VPN/Netzwerk bleiben Arbeiten und Sandboxes unbeeinträchtigt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Installation") {
                if let message = checker.installMessage {
                    Label(message, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                }
                Button("Was ist neu in dieser Version?") { UpdateInstallFlow.showInstalledNotes(checker) }
                    .disabled(checker.installed.release == nil)
                HStack {
                    Button {
                        UpdateInstallFlow.confirmAndQuit(checker)
                    } label: { Label(checker.result.map { "Auf \($0.latest.description) aktualisieren" } ?? "Jetzt aktualisieren", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!checker.canInstall)
                    Link("Nur ZIP herunterladen", destination: UpdateService.downloadURL(for: checker.result?.latest))
                        .font(.caption)
                }
                Text("„Aktualisieren“ beendet Hearth IDE regulär (ungesicherte Dateien und laufende Sandboxes werden wie beim normalen Beenden abgefragt), führt danach den Installer mit SHA-256-Prüfung aus und startet die neue Version. Schlägt das Update fehl, öffnet sich die bisherige Version wieder. Log: ~/Library/Logs/Hearth IDE/update.log")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Alternativ manuell im Terminal:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(UpdateService.installerCommand).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(UpdateService.installerCommand, forType: .string)
                        copied.wrappedValue = true
                    } label: { Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help("Installationsbefehl kopieren")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        if checker.checking {
            Text("Release-Version wird geprüft …").foregroundStyle(.secondary)
        } else if let error = checker.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let result = checker.result {
            switch result.relation {
            case .updateAvailable:
                Label("Version \(result.latest.description) ist verfügbar.", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            case .current:
                Label("Du verwendest das aktuelle Release.", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .ahead:
                Label("Die installierte Version ist neuer als das veröffentlichte Release.", systemImage: "info.circle")
            case .development:
                Text("Release \(result.latest.description) ist veröffentlicht. Ein sicherer Versionsvergleich mit diesem Entwicklungsbuild ist nicht möglich.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Noch kein Prüfergebnis für diesen App-Start.").foregroundStyle(.secondary)
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
                        Button("Was ist neu?") { UpdateInstallFlow.showInstalledNotes(checker) }.controlSize(.small)
                    }
                    Button { checker.installMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Hinweis ausblenden")
                }
                .padding(10).background(Color.secondary.opacity(0.08))
                Divider()
            }
        }
        if let version = checker.notice {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Hearth IDE \(version.description) ist verfügbar.").font(.callout)
                    Spacer(minLength: 4)
                    Button("Jetzt aktualisieren") { UpdateInstallFlow.confirmAndQuit(checker) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    if !compact {
                        Link("Nur herunterladen", destination: UpdateService.downloadURL(for: version)).font(.caption)
                    }
                    Button { checker.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Hinweis für diese Version ausblenden")
                        .accessibilityLabel("Update-Hinweis ausblenden")
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
            alert.messageText = "Hearth IDE auf \(version.description) aktualisieren?"
            alert.informativeText = "Die App wird beendet, das Update installiert (SHA-256-geprüft) und die neue Version automatisch gestartet. Laufende Sandboxes kannst du beim Beenden weiterlaufen lassen; Chats und Sessions bleiben erhalten."
            alert.accessoryView = notesView(sections, emptyText: markdown == nil
                ? "Änderungsnotizen konnten nicht geladen werden."
                : "Für diese Version sind keine Änderungsnotizen hinterlegt.")
            alert.addButton(withTitle: "Beenden und aktualisieren")
            alert.addButton(withTitle: "Abbrechen")
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

    /// "Was ist neu?" for the installed version (after an update).
    static func showInstalledNotes(_ checker: UpdateChecker) {
        Task { @MainActor in
            let markdown = await checker.service.changelog()
            let all = markdown.map(ReleaseNotes.parse) ?? []
            let sections = checker.installed.release.map { v in all.filter { $0.version == v } } ?? Array(all.prefix(1))
            let alert = NSAlert()
            alert.messageText = "Neu in Hearth IDE \(checker.installed.label)"
            alert.informativeText = ""
            alert.accessoryView = notesView(sections, emptyText: markdown == nil ? "Änderungsnotizen konnten nicht geladen werden." : "Keine Änderungsnotizen für diese Version.")
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
