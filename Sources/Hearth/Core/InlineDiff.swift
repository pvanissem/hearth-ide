import Foundation

/// One change block between the index (or nothing, for untracked files) and the
/// working tree, from `git diff -U0`. Line numbers are 1-based; a pure deletion
/// has `newCount == 0` and sits *after* line `newStart`.
struct DiffHunk: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case added, modified, deleted }
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let oldLines: [String]
    let newLines: [String]
    /// Raw `@@ … @@` header plus body, used to stage exactly this hunk.
    let patchBody: String
    var id: String { "\(oldStart),\(oldCount)>\(newStart),\(newCount)" }

    var kind: Kind {
        if oldCount == 0 { return .added }
        if newCount == 0 { return .deleted }
        return .modified
    }

    /// Working-tree lines covered by the hunk (empty for deletions).
    var newRange: ClosedRange<Int>? { newCount > 0 ? newStart...(newStart + newCount - 1) : nil }

    /// Line used for navigation/markers (a deletion marks the line it follows).
    var anchorLine: Int { max(1, newStart) }
}

struct FileDiff: Sendable {
    var hunks: [DiffHunk] = []
    /// Header lines (diff --git/---/+++) needed to build a patch for `git apply`.
    var header = ""
    var untracked = false
}

enum InlineDiff {
    /// Changes not yet staged: working tree vs index (untracked files: everything is new).
    static func load(file: URL, root: String) async -> FileDiff {
        guard let rel = EditorPresentation.relativePath(file, root: root) else { return FileDiff() }
        guard await Git.run(["rev-parse", "--is-inside-work-tree"], in: root) != nil else { return FileDiff() }
        let tracked = await Git.run(["ls-files", "--error-unmatch", "--", rel], in: root) != nil
        if !tracked {
            // Only untracked, non-ignored files count as new.
            guard await Git.run(["ls-files", "--others", "--exclude-standard", "--", rel], in: root)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return FileDiff() }
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let count = lines.last == "" ? lines.count - 1 : lines.count
            guard count > 0 else { return FileDiff(untracked: true) }
            let hunk = DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: count, oldLines: [],
                                newLines: Array(lines.prefix(count)), patchBody: "")
            return FileDiff(hunks: [hunk], untracked: true)
        }
        guard let out = await Git.run(["diff", "-U0", "--no-color", "--no-ext-diff", "--", rel], in: root) else { return FileDiff() }
        return parse(out)
    }

    static func parse(_ diff: String) -> FileDiff {
        var result = FileDiff()
        var headerLines: [String] = []
        var current: (o: Int, oc: Int, n: Int, nc: Int, old: [String], new: [String], raw: [String])?
        let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)

        func flush() {
            guard let c = current else { return }
            result.hunks.append(DiffHunk(oldStart: c.o, oldCount: c.oc, newStart: c.n, newCount: c.nc,
                                         oldLines: c.old, newLines: c.new, patchBody: c.raw.joined(separator: "\n") + "\n"))
            current = nil
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@") {
                flush()
                let ns = line as NSString
                guard let m = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                func num(_ i: Int, _ def: Int) -> Int {
                    m.range(at: i).location == NSNotFound ? def : Int(ns.substring(with: m.range(at: i))) ?? def
                }
                current = (num(1, 0), num(2, 1), num(3, 0), num(4, 1), [], [], [line])
            } else if current != nil {
                if line.hasPrefix("-") { current!.old.append(String(line.dropFirst())); current!.raw.append(line) }
                else if line.hasPrefix("+") { current!.new.append(String(line.dropFirst())); current!.raw.append(line) }
                else if line.hasPrefix("\\") { current!.raw.append(line) }   // "\ No newline at end of file"
            } else if !line.isEmpty {
                headerLines.append(line)
            }
        }
        flush()
        result.header = headerLines.joined(separator: "\n") + "\n"
        return result
    }

    /// Stages one hunk ("accept"), like `git add -p` for this block.
    static func stage(_ hunk: DiffHunk, of diff: FileDiff, file rel: String, root: String) async -> Git.OpResult {
        if diff.untracked { return await Git.mutate(["add", "--", rel], in: root) }
        let patch = diff.header + hunk.patchBody
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-hunk-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try patch.write(to: tmp, atomically: true, encoding: .utf8) } catch {
            return Git.OpResult(ok: false, output: error.localizedDescription)
        }
        return await Git.mutate(["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", tmp.path], in: root)
    }

    /// Text with one hunk reverted to the index version ("reject").
    static func reverting(_ hunk: DiffHunk, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1   // 0-based insert/replace position
        let end = min(lines.count, start + hunk.newCount)
        guard start >= 0, start <= lines.count else { return text }
        lines.replaceSubrange(start..<end, with: hunk.oldLines)
        return lines.joined(separator: "\n")
    }
}
