import AppKit
import SwiftUI

/// Live state for the settings panel.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var angle: Double = 0
    @Published var strength: Double = 0
    @Published var sensorAvailable = false

    /// Current state of the image source, surfaced in the panel.
    @Published var sourceStatus: String = "nothing captured yet"
    @Published var sourceIsRealScreen = false
    @Published var lastCaptureAt: Date?
    @Published var hasScreenRecording = false

    /// Effect preview shown in the settings panel.
    @Published var previewStrength: Double = 0.35
    @Published var previewImage: NSImage?

    /// Downscaled copy of the capture — the backdrop the glass refracts.
    @Published var backdrop: NSImage?

    private var previewTimer: Timer?
    private var lastLiveUpdate: TimeInterval = 0

    private init() {}

    func updateLive(angle: Double, strength: Double) {
        let now = Date().timeIntervalSince1970
        guard now - lastLiveUpdate > 1.0 / 12.0 else { return }
        lastLiveUpdate = now
        self.angle = angle
        self.strength = strength
        let permission = ScreenSource.shared.hasScreenRecordingPermission
        if permission != hasScreenRecording { hasScreenRecording = permission }
    }

    /// Redraw the preview with a small delay so dragging a slider doesn't hammer the GPU.
    func schedulePreview() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            self?.renderPreview()
        }
    }

    func setBackdrop(_ cg: CGImage) {
        let width = 420
        let height = max(1, Int(Double(width) * Double(cg.height) / Double(cg.width)))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let small = context.makeImage() {
            backdrop = NSImage(cgImage: small, size: NSSize(width: width, height: height))
        }
    }

    func renderPreview() {
        guard let renderer = FoldController.shared.overlay.renderer, renderer.hasImage else {
            previewImage = nil
            return
        }
        let source = renderer.imageSize
        let width = 560
        let height = max(1, Int(Double(width) * source.height / max(source.width, 1)))
        var look = FoldLook.current(strength: previewStrength)
        look.strength = previewStrength
        guard let cg = renderer.renderOffscreen(width: width, height: height, look: look) else { return }
        previewImage = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
