import SwiftUI
import AppKit
import SwiftTerm

/// Font and colors of the user's default iTerm2 profile, so the embedded
/// terminal looks like the terminal they chose in the settings.
struct ITermProfile {
    var font: NSFont?
    var foreground: NSColor?
    var background: NSColor?
    var cursor: NSColor?
    var selection: NSColor?
    var ansi: [NSColor] = []

    static func load(dark: Bool) -> ITermProfile? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let profiles = root["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        let guid = root["Default Bookmark Guid"] as? String
        let p = profiles.first { $0["Guid"] as? String == guid } ?? profiles[0]
        // Profiles may keep separate light/dark palettes ("Foreground Color (Dark)").
        let separate = p["Use Separate Colors for Light and Dark Mode"] as? Bool ?? false
        func color(_ key: String) -> NSColor? {
            let dict = (separate ? p["\(key) (\(dark ? "Dark" : "Light"))"] : nil) ?? p[key]
            guard let c = dict as? [String: Any],
                  let r = c["Red Component"] as? Double, let g = c["Green Component"] as? Double,
                  let b = c["Blue Component"] as? Double else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: c["Alpha Component"] as? Double ?? 1)
        }
        var profile = ITermProfile()
        if let spec = p["Normal Font"] as? String, let space = spec.lastIndex(of: " "),
           let size = Double(spec[spec.index(after: space)...]) {
            profile.font = NSFont(name: String(spec[..<space]), size: size)
        }
        profile.foreground = color("Foreground Color")
        profile.background = color("Background Color")
        profile.cursor = color("Cursor Color")
        profile.selection = color("Selection Color")
        profile.ansi = (0..<16).compactMap { color("Ansi \($0) Color") }
        return profile
    }
}

/// Embedded terminal pane: login shell in the workspace, optionally the devkcode
/// session TUI; looks like iTerm2 when that is the preferred terminal.
struct TerminalPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textScale) private var scale
    let root: String?

    enum Mode: Equatable { case shell, session(String) }
    private let mode = State(initialValue: Mode.shell)
    private let generation = State(initialValue: 0)   // bump to restart the process
    private let exited = State(initialValue: Int32?.none)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(title).scaledFont(.caption, bold: true).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu {
                    Button { start(.shell) } label: { Label("Shell im Workspace", systemImage: "terminal") }
                    if let s = model.selectedSession {
                        Button { start(.session(s.id)) } label: {
                            Label("Session-Oberfläche: \(s.title)", systemImage: "rectangle.and.text.magnifyingglass")
                        }
                    }
                } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Neu starten als Shell oder devkcode-Session-Oberfläche")
                Button { generation.wrappedValue += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Terminal neu starten")
                Button { openExternally() } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("In \(TerminalLauncher.preferred.rawValue) öffnen")
            }
            .buttonStyle(.borderless)
            .scaledFont(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            ZStack(alignment: .bottom) {
                EmbeddedTerminal(command: command, cwd: root ?? NSHomeDirectory(), dark: colorScheme == .dark,
                                 scale: scale, onExit: { exited.wrappedValue = $0 })
                    .id("\(generation.wrappedValue)#\(command.joined(separator: " "))#\(root ?? "")#\(colorScheme == .dark)")
                if let code = exited.wrappedValue {
                    HStack {
                        Text("Prozess beendet (Code \(code))").font(.caption)
                        Button("Neu starten") { generation.wrappedValue += 1 }.controlSize(.small)
                    }
                    .padding(8).background(.regularMaterial, in: Capsule()).padding(10)
                }
            }
        }
        .onChange(of: generation.wrappedValue) { exited.wrappedValue = nil }
    }

    private var title: String {
        switch mode.wrappedValue {
        case .shell: (root ?? NSHomeDirectory()).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .session(let id): "devkcode-Session " + (model.inbox.first { $0.id == id }?.title ?? id)
        }
    }

    /// argv for the process (login shell, or the shell running devkcode so PATH etc. are set).
    private var command: [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        switch mode.wrappedValue {
        case .shell:
            return [shell, "-l"]
        case .session(let id):
            guard let cli = model.cli else { return [shell, "-l"] }
            let entry = model.servers.values.first { $0.sessions[id] != nil }?.entry
            let cmd = TerminalLauncher.command(devkcode: cli.executable.path, directory: entry?.repoRoot ?? root ?? NSHomeDirectory(),
                                               profile: entry?.profileName, project: entry?.projectName, sessionID: id)
            return [shell, "-l", "-c", cmd]
        }
    }

    private func start(_ m: Mode) {
        mode.wrappedValue = m
        generation.wrappedValue += 1
    }

    private func openExternally() {
        let dir = root ?? NSHomeDirectory()
        let cmd: String
        if case .session(let id) = mode.wrappedValue, let item = model.inbox.first(where: { $0.id == id }) {
            model.openInTerminal(item)
            return
        } else {
            cmd = "cd \(TerminalLauncher.shellQuote(dir))"
        }
        Task {
            if let err = await TerminalLauncher.launch(TerminalLauncher.preferred, command: cmd) { model.banner = err }
        }
    }
}

/// SwiftTerm's LocalProcessTerminalView (real PTY) wrapped for SwiftUI.
struct EmbeddedTerminal: NSViewRepresentable {
    let command: [String]
    let cwd: String
    let dark: Bool
    let scale: Double
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let security = TerminalSecurity(view)
        context.coordinator.security = security
        view.terminalDelegate = security
        view.processDelegate = context.coordinator
        applyTheme(to: view)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "hearth"
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        view.startProcess(executable: command[0], args: Array(command.dropFirst()),
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + URL(fileURLWithPath: command[0]).lastPathComponent,
                          currentDirectory: cwd)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        let size = baseFontSize * scale
        if abs(view.font.pointSize - size) > 0.1 { view.font = font(size: size) }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    private var profile: ITermProfile? {
        TerminalLauncher.preferred == .iTerm ? ITermProfile.load(dark: dark) : nil
    }

    private var baseFontSize: Double { profile?.font.map { Double($0.pointSize) } ?? 12 }

    private func font(size: Double) -> NSFont {
        if let f = profile?.font, let scaled = NSFont(name: f.fontName, size: size) { return scaled }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func applyTheme(to view: LocalProcessTerminalView) {
        view.font = font(size: baseFontSize * scale)
        if let p = profile {
            if p.ansi.count == 16 {
                view.installColors(p.ansi.map { c in
                    let s = c.usingColorSpace(.sRGB) ?? c
                    return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535),
                                           blue: UInt16(s.blueComponent * 65535))
                })
            }
            if let fg = p.foreground { view.nativeForegroundColor = fg }
            if let bg = p.background { view.nativeBackgroundColor = bg }
            if let c = p.cursor { view.caretColor = c }
            if let s = p.selection { view.selectedTextBackgroundColor = s }
        } else {
            view.nativeForegroundColor = .textColor
            view.nativeBackgroundColor = .textBackgroundColor
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var security: TerminalSecurity?
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onExit(exitCode) }
        }
    }
}
