import Foundation
import SwiftUI

/// Every parameter of the effect. Persisted in UserDefaults, edited in the settings panel.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: - Lid angles

    /// Angle where the effect starts (degrees).
    @Published var startAngle: Double { didSet { save(startAngle, "startAngle") } }
    /// Angle where the fold is complete.
    @Published var endAngle: Double { didSet { save(endAngle, "endAngle") } }
    /// How many degrees ahead of the start angle the screenshot is taken.
    @Published var armLead: Double { didSet { save(armLead, "armLead") } }
    /// How quickly the effect follows the sensor.
    @Published var followSpeed: Double { didSet { save(followSpeed, "followSpeed") } }
    /// Seconds of a motionless lid before the effect releases the screen. 15 or more means never.
    @Published var releaseDelay: Double { didSet { save(releaseDelay, "releaseDelay") } }

    // MARK: - Blur

    /// Maximum blur radius: 2^maxLod pixels.
    @Published var maxLod: Double { didSet { save(maxLod, "maxLod") } }
    /// How fast the FAR edge blurs. Below 1 it blurs immediately — a snappy onset.
    @Published var topCurve: Double { didSet { save(topCurve, "topCurve") } }
    /// How fast the edge AT THE HINGE blurs. Above 1 it stays sharp much longer.
    @Published var hingeCurve: Double { didSet { save(hingeCurve, "hingeCurve") } }
    /// Shape of the gradient between the hinge and the far edge.
    @Published var shape: Double { didSet { save(shape, "shape") } }

    // MARK: - Shadow

    @Published var darkness: Double { didSet { save(darkness, "darkness") } }
    @Published var darkStart: Double { didSet { save(darkStart, "darkStart") } }

    // MARK: - 3D

    /// Maximum tilt of the panel in degrees at a full fold.
    @Published var tiltAngle: Double { didSet { save(tiltAngle, "tiltAngle") } }
    /// Easing curve of the tilt.
    @Published var tiltCurve: Double { didSet { save(tiltCurve, "tiltCurve") } }
    /// Camera distance: smaller means stronger perspective.
    @Published var depth: Double { didSet { save(depth, "depth") } }

    // MARK: - Misc

    @Published var useScreenCapture: Bool { didSet { save(useScreenCapture, "useScreenCapture") } }
    @Published var effectEnabled: Bool { didSet { save(effectEnabled, "effectEnabled") } }

    private init() {
        func number(_ key: String, _ fallback: Double) -> Double {
            UserDefaults.standard.object(forKey: key) == nil
                ? fallback : UserDefaults.standard.double(forKey: key)
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil
                ? fallback : UserDefaults.standard.bool(forKey: key)
        }
        startAngle = number("startAngle", 100)
        endAngle = number("endAngle", 18)
        armLead = number("armLead", 20)
        followSpeed = number("followSpeed", 26)
        releaseDelay = number("releaseDelay", 2.5)
        maxLod = number("maxLod", 7.2)
        topCurve = number("topCurve", 0.45)
        hingeCurve = number("hingeCurve", 4.5)
        shape = number("shape", 1.6)
        darkness = number("darkness", 0.97)
        darkStart = number("darkStart", 0.45)
        tiltAngle = number("tiltAngle", 38)
        tiltCurve = number("tiltCurve", 1.3)
        depth = number("depth", 2.2)
        useScreenCapture = flag("useScreenCapture", true)
        effectEnabled = flag("effectEnabled", true)
    }

    private func save(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }
    private func save(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }

    func resetEffectParameters() {
        for key in ["maxLod", "topCurve", "hingeCurve", "shape", "darkness", "darkStart",
                    "tiltAngle", "tiltCurve", "depth", "startAngle", "endAngle",
                    "armLead", "followSpeed", "releaseDelay"] {
            defaults.removeObject(forKey: key)
        }
        startAngle = 100; endAngle = 18; armLead = 20; followSpeed = 26; releaseDelay = 2.5
        maxLod = 7.2; topCurve = 0.45; hingeCurve = 4.5; shape = 1.6
        darkness = 0.97; darkStart = 0.45
        tiltAngle = 38; tiltCurve = 1.3; depth = 2.2
    }

    /// Lid angle to effect strength, 0…1.
    func strength(forAngle angle: Double) -> Double {
        let start = max(startAngle, endAngle + 1)
        if angle >= start { return 0 }
        if angle <= endAngle { return 1 }
        return (start - angle) / (start - endAngle)
    }
}
