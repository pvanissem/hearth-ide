import SwiftUI
import AppKit

/// Native multi-line chat input: newline at the caret (⇧↩/⌥↩/⌘↩), vertical scroller,
/// grows with its content up to `maxHeight`, placeholder, plain-text paste only.
struct ComposerTextView: NSViewRepresentable {
    enum Key { case submit, up, down, tab, escape }

    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var fontSize: CGFloat
    var minHeight: CGFloat = 62
    var maxHeight: CGFloat = 260
    var focusOnAppear = true
    /// Return true when the key was handled (e.g. by the slash popup).
    var onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = ComposerNSTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.onKey = { [weak coordinator = context.coordinator] key in coordinator?.parent.onKey(key) ?? false }
        scroll.documentView = view
        context.coordinator.textView = view
        apply(view, coordinator: context.coordinator)
        view.string = text
        if focusOnAppear {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window, !(window.firstResponder is NSTextView) || window.firstResponder === window else { return }
                window.makeFirstResponder(view)
            }
        }
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.textView else { return }
        apply(view, coordinator: context.coordinator)
        if !view.string.isLiterallyEqual(to: text) {
            // External change (slash completion, cleared after send, session switch).
            let caretAtEnd = view.selectedRange().location >= (view.string as NSString).length
            view.string = text
            let length = (text as NSString).length
            if caretAtEnd || view.selectedRange().location > length {
                view.setSelectedRange(NSRange(location: length, length: 0))
            }
            view.scrollRangeToVisible(view.selectedRange())
            context.coordinator.updateHeight()
        }
    }

    private func apply(_ view: ComposerNSTextView, coordinator: Coordinator) {
        let font = NSFont.systemFont(ofSize: fontSize)
        if view.font != font {
            view.font = font
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            view.defaultParagraphStyle = style
            view.typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
            view.textStorage?.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
            DispatchQueue.main.async { coordinator.updateHeight() }
        }
        view.placeholder = placeholder
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = textView, notification.object as? NSTextView === view else { return }
            if !parent.text.isLiterallyEqual(to: view.string) { parent.text = view.string }
            updateHeight()
            view.needsDisplay = true
        }

        func updateHeight() {
            guard let view = textView, let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let content = ceil(layout.usedRect(for: container).height + view.textContainerInset.height * 2)
            let target = min(max(content, parent.minHeight), parent.maxHeight)
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { [parent] in parent.height = target }
            }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onKey: ((ComposerTextView.Key) -> Bool)?
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    private var keyFlags: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { keyFlags = [] }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        let flags = keyFlags
        switch selector {
        case #selector(insertNewline(_:)):
            // ⇧/⌥/⌘↩ insert a line break at the caret; plain ↩ submits.
            if flags.contains(.shift) || flags.contains(.option) || flags.contains(.command) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if onKey?(.submit) == true { return }
        case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            insertNewlineIgnoringFieldEditor(nil)
            return
        case #selector(moveUp(_:)): if onKey?(.up) == true { return }
        case #selector(moveDown(_:)): if onKey?(.down) == true { return }
        case #selector(insertTab(_:)): if onKey?(.tab) == true { return }
        case #selector(cancelOperation(_:)): if onKey?(.escape) == true { return }
        default: break
        }
        super.doCommand(by: selector)
    }

    // Keep the input plain text even when pasting rich content.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
