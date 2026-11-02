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
    /// Неоновые лучи — косые светящиеся полосы, медленно проходят по экрану (владелец: «motion background, neon»).
    private var beams: [CAGradientLayer] = []
    private var currentColors: [UIColor] = []
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
            image.opacity = 0.55
            layer.addSublayer(image)
        }
        imageB.opacity = 0.3
        for _ in 0..<5 {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            blob.opacity = 0.85
            layer.addSublayer(blob)
            blobs.append(blob)
        }
        for _ in 0..<2 {
            let beam = CAGradientLayer()
            beam.startPoint = CGPoint(x: 0, y: 0.5)
            beam.endPoint = CGPoint(x: 1, y: 0.5)
            beam.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            beam.locations = [0, 0.5, 1]
            beam.opacity = 0.55
            layer.addSublayer(beam)
            beams.append(beam)
        }
        // Затемнение: текст и кнопки читаются при любой обложке.
        shade.colors = [UIColor(white: 0, alpha: 0.12).cgColor, UIColor(white: 0, alpha: 0.22).cgColor,
                        UIColor(white: 0, alpha: 0.62).cgColor]
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
        let blobSide = max(b.width, b.height) * 0.75
        let spots: [CGPoint] = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.85, y: 0.35), CGPoint(x: 0.3, y: 0.7),
                                CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0.5, y: 0.45)]
        for (blob, spot) in zip(blobs, spots) {
            blob.bounds = CGRect(x: 0, y: 0, width: blobSide, height: blobSide)
            blob.position = CGPoint(x: b.width * spot.x, y: b.height * spot.y)
        }
        for (i, beam) in beams.enumerated() {
            beam.bounds = CGRect(x: 0, y: 0, width: b.width * 0.45, height: max(b.width, b.height) * 1.8)
            beam.position = CGPoint(x: b.width * (i == 0 ? 0.2 : 0.8), y: b.midY)
            beam.setAffineTransform(CGAffineTransform(rotationAngle: i == 0 ? 0.45 : -0.6))
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
            let dx = w * 0.38, dy = h * 0.24
            let sign: CGFloat = i % 2 == 0 ? 1 : -1
            drift.values = [start,
                            CGPoint(x: start.x + dx * sign, y: start.y + dy),
                            CGPoint(x: start.x - dx * 0.5 * sign, y: start.y + dy * 1.6),
                            CGPoint(x: start.x - dx * sign, y: start.y - dy * 0.5),
                            start].map { NSValue(cgPoint: $0) }
            drift.duration = 11 + Double(i) * 3
            drift.calculationMode = .cubic
            drift.repeatCount = .infinity
            blob.add(drift, forKey: "drift")
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.75
            pulse.toValue = 1.35
            pulse.duration = 5 + Double(i) * 1.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            blob.add(pulse, forKey: "pulse")
        }
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
            glow.fromValue = 0.2
            glow.toValue = 0.7
            glow.duration = 3.5 + Double(i)
            glow.autoreverses = true
            glow.repeatCount = .infinity
            beam.add(glow, forKey: "glow")
        }
        animateColors()
    }

    /// Неон «переливается»: каждое пятно и луч по кругу перетекают по цветам трека.
    private func animateColors() {
        let colors = currentColors
        guard colors.count > 1 else { return }
        for (i, blob) in blobs.enumerated() {
            let cycle = CAKeyframeAnimation(keyPath: "colors")
            cycle.values = (0...colors.count).map { k -> [CGColor] in
                let c = colors[(i + k) % colors.count]
                return [c.cgColor, c.withAlphaComponent(0).cgColor]
            }
            cycle.duration = 10 + Double(i) * 2
            cycle.repeatCount = .infinity
            blob.add(cycle, forKey: "cycle")
        }
        for (i, beam) in beams.enumerated() {
            let cycle = CAKeyframeAnimation(keyPath: "colors")
            cycle.values = (0...colors.count).map { k -> [CGColor] in
                let c = colors[(i * 2 + k) % colors.count]
                return [c.withAlphaComponent(0).cgColor, c.cgColor, c.withAlphaComponent(0).cgColor]
            }
            cycle.duration = 14 + Double(i) * 4
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
        onColors?(colors)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.5)
        for (i, blob) in blobs.enumerated() {
            let color = colors[i % colors.count]
            blob.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        for (i, beam) in beams.enumerated() {
            let color = colors[(i * 2) % colors.count]
            beam.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        base.backgroundColor = Self.darkened(colors[0]).cgColor
        CATransaction.commit()
        if cycle {
            // Обложка: неон переливается по её цветам.
            currentColors = colors
            if bounds.width > 0 { animateColors() }
        } else {
            // Видео: цвета задаёт сам кадр (меняется раз в 3 с) — без перелива, иначе он сбивался бы каждый раз.
            (blobs + beams).forEach { $0.removeAnimation(forKey: "cycle") }
        }
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
            colors.append(vivid(candidate.color))
        }
        return colors
    }

    /// Цвет пятна: насыщеннее и не слишком тёмный/светлый.
    private static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        // Неон: насыщенно и ярко.
        return UIColor(hue: hue, saturation: min(1, sat * 1.45 + 0.15), brightness: min(1, max(0.6, bri * 1.25)), alpha: 1)
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
