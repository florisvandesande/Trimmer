import SwiftUI
import AppKit

/// Local event routing leaves mouse scrubbing and trim gestures with SwiftUI.
struct TimelineGestures: NSViewRepresentable {
    var zoom: (Double, Double) -> Void
    var scroll: (Double) -> Void
    func makeNSView(context: Context) -> GestureView { GestureView() }
    func updateNSView(_ view: GestureView, context: Context) { view.zoom = zoom; view.scroll = scroll }
    static func dismantleNSView(_ view: GestureView, coordinator: ()) { view.removeMonitor() }

    final class GestureView: NSView {
        var zoom: ((Double, Double) -> Void)?
        var scroll: ((Double) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window || (event.window == nil && NSApp.keyWindow === window) else { return event }
                let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                guard self.bounds.contains(point) else { return event }
                if event.type == .magnify {
                    self.zoom?(exp(Double(event.magnification)), Double(point.x / max(1, self.bounds.width)))
                } else {
                    let delta = abs(event.scrollingDeltaX) > 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                    self.scroll?(-Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 10))
                }
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { removeMonitor() }
    }
}
