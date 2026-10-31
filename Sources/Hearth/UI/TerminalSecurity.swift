import AppKit
import SwiftTerm

/// LocalProcessTerminalView's OSC 52 methods are public, not open, so overriding
/// them in a subclass cannot enforce a policy. Interpose the terminal delegate;
/// forward PTY I/O/resize events, but never delegate process-triggered clipboard access.
@MainActor
final class TerminalSecurity: TerminalViewDelegate {
    weak var processView: LocalProcessTerminalView?

    init(_ view: LocalProcessTerminalView) { processView = view }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        processView?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { processView?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { processView?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { processView?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { processView?.scrolled(source: source, position: position) }
    func bell(source: TerminalView) { processView?.bell(source: source) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { processView?.iTermContent(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { processView?.rangeChanged(source: source, startY: startY, endY: endY) }
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) { processView?.programStatusChanged(source: source, records: records) }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    // OSC 52: completely deny both directions. Explicit user Cmd+C/Cmd+V remain native actions.
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {}

    // OSC 5522: never return nil/unsupported (those values allow platform clipboard fallback).
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { [] }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { .denied }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .denied }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
}
