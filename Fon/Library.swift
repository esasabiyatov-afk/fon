import UIKit
import CoreImage

struct Track: Codable, Hashable {
    let id: String
    var title: String
    var artist: String
}

/// Данные на телефоне: история прослушивания (для подборок на главной) и старые локальные лайки,
/// которые один раз переносятся в облачный плейлист YouTube (см. CloudLikes).
final class Library {
    static let shared = Library()
    static let didChange = Notification.Name("FonLibraryDidChange")
    private static let historyLimit = 100

    // Старые поля (liked, playlists) читаются для переноса; лишние ключи в файле JSON игнорируются.
    private struct Store: Codable {
        var liked: [Track]?
        var history: [Track]?
    }

    private var store = Store()
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    /// Недавно слушали — новые сверху, без повторов.
    var history: [Track] { store.history ?? [] }

    /// Лайки из прошлых версий (хранились на телефоне) — ждут переноса в облако.
    var legacyLiked: [Track] { store.liked ?? [] }

    func clearLegacyLiked() {
        store.liked = nil
        save()
    }

    func recordPlay(_ track: Track) {
        var list = history.filter { $0.id != track.id }
        list.insert(track, at: 0)
        store.history = Array(list.prefix(Self.historyLimit))
        save()
    }

    func removeFromHistory(_ id: String) {
        store.history = history.filter { $0.id != id }
        save()
    }

    func clearHistory() {
        store.history = []
        save()
    }

    private func save() {
        let snapshot = store
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Квадратные обложки треков из превью YouTube, с кэшем в памяти.
final class ArtworkLoader {
    static let shared = ArtworkLoader()
    enum Size { case small, large }

    private let images = NSCache<NSString, UIImage>()
    private let colors = NSCache<NSString, UIColor>()
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// completion приходит на главном потоке: картинка и её средний цвет (только для .large).
    func load(_ id: String, size: Size, completion: @escaping (UIImage?, UIColor?) -> Void) {
        let key = "\(id)-\(size)" as NSString
        if let image = images.object(forKey: key) {
            completion(image, colors.object(forKey: key))
            return
        }
        // mqdefault — 16:9 без чёрных полос; maxres есть не у всех видео, тогда берём поменьше.
        let names = size == .small ? ["mqdefault", "hqdefault"] : ["maxresdefault", "sddefault", "hqdefault"]
        fetch(id, names: names[...], maxSide: size == .small ? 160 : 900) { [weak self] image in
            let color = (size == .large ? image.flatMap(ArtworkLoader.averageColor) : nil)
            if let image { self?.images.setObject(image, forKey: key) }
            if let color { self?.colors.setObject(color, forKey: key) }
            DispatchQueue.main.async { completion(image, color) }
        }
    }

    private func fetch(_ id: String, names: ArraySlice<String>, maxSide: CGFloat, done: @escaping (UIImage?) -> Void) {
        guard let name = names.first, let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg") else {
            done(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok, let data, let image = UIImage(data: data), image.size.width > 150 {
                done(ArtworkLoader.squareArtwork(image, maxSide: maxSide))
            } else {
                self.fetch(id, names: names.dropFirst(), maxSide: maxSide, done: done)
            }
        }.resume()
    }

    /// Квадратная обложка из превью. Сначала берём кадр 16:9 (у превью 4:3 сверху и снизу чёрные полосы).
    /// Если по бокам кадра однотонные поля — в центре обложка альбома, вырезаем квадрат.
    /// Если картинка на весь кадр — показываем её целиком, а сверху и снизу размытую копию,
    /// чтобы не отрезать края (например, текст на обложке).
    static func squareArtwork(_ image: UIImage, maxSide: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let bandH = min(h, w * 9 / 16)
        let bandW = min(w, bandH * 16 / 9)
        guard let band = cg.cropping(to: CGRect(x: (w - bandW) / 2, y: (h - bandH) / 2, width: bandW, height: bandH).integral) else {
            return image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        if hasFlatSides(band) {
            let bw = CGFloat(band.width), bh = CGFloat(band.height)
            guard let square = band.cropping(to: CGRect(x: (bw - bh) / 2, y: 0, width: bh, height: bh).integral) else { return image }
            let side = min(bh, maxSide)
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }

        let side = min(CGFloat(band.width), maxSide)
        let backdrop = blurred(band)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let full = CGRect(x: 0, y: 0, width: side, height: side)
            if let backdrop {
                let fillW = side * 16 / 9
                UIImage(cgImage: backdrop).draw(in: CGRect(x: (side - fillW) / 2, y: 0, width: fillW, height: side))
            }
            UIColor(white: 0, alpha: 0.3).setFill()
            ctx.fill(full)
            let fitH = side * CGFloat(band.height) / CGFloat(band.width)
            UIImage(cgImage: band).draw(in: CGRect(x: 0, y: (side - fitH) / 2, width: side, height: fitH))
        }
    }

    /// Однотонные ли поля слева и справа от центрального квадрата (как у видео «Topic» с обложкой альбома).
    private static func hasFlatSides(_ band: CGImage) -> Bool {
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
            ctx.interpolationQuality = .low
            ctx.draw(band, in: CGRect(x: 0, y: 0, width: width, height: height))
            let strip = (width - height) / 2
            func stats(_ columns: Range<Int>) -> (mean: Double, deviation: Double) {
                var sum = 0.0, squares = 0.0, count = 0.0
                for y in 0..<height {
                    for x in columns {
                        let i = (y * width + x) * 4
                        let l = (0.299 * Double(buffer[i]) + 0.587 * Double(buffer[i + 1]) + 0.114 * Double(buffer[i + 2])) / 255
                        sum += l
                        squares += l * l
                        count += 1
                    }
                }
                let mean = sum / count
                return (mean, (max(0, squares / count - mean * mean)).squareRoot())
            }
            // Крайний столбец у самого квадрата не берём — там бывает край обложки.
            let left = stats(0..<(strip - 1))
            let right = stats((width - strip + 1)..<width)
            return left.deviation < 0.06 && right.deviation < 0.06 && abs(left.mean - right.mean) < 0.08
        }
    }

    private static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: input.clampedToExtent(),
                kCIInputRadiusKey: max(8, Double(image.width) / 25)
              ]),
              let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    static func averageColor(_ image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)
              ]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

/// Красивое название трека: «Исполнитель - Песня (Official Video)» → «Песня» и «Исполнитель».
enum TrackTitle {
    private static let junk = #"\s*[\(\[]\s*(official|music video|video|audio|lyric|lyrics|visuali[sz]er|clip|mv|hd|hq|4k|премьера|клип|текст|аудио|official audio)[^\)\]]*[\)\]]"#

    static func clean(title: String, artist: String) -> (title: String, artist: String) {
        var name = title.replacingOccurrences(of: junk, with: "", options: [.regularExpression, .caseInsensitive])
        if let bar = name.range(of: " | ") { name = String(name[..<bar.lowerBound]) }
        var by = artist.replacingOccurrences(of: " - Topic", with: "")
        for separator in [" - ", " – ", " — "] {
            guard let range = name.range(of: separator) else { continue }
            let left = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty {
                by = left
                name = right
            }
            break
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        by = by.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? title : name, by.isEmpty ? artist : by)
    }
}

/// Ссылки m.youtube.com для плеера.
enum YouTubeLinks {
    private static let base = "https://m.youtube.com"

    static func watch(_ id: String, list: String? = nil) -> URL? {
        var components = URLComponents(string: base + "/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: id)] + (list.map { [URLQueryItem(name: "list", value: $0)] } ?? [])
        return components.url
    }

    /// Mix YouTube по треку: бесконечная подборка похожей музыки.
    static func mix(_ id: String) -> URL? { watch(id, list: "RD" + id) }

    /// «Мой микс» — личный микс YouTube по аккаунту, стартует с трека.
    static func myMix(seed id: String) -> URL? { watch(id, list: "RDMM") }

    /// Временный плейлист YouTube из своих треков (до 50): «следующий» и автопереход работают как у плейлиста.
    static func queue(_ ids: [String]) -> URL? {
        guard !ids.isEmpty else { return nil }
        var components = URLComponents(string: base + "/watch_videos")!
        components.queryItems = [URLQueryItem(name: "video_ids", value: ids.prefix(50).joined(separator: ","))]
        return components.url
    }
}
