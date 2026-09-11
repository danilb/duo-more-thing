import MetalKit
import MetalPerformanceShaders
import ImageIO
import UniformTypeIdentifiers
import simd

struct FoldUniforms {
    var mvp = matrix_identity_float4x4
    var strength: Float = 0
    var topCurve: Float = 0.45
    var hingeCurve: Float = 4.5
    var shape: Float = 1.6
    var maxLod: Float = 7.2
    var darkness: Float = 0.97
    var darkStart: Float = 0.45
    var pad: Float = 0
}

/// Effect parameters without the matrix — the matrix is derived from them every frame.
struct FoldLook {
    var strength: Double = 0
    var topCurve: Double = 0.45
    var hingeCurve: Double = 4.5
    var shape: Double = 1.6
    var maxLod: Double = 7.2
    var darkness: Double = 0.97
    var darkStart: Double = 0.45
    var tiltAngle: Double = 38
    var tiltCurve: Double = 1.3
    var depth: Double = 2.2

    static func current(strength: Double) -> FoldLook {
        let s = Settings.shared
        return FoldLook(strength: strength, topCurve: s.topCurve, hingeCurve: s.hingeCurve,
                        shape: s.shape, maxLod: s.maxLod, darkness: s.darkness,
                        darkStart: s.darkStart, tiltAngle: s.tiltAngle,
                        tiltCurve: s.tiltCurve, depth: s.depth)
    }
}

/// Draws the frozen screen frame as a panel folding around its bottom edge:
/// perspective, progressive blur and a fade into shadow.
final class FoldRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var pyramid: MPSImageGaussianPyramid?
    private var textureMaxLod: Float = 0

    var look = FoldLook()

    init?(pixelFormat: MTLPixelFormat) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()

        guard let library = FoldRenderer.makeLibrary(device: device) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fold_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fold_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        if pipeline == nil { NSLog("DuoMoreThing: failed to build the render pipeline") }

        if MPSSupportsMTLDevice(device) {
            pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
        }
    }

    /// The shader is compiled at runtime from Resources/Fold.metal: no Metal toolchain
    /// is needed to build, and the effect can be edited without rebuilding.
    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        if let url = Bundle.main.url(forResource: "Fold", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            do { return try device.makeLibrary(source: source, options: nil) }
            catch { NSLog("DuoMoreThing: shader failed to compile: \(error)") }
        }
        if let precompiled = try? device.makeDefaultLibrary(bundle: .main) { return precompiled }
        NSLog("DuoMoreThing: no Metal library found")
        return nil
    }

    var hasImage: Bool { texture != nil }
    var imageSize: CGSize {
        guard let texture else { return .zero }
        return CGSize(width: texture.width, height: texture.height)
    }

    // MARK: - Loading a frame

    func setImage(_ cg: CGImage) {
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let tex = device.makeTexture(descriptor: descriptor) else { return }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        guard let staging = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: tex, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        var target: MTLTexture = tex
        if let pyramid {
            pyramid.encode(commandBuffer: commandBuffer, inPlaceTexture: &target, fallbackCopyAllocator: nil)
        } else if let blit2 = commandBuffer.makeBlitCommandEncoder() {
            blit2.generateMipmaps(for: tex)
            blit2.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        texture = target
        textureMaxLod = Float(max(target.mipmapLevelCount - 1, 0))
    }

    // MARK: - Fold matrix

    /// The panel rotates around its bottom edge and recedes in perspective.
    /// At strength = 0 the projection matches the screen exactly, pixel for pixel.
    private func uniforms(_ look: FoldLook, aspect: Float) -> FoldUniforms {
        var u = FoldUniforms()
        u.strength = Float(look.strength)
        u.topCurve = Float(look.topCurve)
        u.hingeCurve = Float(look.hingeCurve)
        u.shape = Float(look.shape)
        u.maxLod = min(Float(look.maxLod), textureMaxLod)
        u.darkness = Float(look.darkness)
        u.darkStart = Float(look.darkStart)

        let d = Float(max(look.depth, 0.4))
        let f = 2 * d                                  // fov chosen so that at θ=0 the panel == the screen
        let theta = Float(look.tiltAngle) * Float.pi / 180
            * pow(Float(max(look.strength, 0)), Float(max(look.tiltCurve, 0.05)))

        // scale(aspect,1,1) -> rotateX(theta) about y=0 -> translate(0,-0.5,-d) -> perspective
        let scale = float4x4(diagonal: SIMD4<Float>(aspect, 1, 1, 1))
        let c = cos(theta), s = sin(theta)
        let rotate = float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                       SIMD4<Float>(0, c, -s, 0),
                                       SIMD4<Float>(0, s, c, 0),
                                       SIMD4<Float>(0, 0, 0, 1)))
        let translate = float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                          SIMD4<Float>(0, 1, 0, 0),
                                          SIMD4<Float>(0, 0, 1, 0),
                                          SIMD4<Float>(0, -0.5, -d, 1)))
        let near: Float = 0.05, far: Float = 50
        let zs = far / (near - far)
        let projection = float4x4(columns: (SIMD4<Float>(f / aspect, 0, 0, 0),
                                           SIMD4<Float>(0, f, 0, 0),
                                           SIMD4<Float>(0, 0, zs, -1),
                                           SIMD4<Float>(0, 0, far * near / (near - far), 0)))
        u.mvp = projection * translate * rotate * scale
        return u
    }

    // MARK: - Offscreen render (settings preview, debugging)

    func renderOffscreen(width: Int, height: Int, look: FoldLook) -> CGImage? {
        guard let pipeline, let texture, width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        var u = uniforms(look, aspect: Float(width) / Float(height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let texture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let size = view.drawableSize
        var u = uniforms(look, aspect: Float(max(size.width, 1) / max(size.height, 1)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
