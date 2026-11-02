import UIKit
import CoreImage

/// «Живой» фон музыкального плеера (просьба владельца после 1.86 по картинкам: фон «сливается», «живой»,
/// подстраивается под обложку): сильно размытая обложка медленно вращается двумя слоями навстречу,
/// поверх плывут большие мягкие пятна её цветов, снизу затемнение для текста. В фоне приложения анимация стоит.
/// **Плеер не трогает** (владелец после 1.87: «визуальное не должно влиять на плеер»): в 1.87 фон брал кадры видео
/// через `AVPlayerItemVideoOutput` на треке — из-за этого звук «запинался» при сворачивании и отскакивал назад
/// при нажатии на обложку; теперь только картинка обложки.
final class LiveBackdrop: UIView {
    private let base = CALayer()
    private let imageA = CALayer()
    private let imageB = CALayer()
    private var blobs: [CAGradientLayer] = []
    private let shade = CAGradientLayer()
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Новые цвета фона (для ореола обложки).
    var onColors: (([UIColor]) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        base.backgroundColor = UIColor(white: 0.12, alpha: 1).cgColor
        layer.addSublayer(base)
        for image in [imageA, imageB] {
            image.contentsGravity = .resizeAspectFill
            image.opacity = 0.75
            layer.addSublayer(image)
        }
        imageB.opacity = 0.45
        for _ in 0..<4 {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            blob.opacity = 0.8
            layer.addSublayer(blob)
            blobs.append(blob)
        }
        // Затемнение: текст и кнопки читаются при любой обложке.
        shade.colors = [UIColor(white: 0, alpha: 0.25).cgColor, UIColor(white: 0, alpha: 0.35).cgColor,
                        UIColor(white: 0, alpha: 0.7).cgColor]
        shade.locations = [0, 0.45, 1]
        layer.addSublayer(shade)

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setRunning(false)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setRunning(true)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        base.frame = b
        shade.frame = b
        // Картинка больше экрана: при вращении края не видны.
        let side = max(b.width, b.height) * 1.6
        for image in [imageA, imageB] {
            image.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            image.position = CGPoint(x: b.midX, y: b.midY * 0.8)
        }
        let blobSide = max(b.width, b.height) * 0.9
        let spots: [CGPoint] = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.85, y: 0.35), CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.8, y: 0.85)]
        for (blob, spot) in zip(blobs, spots) {
            blob.bounds = CGRect(x: 0, y: 0, width: blobSide, height: blobSide)
            blob.position = CGPoint(x: b.width * spot.x, y: b.height * spot.y)
        }
        CATransaction.commit()
        if imageA.animation(forKey: "spin") == nil { startAnimations() }
    }

    // MARK: - Движение

    private func startAnimations() {
        guard bounds.width > 0 else { return }
        for (image, duration, direction) in [(imageA, 46.0, 1.0), (imageB, 63.0, -1.0)] {
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
        for (i, blob) in blobs.enumerated() {
            let drift = CAKeyframeAnimation(keyPath: "position")
            let start = blob.position
            let dx = w * 0.3, dy = h * 0.18
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            drift.values = [start,
                            CGPoint(x: start.x + dx * sign, y: start.y + dy),
                            CGPoint(x: start.x - dx * 0.5 * sign, y: start.y + dy * 1.6),
                            CGPoint(x: start.x - dx * sign, y: start.y - dy * 0.5),
                            start].map { NSValue(cgPoint: $0) }
            drift.duration = 18 + Double(i) * 5
            drift.calculationMode = .cubic
            drift.repeatCount = .infinity
            blob.add(drift, forKey: "drift")
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.85
            pulse.toValue = 1.25
            pulse.duration = 9 + Double(i) * 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            blob.add(pulse, forKey: "pulse")
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
    }

    // MARK: - Цвета и картинка

    /// Новая обложка: размытая картинка и цвета пятен — плавно.
    func setImage(_ image: UIImage?) {
        guard let image, let small = Self.blurred(image) else { return }
        apply(small, colors: Self.palette(small))
    }

    private func apply(_ blurred: CGImage, colors: [UIColor]) {
        let fade = CATransition()
        fade.duration = 1.2
        fade.type = .fade
        imageA.add(fade, forKey: "fade")
        imageB.add(fade, forKey: "fade")
        imageA.contents = blurred
        imageB.contents = blurred
        guard !colors.isEmpty else { return }
        onColors?(colors)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.5)
        for (i, blob) in blobs.enumerated() {
            let color = colors[i % colors.count]
            blob.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        base.backgroundColor = Self.darkened(colors[0]).cgColor
        CATransaction.commit()
    }

    /// Уменьшенная (64 px) и размытая копия — растянутая на экран, она гладкая и почти ничего не стоит.
    private static func blurred(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let scale = 64 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: small.extent)
        let saturated = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
        return ciContext.createCGImage(saturated, from: small.extent)
    }

    /// 4 заметных цвета картинки: яркие и насыщенные выше, похожие отбрасываются.
    private static func palette(_ image: CGImage) -> [UIColor] {
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
            colors.append(vivid(candidate.color))
        }
        return colors
    }

    /// Цвет пятна: насыщеннее и не слишком тёмный/светлый.
    private static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(1, sat * 1.3 + 0.08), brightness: min(0.85, max(0.4, bri)), alpha: 1)
    }

    private static func darkened(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(1, sat), brightness: 0.18, alpha: 1)
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
