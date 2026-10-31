import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WorkspaceLayoutView()
        .background(WindowAutosave(name: "HearthMainWindow"))
        .safeAreaInset(edge: .top, spacing: 0) { UpdateNoticeBar(checker: model.updates) }
        .sheet(item: Binding(get: { model.startRequest }, set: { model.startRequest = $0 })) { req in
            StartSandboxSheet(request: req)
        }
        .sheet(isPresented: Binding(get: { model.showWelcome }, set: { model.showWelcome = $0 })) {
            WelcomeView()
        }
        .sheet(item: Binding(get: { model.copilotUsage }, set: { model.copilotUsage = $0 })) { usage in
            CopilotUsageView(usage: usage)
        }
        .task { await model.loadProfiles() }
        .task {
            // Reopen panes that had their own window; AppKit restores their frames by autosave name.
            for tab in model.savedDetachedTabs where !model.detachedTabs.contains(tab) {
                model.detachedTabs.insert(tab)
                openWindow(value: tab)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.startRequest = .init() } label: { Label("Sandbox starten", systemImage: "plus") }
                    .help("Sandbox starten (Verzeichnis, Repository klonen, Profil, Projekt)")
                    .disabled(model.busy)
                Menu {
                    Section("Bereich hinzufügen") {
                        ForEach(InspectorTab.allCases) { tab in
                            Button { model.addPane(tab) } label: { Label(tab.title, systemImage: tab.symbol) }
                                .disabled(model.paneTree.contains(tab: tab))
                        }
                    }
                    Section("Am Fensterrand") {
                        Menu {
                            ForEach(InspectorTab.allCases) { tab in
                                Button { model.addPane(tab, atWindowEdge: .windowBottom) } label: { Label(tab.title, systemImage: tab.symbol) }
                            }
                        } label: { Label("Unten über ganze Breite", systemImage: "rectangle.bottomthird.inset.filled") }
                        Menu {
                            ForEach(InspectorTab.allCases) { tab in
                                Button { model.addPane(tab, atWindowEdge: .windowRight) } label: { Label(tab.title, systemImage: tab.symbol) }
                            }
                        } label: { Label("Rechts über ganze Höhe", systemImage: "rectangle.righthalf.inset.filled") }
                    }
                    Section("Layouts") {
                        ForEach(LayoutPreset.allCases) { preset in
                            Button { withAnimation(.easeOut(duration: 0.2)) { model.apply(preset) } } label: {
                                Label(preset.rawValue, systemImage: preset.symbol)
                            }
                        }
                    }
                    if model.maximizedPane != nil {
                        Button("Maximierung aufheben") { model.maximizedPane = nil }
                    }
                } label: {
                    Label("Layout", systemImage: "rectangle.3.group")
                }
                .help("Bereiche hinzufügen, Layouts wählen – Bereiche lassen sich an der Kopfzeile verschieben")
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(banner).font(.callout).lineLimit(3)
                    Button { model.banner = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
    }
}

/// Lets AppKit remember the window's position and size across launches.
struct WindowAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { Tracker(name: name) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Saves the frame under our own key on every move/resize and re-applies it when the
    /// window appears. (SwiftUI replaces AppKit's frameAutosaveName with its own, per scene type.)
    final class Tracker: NSView {
        let name: String
        private var observers: [NSObjectProtocol] = []
        private weak var tracked: NSWindow?
        init(name: String) { self.name = name; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        private var key: String { "hearth.windowFrame.\(name)" }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== tracked else { return }
            tracked = window
            observers.forEach(NotificationCenter.default.removeObserver)
            if Snapshotter.directory == nil, let saved = UserDefaults.standard.string(forKey: key) {
                let frame = NSRectFromString(saved)
                // SwiftUI positions the window after attaching views; apply ours afterwards.
                for delay in [0.0, 0.15, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                        guard let window, frame.width > 100,
                              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
                        window.setFrame(frame, display: true)
                    }
                }
            }
            let save: (Notification) -> Void = { [weak self, weak window] _ in
                guard let self, let window, Snapshotter.directory == nil else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: self.key)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak window] in
                guard let self, let window else { return }
                self.observers = [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification].map {
                    NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main, using: save)
                }
            }
        }
    }
}
