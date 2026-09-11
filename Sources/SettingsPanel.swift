import SwiftUI
import AppKit
import Combine

// MARK: - Panel

struct SettingsPanel: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    preview
                    backgroundCard

                    card("Lid angles") {
                        param("Effect starts at", $settings.startAngle, 30...170) { "\(Int($0))°" }
                        param("Fully folded at", $settings.endAngle, 5...120) { "\(Int($0))°" }
                        param("Capture ahead by", $settings.armLead, 5...60) { "\(Int($0))°" }
                        param("Follow speed", $settings.followSpeed, 4...60) { String(format: "%.0f", $0) }
                        param("Release slight fold", $settings.releaseDelay, 0.5...15) {
                            $0 >= 15 ? "never" : String(format: "%.1f s", $0)
                        }
                    }

                    card("Blur") {
                        param("Max blur", $settings.maxLod, 2...9) { "\(Int(pow(2, $0))) px" }
                        param("Far edge onset", $settings.topCurve, 0.15...2) { String(format: "%.2f", $0) }
                        param("Hinge sharpness", $settings.hingeCurve, 1...9) { String(format: "%.1f", $0) }
                        param("Gradient shape", $settings.shape, 0.3...4) { String(format: "%.2f", $0) }
                    }

                    card("3D fold") {
                        param("Panel tilt", $settings.tiltAngle, 0...70) { "\(Int($0))°" }
                        param("Tilt curve", $settings.tiltCurve, 0.3...3) { String(format: "%.2f", $0) }
                        param("Perspective", $settings.depth, 0.8...6) { String(format: "%.1f", $0) }
                        param("Side fade", $settings.sideFade, 0...2.5) { String(format: "%.2f", $0) }
                    }

                    card("Shadow") {
                        param("Depth", $settings.darkness, 0...1) { String(format: "%.2f", $0) }
                        param("Starts at", $settings.darkStart, 0...0.95) { String(format: "%.2f", $0) }
                    }

                    HStack(spacing: 10) {
                        Button("Play animation") { FoldController.shared.runPreview() }
                            .buttonStyle(.glassProminent)
                        Button("Reset") {
                            settings.resetEffectParameters()
                            AppModel.shared.schedulePreview()
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
        }
        .background { backdrop }
        .overlay(alignment: .top) { titlebarDragStrip }
        .frame(minWidth: 640, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    /// Clicks in the transparent titlebar (to the right of the traffic lights)
    /// still move the window. The rest of the panel must not — otherwise every
    /// slider drag turns into a window drag.
    private var titlebarDragStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .frame(height: 52)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// A blurred screen capture behind the glass — glass needs something to refract.
    private var backdrop: some View {
        ZStack {
            Color.black
            if let image = model.backdrop {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 44, opaque: true)
            }
            LinearGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: Status

    private var status: some View {
        card("Status") {
            HStack(spacing: 14) {
                pill(model.sensorAvailable ? "sensor \(Int(model.angle))°" : "no sensor",
                     ok: model.sensorAvailable)
                pill(model.sourceIsRealScreen ? "live screen" : "wallpaper",
                     ok: model.sourceIsRealScreen)
                Spacer()
                Toggle("Effect", isOn: $settings.effectEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(model.sourceStatus + captureAge)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.sourceIsRealScreen {
                HStack(spacing: 10) {
                    Button("Grant Screen Recording") {
                        ScreenSource.shared.requestScreenRecordingPermission()
                        ScreenSource.shared.refresh()
                    }
                    .buttonStyle(.glassProminent)
                    Button("Refresh capture") { ScreenSource.shared.refresh() }
                        .buttonStyle(.glass)
                }
                Text("If no system prompt appears: System Settings → Privacy & Security → "
                     + "Screen & System Audio Recording → Duo More Thing. Launch the app from Finder or "
                     + "Spotlight: started from a terminal, it asks for the permission on behalf "
                     + "of its parent process. Restart the app after granting.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shows how long ago the frozen frame was taken — makes a stale capture obvious.
    private var captureAge: String {
        guard let at = model.lastCaptureAt else { return "" }
        let seconds = Int(Date().timeIntervalSince(at))
        return seconds < 1 ? " · just now" : " · \(seconds)s ago"
    }

    // MARK: Preview

    private var preview: some View {
        card("Preview") {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.6))
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("no frame yet — hit “Refresh capture”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)

            HStack {
                Text("Folded by")
                    .frame(width: 110, alignment: .leading)
                MacSlider(value: $model.previewStrength, range: 0...1) {
                    AppModel.shared.schedulePreview()
                }
                Text("\(Int(model.previewStrength * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // MARK: Room background

    private var backgroundCard: some View {
        card("Background") {
            HStack {
                Toggle("Room behind the fold", isOn: $settings.useEnvironmentBackground)
                    .toggleStyle(.switch)
                Spacer()
            }
            Text(settings.useEnvironmentBackground
                 ? model.environmentStatus
                 : "off — the fold recedes into black")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.useEnvironmentBackground {
                Text("The FaceTime camera photographs the room; the person is removed on-device and the blurred room sits behind the folding screen. Without camera permission the desktop wallpaper is used instead.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let image = model.environmentPreview {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 10) {
                    if !model.hasCameraPermission {
                        Button("Grant Camera") {
                            EnvironmentSource.shared.requestPermission(explain: true)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button("Recapture room") {
                        EnvironmentSource.shared.refresh()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func param(_ title: String, _ value: Binding<Double>,
                       _ range: ClosedRange<Double>,
                       _ format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)
            MacSlider(value: value, range: range) {
                AppModel.shared.schedulePreview()
            }
            Text(format(value.wrappedValue))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func pill(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(ok ? .green.opacity(0.35) : .orange.opacity(0.4)),
                         in: .capsule)
    }
}

// MARK: - AppKit slider

/// SwiftUI `Slider` is not an `NSControl`, so with a movable-background window
/// AppKit treats the drag as “move the window”. A real `NSSlider` keeps the
/// mouse for itself.
private struct MacSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onChanging: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value,
                              minValue: range.lowerBound,
                              maxValue: range.upperBound,
                              target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if abs(slider.doubleValue - value) > 0.0001 {
            slider.doubleValue = value
        }
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 120,
               height: max(nsView.intrinsicContentSize.height, 16))
    }

    final class Coordinator: NSObject {
        var parent: MacSlider
        init(_ parent: MacSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            parent.value = sender.doubleValue
            parent.onChanging()
        }
    }
}

private final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Window

final class SettingsWindowController: NSWindowController {
    private var cancellable: AnyCancellable?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Duo More Thing"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = SettingsHostingView(rootView: SettingsPanel())
        self.init(window: window)

        // Any settings change redraws the preview.
        cancellable = Settings.shared.objectWillChange.sink { _ in
            AppModel.shared.schedulePreview()
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if Settings.shared.useEnvironmentBackground, EnvironmentSource.shared.image == nil {
            EnvironmentSource.shared.refresh()
        }
        AppModel.shared.renderPreview()
    }
}
