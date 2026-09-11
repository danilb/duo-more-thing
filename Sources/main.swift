import AppKit

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--render-test") {
    let outputDir = index + 1 < arguments.count ? arguments[index + 1] : "./render-test"
    let imagePath = index + 2 < arguments.count ? arguments[index + 2] : nil
    RenderTest.run(outputDir: outputDir, imagePath: imagePath)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
