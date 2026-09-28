import AppKit
import SwiftUI
import WebKit

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

struct WindowAccessor: NSViewRepresentable {
    let store: BrowserStore

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.acceptsMouseMovedEvents = true
            window.setFrameAutosaveName("BarcMainWindow")
            store.window = window
            MouseTracker.shared.install(store: store)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WebContainer: NSViewRepresentable {
    let session: TabSession?

    final class Container: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.white.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ webView: WKWebView?) {
            let current = subviews.first as? WKWebView
            guard current !== webView else { return }
            current?.removeFromSuperview()
            guard let webView else { return }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
    }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.show(session?.webView)
    }
}

@MainActor
final class MouseTracker {
    static let shared = MouseTracker()

    private var monitor: Any?
    private var poll: Timer?
    private weak var store: BrowserStore?
    private var swipeAccumulator: CGFloat = 0
    private var swipeFired = false
    private var revealWork: DispatchWorkItem?

    static let topBarHeight: CGFloat = 38
    static let cardInset: CGFloat = 6

    func install(store: BrowserStore) {
        guard monitor == nil else { return }
        self.store = store
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel {
                    self?.handleScroll(event)
                } else {
                    self?.evaluate()
                }
            }
            return event
        }
    }

    private func evaluate() {
        guard let store, let window = store.window, let content = window.contentView else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let inside = content.bounds.contains(point) && window.isKeyWindow
        let fromTop = content.bounds.height - point.y
        let x = point.x
        let sidebarWidth = CGFloat(store.library.sidebarWidth)
        let contentLeft = store.sidebarVisible ? sidebarWidth : 0

        if store.commandBar != nil {
            store.setTopBar(false)
        } else if store.topBarVisible {
            let keep = (inside && fromTop <= Self.topBarHeight + 16 && x >= contentLeft - 2) || hasOpenMenu()
            if !keep { store.setTopBar(false) }
        } else {
            let trigger = inside && fromTop <= Self.cardInset + 6 && x > contentLeft + 4
            if trigger {
                if revealWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.revealWork = nil
                        guard let self, let store = self.store, let window = store.window, let content = window.contentView else { return }
                        let p = window.mouseLocationOutsideOfEventStream
                        if content.bounds.height - p.y <= Self.cardInset + 12 { store.setTopBar(true) }
                    }
                    revealWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                }
            } else {
                revealWork?.cancel()
                revealWork = nil
            }
        }

        if !store.sidebarVisible {
            if store.sidebarPeek {
                let keep = inside && x <= sidebarWidth + 28
                if !keep && NSEvent.pressedMouseButtons == 0 && NSApp.modalWindow == nil && !hasOpenMenu() {
                    store.setPeek(false)
                }
            } else if inside && x <= 6 && fromTop > 4 {
                store.setPeek(true)
            }
        }

        updatePolling()
    }

    private func hasOpenMenu() -> Bool {
        NSApp.windows.contains { $0.isVisible && ($0.className.contains("Menu") || $0.className.contains("Popover")) }
    }

    private func updatePolling() {
        guard let store else { return }
        let needs = store.topBarVisible || store.sidebarPeek
        if needs, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        } else if !needs {
            poll?.invalidate()
            poll = nil
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard let store, let window = store.window, event.window === window else { return }
        let width = CGFloat(store.library.sidebarWidth)
        let sidebarOnScreen = store.sidebarVisible || store.sidebarPeek
        guard sidebarOnScreen, event.locationInWindow.x < width, event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began {
            swipeAccumulator = 0
            swipeFired = false
        }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 {
            swipeAccumulator += event.scrollingDeltaX
        }
        if !swipeFired, abs(swipeAccumulator) > 90 {
            swipeFired = true
            store.switchSpace(offset: swipeAccumulator > 0 ? -1 : 1)
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipeAccumulator = 0
            swipeFired = false
        }
    }
}
