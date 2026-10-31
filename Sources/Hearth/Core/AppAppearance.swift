import AppKit

/// App-wide light/dark choice, independent of the macOS setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Wie System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    static let defaultsKey = "ui.appearance"

    @MainActor
    static var current: AppAppearance {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            newValue.apply()
        }
    }

    /// Setting NSApp.appearance re-themes every window, including SwiftUI's colorScheme.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
