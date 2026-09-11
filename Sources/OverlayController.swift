import AppKit
import MetalKit

/// A full-screen overlay above the entire interface on the built-in display.
final class OverlayController {

    private var window: NSWindow?
    private var metalView: MTKView?
    let renderer: FoldRenderer?

    private(set) var isVisible = false

    init() {
        renderer = FoldRenderer(pixelFormat: .bgra8Unorm)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.layoutToScreen() }
    }

    var isUsable: Bool { renderer != nil }

    // MARK: - Window

    private func makeWindowIfNeeded() {
        guard window == nil, let renderer, let screen = ScreenSource.builtInScreen else { return }

        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true                 // drawn manually on every sensor update
        view.enableSetNeedsDisplay = false
        view.delegate = renderer
        view.layer?.isOpaque = true
        view.autoResizeDrawable = true

        let w = NSWindow(contentRect: screen.frame,
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false,
                         screen: screen)
        w.contentView = view
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isMovable = false
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // .readOnly so the effect shows up in screen recordings and screenshots (for demos).
        // Our own frame is captured before the overlay appears, and SCContentFilter excludes it.
        w.sharingType = .readOnly
        w.animationBehavior = .none
        w.alphaValue = 1

        window = w
        metalView = view
    }

    private func layoutToScreen() {
        guard let window, let screen = ScreenSource.builtInScreen else { return }
        window.setFrame(screen.frame, display: false)
    }

    // MARK: - API

    func setImage(_ cg: CGImage) {
        renderer?.setImage(cg)
    }

    var hasImage: Bool { renderer?.hasImage ?? false }

    /// Main entry point: effect strength, 0…1.
    func update(strength: Double) {
        let s = max(0, min(1, strength))
        guard let renderer else { return }

        if s <= 0.0005 {
            hide()
            return
        }

        makeWindowIfNeeded()
        guard let window, let metalView else { return }

        renderer.look = FoldLook.current(strength: s)

        if !isVisible {
            layoutToScreen()
            window.orderFrontRegardless()
            isVisible = true
        }
        metalView.draw()
    }

    func hide() {
        guard isVisible, let window else { return }
        window.orderOut(nil)
        isVisible = false
    }
}
