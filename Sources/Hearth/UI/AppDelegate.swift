import AppKit

/// What to do when the last window closes and when quitting with running sandboxes.
enum QuitPreferences {
    enum OnLastWindow: String, CaseIterable, Identifiable {
        case ask, quit, keepRunning
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Fragen"
            case .quit: "App beenden"
            case .keepRunning: "Im Hintergrund weiterlaufen"
            }
        }
    }

    enum OnQuit: String, CaseIterable, Identifiable {
        case ask, stopSandboxes, keepSandboxes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Fragen"
            case .stopSandboxes: "Sandboxes stoppen"
            case .keepSandboxes: "Sandboxes weiterlaufen lassen"
            }
        }
    }

    static var onLastWindow: OnLastWindow {
        get { UserDefaults.standard.string(forKey: "quit.onLastWindow").flatMap(OnLastWindow.init) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "quit.onLastWindow") }
    }

    static var onQuit: OnQuit {
        get { UserDefaults.standard.string(forKey: "quit.onQuit").flatMap(OnQuit.init) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "quit.onQuit") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App once the model exists.
    static weak var model: AppModel?
    private var stopping = false

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.quitting = true
        Self.model?.agents.stopAll()
        if Self.model?.updates.installOnQuit == true, Snapshotter.directory == nil {
            AppUpdateInstaller.launchHelper()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Snapshotter.directory == nil else { return }
        Self.model?.updates.reportPreviousInstall(AppUpdateInstaller.consumeOutcome())
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = shouldTerminate(sender)
        // A cancelled quit must not leave an update armed for a later, unrelated quit.
        if reply == .terminateCancel { Self.model?.updates.installOnQuit = false }
        return reply
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard Snapshotter.directory == nil else { return false }
        switch QuitPreferences.onLastWindow {
        case .quit: return true
        case .keepRunning: return false
        case .ask: break
        }
        let alert = NSAlert()
        alert.messageText = "Hearth IDE beenden?"
        alert.informativeText = "Das Fenster ist geschlossen. Im Hintergrund meldet Hearth IDE weiterhin, wenn ein Agent auf dich wartet. Über das Dock-Symbol holst du das Fenster zurück."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Im Hintergrund weiterlaufen")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Nicht mehr fragen"
        let quit = alert.runModal() == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            QuitPreferences.onLastWindow = quit ? .quit : .keepRunning
        }
        return quit
    }

    private func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model = Self.model, !model.unsavedDocuments.isEmpty, Snapshotter.directory == nil {
            let docs = model.unsavedDocuments
            let alert = NSAlert()
            alert.messageText = docs.count == 1 ? "„\(docs[0].url.lastPathComponent)“ hat ungesicherte Änderungen"
                                                : "\(docs.count) Dateien haben ungesicherte Änderungen"
            alert.informativeText = docs.map(\.url.lastPathComponent).sorted().joined(separator: ", ")
            alert.addButton(withTitle: "Sichern")
            alert.addButton(withTitle: "Nicht sichern")
            alert.addButton(withTitle: "Abbrechen")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let failed = docs.filter { if case .saved = $0.save(force: false) { return false } else { return true } }
                if !failed.isEmpty {
                    model.banner = "Nicht gesichert (extern geändert?): " + failed.map(\.url.lastPathComponent).joined(separator: ", ")
                    return .terminateCancel
                }
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        if let model = Self.model, model.agents.runningCount > 0, Snapshotter.directory == nil {
            let count = model.agents.runningCount
            let alert = NSAlert()
            alert.messageText = count == 1 ? "Eine Agent-Sitzung läuft noch" : "\(count) Agent-Sitzungen laufen noch"
            alert.informativeText = "Beim Beenden werden sie gestoppt. Claude-Code- und Codex-Gespräche lassen sich später mit „Fortsetzen“ weiterführen."
            alert.addButton(withTitle: "Beenden")
            alert.addButton(withTitle: "Abbrechen")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        guard !stopping, let model = Self.model, !model.servers.isEmpty, Snapshotter.directory == nil else {
            return .terminateNow
        }
        var choice = QuitPreferences.onQuit
        if choice == .ask {
            let names = model.servers.values.map(\.entry.displayName).sorted().joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "\(model.servers.count) Sandbox\(model.servers.count == 1 ? " läuft" : "es laufen") noch"
            alert.informativeText = "\(names)\n\nBeim Stoppen werden laufende Agent-Arbeiten abgebrochen. Laufen die Sandboxes weiter, verbindet sich Hearth IDE beim nächsten Start wieder mit ihnen."
            alert.addButton(withTitle: "Sandboxes stoppen und beenden")
            alert.addButton(withTitle: "Nur App beenden")
            alert.addButton(withTitle: "Abbrechen")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Nicht mehr fragen"
            switch alert.runModal() {
            case .alertFirstButtonReturn: choice = .stopSandboxes
            case .alertSecondButtonReturn: choice = .keepSandboxes
            default: return .terminateCancel
            }
            if alert.suppressionButton?.state == .on { QuitPreferences.onQuit = choice }
        }
        guard choice == .stopSandboxes else { return .terminateNow }
        stopping = true
        Task { @MainActor in
            await model.stopAllSandboxes()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
