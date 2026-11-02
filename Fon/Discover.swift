import UIKit

/// Что владельцу нравится на самом деле: пропуски в первые 30 с — минус треку и исполнителю, дослушал — плюс.
/// Учитывается в «Открытиях» на «Главной» и в миксах системного плеера (обычно пропускаемое туда не попадает).
final class Taste {
    static let shared = Taste()

    private struct Stat: Codable {
        var skips = 0
        var completes = 0
    }

    private struct Store: Codable {
        var tracks: [String: Stat] = [:]
        /// Исполнитель (нормализованное имя) → счёт: +1 дослушал, −1 пропустил.
        var artists: [String: Double] = [:]
    }

    private var store = Store()
    private let fileURL: URL
    private var currentID: String?
    private var currentArtist = ""
    private var maxTime: Double = 0
    private var duration: Double = 0

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("taste.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    /// Состояние плеера (раз в секунду, системный и обычный плеер в режиме музыки).
    func progress(_ track: Track, time: Double, duration: Double) {
        if track.id != currentID {
            finish()
            currentID = track.id
            currentArtist = ""
            maxTime = 0
            self.duration = 0
        }
        if !track.artist.isEmpty { currentArtist = track.artist }
        if time.isFinite { maxTime = max(maxTime, time) }
        if duration.isFinite, duration > 0 { self.duration = duration }
    }

    /// Трек сменился: пропуск (3–30 с из длинного трека) или дослушал (до конца < 15 с).
    private func finish() {
        guard let id = currentID, duration > 60 else { return }
        var stat = store.tracks[id] ?? Stat()
        let delta: Double
        if maxTime >= 3, maxTime < 30, maxTime < duration * 0.5 {
            stat.skips += 1
            delta = -1
        } else if duration - maxTime < 15 {
            stat.completes += 1
            delta = 1
        } else {
            return
        }
        store.tracks[id] = stat
        for key in Self.artistKeys(currentArtist) {
            store.artists[key] = min(20, max(-10, store.artists[key, default: 0] + delta))
        }
        if store.tracks.count > 3000 { store.tracks = store.tracks.filter { $0.value.skips > 0 } } // старое — без лишнего
        save()
    }

    /// Обычно пропускает: трек пропущен 2 раза больше, чем дослушан, или исполнитель в минусе.
    func isDisliked(_ track: Track) -> Bool {
        if let stat = store.tracks[track.id], stat.skips - stat.completes >= 2 { return true }
        return Self.artistKeys(track.artist).contains { store.artists[$0, default: 0] <= -3 }
    }

    /// Счёт исполнителей (для подборок): пропуски и дослушивания.
    var artistScores: [String: Double] { store.artists }

    /// Ключи исполнителей: «Miyagi & Andy Panda feat. X» → miyagi, andypanda, x.
    static func artistKeys(_ artist: String) -> [String] { artistNames(artist).map(\.key) }

    /// Исполнители по отдельности: ключ для сравнения и имя как написано (для поиска).
    static func artistNames(_ artist: String) -> [(key: String, name: String)] {
        let parts = artist
            .replacingOccurrences(of: " - Topic", with: "")
            .replacingOccurrences(of: #"\s*(?:&|,|\+|×|\bfeat\.?|\bft\.?|\bx\b|\bи\b|\band\b)\s*"#, with: "|",
                                  options: [.regularExpression, .caseInsensitive])
            .split(separator: "|")
        return parts.compactMap { part -> (key: String, name: String)? in
            let name = part.trimmingCharacters(in: .whitespaces)
            var key = name.lowercased()
            for junk in ["vevo", "official", " ", ".", "_", "-", "'", "\""] { key = key.replacingOccurrences(of: junk, with: "") }
            return key.count >= 2 ? (key: key, name: name) : nil
        }
    }

    /// Треки, которые пропускают чаще, чем дослушивают (2 и больше раз).
    var dislikedIDs: Set<String> { Set(store.tracks.filter { $0.value.skips - $0.value.completes >= 2 }.map(\.key)) }

    private func save() {
        let snapshot = store
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// «Открытия» на «Главной» (просьба владельца после 1.83: «иногда хочется того, что в тренде, но классно звучит,
/// иногда нишевого, что может зайти»). Всё — обычный YouTube, без YouTube Music и без входа (не трогает историю):
/// - «Ниша»: миксы YouTube по 6 любимым трекам; треки, что встречаются в нескольких миксах (точно в моём вкусе),
///   от исполнителей, которых ещё не слушал, с небольшим числом просмотров (`next` каждого — просмотры).
/// - «Новое в вашем вкусе»: свежее (до 3 месяцев) любимых исполнителей (поиск «за год», только их каналы) и из миксов.
/// - «В тренде»: популярное за месяц (поиск по просмотрам) — по любимым исполнителям и «новинки музыки»,
///   выше — знакомые и похожие исполнители.
/// - «Открытия дня»: раз в день ~24 трека — поровну новинок, ниши и трендов, вперемешку, без вчерашних.
/// Уже слушанное, понравившееся и обычно пропускаемое (`Taste`) — не показываем. Полки — раз в 6 часов, кэш на диске.
final class Discover {
    static let shared = Discover()
    static let didChange = Notification.Name("FonDiscoverDidChange")

    struct Shelves: Codable {
        var daily: [Track] = []
        var dailyDay = ""
        var fresh: [Track] = []
        var niche: [Track] = []
        var trending: [Track] = []
        var built: Date?
        /// Что уже было в «Открытиях дня» (не повторять день за днём).
        var shownDaily: [String] = []
        /// Трек Deezer → видео YouTube ("" — не нашлось), чтобы не искать заново.
        var resolved: [String: String]?
    }

    private(set) var shelves = Shelves()

    /// Все треки полок — названия для очереди системного плеера.
    var allTracks: [Track] { shelves.daily + shelves.fresh + shelves.niche + shelves.trending }
    private var building = false
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("discover.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Shelves.self, from: data) {
            shelves = saved
        }
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Обновить, если пора (раз в 6 часов или новый день). `force` — «потянуть вниз».
    func refresh(force: Bool = false) {
        guard !building else { return }
        let fresh = shelves.built.map { Date().timeIntervalSince($0) < 6 * 3600 } ?? false
        guard force || !fresh || shelves.dailyDay != Self.today else { return }
        let likes = CloudLikes.shared.tracks
        let history = Library.shared.history
        guard !likes.isEmpty || !history.isEmpty else { return } // вкуса ещё нет
        building = true
        let profile = Profile(likes: likes, history: history, taste: Taste.shared)
        let resolved = shelves.resolved ?? [:]
        Task { [weak self] in
            let built = await Discover.build(profile, resolved: resolved)
            await MainActor.run {
                guard let self else { return }
                self.building = false
                guard let built else { return }
                self.apply(built)
            }
        }
    }

    // MARK: - Вкус

    /// Снимок вкуса (на главном потоке) — дальше работа в фоне.
    fileprivate struct Profile {
        let known: Set<String>
        /// Исполнитель → насколько нравится (лайки ×3, история, дослушивания − пропуски).
        let affinity: [String: Double]
        /// Имя для поиска по ключу.
        let names: [String: String]
        let seeds: [Track]
        let disliked: Set<String>
        let dislikedArtists: Set<String>

        init(likes: [Track], history: [Track], taste: Taste) {
            known = Set(likes.map(\.id) + history.map(\.id))
            var affinity: [String: Double] = [:]
            var names: [String: String] = [:]
            func add(_ track: Track, _ weight: Double) {
                for artist in Taste.artistNames(track.artist) {
                    affinity[artist.key, default: 0] += weight
                    if names[artist.key] == nil { names[artist.key] = artist.name }
                }
            }
            for track in likes { add(track, 3) }
            for (i, track) in history.enumerated() { add(track, i < 30 ? 1.5 : 1) }
            for (key, score) in taste.artistScores { affinity[key, default: 0] += score }
            self.affinity = affinity
            self.names = names
            // Зёрна миксов: любимые треки разных исполнителей, немного случайно — каждый раз чуть другое.
            var seeds: [Track] = []
            var used = Set<String>()
            let pool = (Array(likes.reversed().prefix(40)) + Array(history.prefix(40)))
                .filter { !taste.isDisliked($0) }
                .sorted { Self.score($0, affinity) > Self.score($1, affinity) }
            for track in Array(pool.prefix(16)).shuffled() + pool where seeds.count < 6 {
                guard let key = Taste.artistKeys(track.artist).first, used.insert(key).inserted else { continue }
                seeds.append(track)
            }
            self.seeds = seeds
            disliked = taste.dislikedIDs
            dislikedArtists = Set(taste.artistScores.filter { $0.value <= -3 }.map(\.key))
        }

        static func score(_ track: Track, _ affinity: [String: Double]) -> Double {
            Taste.artistKeys(track.artist).map { affinity[$0, default: 0] }.max() ?? 0
        }

        func topArtists(_ count: Int) -> [String] {
            affinity.filter { $0.value > 0 && names[$0.key] != nil }
                .sorted { $0.value > $1.value }
                .prefix(count).compactMap { names[$0.key] }
        }

        func isKnownArtist(_ track: Track) -> Bool { isKnownName(track.artist) }

        func isKnownName(_ artist: String) -> Bool {
            Taste.artistKeys(artist).contains { affinity[$0, default: 0] > 0 }
        }

        func isDislikedName(_ artist: String) -> Bool {
            Taste.artistKeys(artist).contains { dislikedArtists.contains($0) }
        }

        func ok(_ track: Track) -> Bool {
            !known.contains(track.id) && !disliked.contains(track.id) && !Taste.artistKeys(track.artist).contains { dislikedArtists.contains($0) }
        }
    }

    // MARK: - Сборка

    private struct Built {
        var fresh: [Track]
        var niche: [Track]
        var trending: [Track]
        var resolved: [String: String] = [:]
    }

    /// Deezer (похожие исполнители с числом фанатов, релизы с датой, чарты) — основа; YouTube (миксы, поиск) —
    /// добавка и запас, если Deezer не ответил. Треки Deezer играются с YouTube — видео находится поиском.
    private static func build(_ profile: Profile, resolved: [String: String]) async -> Built? {
        async let youtube = buildFromYouTube(profile)
        let deezer = await Deezer.picks(profile)
        let fromYouTube = await youtube ?? Built(fresh: [], niche: [], trending: [])
        var cache = resolved
        var used = Set<String>()

        /// Сначала Deezer (или вперемешку с YouTube), до 15 треков; видео для треков Deezer — поиском.
        func merge(_ dz: [Deezer.Song], _ yt: [Track], interleave: Bool) async -> [Track] {
            var out: [Track] = []
            var d = 0, y = 0
            while out.count < 15 && (d < dz.count || y < yt.count) {
                let takeDeezer = d < dz.count && (!interleave || y >= yt.count || out.count % 2 == 0)
                if takeDeezer {
                    let song = dz[d]
                    d += 1
                    let key = String(song.id)
                    var videoID = cache[key]
                    if videoID == nil {
                        videoID = await Deezer.findVideo(song) ?? ""
                        cache[key] = videoID
                    }
                    guard let id = videoID, !id.isEmpty else { continue }
                    let track = Track(id: id, title: song.title, artist: song.artist)
                    if profile.ok(track), used.insert(id).inserted { out.append(track) }
                } else if y < yt.count {
                    let track = yt[y]
                    y += 1
                    if used.insert(track.id).inserted { out.append(track) }
                }
            }
            return out
        }
        let fresh = await merge(deezer.fresh, fromYouTube.fresh, interleave: false)
        let niche = await merge(deezer.niche, fromYouTube.niche, interleave: false)
        let trending = await merge(deezer.trending, fromYouTube.trending, interleave: true)
        if cache.count > 3000 { cache = cache.filter { !$0.value.isEmpty } }
        guard !fresh.isEmpty || !niche.isEmpty || !trending.isEmpty else { return nil }
        return Built(fresh: fresh, niche: niche, trending: trending, resolved: cache)
    }

    private static func buildFromYouTube(_ profile: Profile) async -> Built? {
        // 1. Миксы по любимым трекам: что встречается чаще — то точнее в моём вкусе.
        var counts: [String: Int] = [:]
        var tracks: [String: Track] = [:]
        var order: [String] = []
        for seed in profile.seeds {
            let mix = await YouTubeStreams.queue(videoID: seed.id, playlistID: "RD" + seed.id)
            for track in mix.prefix(25) where track.id != seed.id && profile.ok(track) && !track.title.isEmpty {
                if tracks[track.id] == nil { order.append(track.id) }
                tracks[track.id] = track
                counts[track.id, default: 0] += 1
            }
        }
        let poolArtists = Set(tracks.values.flatMap { Taste.artistKeys($0.artist) })

        // 2. Просмотры и возраст — у кандидатов из миксов (сначала частые, незнакомые исполнители).
        let candidates = order.sorted {
            let a = (counts[$0] ?? 0, profile.isKnownArtist(tracks[$0]!) ? 0 : 1)
            let b = (counts[$1] ?? 0, profile.isKnownArtist(tracks[$1]!) ? 0 : 1)
            return a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
        }.prefix(30)
        var info: [String: (views: Int?, ageDays: Int?)] = [:]
        let ids = Array(candidates)
        for start in stride(from: 0, to: ids.count, by: 5) {
            let chunk = Array(ids[start..<min(start + 5, ids.count)])
            await withTaskGroup(of: (String, (views: Int?, ageDays: Int?)?).self) { group in
                for id in chunk {
                    group.addTask {
                        let value = await YouTubeStreams.videoInfo(id)
                        return (id, value)
                    }
                }
                for await (id, value) in group { if let value { info[id] = value } }
            }
        }

        // «Ниша»: незнакомые исполнители, мало просмотров, чаще в миксах — выше.
        var niche = ids.compactMap { id -> (Track, Int, Int)? in
            guard let track = tracks[id], !profile.isKnownArtist(track), let views = info[id]?.views, views < 1_500_000 else { return nil }
            return (track, counts[id] ?? 0, views)
        }
        niche.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }

        // 3. Новое: из миксов (до 3 месяцев) + любимые исполнители за год (только их каналы).
        var fresh: [Track] = ids.compactMap { id in
            guard let age = info[id]?.ageDays, age <= 90 else { return nil }
            return tracks[id]
        }
        var trendingFound: [(track: Track, views: Int, boost: Double)] = []
        for name in profile.topArtists(5) {
            let key = Taste.artistKeys(name).first ?? ""
            for video in await YouTubeStreams.searchVideos(name, params: "EgQIBRAB") where isTrack(video) && profile.ok(video.track) && (video.ageDays ?? 999) <= 90 {
                let channel = Taste.artistKeys(video.channel).joined()
                let official = video.verified || channel.contains(key) || video.channel.hasSuffix(" - Topic")
                if official, Taste.artistKeys(video.track.artist).contains(key) || video.title.lowercased().contains(name.lowercased()) {
                    fresh.append(video.track)
                }
            }
            // 4. В тренде: популярное за месяц вокруг любимых исполнителей.
            for video in await YouTubeStreams.searchVideos(name, params: "CAMSBAgEEAE=") where isTrack(video) && profile.ok(video.track) && (video.views ?? 0) >= 300_000 && (video.verified || (video.views ?? 0) >= 1_000_000) {
                trendingFound.append((track: video.track, views: video.views ?? 0, boost: 2))
            }
        }
        for query in ["новинки музыки", "new music"] {
            for video in await YouTubeStreams.searchVideos(query, params: "CAMSBAgEEAE=") where isTrack(video) && video.verified && profile.ok(video.track) && (video.views ?? 0) >= 300_000 {
                let keys = Taste.artistKeys(video.track.artist)
                let near = keys.contains { profile.affinity[$0, default: 0] > 0 || poolArtists.contains($0) }
                trendingFound.append((track: video.track, views: video.views ?? 0, boost: near ? 2 : 1))
            }
        }
        // Популярное из миксов тоже в тренде: свежее и много просмотров.
        for id in ids {
            guard let track = tracks[id], let views = info[id]?.views, views >= 1_000_000, (info[id]?.ageDays ?? 999) <= 180 else { continue }
            trendingFound.append((track: track, views: views, boost: 3))
        }
        trendingFound.sort { Double($0.views) * $0.boost > Double($1.views) * $1.boost }

        var used = Set<String>()
        func take(_ list: [Track], _ limit: Int) -> [Track] {
            var out: [Track] = []
            for track in list where out.count < limit && used.insert(track.id).inserted { out.append(track) }
            return out
        }
        let freshShelf = take(fresh, 20)
        let trendShelf = take(trendingFound.map(\.track), 20)
        let nicheShelf = take(niche.map(\.0), 20)
        guard !freshShelf.isEmpty || !trendShelf.isEmpty || !nicheShelf.isEmpty else { return nil }
        return Built(fresh: freshShelf, niche: nicheShelf, trending: trendShelf)
    }

    /// Похоже на трек, а не на сборник, реакцию, обзор, кавер или ремикс от кого попало.
    fileprivate static let junk = try! NSRegularExpression(
        pattern: #"(сборник|подборк|лучшие|best of|top ?\d|хиты|\bhits\b|playlist|плейлист|non.?stop|full album|альбом целиком|реакци|reaction|разбор|обзор|review|интервью|interview|подкаст|podcast|караоке|karaoke|минус|instrumental|tutorial|урок|cover|кавер|slowed|sped up|speed up|nightcore|\b8d\b|bass ?boost|\bmix\b|микс|ремикс|remix|shorts|#shorts|влог|vlog|трансляц|stream)"#,
        options: [.caseInsensitive])

    fileprivate static func isTrack(_ video: YouTubeStreams.FoundVideo) -> Bool {
        guard let seconds = video.seconds, (90...480).contains(seconds) else { return false }
        let text = video.title
        return junk.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
    }

    private func apply(_ built: Built) {
        shelves.resolved = built.resolved
        shelves.fresh = built.fresh
        shelves.niche = built.niche
        shelves.trending = built.trending
        shelves.built = Date()
        // «Открытия дня» — раз в день: поровну новинок, ниши и трендов, вперемешку, без недавно показанных.
        let today = Self.today
        if shelves.dailyDay != today || shelves.daily.isEmpty {
            let shown = Set(shelves.shownDaily)
            let parts = [built.fresh, built.niche, built.trending].map { $0.filter { !shown.contains($0.id) }.shuffled() }
            var daily: [Track] = []
            var seen = Set<String>()
            for i in 0..<10 {
                for part in parts where i < part.count && daily.count < 24 && seen.insert(part[i].id).inserted {
                    daily.append(part[i])
                }
            }
            if daily.count >= 8 {
                shelves.daily = daily
                shelves.dailyDay = today
                shelves.shownDaily = Array((shelves.shownDaily + daily.map(\.id)).suffix(300))
            }
        }
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func save() {
        let snapshot = shelves
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: - Разбор текста YouTube

    /// «2 459 089 просмотров» → 2459089.
    static func number(_ text: String) -> Int? {
        let digits = text.filter(\.isASCIIDigit)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// «3 недели назад» / «1 month ago» / «Трансляция закончилась 2 дня назад» → дни.
    static func ageDays(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard let match = try? NSRegularExpression(pattern: #"(\d+)\s*([a-zа-яё]+)"#)
            .firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let numberRange = Range(match.range(at: 1), in: lower), let unitRange = Range(match.range(at: 2), in: lower),
              let n = Int(lower[numberRange]) else { return nil }
        let unit = String(lower[unitRange])
        let table: [(String, Int)] = [("сек", 0), ("мин", 0), ("час", 0), ("sec", 0), ("min", 0), ("hour", 0),
                                      ("дн", 1), ("ден", 1), ("day", 1), ("нед", 7), ("week", 7),
                                      ("мес", 30), ("month", 30), ("год", 365), ("лет", 365), ("year", 365)]
        guard let factor = table.first(where: { unit.hasPrefix($0.0) })?.1 else { return nil }
        return n * factor
    }

    /// «4:35» / «1:15:45» → секунды.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Открытый API Deezer (без ключа и регистрации; проверено из облака): похожие исполнители с числом фанатов,
/// релизы с датой выхода, лучшие треки исполнителя, чарты жанров. Играем не с Deezer — видео ищется на YouTube.
fileprivate enum Deezer {
    struct Artist {
        let id: Int
        let name: String
        let fans: Int
    }

    struct Song {
        let id: Int
        let title: String
        let artist: String
        let duration: Int
        let date: String
        let rank: Int
    }

    struct Picks {
        var fresh: [Song] = []
        var niche: [Song] = []
        var trending: [Song] = []
    }

    private static func list(_ path: String) async -> [[String: Any]] {
        guard let url = URL(string: "https://api.deezer.com/" + path) else { return [] }
        let request = URLRequest(url: url, timeoutInterval: 15)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["data"] as? [[String: Any]] ?? []
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private static func artist(_ item: [String: Any]) -> Artist? {
        guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
        return Artist(id: id, name: name, fans: item["nb_fan"] as? Int ?? 0)
    }

    private static func song(_ item: [String: Any], artist fallback: String, date: String = "") -> Song? {
        guard let id = item["id"] as? Int else { return nil }
        let title = item["title_short"] as? String ?? item["title"] as? String ?? ""
        guard !title.isEmpty else { return nil }
        let artist = (item["artist"] as? [String: Any])?["name"] as? String ?? fallback
        return Song(id: id, title: title, artist: artist, duration: item["duration"] as? Int ?? 0, date: date,
                    rank: item["rank"] as? Int ?? 0)
    }

    /// Исполнитель Deezer по имени: точное совпадение, иначе первый похожий.
    private static func find(_ name: String) async -> Artist? {
        let found = await list("search/artist?q=\(encoded(name))&limit=5").compactMap(artist)
        let key = Taste.artistKeys(name).joined()
        return found.first { Taste.artistKeys($0.name).joined() == key }
            ?? found.first { Taste.artistKeys($0.name).joined().contains(key) || key.contains(Taste.artistKeys($0.name).joined()) }
    }

    static func picks(_ profile: Discover.Profile) async -> Picks {
        var picks = Picks()
        var seeds: [Artist] = []
        for name in profile.topArtists(6) {
            if let found = await find(name), !seeds.contains(where: { $0.id == found.id }) { seeds.append(found) }
        }
        guard !seeds.isEmpty else { return picks }
        let seedIDs = Set(seeds.map(\.id))

        // Похожие на любимых: чем у большего числа любимых он в похожих — тем ближе.
        var related: [Int: (artist: Artist, count: Int)] = [:]
        for seed in seeds {
            for item in await list("artist/\(seed.id)/related?limit=20") {
                guard let found = artist(item), !seedIDs.contains(found.id),
                      !profile.isKnownName(found.name), !profile.isDislikedName(found.name) else { continue }
                related[found.id] = (artist: found, count: (related[found.id]?.count ?? 0) + 1)
            }
        }
        let close = related.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.artist.fans > $1.artist.fans }

        // Новое: релизы за 90 дней у любимых и ближайших похожих (по дате выхода).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let since = Date().addingTimeInterval(-90 * 86400)
        var genres: [Int: Int] = [:]
        for (i, artist) in (seeds + close.prefix(8).map(\.artist)).enumerated() {
            let albums = await list("artist/\(artist.id)/albums?limit=50")
            if i < seeds.count {
                for album in albums { if let genre = album["genre_id"] as? Int, genre > 0 { genres[genre, default: 0] += 1 } }
            }
            let recent = albums.compactMap { album -> (id: Int, date: String, single: Bool)? in
                guard let id = album["id"] as? Int, let date = album["release_date"] as? String,
                      let day = formatter.date(from: date), day >= since, day <= Date().addingTimeInterval(86400) else { return nil }
                return (id: id, date: date, single: (album["record_type"] as? String) == "single")
            }.sorted { $0.date > $1.date }.prefix(2)
            for album in recent {
                let tracks = await list("album/\(album.id)/tracks?limit=50").compactMap { song($0, artist: artist.name, date: album.date) }
                picks.fresh += tracks.sorted { $0.rank > $1.rank }.prefix(album.single ? 1 : 2)
            }
        }
        picks.fresh.sort { $0.date > $1.date }

        // Ниша: похожие с небольшим числом фанатов — их лучшие треки.
        let small = close.filter { $0.artist.fans < 100_000 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.artist.fans < $1.artist.fans }
        for entry in small.prefix(10) {
            picks.niche += await list("artist/\(entry.artist.id)/top?limit=2").compactMap { song($0, artist: entry.artist.name) }
        }

        // В тренде: популярные похожие — их хиты, и чарт ваших жанров (только знакомые и похожие исполнители).
        let relatedNames = Set(related.values.flatMap { Taste.artistKeys($0.artist.name) })
        var chart: [Song] = []
        for genre in genres.sorted(by: { $0.value > $1.value }).prefix(2).map(\.key) {
            chart += await list("chart/\(genre)/tracks?limit=50").compactMap { song($0, artist: "") }.filter { song in
                Taste.artistKeys(song.artist).contains { relatedNames.contains($0) } || profile.isKnownName(song.artist)
            }
        }
        var popular: [Song] = []
        for entry in close.filter({ $0.artist.fans >= 100_000 }).prefix(6) {
            popular += await list("artist/\(entry.artist.id)/top?limit=2").compactMap { song($0, artist: entry.artist.name) }
        }
        picks.trending = chart + popular.sorted { $0.rank > $1.rank }
        return picks
    }

    /// Видео YouTube для трека Deezer: поиск без входа, название совпадает, исполнитель или длительность — тоже;
    /// лучше — канал «- Topic» (звук альбома) или подтверждённый канал.
    static func findVideo(_ song: Song) async -> String? {
        let videos = await YouTubeStreams.searchVideos("\(song.artist) \(song.title)", params: "EgIQAQ==")
        let name = normalized(song.title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression))
        let artistKeys = Taste.artistKeys(song.artist)
        let wanted = song.title.lowercased()
        let matches = videos.prefix(6).filter { video in
            guard !name.isEmpty, normalized(video.title).contains(name) else { return false }
            if let seconds = video.seconds, seconds > 600 { return false }
            // Кавер, ремикс, slowed… — только если это и есть трек Deezer.
            let junk = Discover.junk.matches(in: video.title, range: NSRange(video.title.startIndex..., in: video.title))
                .compactMap { Range($0.range, in: video.title).map { video.title[$0].lowercased() } }
            if junk.contains(where: { !wanted.contains($0) }) { return false }
            let text = normalized(video.title + video.channel)
            let sameArtist = artistKeys.contains { text.contains($0) }
            let sameLength = video.seconds.map { song.duration > 0 && abs($0 - song.duration) <= 10 } ?? false
            return sameArtist || sameLength
        }
        let best = matches.first { $0.channel.hasSuffix(" - Topic") } ?? matches.first { $0.verified } ?? matches.first
        return best?.track.id
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
