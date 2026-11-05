import MetalKit
import UIKit

/// Фон-шейдер (Metal): каждая точка считается на видеокарте каждый кадр — живая неоновая жидкость, шёлк со светящейся
/// каймой, световые нити, волна-лента, светящаяся и переливающаяся сферы (просьба владельца после 1.96: «где такие
/// графики? в примерах не только линии — разные формы»). Шейдер — `Backdrop.metal`, вид подобран на прототипе.
/// Бережно к батарее и плавности: 30 кадров в секунду, пониженное разрешение там, где формы мягкие, пауза в фоне
/// приложения и когда фон не виден. Плеер не трогает: только своя картинка на видеокарте.
final class ShaderBackdrop: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var c1: SIMD4<Float>
        var c2: SIMD4<Float>
        var c3: SIMD4<Float>
        var params: SIMD4<Float>
        var size: SIMD4<Float>
    }

    private static let sharedDevice = MTLCreateSystemDefaultDevice()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device = sharedDevice, let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "backdropVertex"),
              let fragment = library.makeFunction(name: "backdropFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    /// Шейдер собрался и видеокарта есть — иначе стили-шейдеры показываются как «Неон».
    static var available: Bool { pipeline != nil }

    private let queue: MTLCommandQueue?
    /// Номер формы в шейдере: 0 жидкость, 1 шёлк, 2 нити, 3 волна, 4 сфера, 5 перелив.
    var shape: Int = 0 { didSet { updateQuality() } }

    /// Разрешение и частота кадров (оптимизация, просьба владельца «оптимизируй»): мягким формам хватает
    /// 0,75 пикселя на точку (растягивается плавно, разницы не видно), нитям — 1, тонким линиям (волна, сфера) — 1,5;
    /// 30 кадров/с. В режиме энергосбережения — 24 кадра и чуть меньше пикселей, телефон греется — 15 кадров и 0,5.
    private func updateQuality() {
        var scale: CGFloat
        switch shape {
        case 3, 4: scale = min(UIScreen.main.scale, 1.5)
        case 2: scale = 1
        default: scale = 0.75
        }
        var fps = 30
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            fps = 24
            scale = max(0.5, scale * 0.8)
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            fps = 15
            scale = 0.5
        default: break
        }
        if contentScaleFactor != scale { contentScaleFactor = scale }
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
    }
    var dim: Float = 0
    private var colors: [SIMD3<Float>] = [SIMD3(0.3, 0.8, 1), SIMD3(0.45, 0.4, 1), SIMD3(0.9, 0.4, 0.9)]
    private var target: [SIMD3<Float>] = [SIMD3(0.3, 0.8, 1), SIMD3(0.45, 0.4, 1), SIMD3(0.9, 0.4, 0.9)]
    private var time: Float = 0
    private var lastFrame: CFTimeInterval = 0

    init() {
        queue = Self.sharedDevice?.makeCommandQueue()
        super.init(frame: .zero, device: Self.sharedDevice)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isUserInteractionEnabled = false
        backgroundColor = .black
        contentScaleFactor = 1
        // Каждый фон начинает со своего места — не одинаковые картинки в плеере и под лентами.
        time = Float.random(in: 0...60)
        updateQuality()
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateQuality() }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Цвета обложки — плавно перетекают к новым (~1 с).
    func setColors(_ list: [UIColor]) {
        guard !list.isEmpty else { return }
        target = (0..<3).map { i in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            list[i % list.count].getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
    }

    /// Пауза: в фоне приложения и когда фон не виден (под развёрнутым плеером, вне экрана).
    func setActive(_ active: Bool) {
        if active && isPaused { lastFrame = 0 }
        isPaused = !active
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = Self.pipeline, let queue, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, bounds.width > 0 else { return }
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 0 : min(0.1, now - lastFrame)
        lastFrame = now
        time += Float(dt)
        let ease = Float(min(1, dt * 1.2))
        for i in 0..<3 { colors[i] += (target[i] - colors[i]) * ease }
        let pixelsPerPoint = Float(drawableSize.width / bounds.width)
        var uniforms = Uniforms(
            c1: SIMD4(colors[0], 1), c2: SIMD4(colors[1], 1), c3: SIMD4(colors[2], 1),
            params: SIMD4(time * 0.6, Float(shape), dim, pixelsPerPoint),
            size: SIMD4(Float(drawableSize.width), Float(drawableSize.height), 0, 0.45))
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
