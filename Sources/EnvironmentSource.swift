import AppKit
import AVFoundation
import Vision
import CoreImage
import CoreVideo

/// One-shot FaceTime photo of the room in front of the Mac, with the person
/// removed on-device and the hole filled from the surrounding background.
/// Used as the space behind the folding panel.
final class EnvironmentSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    static let shared = EnvironmentSource()

    private(set) var image: CGImage?
    private(set) var lastCapture: Date = .distantPast

    var onImage: ((CGImage?) -> Void)?

    private let sessionQueue = DispatchQueue(label: "duo.environment.session")
    private let frameQueue = DispatchQueue(label: "duo.environment.frame")
    private let processQueue = DispatchQueue(label: "duo.environment.process", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var capturing = false
    private var skipRemaining = 0
    private var frameWait: DispatchSemaphore?
    private var grabbed: CGImage?

    private override init() { super.init() }

    // MARK: - Permission

    var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestPermission(explain: Bool = true) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.publishStatus(granted ? "camera allowed — capturing…" : "camera permission denied")
                    if granted { self?.refresh() }
                }
            }
            return
        }
        if status == .authorized {
            refresh()
            return
        }
        if explain {
            let alert = NSAlert()
            alert.messageText = "Camera permission required"
            alert.informativeText = """
            System Settings → Privacy & Security → Camera → enable Duo More Thing.
            The camera takes a still of the room; the person is removed on-device \
            and the blurred room becomes the space behind the folding screen.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
        publishStatus("camera permission denied")
    }

    func clear() {
        image = nil
        onImage?(nil)
        publishStatus("room background off — using black")
        DispatchQueue.main.async { AppModel.shared.environmentPreview = nil }
    }

    // MARK: - Capture

    /// Grabs a fresh room photo. minInterval skips a recapture if the last one is recent.
    func refresh(minInterval: TimeInterval = 0) {
        guard Settings.shared.useEnvironmentBackground else { clear(); return }
        guard Date().timeIntervalSince(lastCapture) >= minInterval else { return }
        guard !capturing else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            requestPermission(explain: false)
            return
        default:
            publishStatus("camera permission denied")
            return
        }

        capturing = true
        publishStatus("photographing the room…")
        sessionQueue.async { [weak self] in
            self?.captureThenProcess()
        }
    }

    private func captureThenProcess() {
        defer { capturing = false }
        guard let device = cameraDevice() else {
            publishStatus("no camera found")
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .medium
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                publishStatus("could not open the camera")
                return
            }
            session.addInput(input)
        } catch {
            publishStatus("camera: \(error.localizedDescription)")
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else {
            publishStatus("could not read from the camera")
            return
        }
        session.addOutput(output)
        if let conn = output.connection(with: .video) {
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
        session.commitConfiguration()

        self.session = session
        self.output = output
        self.grabbed = nil
        self.skipRemaining = 10          // let auto-exposure settle
        let wait = DispatchSemaphore(value: 0)
        self.frameWait = wait

        session.startRunning()
        let result = wait.wait(timeout: .now() + 3.5)
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        self.session = nil
        self.output = nil
        self.frameWait = nil

        guard result == .success, let frame = grabbed else {
            publishStatus("camera produced no frame")
            return
        }
        grabbed = nil

        processQueue.async { [weak self] in
            self?.finish(frame: frame)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if skipRemaining > 0 {
            skipRemaining -= 1
            return
        }
        guard let wait = frameWait else { return }
        frameWait = nil
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ci = CIImage(cvPixelBuffer: pb)
            grabbed = ciContext.createCGImage(ci, from: ci.extent)
        }
        wait.signal()
    }

    private func cameraDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - Person removal + blur

    private func finish(frame: CGImage) {
        publishStatus("removing person…")
        let mask = personMask(from: frame)
        let filled = RoomFill.removePerson(from: frame, personMask: mask) ?? frame
        let softened = soften(filled)
        let note: String
        if mask == nil {
            note = "no person found — using blurred room"
        } else {
            note = "room ready (person removed)"
        }
        DispatchQueue.main.async { [weak self] in
            guard Settings.shared.useEnvironmentBackground else { return }
            self?.image = softened
            self?.lastCapture = Date()
            self?.onImage?(softened)
            AppModel.shared.environmentStatus = note
            AppModel.shared.hasCameraPermission = true
            AppModel.shared.setEnvironmentPreview(softened)
            AppModel.shared.renderPreview()
        }
    }

    /// Still-image person matte. Instance masks are preferred; the
    /// video-oriented segmentation request is the fallback.
    private func personMask(from image: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            let request = VNGeneratePersonInstanceMaskRequest()
            try handler.perform([request])
            if let observation = request.results?.first,
               !observation.allInstances.isEmpty {
                let buffer = try observation.generateScaledMaskForImage(
                    forInstances: observation.allInstances, from: handler)
                return cgImage(from: buffer)
            }
        } catch {
            NSLog("DuoMoreThing: person instance mask failed: \(error.localizedDescription)")
        }
        do {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([request])
            if let buffer = request.results?.first?.pixelBuffer {
                return cgImage(from: buffer)
            }
        } catch {
            NSLog("DuoMoreThing: person segmentation failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    private func soften(_ image: CGImage) -> CGImage {
        let ci = CIImage(cgImage: image)
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28])
            .cropped(to: ci.extent)
        let graded = blurred.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: -0.04,
            kCIInputContrastKey: 0.92,
            kCIInputSaturationKey: 0.82
        ])
        return ciContext.createCGImage(graded, from: ci.extent) ?? image
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async {
            AppModel.shared.environmentStatus = text
            AppModel.shared.hasCameraPermission = self.hasPermission
        }
    }
}

// MARK: - Push-pull fill of the person-shaped hole

private enum RoomFill {

    static func removePerson(from image: CGImage, personMask: CGImage?) -> CGImage? {
        let maxWidth = 960
        let scale = min(1, CGFloat(maxWidth) / CGFloat(max(image.width, 1)))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard var rgba = rgbaBytes(from: image, width: w, height: h) else { return nil }
        var keep = [Float](repeating: 1, count: w * h)
        if let personMask {
            var matte = grayBytes(from: personMask, width: w, height: h)
            matte = dilate(matte, w: w, h: h, iterations: 7)
            for i in 0..<keep.count {
                keep[i] = matte[i] > 28 ? 0 : 1
            }
        }

        var r = [Float](repeating: 0, count: w * h)
        var g = [Float](repeating: 0, count: w * h)
        var b = [Float](repeating: 0, count: w * h)
        for i in 0..<w * h {
            r[i] = Float(rgba[i * 4 + 0])
            g[i] = Float(rgba[i * 4 + 1])
            b[i] = Float(rgba[i * 4 + 2])
        }

        var levels: [Level] = [Level(r: r, g: g, b: b, wgt: keep, w: w, h: h)]
        while let last = levels.last, last.w > 4, last.h > 4 {
            levels.append(downsample(last))
        }
        for i in stride(from: levels.count - 2, through: 0, by: -1) {
            levels[i] = upsampleFill(fine: levels[i], coarse: levels[i + 1])
        }
        let top = levels[0]
        for i in 0..<w * h {
            rgba[i * 4 + 0] = u8(top.r[i])
            rgba[i * 4 + 1] = u8(top.g[i])
            rgba[i * 4 + 2] = u8(top.b[i])
            rgba[i * 4 + 3] = 255
        }
        return cgImage(rgba: rgba, width: w, height: h)
    }

    private struct Level {
        var r, g, b, wgt: [Float]
        var w, h: Int
    }

    private static func downsample(_ src: Level) -> Level {
        let w = max(1, src.w / 2)
        let h = max(1, src.h / 2)
        var r = [Float](repeating: 0, count: w * h)
        var g = [Float](repeating: 0, count: w * h)
        var b = [Float](repeating: 0, count: w * h)
        var wt = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sr: Float = 0, sg: Float = 0, sb: Float = 0, sw: Float = 0
                for dy in 0..<2 {
                    let sy = min(y * 2 + dy, src.h - 1)
                    for dx in 0..<2 {
                        let sx = min(x * 2 + dx, src.w - 1)
                        let i = sy * src.w + sx
                        let k = src.wgt[i]
                        sr += src.r[i] * k; sg += src.g[i] * k; sb += src.b[i] * k
                        sw += k
                    }
                }
                let o = y * w + x
                if sw > 1e-4 {
                    r[o] = sr / sw; g[o] = sg / sw; b[o] = sb / sw
                    wt[o] = min(1, sw / 4)
                }
            }
        }
        return Level(r: r, g: g, b: b, wgt: wt, w: w, h: h)
    }

    private static func upsampleFill(fine: Level, coarse: Level) -> Level {
        var out = fine
        for y in 0..<fine.h {
            let fy = (Float(y) + 0.5) / Float(fine.h) * Float(coarse.h) - 0.5
            let y0 = max(0, min(coarse.h - 1, Int(floor(fy))))
            let y1 = max(0, min(coarse.h - 1, y0 + 1))
            let ty = fy - Float(y0)
            for x in 0..<fine.w {
                let i = y * fine.w + x
                if fine.wgt[i] > 0.45 { continue }
                let fx = (Float(x) + 0.5) / Float(fine.w) * Float(coarse.w) - 0.5
                let x0 = max(0, min(coarse.w - 1, Int(floor(fx))))
                let x1 = max(0, min(coarse.w - 1, x0 + 1))
                let tx = fx - Float(x0)
                func samp(_ ch: [Float], _ xx: Int, _ yy: Int) -> Float { ch[yy * coarse.w + xx] }
                func bilerp(_ ch: [Float]) -> Float {
                    let a = samp(ch, x0, y0) * (1 - tx) + samp(ch, x1, y0) * tx
                    let b = samp(ch, x0, y1) * (1 - tx) + samp(ch, x1, y1) * tx
                    return a * (1 - ty) + b * ty
                }
                out.r[i] = bilerp(coarse.r)
                out.g[i] = bilerp(coarse.g)
                out.b[i] = bilerp(coarse.b)
                out.wgt[i] = 1
            }
        }
        return out
    }

    private static func dilate(_ src: [UInt8], w: Int, h: Int, iterations: Int) -> [UInt8] {
        var a = src
        var b = src
        for _ in 0..<iterations {
            for y in 0..<h {
                let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
                for x in 0..<w {
                    let x0 = max(0, x - 1), x1 = min(w - 1, x + 1)
                    var m: UInt8 = 0
                    for yy in y0...y1 {
                        let row = yy * w
                        m = max(m, a[row + x0])
                        m = max(m, a[row + x])
                        m = max(m, a[row + x1])
                    }
                    b[y * w + x] = m
                }
            }
            swap(&a, &b)
        }
        return a
    }

    private static func rgbaBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    private static func grayBytes(from image: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func u8(_ x: Float) -> UInt8 {
        UInt8(max(0, min(255, x.rounded())))
    }
}
