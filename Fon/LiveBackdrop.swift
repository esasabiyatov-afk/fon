import UIKit
import CoreImage

/// «Живой» фон музыкального плеера и всех своих экранов (просьба владельца после 1.86 по картинкам: фон «сливается»,
/// «живой», подстраивается под обложку). Три стиля на выбор (`Settings.backdropStyle`, настройщик «Оформление»,
/// просьба владельца после 1.91): **Мягкий** — размытая обложка медленно вращается двумя слоями, плывут 4 больших
/// мягких пятна её цветов (фон 1.89); **Неон** — глубокий чёрный, яркие насыщенные пятна с ярким ядром, 2 косых луча,
/// цвета переливаются; **Чёрный** — почти чёрный, едва заметное свечение у обложки: тёмное видео сливается с фоном,
/// «видео больше, чем видео». В фоне приложения анимация стоит.
/// **Плеер не трогает** (владелец после 1.87: «визуальное не должно влиять на плеер»): в 1.87 фон брал кадры видео
/// через `AVPlayerItemVideoOutput` на треке — из-за этого звук «запинался» при сворачивании и отскакивал назад
/// при нажатии на обложку; теперь только картинка обложки и миниатюры кадров, скачанные отдельно.
final class LiveBackdrop: UIView {
    private let base = CALayer()
    private let imageA = CALayer()
    private let imageB = CALayer()
    private var blobs: [CAGradientLayer] = []
    private let shade = CAGradientLayer()
    /// Дополнительное затемнение — для фона под лентами (содержимое должно читаться).
    private let dimLayer = CALayer()
    var dim: Float = 0 { didSet { dimLayer.opacity = dim; shaderView?.dim = dim } }
    /// Неоновые лучи — косые светящиеся полосы, медленно проходят по экрану (владелец: «motion background, neon»).
    private var beams: [CAGradientLayer] = []
    /// Стили-шейдеры (жидкость, шёлк, нити, волна, сферы): своя картинка на видеокарте поверх всего (`ShaderBackdrop`).
    /// В 1.95–1.96 вместо них были линии `CAShapeLayer` — владелец: «дешёвые анимации, как в паинте; где такие графики?».
    private var shaderView: ShaderBackdrop?
    /// Этот фон закрывает собой весь экран (настройщик «Оформление»): пока он открыт, шейдеры остальных фонов
    /// (под лентами, в плеере) стоят — их не видно, а считать два шейдера сразу незачем.
    var coversOthers = false
    private static var covering = 0
    private static let coverChanged = Notification.Name("FonBackdropCoverChanged")

    /// Вызывают экраны с фоном во весь экран: появился / ушёл.
    func setCovering(_ on: Bool) {
        guard coversOthers else { return }
        Self.covering = max(0, Self.covering + (on ? 1 : -1))
        NotificationCenter.default.post(name: Self.coverChanged, object: nil)
    }
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    var style: BackdropStyle = Settings.backdropStyle {
        didSet { if style != oldValue { restyle() } }
    }
    /// Шейдер не собрался или нет видеокарты — вместо стилей-шейдеров обычный «Неон».
    private var look: Look {
        let look = Look.of(style)
        return look.shader != nil && !ShaderBackdrop.available ? Look.of(.neon) : look
    }
    /// Последняя картинка и её цвета «как есть» — при смене стиля перекрашиваем без новой загрузки.
    private var rawColors: [UIColor] = []
    private var lastCycle = true
    private var toned: [UIColor] = []

    /// Новые цвета фона (для ореола обложки).
    var onColors: (([UIColor]) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        base.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(base)
        for image in [imageA, imageB] {
            image.contentsGravity = .resizeAspectFill
            layer.addSublayer(image)
        }
        for _ in 0..<5 {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            layer.addSublayer(blob)
            blobs.append(blob)
        }
        for _ in 0..<2 {
            let beam = CAGradientLayer()
            beam.startPoint = CGPoint(x: 0, y: 0.5)
            beam.endPoint = CGPoint(x: 1, y: 0.5)
            beam.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            beam.locations = [0, 0.5, 1]
            layer.addSublayer(beam)
            beams.append(beam)
        }
        shade.locations = [0, 0.45, 1]
        layer.addSublayer(shade)
        dimLayer.backgroundColor = UIColor.black.cgColor
        dimLayer.opacity = 0
        layer.addSublayer(dimLayer)
        applyLook()

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setRunning(false)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setRunning(true)
        }
        nc.addObserver(forName: Settings.designChanged, object: nil, queue: .main) { [weak self] _ in
            self?.style = Settings.backdropStyle
        }
        nc.addObserver(forName: Self.coverChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateShaderActivity()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Стили

    /// Параметры стиля: что видно, насколько ярко и как быстро движется.
    private struct Look {
        var imageOpacity: (Float, Float)
        var blobCount: Int
        var blobSize: CGFloat
        var blobOpacity: Float
        var drift: (base: Double, step: Double, dx: CGFloat, dy: CGFloat)
        var pulse: (from: CGFloat, to: CGFloat, base: Double, step: Double)
        var beams: Bool
        var cycle: Bool
        var shade: (CGFloat, CGFloat, CGFloat)
        /// Яркость подложки цвета обложки; nil — чистый чёрный.
        var baseBrightness: CGFloat?
        /// Яркое ядро у пятна — неоновое свечение, а не мягкое облако.
        var core: Bool
        /// Форма шейдера (`ShaderBackdrop.shape`); nil — обычный фон из слоёв.
        var shader: Int?

        static func of(_ style: BackdropStyle) -> Look {
            switch style {
            case .soft:
                return Look(imageOpacity: (0.75, 0.45), blobCount: 4, blobSize: 0.75, blobOpacity: 0.75,
                            drift: (18, 5, 0.3, 0.2), pulse: (0.85, 1.25, 9, 2), beams: false, cycle: false,
                            shade: (0.25, 0.35, 0.7), baseBrightness: 0.18, core: false)
            case .neon:
                return Look(imageOpacity: (0.16, 0.08), blobCount: 5, blobSize: 0.6, blobOpacity: 1,
                            drift: (10, 2.5, 0.4, 0.26), pulse: (0.7, 1.4, 4.5, 1.2), beams: true, cycle: true,
                            shade: (0, 0.08, 0.5), baseBrightness: nil, core: true)
            case .black:
                return Look(imageOpacity: (0.1, 0), blobCount: 2, blobSize: 0.7, blobOpacity: 0.4,
                            drift: (26, 6, 0.15, 0.1), pulse: (0.9, 1.15, 12, 3), beams: false, cycle: false,
                            shade: (0, 0, 0.35), baseBrightness: nil, core: false)
            case .fluid, .silk, .fibers, .wave, .orb, .prism:
                let shape: [BackdropStyle: Int] = [.fluid: 0, .silk: 1, .fibers: 2, .wave: 3, .orb: 4, .prism: 5]
                return Look(imageOpacity: (0, 0), blobCount: 0, blobSize: 0.5, blobOpacity: 0,
                            drift: (20, 5, 0.1, 0.1), pulse: (1, 1, 10, 2), beams: false, cycle: false,
                            shade: (0, 0, 0), baseBrightness: nil, core: false, shader: shape[style])
            case .haze:
                return Look(imageOpacity: (0.95, 0.55), blobCount: 2, blobSize: 0.8, blobOpacity: 0.3,
                            drift: (24, 6, 0.2, 0.12), pulse: (0.9, 1.2, 12, 3), beams: false, cycle: false,
                            shade: (0.1, 0.2, 0.55), baseBrightness: 0.12, core: false)
            }
        }
    }

    /// Прозрачность слоёв, затемнение и видимость — по стилю.
    private func applyLook() {
        let look = self.look
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageA.opacity = look.imageOpacity.0
        imageB.opacity = look.imageOpacity.1
        let stops: [NSNumber] = look.core ? [0, 0.28, 1] : [0, 1]
        for (i, blob) in blobs.enumerated() {
            blob.isHidden = i >= look.blobCount
            blob.opacity = look.blobOpacity
            blob.locations = stops
        }
        beams.forEach { $0.isHidden = !look.beams; $0.opacity = 0.6 }
        shade.colors = [UIColor(white: 0, alpha: look.shade.0).cgColor, UIColor(white: 0, alpha: look.shade.1).cgColor,
                        UIColor(white: 0, alpha: look.shade.2).cgColor]
        CATransaction.commit()
        updateShader()
    }

    /// Шейдер — только у стилей-шейдеров; у остальных его нет (и он ничего не считает).
    private func updateShader() {
        if let shape = look.shader {
            let view = shaderView ?? ShaderBackdrop()
            if shaderView == nil {
                shaderView = view
                view.frame = bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(view)
            }
            view.shape = shape
            view.dim = dim
            if !toned.isEmpty { view.setColors(toned) }
            updateShaderActivity()
        } else if let view = shaderView {
            view.setActive(false)
            view.removeFromSuperview()
            shaderView = nil
        }
    }

    /// Шейдер считает, только пока фон виден и приложение открыто.
    private func updateShaderActivity() {
        shaderView?.setActive(!isHidden && window != nil && layer.speed != 0
                              && UIApplication.shared.applicationState != .background
                              && (coversOthers || Self.covering == 0))
    }

    override var isHidden: Bool {
        didSet { updateShaderActivity() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateShaderActivity()
    }

    /// Стиль поменяли в настройщике: заново прозрачности, цвета и движение (без новой загрузки картинки).
    private func restyle() {
        ([imageA, imageB] + blobs + beams).forEach { $0.removeAllAnimations() }
        applyLook()
        if !rawColors.isEmpty { applyColors(animated: true) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        base.frame = b
        shade.frame = b
        dimLayer.frame = b
        // Картинка больше экрана: при вращении края не видны.
        let side = max(b.width, b.height) * 1.6
        for image in [imageA, imageB] {
            image.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            image.position = CGPoint(x: b.midX, y: b.midY * 0.8)
        }
        let blobSide = max(b.width, b.height) * look.blobSize
        // У «Чёрного» свечение — только у обложки (верх экрана).
        let spots: [CGPoint] = look.blobCount <= 2
            ? [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.72, y: 0.5)]
            : [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.85, y: 0.35), CGPoint(x: 0.3, y: 0.7),
               CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0.5, y: 0.45)]
        for (blob, spot) in zip(blobs, spots) {
            blob.bounds = CGRect(x: 0, y: 0, width: blobSide, height: blobSide)
            blob.position = CGPoint(x: b.width * spot.x, y: b.height * spot.y)
        }
        for (i, beam) in beams.enumerated() {
            beam.bounds = CGRect(x: 0, y: 0, width: b.width * 0.32, height: max(b.width, b.height) * 1.8)
            beam.position = CGPoint(x: b.width * (i == 0 ? 0.2 : 0.8), y: b.midY)
            beam.setAffineTransform(CGAffineTransform(rotationAngle: i == 0 ? 0.45 : -0.6))
        }
        CATransaction.commit()
        if imageA.animation(forKey: "spin") == nil { startAnimations() }
    }

    // MARK: - Движение

    private func startAnimations() {
        guard bounds.width > 0 else { return }
        let look = self.look
        let slow = style == .neon ? 0.75 : 1.0
        for (image, duration, direction) in [(imageA, 46.0 * slow, 1.0), (imageB, 63.0 * slow, -1.0)] {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = direction * 2 * Double.pi
            spin.duration = duration
            spin.repeatCount = .infinity
            image.add(spin, forKey: "spin")
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 1.18
            breathe.duration = duration / 3
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            image.add(breathe, forKey: "breathe")
        }
        let w = bounds.width, h = bounds.height
        for (i, blob) in blobs.enumerated() where i < look.blobCount {
            let drift = CAKeyframeAnimation(keyPath: "position")
            let start = blob.position
            let dx = w * look.drift.dx, dy = h * look.drift.dy
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            drift.values = [start,
                            CGPoint(x: start.x + dx * sign, y: start.y + dy),
                            CGPoint(x: start.x - dx * 0.5 * sign, y: start.y + dy * 1.6),
                            CGPoint(x: start.x - dx * sign, y: start.y - dy * 0.5),
                            start].map { NSValue(cgPoint: $0) }
            drift.duration = look.drift.base + Double(i) * look.drift.step
            drift.calculationMode = .cubic
            drift.repeatCount = .infinity
            blob.add(drift, forKey: "drift")
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = look.pulse.from
            pulse.toValue = look.pulse.to
            pulse.duration = look.pulse.base + Double(i) * look.pulse.step
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            blob.add(pulse, forKey: "pulse")
        }
        if look.beams {
            // Лучи медленно проходят поперёк экрана туда-обратно.
            for (i, beam) in beams.enumerated() {
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = i == 0 ? -w * 0.3 : w * 1.3
                sweep.toValue = i == 0 ? w * 1.3 : -w * 0.3
                sweep.duration = i == 0 ? 9 : 13
                sweep.autoreverses = true
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                beam.add(sweep, forKey: "sweep")
                let glow = CABasicAnimation(keyPath: "opacity")
                glow.fromValue = 0.3
                glow.toValue = 0.95
                glow.duration = 3.5 + Double(i)
                glow.autoreverses = true
                glow.repeatCount = .infinity
                beam.add(glow, forKey: "glow")
            }
        }
        animateColors()
    }

    private func blobStops(_ c: UIColor) -> [CGColor] {
        look.core ? [c.cgColor, c.withAlphaComponent(0.75).cgColor, c.withAlphaComponent(0).cgColor]
                  : [c.cgColor, c.withAlphaComponent(0).cgColor]
    }

    private func beamStops(_ c: UIColor) -> [CGColor] {
        [c.withAlphaComponent(0).cgColor, c.cgColor, c.withAlphaComponent(0).cgColor]
    }

    /// Неон «переливается»: каждое пятно и луч по кругу перетекают по цветам трека (только у обложки — не у видео).
    private func animateColors() {
        let colors = toned
        guard look.cycle, lastCycle, colors.count > 1, bounds.width > 0 else {
            (blobs + beams).forEach { $0.removeAnimation(forKey: "cycle") }
            return
        }
        for (i, blob) in blobs.enumerated() {
            let cycle = CAKeyframeAnimation(keyPath: "colors")
            cycle.values = (0...colors.count).map { blobStops(colors[(i + $0) % colors.count]) }
            cycle.duration = 8 + Double(i) * 2
            cycle.repeatCount = .infinity
            blob.add(cycle, forKey: "cycle")
        }
        for (i, beam) in beams.enumerated() {
            let cycle = CAKeyframeAnimation(keyPath: "colors")
            cycle.values = (0...colors.count).map { beamStops(colors[(i * 2 + $0) % colors.count]) }
            cycle.duration = 12 + Double(i) * 4
            cycle.repeatCount = .infinity
            beam.add(cycle, forKey: "cycle")
        }
    }

    /// Пауза анимации (в фоне приложения) и продолжение с того же места.
    func setRunning(_ running: Bool) {
        if running {
            guard layer.speed == 0 else { return }
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            guard layer.speed != 0 else { return }
            let paused = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = paused
        }
        updateShaderActivity()
    }

    // MARK: - Под видео — по миниатюрам кадров (отдельно от плеера)

    private var followKey = ""
    private var followedAt: Date = .distantPast
    private var following = false
    private static var sheets: [URL: CGImage] = [:]
    private static var sheetOrder: [URL] = []

    /// Видео на месте обложки: фон догоняет текущий кадр по миниатюрам YouTube (те, что при перемотке), не чаще раза
    /// в 3 с и с опозданием — не страшно (владелец после 1.88: «фон может догонять, это не главное»). Плеер не трогаем:
    /// картинки качаются отдельно по сети (в 1.87 кадры брались с самого трека — звук запинался).
    func follow(storyboard spec: String?, time: Double, duration: Double) {
        guard let spec, duration > 0, !following, Date().timeIntervalSince(followedAt) >= 3,
              UIApplication.shared.applicationState == .active, let board = Storyboard(spec: spec),
              let frame = board.frame(at: time, duration: duration) else { return }
        let key = frame.url.absoluteString + "#\(frame.rect.minX),\(frame.rect.minY)"
        guard key != followKey else { return }
        followKey = key
        followedAt = Date()
        following = true
        Task.detached(priority: .utility) { [weak self] in
            var sheet = await MainActor.run { LiveBackdrop.sheets[frame.url] }
            if sheet == nil, let (data, _) = try? await URLSession.shared.data(from: frame.url),
               let image = UIImage(data: data)?.cgImage {
                sheet = image
                await MainActor.run {
                    LiveBackdrop.sheets[frame.url] = image
                    LiveBackdrop.sheetOrder.append(frame.url)
                    if LiveBackdrop.sheetOrder.count > 4 { LiveBackdrop.sheets[LiveBackdrop.sheetOrder.removeFirst()] = nil }
                }
            }
            let piece = sheet?.cropping(to: frame.rect)
            let small = piece.flatMap { LiveBackdrop.blurred(UIImage(cgImage: $0)) }
            let colors = small.map { LiveBackdrop.palette($0) } ?? []
            await MainActor.run {
                guard let self else { return }
                self.following = false
                if let small { self.apply(small, colors: colors, cycle: false) }
            }
        }
    }

    /// Видео убрали с обложки — снова по обложке.
    func stopFollowing() {
        followKey = ""
        followedAt = .distantPast
    }

    // MARK: - Цвета и картинка

    /// Неон по умолчанию (ничего не играет): фиолетовый, синий, малиновый, бирюзовый.
    func setDefault() {
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.08, green: 0.04, blue: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let spots: [(UIColor, CGRect)] = [
                (UIColor(red: 0.55, green: 0.2, blue: 1, alpha: 1), CGRect(x: -10, y: -10, width: 44, height: 44)),
                (UIColor(red: 0.1, green: 0.45, blue: 1, alpha: 1), CGRect(x: 30, y: 0, width: 40, height: 40)),
                (UIColor(red: 1, green: 0.2, blue: 0.6, alpha: 1), CGRect(x: 0, y: 34, width: 36, height: 36)),
                (UIColor(red: 0.1, green: 0.9, blue: 0.85, alpha: 1), CGRect(x: 36, y: 36, width: 32, height: 32))]
            for (color, rect) in spots {
                color.setFill()
                UIBezierPath(ovalIn: rect).fill()
            }
        }
        setImage(image)
    }

    /// Новая обложка: размытая картинка и цвета пятен — плавно.
    func setImage(_ image: UIImage?) {
        guard let image, let small = Self.blurred(image) else { return }
        apply(small, colors: Self.palette(small))
    }

    private func apply(_ blurred: CGImage, colors: [UIColor], cycle: Bool = true) {
        let fade = CATransition()
        fade.duration = 1.2
        fade.type = .fade
        imageA.add(fade, forKey: "fade")
        imageB.add(fade, forKey: "fade")
        imageA.contents = blurred
        imageB.contents = blurred
        guard !colors.isEmpty else { return }
        rawColors = colors
        // Видео: цвета задаёт сам кадр (меняется раз в 3 с) — без перелива, иначе он сбивался бы каждый раз.
        lastCycle = cycle
        applyColors(animated: true)
    }

    /// Цвета пятен, лучей и подложки — из цветов картинки, по стилю.
    private func applyColors(animated: Bool) {
        let look = self.look
        toned = rawColors.map { Self.tone($0, style) }
        guard !toned.isEmpty else { return }
        onColors?(toned)
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(1.5) } else { CATransaction.setDisableActions(true) }
        for (i, blob) in blobs.enumerated() {
            blob.colors = blobStops(toned[i % toned.count])
        }
        for (i, beam) in beams.enumerated() {
            beam.colors = beamStops(toned[(i * 2) % toned.count])
        }
        base.backgroundColor = (look.baseBrightness.map { Self.darkened(toned[0], to: $0) } ?? .black).cgColor
        CATransaction.commit()
        animateColors()
        shaderView?.setColors(toned)
    }

    /// Уменьшенная (64 px) и размытая копия — растянутая на экран, она гладкая и почти ничего не стоит.
    fileprivate static func blurred(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let scale = 64 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: small.extent)
        let saturated = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
        return ciContext.createCGImage(saturated, from: small.extent)
    }

    /// 4 заметных цвета картинки: яркие и насыщенные выше, похожие отбрасываются.
    fileprivate static func palette(_ image: CGImage) -> [UIColor] {
        let w = 12, h = 12
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var candidates: [(color: UIColor, score: CGFloat, hue: CGFloat, bri: CGFloat)] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = UIColor(red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            candidates.append((color, sat * 0.7 + bri * 0.3, hue, bri))
        }
        candidates.sort { $0.score > $1.score }
        var picked: [(hue: CGFloat, bri: CGFloat)] = []
        var colors: [UIColor] = []
        for candidate in candidates where colors.count < 4 {
            let close = picked.contains {
                let dh = min(abs($0.hue - candidate.hue), 1 - abs($0.hue - candidate.hue))
                return dh < 0.06 && abs($0.bri - candidate.bri) < 0.25
            }
            if close { continue }
            picked.append((candidate.hue, candidate.bri))
            colors.append(candidate.color)
        }
        return colors
    }

    /// Цвет пятна по стилю: мягкий — насыщеннее, но спокойно; неон — максимально насыщенно и ярко;
    /// чёрный — приглушённое свечение.
    private static func tone(_ color: UIColor, _ style: BackdropStyle) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        switch style {
        case .soft:
            return UIColor(hue: hue, saturation: min(1, sat * 1.3 + 0.08), brightness: min(0.85, max(0.4, bri * 1.15)), alpha: 1)
        case .neon:
            // Серое (почти без цвета) остаётся белёсым свечением, остальное — чистый неон.
            let s = sat < 0.1 ? 0.12 : min(1, max(0.85, sat * 1.6 + 0.3))
            return UIColor(hue: hue, saturation: s, brightness: min(1, max(0.92, bri * 1.4)), alpha: 1)
        case .black:
            return UIColor(hue: hue, saturation: min(1, sat * 1.2 + 0.05), brightness: min(0.8, max(0.45, bri)), alpha: 1)
        case .fluid, .silk, .fibers:
            return UIColor(hue: hue, saturation: min(1, max(0.5, sat * 1.2)), brightness: 0.95, alpha: 1)
        case .wave, .orb:
            return UIColor(hue: hue, saturation: min(1, max(0.6, sat * 1.3)), brightness: 1, alpha: 1)
        case .prism:
            return UIColor(hue: hue, saturation: min(1, sat * 0.9 + 0.1), brightness: 0.9, alpha: 1)
        case .haze:
            return UIColor(hue: hue, saturation: sat * 0.55, brightness: min(0.85, max(0.45, bri * 0.9)), alpha: 1)
        }
    }

    private static func darkened(_ color: UIColor, to brightness: CGFloat) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(1, sat), brightness: brightness, alpha: 1)
    }
}

/// Подложка под названием и кнопками плеера «под стекло» (владелец после 1.87: «низ более стеклянным»):
/// тонкое размытие, сверху блик, лёгкий оттенок цвета фона и светлая кромка — ярче сверху-слева, как у стекла.
/// На iOS 26 (сборка Xcode 26) — **настоящее системное стекло** `UIGlassEffect` (владелец после 1.87: «прям как стекло
/// iOS 26»): блик, кромку и преломление рисует система, оттенок — `tintColor`. Иначе — размытие с бликом и кромкой.
final class GlassPanel: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let tint = CALayer()
    private let sheen = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let streak = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    var cornerRadius: CGFloat = 30 { didSet { setNeedsLayout() } }
    /// Глянец (блик, полоса отражения, яркая кромка) или матовое стекло — тема в настройщике «Оформление».
    /// Светлое матовое стекло (тема «Светлое»): белёсая подложка и яркая кромка, без бликов.
    var frosted = false {
        didSet {
            guard !native else { return }
            layer.backgroundColor = (frosted ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0.04, alpha: 0.16)).cgColor
            if frosted { rim.opacity = 1 }
        }
    }
    var glossy = true {
        didSet {
            sheen.isHidden = !glossy
            streak.isHidden = !glossy
            rim.opacity = glossy ? 1 : 0.35
        }
    }

    /// Системное стекло iOS 26 вместо своего.
    private var native = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            native = true
            blur.effect = UIGlassEffect()
            blur.layer.cornerCurve = .continuous
            addSubview(blur)
            return
        }
        #endif
        clipsToBounds = true
        // Без размытия: под подложкой и так размытый фон, а живое размытие поверх движущегося фона пересчитывается
        // каждый кадр — ползунок и анимации начинали дёргаться (владелец после 1.88: «раньше было плавно»).
        layer.backgroundColor = UIColor(white: 0.04, alpha: 0.16).cgColor // прозрачнее: фон виден насквозь
        tint.backgroundColor = UIColor(white: 1, alpha: 0.04).cgColor
        layer.addSublayer(tint)
        // Глянец (владелец после 1.88: «больше глянцевости и прозрачности»): яркий блик по верху,
        // косая полоса отражения и лёгкий отсвет снизу. Всё — неподвижные слои, на плавность не влияют.
        sheen.colors = [UIColor(white: 1, alpha: 0.30).cgColor, UIColor(white: 1, alpha: 0.10).cgColor,
                        UIColor(white: 1, alpha: 0.0).cgColor, UIColor(white: 1, alpha: 0.0).cgColor,
                        UIColor(white: 1, alpha: 0.07).cgColor]
        sheen.locations = [0, 0.12, 0.35, 0.8, 1]
        layer.addSublayer(sheen)
        streak.colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.13).cgColor,
                         UIColor(white: 1, alpha: 0.02).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        streak.locations = [0.2, 0.32, 0.42, 0.55]
        streak.startPoint = CGPoint(x: 0, y: 0)
        streak.endPoint = CGPoint(x: 1, y: 0.75)
        layer.addSublayer(streak)
        rim.colors = [UIColor(white: 1, alpha: 0.85).cgColor, UIColor(white: 1, alpha: 0.18).cgColor,
                      UIColor(white: 1, alpha: 0.08).cgColor, UIColor(white: 1, alpha: 0.45).cgColor]
        rim.locations = [0, 0.35, 0.65, 1]
        rim.startPoint = CGPoint(x: 0, y: 0)
        rim.endPoint = CGPoint(x: 1, y: 1)
        rimMask.fillColor = UIColor.clear.cgColor
        rimMask.strokeColor = UIColor.white.cgColor
        rimMask.lineWidth = 1.4
        rim.mask = rimMask
        layer.addSublayer(rim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        if native {
            blur.layer.cornerRadius = cornerRadius // форму стекла система берёт из скругления
            return
        }
        layer.cornerRadius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        sheen.frame = bounds
        streak.frame = bounds
        rim.frame = bounds
        rimMask.frame = bounds
        rimMask.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), cornerRadius: cornerRadius).cgPath
        CATransaction.commit()
    }

    /// Лёгкий оттенок цвета фона — стекло «вбирает» цвет под ним.
    func setTint(_ color: UIColor?) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), native {
            let glass = UIGlassEffect()
            glass.tintColor = color?.withAlphaComponent(0.18)
            UIView.animate(withDuration: 1.2) { self.blur.effect = glass }
            return
        }
        #endif
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        tint.backgroundColor = (color?.withAlphaComponent(0.10) ?? UIColor(white: 1, alpha: 0.04)).cgColor
        CATransaction.commit()
    }
}

/// Миниатюры кадров видео YouTube (`storyboards.playerStoryboardSpecRenderer.spec`, формат как у yt-dlp):
/// «база|ширина#высота#кадров#столбцов#строк#…#имя#sigh|…»; уровень 1 — кадры 80×45 листами 10×10.
private struct Storyboard {
    let template: String
    let width: Int, height: Int, count: Int, cols: Int, rows: Int

    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let index = parts.count > 2 ? 2 : 1 // уровень 1 (80×45), а если его нет — 0
        let args = parts[index].components(separatedBy: "#")
        guard args.count == 8, let w = Int(args[0]), let h = Int(args[1]), let n = Int(args[2]),
              let c = Int(args[3]), let r = Int(args[4]), w > 0, h > 0, n > 0, c > 0, r > 0 else { return nil }
        template = parts[0].replacingOccurrences(of: "$L", with: String(index - 1))
            .replacingOccurrences(of: "$N", with: args[6]) + "&sigh=" + args[7]
        width = w; height = h; count = n; cols = c; rows = r
    }

    func frame(at time: Double, duration: Double) -> (url: URL, rect: CGRect)? {
        let i = min(count - 1, max(0, Int(time / duration * Double(count))))
        let perSheet = cols * rows
        guard let url = URL(string: template.replacingOccurrences(of: "$M", with: String(i / perSheet))) else { return nil }
        let pos = i % perSheet
        return (url, CGRect(x: (pos % cols) * width, y: (pos / cols) * height, width: width, height: height))
    }
}
