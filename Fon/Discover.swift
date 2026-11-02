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
        Task { [weak self] in
            let built = await Discover.build(profile)
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
    private struct Profile {
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

        var topArtists: [String] {
            affinity.filter { $0.value > 0 && names[$0.key] != nil }
                .sorted { $0.value > $1.value }
                .prefix(5).compactMap { names[$0.key] }
        }

        func isKnownArtist(_ track: Track) -> Bool {
            Taste.artistKeys(track.artist).contains { affinity[$0, default: 0] > 0 }
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
    }

    private static func build(_ profile: Profile) async -> Built? {
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
        for name in profile.topArtists {
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
        let freshShelf = take(fresh, 15)
        let trendShelf = take(trendingFound.map(\.track), 15)
        let nicheShelf = take(niche.map(\.0), 15)
        guard !freshShelf.isEmpty || !trendShelf.isEmpty || !nicheShelf.isEmpty else { return nil }
        return Built(fresh: freshShelf, niche: nicheShelf, trending: trendShelf)
    }

    /// Похоже на трек, а не на сборник, реакцию, обзор, кавер или ремикс от кого попало.
    private static let junk = try! NSRegularExpression(
        pattern: #"(сборник|подборк|лучшие|best of|top ?\d|хиты|\bhits\b|playlist|плейлист|non.?stop|full album|альбом целиком|реакци|reaction|разбор|обзор|review|интервью|interview|подкаст|podcast|караоке|karaoke|минус|instrumental|tutorial|урок|cover|кавер|slowed|sped up|speed up|nightcore|\b8d\b|bass ?boost|\bmix\b|микс|ремикс|remix|shorts|#shorts|влог|vlog|трансляц|stream)"#,
        options: [.caseInsensitive])

    private static func isTrack(_ video: YouTubeStreams.FoundVideo) -> Bool {
        guard let seconds = video.seconds, (90...480).contains(seconds) else { return false }
        let text = video.title
        return junk.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
    }

    private func apply(_ built: Built) {
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
