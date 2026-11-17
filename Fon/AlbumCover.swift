import UIKit

/// Квадратная обложка альбома для экрана блокировки (просьба владельца после 1.110: «если есть обложка, вставлять
/// в фон экрана блокировки — только туда пока что»). Источник — открытый поиск iTunes (Apple, без ключа):
/// `itunes.apple.com/search?entity=song` → `artworkUrl100` → та же картинка 1200×1200. Берём, только если совпали и
/// название, и исполнитель; нет — на экране блокировки остаётся кадр YouTube. Ответ (адрес или «нет») помнится на
/// диске, картинки — в `Caches/covers`.
enum AlbumCover {
    private static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static let indexFile = folder.appendingPathComponent("index.json")
    private static let lock = NSLock()
    /// id видео → адрес обложки ("" — не нашлось).
    private static var index: [String: String] = {
        guard let data = try? Data(contentsOf: indexFile),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return saved
    }()

    static func load(id: String, title: String, artist: String, completion: @escaping (UIImage?) -> Void) {
        Task.detached(priority: .utility) {
            let image = await find(id: id, title: title, artist: artist)
            await MainActor.run { completion(image) }
        }
    }

    private static func find(id: String, title: String, artist: String) async -> UIImage? {
        let file = folder.appendingPathComponent(id + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        lock.lock()
        let known = index[id]
        lock.unlock()
        var address = known
        if address == nil {
            guard !title.isEmpty, !artist.isEmpty else { return nil }
            address = await search(title: title, artist: artist) ?? ""
            remember(id, address ?? "")
        }
        guard let address, !address.isEmpty, let url = URL(string: address),
              let (data, reply) = try? await URLSession.shared.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        try? data.write(to: file)
        cleanUp()
        return image
    }

    private static func remember(_ id: String, _ address: String) {
        lock.lock()
        index[id] = address
        if index.count > 3000 { index = [:] }
        let data = try? JSONEncoder().encode(index)
        lock.unlock()
        try? data?.write(to: indexFile)
    }

    private static func search(title: String, artist: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(title)"),
                                 URLQueryItem(name: "entity", value: "song"),
                                 URLQueryItem(name: "limit", value: "10")]
        guard let url = components.url,
              let (data, reply) = try? await URLSession.shared.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wantedTitle = normalized(title), wantedArtist = normalized(artist)
        guard !wantedTitle.isEmpty, !wantedArtist.isEmpty else { return nil }
        let match = results.first { result in
            let name = normalized(result["trackName"] as? String ?? "")
            let by = normalized(result["artistName"] as? String ?? "")
            guard !name.isEmpty, !by.isEmpty else { return false }
            let sameTitle = name == wantedTitle || name.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(name)
            let sameArtist = by.contains(wantedArtist) || wantedArtist.contains(by)
            return sameTitle && sameArtist
        }
        guard let small = match?["artworkUrl100"] as? String else { return nil }
        return small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
    }

    /// Только буквы и цифры: «Love Riot (feat. X)» и «love riot» совпадают по началу.
    private static func normalized(_ text: String) -> String {
        let cut = text.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        return String(cut.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Не больше 300 картинок (~60 МБ): старые удаляются.
    private static func cleanUp() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let images = files.filter { $0.pathExtension == "jpg" }
        guard images.count > 300 else { return }
        let sorted = images.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        sorted.prefix(images.count - 300).forEach { try? manager.removeItem(at: $0) }
    }
}
