import AppKit
import QuartzCore

/// Ties together the lid sensor, the screen capture and the overlay.
final class FoldController {

    static let shared = FoldController()

    let sensor = LidAngleSensor()
    let overlay = OverlayController()

    private(set) var angle: Double = 180
    private(set) var displayStrength: Double = 0
    private var targetStrength: Double = 0
    private var lastTick: CFTimeInterval?
    private var timer: Timer?

    /// Manual strength control from the settings panel (nil means the sensor drives it).
    var manualOverride: Double? {
        didSet { if manualOverride != nil { ensureImage() } }
    }

    // Pre-capture: grab the frame while the overlay is still hidden.
    private var armed = false
    private var wasActive = false
    private var previousAngle: Double = 180
    private var lastMovementAngle: Double = 180
    private var lastMovementTime: CFTimeInterval = 0
    private var lastClosingTime: CFTimeInterval = 0
    private var released = false
    private var previewStart: CFTimeInterval?
    private let previewDuration: CFTimeInterval = 2.2

    var onTick: ((Double, Double) -> Void)?   // (angle, strength)

    private init() {
        ScreenSource.shared.onImage = { [weak self] image in
            self?.overlay.setImage(image)
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            // After waking the frame is stale — refresh so the unfold shows current content.
            self?.armed = true
            ScreenSource.shared.refresh()
            _ = self
        }
    }

    func start() {
        sensor.start()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func runPreview() {
        ensureImage()
        previewStart = CACurrentMediaTime()
    }

    private func ensureImage() {
        if !overlay.hasImage || Date().timeIntervalSince(ScreenSource.shared.lastCapture) > 1.0 {
            ScreenSource.shared.refresh()
        }
    }

    // MARK: - Tick

    private func tick() {
        let settings = Settings.shared
        let now = CACurrentMediaTime()
        let dt = min(now - (lastTick ?? now - 1.0 / 60.0), 0.1)
        lastTick = now

        previousAngle = angle
        if let sensorAngle = sensor.read() { angle = sensorAngle }

        if let preview = previewStart {
            let t = (now - preview) / previewDuration
            if t >= 1 {
                previewStart = nil
                targetStrength = 0
            } else {
                // 0 -> 1 -> 0, with a pause while fully folded
                let x = t < 0.4 ? t / 0.4 : (t < 0.6 ? 1.0 : 1.0 - (t - 0.6) / 0.4)
                targetStrength = min(1, max(0, x))
            }
        } else if let manual = manualOverride {
            targetStrength = manual
        } else if settings.effectEnabled && sensor.isAvailable {
            // The lid has been still for a while — release the screen so it stays usable.
            if abs(angle - lastMovementAngle) > 1.0 {
                lastMovementAngle = angle
                lastMovementTime = now
                released = false
            } else if settings.releaseDelay < 15,
                      now - lastMovementTime > settings.releaseDelay {
                released = true
            }
            targetStrength = released ? 0 : settings.strength(forAngle: angle)

            // Arming. A fresh frame is captured once per closing motion, while the
            // overlay is still hidden — otherwise the app would capture itself.
            //
            // This keys off movement, not an absolute angle: a laptop normally sits
            // around 125° and is never opened past 140°, so a plain threshold would
            // arm once at launch and never again.
            let closing = angle - previousAngle < -0.4
            let idle = displayStrength <= 0.0005 && !overlay.isVisible
            if idle {
                if wasActive {                       // a fold cycle just finished
                    armed = false
                    wasActive = false
                }
                if closing {
                    lastClosingTime = now
                    if !armed && angle < settings.startAngle + settings.armLead {
                        armed = true
                        ScreenSource.shared.refresh(minInterval: 0.3)
                    }
                } else if now - lastClosingTime > 0.6 {
                    armed = false                    // motion stopped, ready for the next one
                }
            } else {
                wasActive = true
            }
        } else {
            targetStrength = 0
        }

        if targetStrength > 0 && !overlay.hasImage { ensureImage() }

        let factor = 1 - exp(-dt * max(settings.followSpeed, 1))
        displayStrength += (targetStrength - displayStrength) * factor
        if abs(targetStrength - displayStrength) < 0.0008 { displayStrength = targetStrength }

        overlay.update(strength: displayStrength)
        AppModel.shared.sensorAvailable = sensor.isAvailable
        onTick?(angle, displayStrength)
    }
}
