import SwiftUI
import AppKit

/// Observe user scrolls only: growing text and programmatic scrollTo calls must
/// not turn off following just because the document temporarily gets taller.
struct ChatScrollTracking: NSViewRepresentable {
    let onUserScroll: (Bool) -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(onUserScroll: onUserScroll) }
    func updateNSView(_ view: Tracker, context: Context) { view.onUserScroll = onUserScroll }
    static func dismantleNSView(_ view: Tracker, coordinator: ()) { view.disconnect() }

    final class Tracker: NSView {
        var onUserScroll: (Bool) -> Void
        private weak var trackedScroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var liveScroll = false

        init(onUserScroll: @escaping (Bool) -> Void) {
            self.onUserScroll = onUserScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disconnect()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }

        func disconnect() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            trackedScroll = nil
            liveScroll = false
        }

        private func connect() {
            guard window != nil, let scroll = enclosingScrollView, trackedScroll !== scroll else { return }
            trackedScroll = scroll
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.liveScroll = true
            })
            observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.report()
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.report()
                self?.liveScroll = false
            })
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Include keyboard scrolling and drag-selection autoscroll, not just wheel/trackpad.
                let event = NSApp.currentEvent?.type
                if self.liveScroll || event == .scrollWheel || event == .keyDown || event == .leftMouseDragged {
                    self.report()
                }
            })
        }

        private func report() {
            guard let scroll = trackedScroll, let document = scroll.documentView else { return }
            let visible = scroll.contentView.documentVisibleRect
            let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            let atBottom = remaining <= 24
            onUserScroll(atBottom)
        }
    }
}
