import SwiftUI
import AppKit
import Markdown

/// Colors close to OpenCode's TUI markdown theme, adapted to light/dark via system colors.
enum MarkdownStyle {
    static let heading = Color(nsColor: .systemPurple)
    static let strong = Color(nsColor: .systemOrange)
    static let emphasis = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.90, green: 0.75, blue: 0.48, alpha: 1) : NSColor(srgbRed: 0.62, green: 0.45, blue: 0.05, alpha: 1) })
    static let code = Color(nsColor: .systemGreen)
    static let link = Color(nsColor: .systemTeal)
    static let marker = Color(nsColor: .systemOrange)
    static let quote = emphasis
}

private struct MarkdownMonoKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Render Markdown in a monospaced font, like the terminal UI.
    var markdownMono: Bool {
        get { self[MarkdownMonoKey.self] }
        set { self[MarkdownMonoKey.self] = newValue }
    }
}

/// GitHub-flavoured Markdown (headings, lists, tables, quotes, code) for chat and preview.
/// Parsed with Apple's swift-markdown; code blocks use the editor's syntax highlighter.
struct MarkdownBlocks: View {
    @Environment(\.textScale) private var scale
    @Environment(\.markdownMono) private var mono
    let text: String

    var body: some View {
        if mono {
            SelectableMarkdown(text: text, scale: scale)
        } else {
            let document = Document(parsing: text)
            MarkdownChildren(children: Array(document.children), scale: scale)
                .font(.system(size: 13 * scale))
                .textSelection(.enabled)
        }
    }
}

private struct MarkdownChildren: View {
    let children: [Markup]
    let scale: Double
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing * scale) {
            ForEach(Array(children.enumerated()), id: \.offset) { _, node in
                MarkdownBlock(node: node, scale: scale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlock: View {
    @Environment(\.markdownMono) private var mono
    let node: Markup
    let scale: Double

    var body: some View {
        switch node {
        case let p as Paragraph:
            SwiftUI.Text(MarkdownInline.render(p.children, scale: scale))
                .fixedSize(horizontal: false, vertical: true)
        case let h as Heading:
            heading(h)
        case let c as CodeBlock:
            CodeBlockView(code: c.code, language: c.language, scale: scale)
        case let l as UnorderedList:
            ListView(items: Array(l.listItems), ordered: false, start: 1, scale: scale)
        case let l as OrderedList:
            ListView(items: Array(l.listItems), ordered: true, start: Int(l.startIndex), scale: scale)
        case let q as BlockQuote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(MarkdownStyle.quote.opacity(0.7)).frame(width: 3)
                MarkdownChildren(children: Array(q.children), scale: scale, spacing: 6)
                    .foregroundStyle(MarkdownStyle.quote)
            }
            .fixedSize(horizontal: false, vertical: true)
        case is ThematicBreak:
            Divider().padding(.vertical, 2)
        case let t as Markdown.Table:
            TableView(table: t, scale: scale)
        case let html as HTMLBlock:
            SwiftUI.Text(html.rawHTML.trimmingCharacters(in: .newlines))
                .font(.system(size: 12 * scale, design: .monospaced)).foregroundStyle(.secondary)
        default:
            SwiftUI.Text(node.format()).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ h: Heading) -> some View {
        let sizes: [Double] = [22, 18, 15.5, 14, 13, 13]
        let size = sizes[min(max(h.level, 1), 6) - 1] * scale
        return VStack(alignment: .leading, spacing: 4) {
            SwiftUI.Text(AttributedString(mono ? String(repeating: "#", count: h.level) + " " : "") + MarkdownInline.render(h.children, scale: scale, baseSize: size))
                .font(.system(size: mono ? 13.5 * scale : size, weight: .bold, design: mono ? .monospaced : .default))
                .foregroundStyle(MarkdownStyle.heading)
                .fixedSize(horizontal: false, vertical: true)
            if h.level <= 2 && !mono { Divider() }
        }
        .padding(.top, (h.level <= 2 ? 6 : 2) * scale)
    }
}

private struct ListView: View {
    let items: [ListItem]
    let ordered: Bool
    let start: Int
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item, index: start + i)
                        .frame(minWidth: 14 * scale, alignment: .trailing)
                    MarkdownChildren(children: Array(item.children), scale: scale, spacing: 4)
                }
            }
        }
        .padding(.leading, 4 * scale)
    }

    @ViewBuilder
    private func marker(_ item: ListItem, index: Int) -> some View {
        if let box = item.checkbox {
            Image(systemName: box == .checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(box == .checked ? Color.accentColor : .secondary)
        } else if ordered {
            SwiftUI.Text("\(index).").monospacedDigit().foregroundStyle(MarkdownStyle.marker)
        } else {
            SwiftUI.Text("•").foregroundStyle(MarkdownStyle.marker)
        }
    }
}

private struct TableView: View {
    let table: Markdown.Table
    let scale: Double

    var body: some View {
        let alignments = table.columnAlignments
        let head = Array(table.head.cells)
        let rows = table.body.rows.map { Array($0.cells) }
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(head.enumerated()), id: \.offset) { i, cell in
                    cellView(cell, bold: true, alignment: alignments[safe: i] ?? nil)
                }
            }
            .background(Color.primary.opacity(0.06))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<head.count, id: \.self) { i in
                        if let cell = row[safe: i] {
                            cellView(cell, bold: false, alignment: alignments[safe: i] ?? nil)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cellView(_ cell: Markdown.Table.Cell, bold: Bool, alignment: Markdown.Table.ColumnAlignment?) -> some View {
        let a: Alignment = alignment == .center ? .center : alignment == .right ? .trailing : .leading
        return SwiftUI.Text(MarkdownInline.render(cell.children, scale: scale))
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(bold ? MarkdownStyle.heading : Color.primary)
            .multilineTextAlignment(a == .center ? .center : a == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: a)
            .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// Fenced code with the editor's highlighter and a copy button.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let scale: Double
    private let copied = State(initialValue: false)

    var body: some View {
        let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                SwiftUI.Text(Self.highlighted(trimmed, language: language, size: 12 * scale))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    SwiftUI.Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)
                    copied.wrappedValue = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied.wrappedValue = false }
                } label: { Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
            }
            .padding(6)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    static func highlighted(_ code: String, language: String?, size: Double) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.font = .system(size: size, design: .monospaced)
        for token in Highlighter.tokens(in: code, language: Self.language(language)) {
            guard let r = Range(token.range, in: code),
                  let lower = AttributedString.Index(r.lowerBound, within: attributed),
                  let upper = AttributedString.Index(r.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = Color(nsColor: CodeEditor.color(token.kind))
        }
        return attributed
    }

    /// Maps the fence info string (```ts, ```bash …) to our languages.
    static func language(_ name: String?) -> SyntaxLanguage {
        guard let raw = name?.lowercased().split(separator: " ").first.map(String.init), !raw.isEmpty else { return .plain }
        if let l = SyntaxLanguage(rawValue: raw) { return l }
        switch raw {
        case "sh", "bash", "zsh", "console", "shell-session", "fish": return .shell
        case "docker": return .dockerfile
        case "make": return .makefile
        case "objc", "c++": return .c
        default: return SyntaxLanguage.detect(URL(fileURLWithPath: "x.\(raw)"))
        }
    }
}

/// Inline Markdown (emphasis, code, links …) as one AttributedString.
enum MarkdownInline {
    static func render(_ children: some Sequence<Markup>, scale: Double, baseSize: Double? = nil) -> AttributedString {
        var out = AttributedString()
        for child in children { out += render(child, scale: scale, baseSize: baseSize ?? 13 * scale) }
        return out
    }

    private static func render(_ node: Markup, scale: Double, baseSize: Double) -> AttributedString {
        func kids() -> AttributedString {
            var s = AttributedString()
            for c in node.children { s += render(c, scale: scale, baseSize: baseSize) }
            return s
        }
        switch node {
        case let t as Markdown.Text:
            return AttributedString(t.string)
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let c as InlineCode:
            var s = AttributedString(c.code)
            s.font = .system(size: baseSize * 0.92, design: .monospaced)
            s.foregroundColor = MarkdownStyle.code
            s.backgroundColor = Color.primary.opacity(0.05)
            return s
        case is Strong:
            var s = kids()
            s.inlinePresentationIntent = (s.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            s.foregroundColor = s.foregroundColor ?? MarkdownStyle.strong
            return s
        case is Emphasis:
            var s = kids()
            s.inlinePresentationIntent = (s.inlinePresentationIntent ?? []).union(.emphasized)
            s.foregroundColor = s.foregroundColor ?? MarkdownStyle.emphasis
            return s
        case is Strikethrough:
            var s = kids()
            s.strikethroughStyle = .single
            return s
        case let l as Markdown.Link:
            var s = kids()
            if let dest = l.destination, let url = URL(string: dest) { s.link = url }
            s.foregroundColor = MarkdownStyle.link
            s.underlineStyle = .single
            return s
        case let img as Markdown.Image:
            return AttributedString(img.plainText.isEmpty ? (img.source ?? "") : img.plainText)
        case let html as InlineHTML:
            return AttributedString(html.rawHTML)
        default:
            return kids()
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
