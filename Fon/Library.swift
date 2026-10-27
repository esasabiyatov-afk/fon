import UIKit
import CoreImage

struct Track: Codable, Hashable {
    let id: String
    var title: String
    var artist: String
}

struct Playlist: Codable {
    let id: UUID
    var name: String
    var tracks: [Track]
}

/// Откуда список треков: «Понравившиеся» или свой плейлист.
enum TrackListSource: Equatable {
    case liked
    case playlist(UUID)
}

/// Своя медиатека режима музыки: «Понравившиеся» и плейлисты. Хранится в JSON на телефоне.
final class Library {
    static let shared = Library()
    static let didChange = Notification.Name("FonLibraryDidChange")

    private struct Store: Codable {
        var liked: [Track] = []
        var playlists: [Playlist] = []
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

    var liked: [Track] { store.liked }
    var playlists: [Playlist] { store.playlists }

    func isLiked(_ id: String) -> Bool { store.liked.contains { $0.id == id } }

    func toggleLike(_ track: Track) {
        if let i = store.liked.firstIndex(where: { $0.id == track.id }) {
            store.liked.remove(at: i)
        } else {
            store.liked.insert(track, at: 0)
        }
        save()
    }

    func title(of source: TrackListSource) -> String {
        switch source {
        case .liked: return "Понравившиеся"
        case .playlist(let id): return store.playlists.first { $0.id == id }?.name ?? "Плейлист"
        }
    }

    func tracks(in source: TrackListSource) -> [Track] {
        switch source {
        case .liked: return store.liked
        case .playlist(let id): return store.playlists.first { $0.id == id }?.tracks ?? []
        }
    }

    func contains(_ trackID: String, in source: TrackListSource) -> Bool {
        tracks(in: source).contains { $0.id == trackID }
    }

    /// Добавляет трек в конец списка. false — если он там уже был.
    @discardableResult
    func add(_ track: Track, to source: TrackListSource) -> Bool {
        guard !contains(track.id, in: source) else { return false }
        mutate(source) { $0.append(track) }
        return true
    }

    func removeTrack(at index: Int, from source: TrackListSource) {
        mutate(source) { if $0.indices.contains(index) { $0.remove(at: index) } }
    }

    func moveTrack(from: Int, to: Int, in source: TrackListSource) {
        mutate(source) { tracks in
            guard tracks.indices.contains(from), tracks.indices.contains(to) else { return }
            tracks.insert(tracks.remove(at: from), at: to)
        }
    }

    @discardableResult
    func createPlaylist(named name: String) -> Playlist {
        let playlist = Playlist(id: UUID(), name: name, tracks: [])
        store.playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = store.playlists.firstIndex(where: { $0.id == id }) else { return }
        store.playlists[i].name = name
        save()
    }

    func deletePlaylist(_ id: UUID) {
        store.playlists.removeAll { $0.id == id }
        save()
    }

    private func mutate(_ source: TrackListSource, _ change: (inout [Track]) -> Void) {
        switch source {
        case .liked:
            change(&store.liked)
        case .playlist(let id):
            guard let i = store.playlists.firstIndex(where: { $0.id == id }) else { return }
            change(&store.playlists[i].tracks)
        }
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
