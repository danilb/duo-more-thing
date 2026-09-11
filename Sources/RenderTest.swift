import AppKit

/// Offscreen run of the effect: `DuoMoreThing --render-test <outdir> [image-path]`.
/// Lets you see the result and tune parameters without touching the lid.
enum RenderTest {

    static func run(outputDir: String, imagePath: String?) {
        guard let renderer = FoldRenderer(pixelFormat: .rgba8Unorm) else {
            FileHandle.standardError.write(Data("no Metal renderer\n".utf8)); exit(1)
        }

        var source: CGImage?
        if let imagePath,
           let provider = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil) {
            source = CGImageSourceCreateImageAtIndex(provider, 0, nil)
        }
        if source == nil {
            let semaphore = DispatchSemaphore(value: 0)
            ScreenSource.shared.onImage = { image in source = image; semaphore.signal() }
            ScreenSource.shared.refresh()
            _ = semaphore.wait(timeout: .now() + 5)
        }
        guard let source else {
            FileHandle.standardError.write(Data("no source image\n".utf8)); exit(1)
        }

        renderer.setImage(source)

        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Scale down by width to keep the files light.
        let width = min(source.width, 1440)
        let height = Int(Double(width) * Double(source.height) / Double(source.width))

        for step in 0...5 {
            let strength = Double(step) / 5.0
            let look = FoldLook.current(strength: strength)
            guard let image = renderer.renderOffscreen(width: width, height: height, look: look)
            else { continue }
            let url = dir.appendingPathComponent(String(format: "fold-%02d.png", Int(strength * 100)))
            FoldRenderer.writePNG(image, to: url)
            print("→ \(url.path)")
        }
        exit(0)
    }
}
