import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Hearth

@MainActor
struct ComposerInputTests {
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw SandboxGitRunner.Failure(message) }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func newlineAtCaretSubmitAndScrolling() async throws {
        _ = NSApplication.shared
        final class Box { var text = "erste Zeile\nzweite Zeile"; var height: CGFloat = 62; var keys: [ComposerTextView.Key] = []; var popup = false }
        let box = Box()
        func view() -> AnyView {
            AnyView(ComposerTextView(text: Binding(get: { box.text }, set: { box.text = $0 }),
                                     height: Binding(get: { box.height }, set: { box.height = $0 }),
                                     placeholder: "Eingabe", fontSize: 14,
                                     onKey: { key in
                                         box.keys.append(key)
                                         return key == .submit || (box.popup && (key == .up || key == .down))
                                     })
                .frame(width: 400, height: box.height))
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 420, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: view())
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        let text = try { () throws -> ComposerNSTextView in
            guard let t = find(ComposerNSTextView.self, in: host) else { throw SandboxGitRunner.Failure("No native composer") }
            return t
        }()
        window.makeFirstResponder(text)
        try require(text.enclosingScrollView?.hasVerticalScroller == true, "Composer has no vertical scroller")

        // Caret after "erste Zeile": ⇧↩ must split there, not append at the end.
        text.setSelectedRange(NSRange(location: 11, length: 0))
        text.keyDown(with: key("\r", code: 36, flags: .shift, window: window))
        try require(box.text == "erste Zeile\n\nzweite Zeile", "⇧↩ not inserted at caret: \(box.text.debugDescription)")
        try require(text.selectedRange().location == 12 && box.keys.isEmpty, "Caret/submit wrong after ⇧↩")
        text.insertText("neu", replacementRange: text.selectedRange())
        try require(box.text == "erste Zeile\nneu\nzweite Zeile", "Typing after ⇧↩ not at caret")
        text.keyDown(with: key("\r", code: 36, flags: .option, window: window))
        try require(box.text.components(separatedBy: "\n").count == 4 && box.keys.isEmpty, "⌥↩ newline")

        // Plain ↩ submits without inserting a newline.
        let before = box.text
        text.keyDown(with: key("\r", code: 36, window: window))
        try require(box.keys == [.submit] && box.text == before, "↩ did not submit / inserted text")

        // Arrow keys move the caret unless the slash popup consumes them.
        box.keys = []
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [.numericPad, .function], window: window))
        try require(box.keys == [.down] && text.selectedRange().location > 0, "Down arrow should move caret without popup")
        box.popup = true
        let caret = text.selectedRange().location
        text.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [.numericPad, .function], window: window))
        try require(text.selectedRange().location == caret, "Popup navigation moved caret")

        // Long input: height capped, content scrollable.
        box.text = (1...80).map { "Zeile \($0)" }.joined(separator: "\n")
        host.rootView = view()
        try await Task.sleep(for: .milliseconds(150))
        host.rootView = view()
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try { () throws -> NSScrollView in
            guard let s = text.enclosingScrollView else { throw SandboxGitRunner.Failure("No scroll view") }
            return s
        }()
        try require(box.height == 260, "Height not capped: \(box.height)")
        try require(text.frame.height > scroll.contentView.bounds.height + 100, "Long text not scrollable")

        // Cleared after sending: shrinks back.
        box.text = ""
        host.rootView = view()
        try await Task.sleep(for: .milliseconds(150))
        try require(text.string.isEmpty && box.height == 62, "Composer did not reset after send")
    }
}
