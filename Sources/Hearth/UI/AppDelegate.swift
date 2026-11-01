import AppKit

/// What to do when the last window closes.
enum QuitPreferences {
    enum OnLastWindow: String, CaseIterable, Identifiable {
        case ask, quit, keepRunning
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask"
            case .quit: String(localized: "Quit app")
            case .keepRunning: "Keep running in the background"
            }
        }
    }

    static var onLastWindow: OnLastWindow {
        get { UserDefaults.standard.string(forKey: "quit.onLastWindow").flatMap(OnLastWindow.init) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "quit.onLastWindow") }
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App once the model exists.
    static weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.layout.quitting = true
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
        alert.messageText = String(localized: "Quit Hearth IDE?")
        alert.informativeText = String(localized: "The window is closed. In the background Hearth IDE still tells you when an agent is waiting for you. Click the Dock icon to bring the window back.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: "Keep running in the background")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        let quit = alert.runModal() == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            QuitPreferences.onLastWindow = quit ? .quit : .keepRunning
        }
        return quit
    }

    private func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model = Self.model, !model.editor.unsavedDocuments.isEmpty, Snapshotter.directory == nil {
            let docs = model.editor.unsavedDocuments
            let alert = NSAlert()
            alert.messageText = docs.count == 1 ? String(localized: "“\(docs[0].url.lastPathComponent)” has unsaved changes")
                                                : String(localized: "\(docs.count) files have unsaved changes")
            alert.informativeText = docs.map(\.url.lastPathComponent).sorted().joined(separator: ", ")
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Don’t save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let failed = docs.filter { if case .saved = $0.save(force: false) { return false } else { return true } }
                if !failed.isEmpty {
                    model.banner = String(localized: "Not saved (changed elsewhere?): ") + failed.map(\.url.lastPathComponent).joined(separator: ", ")
                    return .terminateCancel
                }
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        if let model = Self.model, model.agents.runningCount > 0, Snapshotter.directory == nil {
            let count = model.agents.runningCount
            let alert = NSAlert()
            alert.messageText = count == 1 ? String(localized: "An agent session is still running") : String(localized: "\(count) agent sessions are still running")
            alert.informativeText = String(localized: "Quitting stops them. Claude Code and Codex conversations can be continued later with “Resume”.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }
}
