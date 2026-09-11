import AppKit
import ScreenCaptureKit

/// Image source for the overlay: a screenshot (ScreenCaptureKit) or the wallpaper.
///
/// The screenshot is taken BEFORE the overlay appears (on "arming", as soon as the
/// lid starts moving down), so the overlay never ends up in its own frame.
final class ScreenSource {
    static let shared = ScreenSource()

    private(set) var image: CGImage?
    private(set) var lastCapture: Date = .distantPast
    private var isCapturing = false

    var onImage: ((CGImage) -> Void)?

    // MARK: - Built-in display

    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            CGDisplayIsBuiltin(displayID(of: screen)) != 0
        } ?? NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    // MARK: - Permissions

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// explain=false: only the system prompt (used at launch).
    /// explain=true: plus our own alert with the route into System Settings (from the menu).
    func requestScreenRecordingPermission(explain: Bool = true) {
        let granted = CGRequestScreenCaptureAccess()
        if !granted && explain {
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission required"
            alert.informativeText = """
            System Settings → Privacy & Security → Screen & System Audio Recording → enable Duo More Thing.
            Without it the app falls back to showing your wallpaper.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Debug: use a fixed image as the source instead of capturing the screen.
    /// Used to produce the demo shots in the README without exposing a real desktop.
    func useFixedImage(atPath path: String) -> Bool {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        fixedImage = cg
        adopt(cg, real: true, note: "demo image")
        return true
    }

    private var fixedImage: CGImage?

    // MARK: - Capture

    /// Refreshes the image. minInterval guards against capturing too often.
    func refresh(minInterval: TimeInterval = 0.0) {
        guard !isCapturing else { return }
        guard Date().timeIntervalSince(lastCapture) >= minInterval else { return }
        guard let screen = ScreenSource.builtInScreen else { return }
        if let fixedImage {
            adopt(fixedImage, real: true, note: "demo image")
            return
        }

        if Settings.shared.useScreenCapture && hasScreenRecordingPermission {
            isCapturing = true
            let targetID = ScreenSource.displayID(of: screen)
            let scale = screen.backingScaleFactor
            Task { @MainActor in
                defer { self.isCapturing = false }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == targetID })
                            ?? content.displays.first else {
                        self.useWallpaper(for: screen); return
                    }
                    // Exclude our own overlay window in case it happens to be visible.
                    let mine = content.windows.filter {
                        $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: mine)
                    let config = SCStreamConfiguration()
                    config.width = Int(CGFloat(display.width) * scale)
                    config.height = Int(CGFloat(display.height) * scale)
                    config.showsCursor = false
                    config.captureResolution = .best
                    let shot = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: config)
                    self.adopt(shot, real: true,
                               note: "screen capture \(shot.width)×\(shot.height)")
                } catch {
                    NSLog("DuoMoreThing: capture failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        AppModel.shared.sourceStatus = "capture failed: \(error.localizedDescription)"
                    }
                    self.useWallpaper(for: screen)
                }
            }
        } else {
            useWallpaper(for: screen)
        }
    }

    private func adopt(_ cg: CGImage, real: Bool, note: String) {
        image = cg
        lastCapture = Date()
        onImage?(cg)
        DispatchQueue.main.async {
            AppModel.shared.sourceIsRealScreen = real
            AppModel.shared.lastCaptureAt = Date()
            AppModel.shared.sourceStatus = note
            AppModel.shared.hasScreenRecording = CGPreflightScreenCaptureAccess()
            AppModel.shared.setBackdrop(cg)
            AppModel.shared.renderPreview()
        }
    }

    // MARK: - Fallback: desktop wallpaper

    /// The desktop picture, aspect-filled to the given screen (built-in if nil).
    static func desktopWallpaperImage(for screen: NSScreen? = nil) -> CGImage? {
        guard let screen = screen ?? builtInScreen else { return nil }
        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                               height: screen.frame.height * screen.backingScaleFactor)
        var source: CGImage?
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            source = cg
        }
        guard let context = CGContext(data: nil,
                                      width: Int(pixelSize.width),
                                      height: Int(pixelSize.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))
        if let source {
            let sw = CGFloat(source.width), sh = CGFloat(source.height)
            let scale = max(pixelSize.width / sw, pixelSize.height / sh)
            let w = sw * scale, h = sh * scale
            context.draw(source, in: CGRect(x: (pixelSize.width - w) / 2,
                                            y: (pixelSize.height - h) / 2,
                                            width: w, height: h))
        }
        return context.makeImage()
    }

    private func useWallpaper(for screen: NSScreen) {
        guard let cg = ScreenSource.desktopWallpaperImage(for: screen) else { return }
        let reason = Settings.shared.useScreenCapture
            ? "no Screen Recording permission — showing the wallpaper instead"
            : "source switched to wallpaper"
        adopt(cg, real: false, note: reason)
    }
}
