import Foundation

/// Shared ISO-8601 parsing. Creating an `ISO8601DateFormatter` loads ICU data and is
/// expensive, so the formatters are reused.
enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}

extension String {
    func lastNonEmptyLines(_ n: Int) -> String {
        split(separator: "\n").suffix(n).joined(separator: "\n")
    }

    /// Without terminal colour/cursor escape sequences.
    var strippingANSI: String {
        replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }
}
