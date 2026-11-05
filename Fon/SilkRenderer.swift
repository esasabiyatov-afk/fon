import CoreGraphics
import Foundation

/// Параметры светящихся линий (стили «Контур», «Аврора», «Лента»).
struct SilkSpec {
    var count: Int           // сколько линий
    var vertical: Bool       // нити сверху вниз или волны слева направо
    var width: CGFloat       // толщина яркого ядра, pt
    var amplitude: CGFloat   // размах изгиба (доля ширины/высоты)
    var spread: CGFloat      // на какую долю экрана разбросаны линии
    var phaseStep: CGFloat   // сдвиг фазы между линиями: мало — нити почти параллельны, много — разные кривые
    var frequency: CGFloat   // сколько волн на экран
    var alpha: CGFloat
    var glow: CGFloat        // радиус свечения, pt
    var fold: Bool           // мягкий объём под линией — «складка шёлка» (референсы владельца)
    var body: CGFloat        // ширина общего мягкого сияния вокруг пучка (0 — нет)
    var twist: CGFloat       // пучок сходится и расходится, как скрученная лента (0…1)
    var center: CGFloat      // где по поперечной оси проходит пучок (0…1)
}

/// Рисует картинку светящихся линий заранее, в фоне (Core Graphics): мягкое размытое свечение, складка-объём,
/// яркое почти белое ядро, линии гаснут к краям экрана. Анимация потом двигает уже готовую картинку —
/// это ничего не стоит и не трогает плеер. Вид подобран на прототипе (Python), до переноса сюда.
/// Не `UIView`: так работа не привязывается к главному потоку.
enum SilkRenderer {
    /// Масштаб картинки: 1,5 — линии чёткие, а память умеренная (~4 МБ на картинку).
    static let scale: CGFloat = 1.5

    static func render(_ spec: SilkSpec, size: CGSize, colors: [(CGFloat, CGFloat, CGFloat)], variant: Int) -> CGImage? {
        guard !colors.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Сверху вниз, в точках.
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let paths = (0..<spec.count).map { curve($0, spec, size: size, variant: variant) }
        func color(_ k: Int, _ alpha: CGFloat, whiten: CGFloat = 0) -> CGColor {
            let (r, g, b) = colors[k % colors.count]
            return CGColor(srgbRed: r + (1 - r) * whiten, green: g + (1 - g) * whiten, blue: b + (1 - b) * whiten, alpha: alpha)
        }

        // 1. Общее мягкое сияние вокруг пучка.
        if spec.body > 0 {
            glow(ctx, curve(spec.count / 2, spec, size: size, variant: variant), width: spec.body,
                 color: color(0, 0.22), blur: spec.body * 0.5)
        }
        // 2. Складки: мягкий светлый объём чуть ниже каждой линии.
        if spec.fold {
            for (k, path) in paths.enumerated() {
                var shift = CGAffineTransform(translationX: 0, y: 34)
                guard let shifted = path.copy(using: &shift) else { continue }
                let (r, g, b) = colors[k % colors.count]
                let soft = CGColor(srgbRed: r * 0.6 + 0.24, green: g * 0.6 + 0.24, blue: b * 0.6 + 0.27, alpha: 0.3 * strength(k, spec, variant))
                glow(ctx, shifted, width: 70, color: soft, blur: 30)
            }
        }
        // 3. Свечение — одним размытием на цвет (у «Авроры» 40 нитей: размывать каждую по отдельности долго).
        for c in 0..<min(colors.count, spec.count) {
            let group = CGMutablePath()
            for k in stride(from: c, to: spec.count, by: colors.count) { group.addPath(paths[k]) }
            glow(ctx, group, width: spec.width * 7, color: color(c, spec.alpha * 0.75), blur: spec.glow)
            glow(ctx, group, width: spec.width * 2.5, color: color(c, spec.alpha * 0.85), blur: spec.glow * 0.35)
        }
        // 4. Яркое ядро: почти белое, у каждой линии своя яркость — кажется, что линии на разной глубине.
        for (k, path) in paths.enumerated() {
            ctx.addPath(path)
            ctx.setLineWidth(spec.width * 0.55)
            ctx.setStrokeColor(color(k, 0.95 * spec.alpha * strength(k, spec, variant), whiten: 0.55))
            ctx.strokePath()
        }
        // 5. Линии гаснут к краям: вдоль — полностью, поперёк — наполовину.
        fade(ctx, size: size, along: !spec.vertical, stops: [0, 1, 1, 0], at: [0, 0.2, 0.8, 1])
        fade(ctx, size: size, along: spec.vertical, stops: [0.45, 1, 1, 0.45], at: [0, 0.25, 0.75, 1])
        return ctx.makeImage()
    }

    /// Плавная кривая через весь экран: волна из двух синусов, у каждой линии свой сдвиг фазы.
    private static func curve(_ k: Int, _ spec: SilkSpec, size: CGSize, variant: Int) -> CGPath {
        let long = spec.vertical ? size.height : size.width
        let across = spec.vertical ? size.width : size.height
        let n = CGFloat(max(1, spec.count - 1))
        let t = spec.count > 1 ? CGFloat(k) / n : 0.5
        let v = CGFloat(variant)
        let center = across * spec.center
        let deviation = across * (t - 0.5) * spec.spread
        let phase = CGFloat(k) * spec.phaseStep + v * 1.3
        let amp = across * spec.amplitude * (0.85 + 0.3 * sin(CGFloat(k) * 1.7 + v))
        var points: [CGPoint] = []
        let steps = 96
        for s in 0...steps {
            let u = CGFloat(s) / CGFloat(steps)
            let along = long * (-0.1 + 1.2 * u)
            let wave = sin(u * 2 * .pi * spec.frequency + phase)
                + 0.45 * sin(u * 2 * .pi * spec.frequency * 2.1 + phase * 1.7 + v)
            let squeeze = (1 - spec.twist) + spec.twist * cos(u * 2 * .pi * 0.55 + 0.6 + v * 0.8)
            let offset = center + deviation * squeeze + amp * wave
            points.append(spec.vertical ? CGPoint(x: offset, y: along) : CGPoint(x: along, y: offset))
        }
        // Сглаживание: квадратичные кривые через середины отрезков — без изломов.
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Яркость линии 0,5…1 — «псевдослучайная», но одинаковая при каждой отрисовке.
    private static func strength(_ k: Int, _ spec: SilkSpec, _ variant: Int) -> CGFloat {
        let x = sin(CGFloat(k + variant * 7) * 12.9898) * 43758.5453
        return 0.5 + 0.5 * (x - floor(x))
    }

    /// Только размытое свечение линии, без самой линии: линию рисуем далеко за краем, а её тень — на место.
    /// Сдвиг тени задаётся в пикселях (не зависит от масштаба), поэтому умножаем на `scale`.
    private static func glow(_ ctx: CGContext, _ path: CGPath, width: CGFloat, color: CGColor, blur: CGFloat) {
        let away: CGFloat = 20000
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -away * scale, height: 0), blur: blur * scale, color: color)
        ctx.translateBy(x: away, y: 0)
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Умножить прозрачность картинки на плавный градиент (вдоль оси x или y).
    private static func fade(_ ctx: CGContext, size: CGSize, along horizontal: Bool, stops: [CGFloat], at locations: [CGFloat]) {
        let colors = stops.map { CGColor(gray: 0, alpha: $0) } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: locations) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.destinationIn)
        let end = horizontal ? CGPoint(x: size.width, y: 0) : CGPoint(x: 0, y: size.height)
        ctx.drawLinearGradient(gradient, start: .zero, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}
