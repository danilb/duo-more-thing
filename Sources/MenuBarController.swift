import AppKit

final class MenuBarController: NSObject {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let angleItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem()
    private let sourceItem = NSMenuItem()
    private var settingsWindow: SettingsWindowController?
    private var lastTitleUpdate: TimeInterval = 0

    override init() {
        super.init()

        item.button?.image = NSImage(systemSymbolName: "macbook.and.iphone",
                                     accessibilityDescription: "Duo More Thing")
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        angleItem.isEnabled = false
        menu.addItem(angleItem)
        menu.addItem(.separator())

        enabledItem.title = "Effect Enabled"
        enabledItem.action = #selector(toggleEnabled)
        enabledItem.target = self
        menu.addItem(enabledItem)

        let preview = NSMenuItem(title: "Play Animation", action: #selector(runPreview), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let tune = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        tune.target = self
        menu.addItem(tune)

        menu.addItem(.separator())

        sourceItem.action = #selector(toggleSource)
        sourceItem.target = self
        menu.addItem(sourceItem)

        let permission = NSMenuItem(title: "Grant Screen Recording…",
                                    action: #selector(requestPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        refreshStates()
    }

    private func refreshStates() {
        enabledItem.state = Settings.shared.effectEnabled ? .on : .off
        let capture = Settings.shared.useScreenCapture
        sourceItem.title = capture ? "Source: Screen Capture" : "Source: Wallpaper"
        sourceItem.state = capture ? .on : .off
    }

    func update(angle: Double, strength: Double) {
        let now = Date().timeIntervalSince1970
        if now - lastTitleUpdate > 0.12 {
            lastTitleUpdate = now
            item.button?.title = FoldController.shared.sensor.isAvailable
                ? String(format: " %.0f°", angle) : ""
        }
        var line = FoldController.shared.sensor.isAvailable
            ? String(format: "Lid angle: %.0f°   strength: %.2f", angle, strength)
            : "Lid angle sensor unavailable"
        if !AppModel.shared.sourceIsRealScreen { line += "   ⚠︎ wallpaper" }
        angleItem.title = line
        AppModel.shared.updateLive(angle: angle, strength: strength)
    }

    @objc private func toggleEnabled() {
        Settings.shared.effectEnabled.toggle()
        refreshStates()
    }

    @objc private func toggleSource() {
        Settings.shared.useScreenCapture.toggle()
        if Settings.shared.useScreenCapture && !ScreenSource.shared.hasScreenRecordingPermission {
            ScreenSource.shared.requestScreenRecordingPermission()
        }
        ScreenSource.shared.refresh()
        refreshStates()
    }

    @objc private func requestPermission() {
        ScreenSource.shared.requestScreenRecordingPermission()
    }

    @objc private func runPreview() {
        FoldController.shared.runPreview()
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.present()
    }
}
