import Foundation

/// A Mermaid diagram found in the workspace: a whole `.mmd` file or a
/// ```mermaid fenced block inside Markdown.
struct MermaidDiagram: Identifiable, Hashable, Codable, Sendable {
    let file: String
    let index: Int
    let title: String
    let source: String
    let line: Int
    var id: String { "\(file)#\(index)" }

    var kind: String {
        let first = source.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("%%") }
        return first.map { String($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") } ?? ""
    }
}

enum MermaidScanner {
    static let skipped: Set<String> = [".git", "node_modules", ".build", "target", "build", "dist", "vendor", ".gradle", ".venv", ".idea"]
    static let maxBytes = 512_000

    static func scan(root: String) async -> [MermaidDiagram] {
        await Task.detached(priority: .utility) {
            let rootURL = URL(fileURLWithPath: root)
            guard let it = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
                return []
            }
            var result: [MermaidDiagram] = []
            while let url = it.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skipped.contains(url.lastPathComponent) { it.skipDescendants() }
                    continue
                }
                guard (values?.fileSize ?? 0) < maxBytes else { continue }
                let ext = url.pathExtension.lowercased()
                guard ["mmd", "mermaid", "md", "markdown"].contains(ext),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rel = String(url.path.dropFirst(rootURL.path.count + 1))
                if ext == "mmd" || ext == "mermaid" {
                    result.append(MermaidDiagram(file: rel, index: 0, title: url.deletingPathExtension().lastPathComponent,
                                                 source: text, line: 1))
                } else {
                    result += blocks(in: text, file: rel)
                }
            }
            // Architecture docs first, then by path.
            return result.sorted {
                (rank($0.file), $0.file, $0.index) < (rank($1.file), $1.file, $1.index)
            }
        }.value
    }

    static func rank(_ file: String) -> Int {
        let f = file.lowercased()
        if f.contains("architect") { return 0 }
        if f.hasPrefix("docs/") { return 1 }
        return 2
    }

    /// Extracts ```mermaid blocks; the nearest preceding heading becomes the title.
    static func blocks(in text: String, file: String) -> [MermaidDiagram] {
        var out: [MermaidDiagram] = []
        var heading = (file as NSString).lastPathComponent
        var inBlock = false
        var start = 0
        var buffer: [Substring] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if trimmed.hasPrefix("```") {
                    out.append(MermaidDiagram(file: file, index: out.count, title: heading,
                                              source: buffer.joined(separator: "\n"), line: start))
                    inBlock = false
                } else {
                    buffer.append(line)
                }
            } else if trimmed.hasPrefix("```mermaid") {
                inBlock = true
                start = i + 1
                buffer = []
            } else if trimmed.hasPrefix("#") {
                heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }
}
