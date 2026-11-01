import Foundation
import Testing
@testable import Hearth

/// The German translation (Resources/de.lproj). Missing keys are found by
/// scripts/check-localization.sh, which CI runs; this checks the file itself.
struct LocalizationTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/de.lproj/Localizable.strings")

    static func german() throws -> [String: String] {
        let data = try Data(contentsOf: file)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    static func placeholders(_ s: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(lld|llu|ld|lf|@|d|f|u)"#)
        let text = s.replacingOccurrences(of: "%%", with: "")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range(at: 1), in: text)!]) }.sorted()
    }

    @Test func everyTranslationKeepsItsPlaceholders() throws {
        let german = try Self.german()
        #expect(german.count > 600)
        for (key, value) in german {
            #expect(Self.placeholders(key) == Self.placeholders(value), "\(key) → \(value)")
        }
    }

    @Test func coreTextsAreTranslated() throws {
        let german = try Self.german()
        for key in ["Sessions", "Start agent…", "Language", "Restart now", "Needs attention (%lld)",
                    "Port %lld is already in use on this Mac. Stop the other process or choose another port."] {
            #expect(german[key] != nil && german[key] != key, "\(key) is not translated")
        }
    }

    @Test func englishIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.chosen == .english)
        #expect(AppLanguage.german.title == "Deutsch" && AppLanguage.english.title == "English")
    }
}
