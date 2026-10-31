import Foundation

/// "Go to definition" without a language server: finds declarations of a symbol
/// in the workspace with per-language patterns. Good enough for class/func/type
/// jumps in Java, Kotlin, Go, Swift, TS/JS, Python, Rust, C#.
struct SymbolLocation: Identifiable, Hashable, Sendable {
    let path: String      // relative to the workspace root
    let line: Int
    let preview: String
    var id: String { "\(path):\(line)" }
}

enum SymbolFinder {
    static let skipped: Set<String> = [".git", "node_modules", ".build", "target", "build", "dist", "vendor",
                                       ".gradle", ".venv", ".idea", ".swiftpm", "coverage", "out"]
    static let maxFiles = 8000
    static let maxBytes = 1_000_000

    static let sourceExtensions: Set<String> = ["java", "kt", "kts", "go", "swift", "ts", "tsx", "js", "jsx", "mjs",
                                                "py", "rs", "cs", "rb", "scala", "groovy", "c", "h", "cpp", "hpp", "m"]

    static func isIdentifier(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
    }

    /// Declaration patterns; `S` is replaced by the escaped symbol.
    static func patterns(for ext: String) -> [String] {
        let common = [
            #"\b(?:class|interface|enum|record|struct|protocol|extension|object|trait|actor|typealias|annotation)\s+S\b"#,
        ]
        switch ext {
        case "go":
            return [#"^func\s+(?:\([^)]*\)\s*)?S\s*[\[(]"#, #"^type\s+S\b"#, #"^\s*(?:var|const)\s+S\b"#,
                    #"^\s+S\s+(?:=|[A-Za-z*\[])"#]
        case "java", "kt", "kts", "scala", "groovy", "cs":
            return common + [#"\bfun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?S\s*\("#,
                             #"^\s*(?:@\w+\s+)*(?:(?:public|private|protected|static|final|abstract|synchronized|default|override|suspend|open|internal|async|virtual)\s+)*[\w<>\[\],.? ]+\s+S\s*\([^;]*$"#,
                             #"\b(?:val|var)\s+S\b"#]
        case "swift":
            return common + [#"\bfunc\s+S\b"#, #"\b(?:let|var)\s+S\b"#, #"\bcase\s+S\b"#]
        case "ts", "tsx", "js", "jsx", "mjs":
            return common + [#"\bfunction\*?\s+S\b"#, #"\b(?:const|let|var)\s+S\s*[=:]"#, #"\btype\s+S\b"#,
                             #"^\s*(?:public |private |protected |static |async |readonly )*S\s*(?:<[^>]*>)?\([^)]*\)\s*[:{]"#]
        case "py":
            return [#"^\s*(?:async\s+)?def\s+S\b"#, #"^\s*class\s+S\b"#, #"^S\s*="#]
        case "rs":
            return common + [#"\bfn\s+S\b"#, #"\b(?:type|const|static|mod)\s+S\b"#]
        case "rb":
            return [#"^\s*def\s+(?:self\.)?S\b"#, #"^\s*(?:class|module)\s+S\b"#]
        default:
            return common + [#"\b(?:func|function|def|fn|fun)\s+S\b"#]
        }
    }

    /// Finds declarations; results from the qualifier's package/dir and the
    /// current file's folder come first.
    static func find(symbol: String, qualifier: String?, root: String, currentFile: String?) async -> [SymbolLocation] {
        guard isIdentifier(symbol) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let rootURL = URL(fileURLWithPath: root)
            let escaped = NSRegularExpression.escapedPattern(for: symbol)
            var cache: [String: [NSRegularExpression]] = [:]
            func regexes(_ ext: String) -> [NSRegularExpression] {
                if let r = cache[ext] { return r }
                let r = patterns(for: ext).compactMap {
                    try? NSRegularExpression(pattern: $0.replacingOccurrences(of: "S", with: escaped), options: .anchorsMatchLines)
                }
                cache[ext] = r
                return r
            }
            let currentExt = currentFile.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            guard let it = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
                return []
            }
            var results: [SymbolLocation] = []
            var scanned = 0
            while let url = it.nextObject() as? URL, scanned < maxFiles, results.count < 50 {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skipped.contains(url.lastPathComponent) { it.skipDescendants() }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard sourceExtensions.contains(ext), (values?.fileSize ?? 0) < maxBytes else { continue }
                // Stay within the language family of the current file when known.
                if let ce = currentExt, sourceExtensions.contains(ce), family(ce) != family(ext) { continue }
                scanned += 1
                guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(symbol) else { continue }
                let ns = text as NSString
                var seenLines = Set<Int>()
                for regex in regexes(ext) {
                    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        let line = lineNumber(of: m.range.location, in: ns)
                        guard seenLines.insert(line).inserted else { continue }
                        let lineText = ns.substring(with: ns.lineRange(for: NSRange(location: m.range.location, length: 0)))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        // Skip comments and call sites that merely look like declarations.
                        if lineText.hasPrefix("//") || lineText.hasPrefix("*") || lineText.hasPrefix("#") || lineText.hasPrefix("return ") { continue }
                        results.append(SymbolLocation(path: String(url.path.dropFirst(rootURL.path.count + 1)),
                                                      line: line, preview: String(lineText.prefix(160))))
                    }
                }
            }
            let currentDir = currentFile.map { (($0 as NSString).deletingLastPathComponent) }
            return results.sorted { a, b in
                score(a, symbol: symbol, qualifier: qualifier, currentFile: currentFile, currentDir: currentDir)
                    > score(b, symbol: symbol, qualifier: qualifier, currentFile: currentFile, currentDir: currentDir)
            }
        }.value
    }

    static func family(_ ext: String) -> String {
        switch ext {
        case "java", "kt", "kts", "scala", "groovy": "jvm"
        case "ts", "tsx", "js", "jsx", "mjs": "js"
        case "c", "h", "cpp", "hpp", "m": "c"
        default: ext
        }
    }

    private static func score(_ l: SymbolLocation, symbol: String, qualifier: String?, currentFile: String?, currentDir: String?) -> Int {
        var s = 0
        let file = (l.path as NSString).lastPathComponent
        let dir = (l.path as NSString).deletingLastPathComponent
        if (file as NSString).deletingPathExtension == symbol { s += 50 }        // Foo.java for class Foo
        if let q = qualifier, dir.split(separator: "/").last.map(String.init) == q { s += 40 }  // Go: pkg.Func
        if let q = qualifier, file.lowercased().hasPrefix(q.lowercased()) { s += 10 }
        if l.path == currentFile { s += 30 }
        if dir == currentDir { s += 15 }
        if l.path.contains("_test.") || l.path.contains("/test/") || l.path.contains("Test.") { s -= 20 }
        return s
    }

    static func lineNumber(of location: Int, in ns: NSString) -> Int {
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        return line
    }
}
