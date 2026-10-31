import SwiftUI
import AppKit
import Markdown

/// One TextKit document per Markdown message, not one selection surface per block.
/// The outer chat ScrollView owns scrolling; this view reports its wrapped text height.
struct SelectableMarkdown: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let scale: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.clipsToBounds = true
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        let cache = context.coordinator
        guard !(cache.text?.isLiterallyEqual(to: text) ?? false) || cache.scale != scale || cache.scheme != colorScheme else { return }
        cache.text = text; cache.scale = scale; cache.scheme = colorScheme
        let selection = view.selectedRanges
        view.textStorage?.setAttributedString(NativeMarkdownRenderer(scale: scale).render(text))
        // Streaming/theme updates must not throw away a selection or steal keyboard focus.
        let length = (view.string as NSString).length
        view.selectedRanges = selection.map {
            let r = $0.rangeValue
            let location = min(r.location, length)
            return NSValue(range: NSRange(location: location, length: min(r.length, length - location)))
        }
        view.invalidateIntrinsicContentSize()
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.measuredWidth
        guard width.isFinite, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }

    final class Coordinator {
        var text: String?
        var scale: Double?
        var scheme: ColorScheme?
    }
}

/// NSTextView doesn't reliably invalidate SwiftUI's cached height when read-only
/// text grows or a pane is resized. Measure against both proposals and actual width.
final class MarkdownTextView: NSTextView {
    private(set) var measuredWidth: CGFloat = 600
    func measuredSize(width: CGFloat) -> CGSize {
        measuredWidth = max(1, width)
        guard let container = textContainer, let layout = layoutManager else { return CGSize(width: width, height: 1) }
        container.containerSize = NSSize(width: measuredWidth, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).maxY + textContainerInset.height * 2))
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredSize(width: measuredWidth).height)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, abs(newSize.width - measuredWidth) > 0.5 {
            _ = measuredSize(width: newSize.width)
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }
}

/// Produces native paragraphs and text-table cells in one attributed string. No HTML,
/// web content, or text attachments: selection and copy include the actual cell/code text.
struct NativeMarkdownRenderer {
    let scale: Double
    private var size: CGFloat { 12.5 * scale }
    private var font: NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    private var emphasis: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.90, green: 0.75, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.45, blue: 0.05, alpha: 1) }
    }

    func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for node in Document(parsing: markdown).children { output.append(block(node)) }
        return output
    }

    private func plain(_ text: String, font: NSFont? = nil, color: NSColor = .labelColor) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: [.font: font ?? self.font, .foregroundColor: color])
    }

    private func paragraph(_ text: NSAttributedString, indent: CGFloat = 0, spacing: CGFloat = 8) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.append(plain("\n"))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing * scale
        style.lineSpacing = 2 * scale
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    private func inline(_ children: some Sequence<Markup>, bold: Bool = false, italic: Bool = false) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: "")
        let baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        let styledFont = italic ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask) : baseFont
        let color: NSColor = bold ? .systemOrange : italic ? emphasis : .labelColor
        for node in children {
            switch node {
            case let text as Markdown.Text: out.append(plain(text.string, font: styledFont, color: color))
            case is SoftBreak: out.append(plain(" "))
            case is LineBreak: out.append(plain("\n"))
            case is Strong: out.append(inline(node.children, bold: true, italic: italic))
            case is Emphasis: out.append(inline(node.children, bold: bold, italic: true))
            case let code as InlineCode:
                let part = plain(code.code, color: .systemGreen)
                part.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.05), range: NSRange(location: 0, length: part.length))
                out.append(part)
            case let link as Markdown.Link:
                let part = inline(link.children, bold: bold, italic: italic)
                if let destination = link.destination, let url = URL(string: destination),
                   ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    part.addAttributes([.link: url, .foregroundColor: NSColor.systemTeal,
                                        .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 0, length: part.length))
                }
                out.append(part)
            case is Strikethrough:
                let part = inline(node.children, bold: bold, italic: italic)
                part.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: part.length))
                out.append(part)
            case let image as Markdown.Image: out.append(plain(image.plainText.isEmpty ? image.source ?? "" : image.plainText))
            case let html as InlineHTML: out.append(plain(html.rawHTML))
            default: out.append(inline(node.children, bold: bold, italic: italic))
            }
        }
        return out
    }

    private func block(_ node: Markup, indent: CGFloat = 0) -> NSMutableAttributedString {
        switch node {
        case let p as Paragraph: return paragraph(inline(p.children), indent: indent)
        case let h as Heading:
            let text = plain(String(repeating: "#", count: h.level) + " ", color: .systemPurple)
            text.append(inline(h.children))
            text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13.5 * scale, weight: .bold),
                                .foregroundColor: NSColor.systemPurple], range: NSRange(location: 0, length: text.length))
            return paragraph(text, indent: indent, spacing: 10)
        case let list as UnorderedList: return listItems(Array(list.listItems), start: nil, indent: indent)
        case let list as OrderedList: return listItems(Array(list.listItems), start: Int(list.startIndex), indent: indent)
        case let quote as BlockQuote:
            let out = NSMutableAttributedString(string: "")
            for child in quote.children { out.append(block(child, indent: indent + 16 * scale)) }
            out.addAttribute(.foregroundColor, value: emphasis, range: NSRange(location: 0, length: out.length))
            return out
        case let code as CodeBlock:
            let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            let rendered = plain(text)
            for token in Highlighter.tokens(in: text, language: CodeBlockView.language(code.language)) {
                rendered.addAttribute(.foregroundColor, value: CodeEditor.color(token.kind), range: token.range)
            }
            let result = paragraph(rendered, indent: indent + 8 * scale, spacing: 0)
            result.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.05), range: NSRange(location: 0, length: result.length))
            return result
        case let table as Markdown.Table: return textTable(table, indent: indent)
        case is ThematicBreak: return paragraph(plain("────────────────────", color: .separatorColor), indent: indent)
        case let html as HTMLBlock: return paragraph(plain(html.rawHTML), indent: indent)
        default:
            let out = NSMutableAttributedString(string: "")
            for child in node.children { out.append(block(child, indent: indent)) }
            return out
        }
    }

    private func listItems(_ items: [ListItem], start: Int?, indent: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: "")
        for (index, item) in items.enumerated() {
            let marker = item.checkbox.map { $0 == .checked ? "☑ " : "☐ " } ?? start.map { "\($0 + index). " } ?? "• "
            var first = true
            for child in item.children {
                if first, let p = child as? Paragraph {
                    let text = plain(marker, color: .systemOrange)
                    text.append(inline(p.children))
                    let para = paragraph(text, indent: indent, spacing: 4)
                    let style = (para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                    style.headIndent = indent + (marker as NSString).size(withAttributes: [.font: font]).width
                    para.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: para.length))
                    out.append(para)
                } else {
                    out.append(block(child, indent: indent + 18 * scale))
                }
                first = false
            }
        }
        return out
    }

    private func textTable(_ node: Markdown.Table, indent: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: "")
        let head = Array(node.head.cells)
        guard !head.isEmpty else { return out }
        let table = NSTextTable()
        table.numberOfColumns = head.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let rows = [head] + node.body.rows.map { Array($0.cells) }
        for (r, row) in rows.enumerated() {
            for c in 0..<head.count {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(head.count), type: .percentageValueType)
                cell.setWidth(6 * scale, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.verticalAlignment = NSTextBlock.VerticalAlignment(rawValue: 0)! // top; the Swift case name differs between SDKs
                if r == 0 { cell.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06) }
                let text = c < row.count ? inline(row[c].children) : plain("")
                if r == 0 {
                    text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                                        .foregroundColor: NSColor.systemPurple], range: NSRange(location: 0, length: text.length))
                }
                let para = paragraph(text, indent: indent, spacing: 0)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                style.lineSpacing = 2 * scale
                let alignment = c < node.columnAlignments.count ? node.columnAlignments[c] : nil
                style.alignment = alignment == .center ? .center : alignment == .right ? .right : .left
                para.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: para.length))
                out.append(para)
            }
        }
        out.append(paragraph(plain(""), spacing: 4))
        return out
    }
}
