import AppKit

/// IDE-style editing commands for the code editor. All edits go through
/// shouldChangeText/didChangeText so ⌘Z undoes each command as one step.
extension CodeTextView {
    static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]

    var ns: NSString { string as NSString }

    /// Full lines touched by the selection (a trailing newline-only selection end doesn't count).
    var selectedLinesRange: NSRange {
        var sel = selectedRange()
        if sel.length > 0, ns.length >= NSMaxRange(sel), NSMaxRange(sel) > 0,
           ns.character(at: NSMaxRange(sel) - 1) == 10 { sel.length -= 1 }
        return ns.lineRange(for: sel)
    }

    func replace(_ range: NSRange, with text: String, select newSelection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let s = newSelection { setSelectedRange(s) }
    }

    // MARK: Line comments (⌘/)

    var lineCommentPrefix: String? {
        switch language {
        case .python, .ruby, .shell, .yaml, .toml, .properties, .dockerfile, .makefile: "#"
        case .sql: "--"
        case .xml, .html, .markdown, .json, .plain, .css: nil
        default: "//"
        }
    }

    func toggleComment() {
        guard let prefix = lineCommentPrefix else { NSSound.beep(); return }
        let range = selectedLinesRange
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        let content = lines.enumerated().filter { $0.offset < lines.count - 1 || !$0.element.isEmpty }.map(\.element)
        let nonEmpty = content.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
        // Comment at the smallest indentation, like VS Code.
        let indent = nonEmpty.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let out = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented {
                guard let r = line.range(of: prefix) else { return line }
                var l = line
                l.removeSubrange(r)
                if l[r.lowerBound...].hasPrefix(" ") { l.remove(at: r.lowerBound) }
                return l
            }
            let idx = line.index(line.startIndex, offsetBy: min(indent, line.count))
            return String(line[..<idx]) + prefix + " " + String(line[idx...])
        }.joined(separator: "\n")
        replace(range, with: out, select: NSRange(location: range.location, length: (out as NSString).length - (out.hasSuffix("\n") ? 1 : 0)))
    }

    // MARK: Duplicate / move lines

    func duplicateLines() {
        let range = selectedLinesRange
        var block = ns.substring(with: range)
        if !block.hasSuffix("\n") { block = "\n" + block }   // last line without newline
        let insertAt = NSMaxRange(range)
        let sel = selectedRange()
        replace(NSRange(location: insertAt, length: 0), with: block,
                select: NSRange(location: sel.location + (block as NSString).length, length: sel.length))
    }

    func moveLines(up: Bool) {
        let range = selectedLinesRange
        let sel = selectedRange()
        if up {
            guard range.location > 0 else { return }
            let prev = ns.lineRange(for: NSRange(location: range.location - 1, length: 0))
            var block = ns.substring(with: range), prevText = ns.substring(with: prev)
            if !block.hasSuffix("\n") { block += "\n"; prevText.removeLast() }
            replace(NSRange(location: prev.location, length: prev.length + range.length), with: block + prevText,
                    select: NSRange(location: sel.location - prev.length, length: sel.length))
        } else {
            guard NSMaxRange(range) < ns.length else { return }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            var block = ns.substring(with: range), nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; block.removeLast() }
            replace(NSRange(location: range.location, length: range.length + next.length), with: nextText + block,
                    select: NSRange(location: sel.location + (nextText as NSString).length, length: sel.length))
        }
    }

    // MARK: Indent / outdent selection (Tab / ⇧Tab)

    func shiftLines(right: Bool, unit: String) {
        let range = selectedLinesRange
        let lines = ns.substring(with: range).components(separatedBy: "\n")
        let out = lines.enumerated().map { i, line -> String in
            if i == lines.count - 1 && line.isEmpty { return line }
            if right { return line.isEmpty ? line : unit + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, max(unit == "\t" ? 4 : unit.count, 1))))
        }.joined(separator: "\n")
        replace(range, with: out, select: NSRange(location: range.location, length: (out as NSString).length - (out.hasSuffix("\n") ? 1 : 0)))
    }

    // MARK: Auto-closing pairs

    /// Returns true when the keystroke was handled.
    func handlePairs(typed: String) -> Bool {
        guard autoClosePairs, typed.count == 1, let c = typed.first else { return false }
        let sel = selectedRange()
        let next: Character? = NSMaxRange(sel) < ns.length ? Character(UnicodeScalar(ns.character(at: NSMaxRange(sel)))!) : nil
        // Typing the closing char right before an identical one just steps over it.
        if sel.length == 0, let next, next == c, Self.pairs.values.contains(c) {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return true
        }
        guard let close = Self.pairs[c] else { return false }
        if sel.length > 0 {   // wrap the selection
            let inner = ns.substring(with: sel)
            replace(sel, with: "\(c)\(inner)\(close)", select: NSRange(location: sel.location + 1, length: sel.length))
            return true
        }
        // Quotes: don't pair inside words (it's → it's, not it''s).
        if c == "\"" || c == "'" || c == "`" {
            let prev: Character? = sel.location > 0 ? Character(UnicodeScalar(ns.character(at: sel.location - 1))!) : nil
            if let prev, prev.isLetter || prev.isNumber || prev == c { return false }
        }
        if let next, !(next.isWhitespace || ")]}>,;:".contains(next)) { return false }
        replace(sel, with: "\(c)\(close)", select: NSRange(location: sel.location + 1, length: 0))
        return true
    }

    /// Backspace between an empty pair removes both characters.
    func handlePairBackspace() -> Bool {
        let sel = selectedRange()
        guard autoClosePairs, sel.length == 0, sel.location > 0, sel.location < ns.length else { return false }
        let prev = Character(UnicodeScalar(ns.character(at: sel.location - 1))!)
        let next = Character(UnicodeScalar(ns.character(at: sel.location))!)
        guard Self.pairs[prev] == next else { return false }
        replace(NSRange(location: sel.location - 1, length: 2), with: "", select: NSRange(location: sel.location - 1, length: 0))
        return true
    }

    // MARK: Bracket matching

    /// Range of the bracket matching the one next to the caret, if any.
    func matchingBracket() -> (NSRange, NSRange)? {
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        let open: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        let close: [unichar: unichar] = [41: 40, 93: 91, 125: 123]
        for pos in [sel.location - 1, sel.location] where pos >= 0 && pos < ns.length {
            let ch = ns.character(at: pos)
            if let target = open[ch] {
                var depth = 0
                var i = pos
                while i < ns.length && i - pos < 20_000 {
                    let c = ns.character(at: i)
                    if c == ch { depth += 1 } else if c == target { depth -= 1; if depth == 0 { return (NSRange(location: pos, length: 1), NSRange(location: i, length: 1)) } }
                    i += 1
                }
            } else if let target = close[ch] {
                var depth = 0
                var i = pos
                while i >= 0 && pos - i < 20_000 {
                    let c = ns.character(at: i)
                    if c == ch { depth += 1 } else if c == target { depth -= 1; if depth == 0 { return (NSRange(location: i, length: 1), NSRange(location: pos, length: 1)) } }
                    i -= 1
                }
            }
        }
        return nil
    }
}
