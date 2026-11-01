import AppKit

/// Opens a command in the user's terminal app: new tab, wait until the shell is ready,
/// then type the command (typing early gets mangled in Terminal.app).
enum TerminalLauncher {
    enum App: String, CaseIterable, Identifiable {
        case iTerm = "iTerm2", ghostty = "Ghostty", terminal = "Terminal"
        var id: String { rawValue }

        var bundleID: String {
            switch self {
            case .iTerm: "com.googlecode.iterm2"
            case .ghostty: "com.mitchellh.ghostty"
            case .terminal: "com.apple.Terminal"
            }
        }

        var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    static let defaultsKey = "terminalApp"

    static var installed: [App] { App.allCases.filter(\.isInstalled) }

    static var preferred: App {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey), let app = App(rawValue: raw), app.isInstalled {
                return app
            }
            return installed.first ?? .terminal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    static func script(for app: App, command: String) -> String {
        let cmd = appleScriptQuote(command)
        switch app {
        case .iTerm:
            return """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                tell current session of current window to write text \(cmd)
            end tell
            """
        case .ghostty:
            return """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration
                set newTab to new tab in front window with configuration cfg
                set term to focused terminal of newTab
                set waited to 0
                repeat while working directory of term is "" and waited < 50
                    delay 0.1
                    set waited to waited + 1
                end repeat
                input text \(cmd) to term
                send key "enter" to term
            end tell
            """
        case .terminal:
            return """
            tell application "Terminal"
                activate
                set newTab to do script ""
                set waited to 0
                repeat while busy of newTab and waited < 50
                    delay 0.1
                    set waited to waited + 1
                end repeat
                delay 0.3
                do script \(cmd) in newTab
            end tell
            """
        }
    }

    /// Runs the script via osascript so failures come back as readable text.
    static func launch(_ app: App, command: String) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script(for: app, command: command)]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return error.localizedDescription }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : String(decoding: data, as: UTF8.self)
        }.value
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
