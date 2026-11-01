import SwiftUI
import AppKit

@main
struct HearthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model: AppModel

    init() {
        // Before anything is localized: the bundle picks its language on first use.
        AppLanguage.applyAtLaunch()
        model = AppModel()
        AppDelegate.model = model
        if Snapshotter.directory != nil {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Snapshotter.run(model: model)
            return
        }
        // Needed when launched via `swift run` without an app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppAppearance.current.apply()
        let updates = model.updates
        let appModel = model
        UpdateInstallFlow.prepareForQuit = { appModel.showWelcome = false }
        Task { await updates.checkOnLaunch() }
    }

    var body: some Scene {
        WindowGroup("Hearth IDE") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 650)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Larger text") { model.textZoom.zoomAll(by: 1.1) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller text") { model.textZoom.zoomAll(by: 1 / 1.1) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual size") { model.textZoom.reset() }.keyboardShortcut("0", modifiers: .command)
            }
        }

        WindowGroup("Diagram", for: MermaidDiagram.self) { $diagram in
            if let d = diagram {
                MermaidCanvas(source: d.source, title: d.title)
                    .navigationTitle("\(d.title) – \(d.file)")
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
        .defaultSize(width: 1200, height: 800)

        WindowGroup("Area", for: InspectorTab.self) { $tab in
            if let tab {
                DetachedPaneView(tab: tab)
                    .environment(model)
                    .frame(minWidth: 380, minHeight: 300)
            }
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView().environment(model)
        }
    }
}
