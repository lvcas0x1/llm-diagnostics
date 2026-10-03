import AppKit
import SwiftUI

/// Sizes the menu bar panel window to its content height, keeping the top edge where the panel
/// opened. MenuBarExtra grows its window when content grows but never shrinks it (content is
/// then centered in leftover space), and its own resizing moves the top edge.
struct PanelWindowSizer: NSViewRepresentable {
    /// Measured height of the panel content.
    let height: CGFloat

    func makeNSView(context: Context) -> SizerView { SizerView() }

    func updateNSView(_ view: SizerView, context: Context) {
        view.wantedHeight = height
        view.apply()
    }

    final class SizerView: NSView {
        var wantedHeight: CGFloat = 0
        private var pinnedTop: CGFloat?
        private var applying = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Selector-based observers are removed automatically when the view is deallocated.
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize),
                                                   name: NSWindow.didResizeNotification, object: window)
        }

        /// The panel is positioned under the menu bar when it opens; remember that top edge.
        @objc private func windowDidBecomeKey() {
            pinnedTop = window?.frame.maxY
            apply()
        }

        /// MenuBarExtra resized the window itself: put back our height and top edge.
        @objc private func windowDidResize() { apply() }

        func apply() {
            guard !applying, let window, wantedHeight > 1 else { return }
            let top = pinnedTop ?? window.frame.maxY
            let target = NSRect(x: window.frame.minX, y: top - wantedHeight,
                                width: window.frame.width, height: wantedHeight)
            guard abs(window.frame.height - target.height) > 0.5 || abs(window.frame.maxY - top) > 0.5 else { return }
            applying = true
            window.setFrame(target, display: true, animate: false)
            applying = false
        }
    }
}
