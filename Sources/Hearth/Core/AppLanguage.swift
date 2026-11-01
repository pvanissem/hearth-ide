import AppKit

/// The app's language: English by default, German on request (Settings › General).
/// macOS picks a bundle's localization at launch from `AppleLanguages`, so the choice is
/// written there for this app before anything is localized, and a change needs a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", german = "de"
    var id: String { rawValue }

    /// Each language in its own name, never translated.
    var title: String { self == .english ? "English" : "Deutsch" }

    static let defaultsKey = "ui.language"

    static var chosen: AppLanguage {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init) ?? .english
    }

    /// The language the running app shows.
    static var active: AppLanguage {
        Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true ? .german : .english
    }

    /// Call first thing at launch.
    static func applyAtLaunch() {
        UserDefaults.standard.set([chosen.rawValue], forKey: "AppleLanguages")
    }

    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    /// Quits and starts the app again once this process has ended (a cancelled quit cancels it).
    @MainActor
    static func relaunch() {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { NSApp.terminate(nil); return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", """
            i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 0; sleep 0.1; done
            /usr/bin/open "$2"
            """, "hearth-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundle]
        try? helper.run()
        NSApp.terminate(nil)
    }
}
