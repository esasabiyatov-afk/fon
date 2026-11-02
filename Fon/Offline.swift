import AVFoundation
import Network
import UIKit

/// Музыка без интернета (просьба владельца после 1.83: «нет инета — на улице в наушниках включил: о, это моя любимая,
/// или что-то новое, но в моём вкусе»). Приложение само скачивает **только звук** (файл YouTube 360p → дорожка m4a,
/// ~3–4 МБ на трек) в `Application Support/Offline` — iOS эту папку не чистит, обновления через SideStore её не трогают.
/// Что качается, по важности: «Понравившиеся» → часто слушаемое → миксы по любимым исполнителям → немного рекомендаций.
/// Лимит 2 ГБ: не влезает — уходят менее важные и давно не нужные. Качает по одному треку и только по Wi-Fi.
/// Играет системный плеер (`NativeAudio`): скачанный трек — с телефона, без сети — следующий скачанный или вперемешку.
final class OfflineStore {
    static let shared = OfflineStore()
    static let didChange = Notification.Name("FonOfflineDidChange")
    static let limit: Int64 = 2 * 1024 * 1024 * 1024

    /// Меньше — важнее. `manual` — скачал сам (кнопкой ↓ или «Скачать микс»): важнее всего и качается и не по Wi-Fi.
    enum Source: Int, Codable { case manual = -1, liked = 0, frequent = 1, mix = 2, recommended = 3 }

    struct Entry: Codable {
        var track: Track
        var source: Source
        var size: Int64
        var added: Date
        /// Когда подборка в последний раз хотела этот трек (давно не нужные миксы/рекомендации уступают место новым).
        var wanted: Date
    }

    private struct Index: Codable {
        var entries: [String: Entry] = [:]
        var plays: [String: Int] = [:]
        /// Удалённые владельцем вручную — сами больше не качаются.
        var blocked: [String] = []
    }

    private var index = Index()
    private(set) var online = true
    private var expensive = false
    private let monitor = NWPathMonitor()
    private let directory: URL
    private var pending: [(track: Track, source: Source)] = []
    private(set) var downloading: Track?
    private var failed: [String: Date] = [:]
    private var lastFullPlan: Date?
    private var planTimer: Timer?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode(Index.self, from: data) {
            index = saved
        }
        // Запись без файла (удалили, не докачалось) — забываем.
        index.entries = index.entries.filter { FileManager.default.fileExists(atPath: fileURL($0.key).path) }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOnline = self.online
                self.online = path.status == .satisfied
                self.expensive = path.isExpensive || path.isConstrained
                if self.online != wasOnline { NotificationCenter.default.post(name: Self.didChange, object: nil) }
                self.schedulePlan(after: 3)
            }
        }
        monitor.start(queue: DispatchQueue(label: "fon.offline.network"))
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedulePlan(after: 5)
        }
        nc.addObserver(forName: CloudLikes.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.schedulePlan(after: 10)
        }
    }

    /// Вызвать при запуске приложения — дальше всё само.
    func start() { schedulePlan(after: 8) }

    // MARK: - Что скачано

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent(Self.safe(id) + ".m4a") }

    /// Скачанные: сначала понравившиеся, потом остальные; новые — выше.
    var tracks: [Track] {
        index.entries.values.sorted {
            $0.source.rawValue != $1.source.rawValue ? $0.source.rawValue < $1.source.rawValue : $0.added > $1.added
        }.map(\.track)
    }

    var totalSize: Int64 { index.entries.values.reduce(0) { $0 + $1.size } }
    var waitingCount: Int { pending.count + (downloading == nil ? 0 : 1) }
    var waitsForWiFi: Bool { online && expensive && !pending.isEmpty }
    /// Wi-Fi (не мобильная сеть и не экономия трафика) — для автовоспроизведения в ленте.
    var onWiFi: Bool { online && !expensive }

    func file(for id: String) -> URL? {
        guard index.entries[id] != nil else { return nil }
        let url = fileURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func track(for id: String) -> Track? { index.entries[id]?.track }

    enum State { case missing, waiting, downloaded }

    func state(for id: String) -> State {
        if file(for: id) != nil { return .downloaded }
        if downloading?.id == id || pending.contains(where: { $0.track.id == id }) { return .waiting }
        return .missing
    }

    /// Скачать самому (кнопка ↓ в плеере, «Скачать трек/микс» на карточках) — первыми в очереди, можно и не по Wi-Fi.
    func download(_ tracks: [Track]) {
        var fresh: [(track: Track, source: Source)] = []
        for track in tracks where !track.id.isEmpty {
            index.blocked.removeAll { $0 == track.id }
            failed[track.id] = nil
            if var entry = index.entries[track.id] {
                entry.source = .manual
                index.entries[track.id] = entry
            } else if downloading?.id != track.id, !fresh.contains(where: { $0.track.id == track.id }) {
                fresh.append((track: track, source: .manual))
            }
        }
        pending.removeAll { item in fresh.contains { $0.track.id == item.track.id } }
        pending.insert(contentsOf: fresh, at: 0)
        save()
        notify()
        startNext()
    }

    /// Микс по треку (`RD<id>`, до 25 треков) — целиком.
    func downloadMix(seed: String, completion: ((Int) -> Void)? = nil) {
        Task { [weak self] in
            let mix = await YouTubeStreams.queue(videoID: seed, playlistID: "RD" + seed)
            let list = Array(mix.prefix(25))
            await MainActor.run {
                self?.download(list)
                completion?(list.count)
            }
        }
    }

    /// Трек отыграл 20 с (история «Недавно слушали») — для «часто слушаю».
    func notePlay(_ id: String) {
        index.plays[id, default: 0] += 1
        save()
    }

    /// Удалить вручную (смахнуть в «Скачанных») — и больше не качать сам.
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
        index.entries[id] = nil
        if !index.blocked.contains(id) { index.blocked.append(id) }
        pending.removeAll { $0.track.id == id }
        save()
        notify()
    }

    // MARK: - Подборка: что скачать

    private func schedulePlan(after seconds: TimeInterval) {
        planTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.plan() }
        RunLoop.main.add(timer, forMode: .common)
        planTimer = timer
    }

    private func plan() {
        guard online, !expensive else { return }
        // 1. «Понравившиеся» — все, новые первыми.
        var base: [(Track, Source)] = CloudLikes.shared.tracks.reversed().map { ($0, Source.liked) }
        // 2. Часто слушаю: сыгранные не раз, потом просто последние.
        let history = Library.shared.history
        let plays = index.plays
        base += history.filter { plays[$0.id, default: 0] >= 2 }
            .sorted { plays[$0.id, default: 0] > plays[$1.id, default: 0] }
            .prefix(60).map { ($0, Source.frequent) }
        base += history.prefix(30).map { ($0, Source.frequent) }
        // 4. Немного рекомендаций (лента YouTube «Музыка») — новое в моём вкусе.
        let recommended: [(Track, Source)] = MusicFeed.shared.feedVideos.prefix(20).compactMap { item in
            guard let id = item.videoId else { return nil }
            let clean = TrackTitle.clean(title: item.title, artist: item.subtitle)
            return (Track(id: id, title: clean.title, artist: clean.artist), Source.recommended)
        }
        // 3. Миксы по любимым исполнителям — из сети, не чаще раза в 6 часов (до тех пор — прошлые).
        guard lastFullPlan.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else {
            apply(base + lastMixes + recommended)
            return
        }
        lastFullPlan = Date()
        apply(base + lastMixes + recommended)
        var seeds: [String] = []
        var artists = Set<String>()
        for track in Array(history.prefix(40)) + Array(CloudLikes.shared.tracks.reversed().prefix(40)) where seeds.count < 4 {
            let key = track.artist.lowercased()
            guard !key.isEmpty, artists.insert(key).inserted else { continue }
            seeds.append(track.id)
        }
        let baseList = base
        Task { [weak self] in
            var mixes: [Track] = []
            for seed in seeds {
                let mix = await YouTubeStreams.queue(videoID: seed, playlistID: "RD" + seed)
                mixes += mix.prefix(12)
            }
            let found = mixes
            await MainActor.run {
                guard let self else { return }
                self.lastMixes = found.map { ($0, Source.mix) }
                self.apply(baseList + self.lastMixes + recommended)
            }
        }
    }

    private var lastMixes: [(Track, Source)] = []

    private func apply(_ list: [(Track, Source)]) {
        let now = Date()
        var queue: [(track: Track, source: Source)] = []
        var seen = Set(index.blocked)
        for (track, source) in list where !track.id.isEmpty && seen.insert(track.id).inserted {
            if var entry = index.entries[track.id] {
                entry.wanted = now
                if source.rawValue < entry.source.rawValue { entry.source = source }
                if entry.track.title.isEmpty, !track.title.isEmpty { entry.track = track }
                index.entries[track.id] = entry
            } else {
                queue.append((track, source))
            }
        }
        // Давно не нужные миксы и рекомендации (2 недели) — уступают место свежим.
        for (id, entry) in index.entries where entry.source.rawValue >= Source.mix.rawValue
            && now.timeIntervalSince(entry.wanted) > 14 * 86400 {
            try? FileManager.default.removeItem(at: fileURL(id))
            index.entries[id] = nil
        }
        // Свои (скачать самому) — остаются первыми.
        let manual = pending.filter { $0.source == .manual }
        let manualIDs = Set(manual.map(\.track.id))
        pending = manual + queue.filter { !manualIDs.contains($0.track.id) }.sorted { $0.source.rawValue < $1.source.rawValue }
        save()
        notify()
        startNext()
    }

    // MARK: - Скачивание

    private func startNext() {
        guard downloading == nil, online else { return }
        // Сами по себе — только по Wi-Fi; то, что владелец скачал сам, — по любой сети.
        while let at = pending.firstIndex(where: { !expensive || $0.source == .manual }) {
            let next = pending.remove(at: at)
            if index.entries[next.track.id] != nil { continue }
            if let failedAt = failed[next.track.id], Date().timeIntervalSince(failedAt) < 24 * 3600 { continue }
            guard makeRoom(for: next.source) else {
                pending.removeAll { $0.source.rawValue >= next.source.rawValue } // менее важным места тем более нет
                continue
            }
            downloading = next.track
            notify()
            let item = next
            let destination = fileURL(item.track.id)
            Task { [weak self] in
                let result = await Self.download(item.track, to: destination)
                await MainActor.run {
                    guard let self else { return }
                    self.downloading = nil
                    if let result {
                        let (size, title) = result
                        var track = item.track
                        if track.title.isEmpty, let title {
                            let clean = TrackTitle.clean(title: title, artist: "")
                            track = Track(id: track.id, title: clean.title, artist: clean.artist)
                        }
                        self.index.entries[track.id] = Entry(track: track, source: item.source, size: size, added: Date(), wanted: Date())
                        self.save()
                        // Обложки — заранее, чтобы и без сети были.
                        ArtworkLoader.shared.load(track.id, size: .small) { _, _ in }
                        ArtworkLoader.shared.load(track.id, size: .player) { _, _ in }
                    } else {
                        self.failed[item.track.id] = Date()
                    }
                    self.notify()
                    self.startNext()
                }
            }
            return
        }
        notify()
    }

    /// Место под ещё один трек (~6 МБ с запасом): если не хватает — удаляем менее важные, начиная с давно не нужных.
    private func makeRoom(for source: Source) -> Bool {
        let need: Int64 = 6 * 1024 * 1024
        guard totalSize + need > Self.limit else { return true }
        let victims = index.entries.values
            .filter { $0.source.rawValue > source.rawValue }
            .sorted { $0.source.rawValue != $1.source.rawValue ? $0.source.rawValue > $1.source.rawValue : $0.wanted < $1.wanted }
        for victim in victims where totalSize + need > Self.limit {
            try? FileManager.default.removeItem(at: fileURL(victim.track.id))
            index.entries[victim.track.id] = nil
        }
        save()
        return totalSize + need <= Self.limit
    }

    /// Ссылка — как у системного плеера; файл — кусками по 4 МБ (целиком YouTube отдаёт медленно);
    /// у файла 360p оставляем только звук (m4a). Возвращает размер и название с YouTube.
    private static func download(_ track: Track, to destination: URL) async -> (Int64, String?)? {
        let found = await DirectStream.find(track.id)
        guard let stream = found.streams.first(where: { $0.client == "Прямо звук" }) ?? found.streams.first else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return nil }
        let chunk: Int64 = 4 * 1024 * 1024
        var offset: Int64 = 0
        var total: Int64?
        while total.map({ offset < $0 }) ?? true {
            var request = URLRequest(url: stream.url, timeoutInterval: 30)
            stream.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                try? handle.close()
                return nil
            }
            if total == nil {
                // «bytes 0-4194303/12345678» — полный размер; без него ответ — весь файл сразу.
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                total = range.split(separator: "/").last.flatMap { Int64($0) } ?? Int64(data.count)
                // Очень длинные записи (сборники на час) не качаем — место для треков.
                if let total, total > 80 * 1024 * 1024 { try? handle.close(); return nil }
            }
            handle.write(data)
            offset += Int64(data.count)
        }
        try? handle.close()
        try? FileManager.default.removeItem(at: destination)
        guard await exportAudio(from: temp, to: destination) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return nil }
        return (size, found.title)
    }

    /// Только звуковая дорожка (без перекодирования, где можно) → m4a.
    private static func exportAudio(from source: URL, to destination: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return false }
        session.outputURL = destination
        session.outputFileType = .m4a
        return await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume(returning: session.status == .completed)
            }
        }
    }

    // MARK: - Служебное

    private func save() {
        let snapshot = index
        let url = indexURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func safe(_ id: String) -> String {
        String(id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    /// «1,2 ГБ» / «350 МБ».
    static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
