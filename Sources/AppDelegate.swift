import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = FoldController.shared
        guard controller.overlay.isUsable else {
            let alert = NSAlert()
            alert.messageText = "Metal is unavailable"
            alert.informativeText = "Could not create the renderer. Check that Fold.metal is present in Resources."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let bar = MenuBarController()
        menuBar = bar
        controller.onTick = { [weak bar] angle, strength in
            bar?.update(angle: angle, strength: strength)
        }
        controller.start()

        if !controller.sensor.isAvailable {
            NSLog("DuoMoreThing: no lid angle sensor found — only manual mode and preview will work)")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--image"),
           index + 1 < CommandLine.arguments.count {
            _ = ScreenSource.shared.useFixedImage(atPath: CommandLine.arguments[index + 1])
        }
        // Without Screen Recording permission only the wallpaper mode works.
        if Settings.shared.useScreenCapture && !ScreenSource.shared.hasScreenRecordingPermission {
            ScreenSource.shared.requestScreenRecordingPermission(explain: false)
        }
        // Prepare the first frame up front.
        ScreenSource.shared.refresh()

        // Debug: --hold 0.55 pins the effect strength so the lid can stay put.
        if let index = CommandLine.arguments.firstIndex(of: "--hold"),
           index + 1 < CommandLine.arguments.count,
           let value = Double(CommandLine.arguments[index + 1]) {
            FoldController.shared.manualOverride = value
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { bar.openSettings() }
        }
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                FoldController.shared.runPreview()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FoldController.shared.overlay.hide()
        FoldController.shared.sensor.stop()
    }
}
