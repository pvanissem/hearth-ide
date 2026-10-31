import AppKit
import Testing
@testable import Hearth

@MainActor
struct ChatInteractionTests {
    @Test func selectionCrossesMarkdownBlocks() {
        _ = NSApplication.shared
        let markdown = """
        ## Heading
        Paragraph with **bold** and 😀.

        - First
          - Nested

        | Area | Result |
        | --- | --- |
        | Field | A long result that wraps inside its cell without overlapping the next row. |
        | Other | Second row |

        ```swift
        let answer = 42
        ```

        Final paragraph.
        """
        for scale in [1.0, 1.8] {
            let view = NSTextView(usingTextLayoutManager: false)
            view.isEditable = false
            view.isSelectable = true
            view.textContainer!.widthTracksTextView = false
            view.textStorage!.setAttributedString(NativeMarkdownRenderer(scale: scale).render(markdown))
            for width in [340.0, 760.0] {
                view.textContainer!.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                view.layoutManager!.ensureLayout(for: view.textContainer!)
                let rect = view.layoutManager!.usedRect(for: view.textContainer!)
                #expect(rect.height.isFinite && rect.height > 100)
            }
            view.selectAll(nil)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            // TextKit 1 advertises the legacy string type; ordinary Cmd+C handles this automatically.
            let type = NSPasteboard.PasteboardType("NSStringPboardType")
            #expect(view.writeSelection(to: pasteboard, types: [type]))
            let copied = pasteboard.string(forType: type) ?? ""
            for expected in ["Heading", "Nested", "Second row", "let answer = 42", "Final paragraph.", "😀"] {
                #expect(copied.contains(expected))
            }
            let text = view.string as NSString
            let start = text.range(of: "First").location
            let end = text.range(of: "Final paragraph.").location
            view.setSelectedRange(NSRange(location: start, length: end - start))
            #expect(view.writeSelection(to: pasteboard, types: [type]))
            let partial = pasteboard.string(forType: type) ?? ""
            #expect(partial.hasPrefix("First"))
            #expect(partial.contains("let answer = 42"))
            #expect(!partial.contains("Heading"))
        }
    }

    @Test func scrollingPausesAndResumesFollowing() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let document = FlippedChatDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        scroll.documentView = document
        var following = true
        var callbacks = 0
        let tracker = ChatScrollTracking.Tracker { following = $0; callbacks += 1 }
        document.addSubview(tracker)
        window.contentView = scroll
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(!following)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let pausedCallbacks = callbacks
        document.setFrameSize(NSSize(width: 400, height: 1300))
        #expect(!following && callbacks == pausedCallbacks)
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1100))
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(following)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        tracker.disconnect()
    }
}

private final class FlippedChatDocument: NSView {
    override var isFlipped: Bool { true }
}
