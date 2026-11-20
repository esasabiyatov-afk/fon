import AVFoundation
import CryptoKit
import MediaPlayer
import UIKit
import WebKit

/// Ссылка на поток трека и с какими заголовками её открывать.
/// Время/длина в целые секунды без вылета: `Int(.nan)` роняет приложение (отчёт iOS после 1.110: переход в
/// режим видео, пока трек ещё грузился, — у AVPlayer время было NaN, `handoverURL` упал).
extension Double {
    var safeInt: Int { isFinite ? Int(max(-9e15, min(9e15, self))) : 0 }
}

struct AudioStream {
    let url: URL
    let headers: [String: String]
    let client: String
}

/// Вход в Google для запросов самого приложения. Cookies копируются из WKWebView, пока приложение открыто:
/// в фоне хранилище WebKit может спать, а следующий трек надо найти и в фоне.
enum YouTubeSession {
    private static let lock = NSLock()
    private static var cookies: [HTTPCookie] = []

    static func refresh(completion: (() -> Void)? = nil) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
            // Как браузер для www.youtube.com: общие cookies `.youtube.com` и самого www — без чужих поддоменов
            // (m., music.), иначе одно имя (PREF, VISITOR_INFO1_LIVE…) шло несколько раз с разными значениями.
            // Свежие — первыми; из одноимённых берём одну.
            let now = Date()
            var seen = Set<String>()
            let youtube = all.filter { cookie in
                let domain = cookie.domain.lowercased()
                let matches = domain == "www.youtube.com" || domain == ".youtube.com" || domain == "youtube.com"
                    || domain == ".www.youtube.com"
                return matches && (cookie.expiresDate.map { $0 > now } ?? true)
            }
            .sorted { ($0.domain == ".youtube.com" ? 0 : 1) < ($1.domain == ".youtube.com" ? 0 : 1) }
            .filter { seen.insert($0.name).inserted }
            lock.lock()
            cookies = youtube
            refreshedAt = Date()
            lock.unlock()
            completion?()
        }
    }

    /// Свежая копия перед каждым поиском потока: Google время от времени обновляет cookies входа, и за час-другой
    /// игры старая копия могла устареть (страница видео отвечала бы как без входа).
    private static var refreshedAt = Date.distantPast

    static func refreshed() async {
        // Копия моложе 20 с — свежая (поиск заранее и старт трека шли подряд, каждый ждал WebKit).
        lock.lock()
        let fresh = Date().timeIntervalSince(refreshedAt) < 20 && !cookies.isEmpty
        lock.unlock()
        if fresh { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { refresh { done.resume() } }
        }
    }

    /// Для подсказки об ошибке: сколько cookies YouTube и есть ли вход.
    static var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let signedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
        return "cookies: \(cookies.count), вход: \(signedIn ? "да" : "нет")"
    }

    /// Диагностика: имена cookies (без значений) и значение одной (PREF — настройки, не секрет).
    static var cookieNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cookies.map(\.name).sorted()
    }

    static func cookieValue(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cookies.first { $0.name == name }?.value
    }

    static var cookieHeader: String? { cookieHeaderWithout([]) }

    static func cookieHeaderWithout(_ names: Set<String>) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return HTTPCookie.requestHeaderFields(with: cookies.filter { !names.contains($0.name) })["Cookie"]
    }

    private static var sapisid: String? {
        lock.lock()
        defer { lock.unlock() }
        return (cookies.first { $0.name == "SAPISID" } ?? cookies.first { $0.name == "__Secure-3PAPISID" })?.value
    }

    /// Заголовок, которым страница YouTube подписывает запросы внутреннего API от имени аккаунта.
    static func authorization(origin: String) -> String? {
        guard let id = sapisid else { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        let hash = Insecure.SHA1.hash(data: Data("\(ts) \(id) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hash)"
    }
}

/// Запросы к YouTube из самого приложения (URLSession — работают и в фоне). Поток трека ищет `DirectStream`;
/// здесь — общее: User-Agent, настройки клиента со страницы, очередь микса (`next`) и разбор ответа страницы.
/// Старые пути (HLS «Safari для Mac», PO-токен BotGuard, скрытое окно `app=desktop`) убраны после 1.64:
/// прямой путь заработал, а они не работали или были не нужны (история — в git и CLAUDE.md).
enum YouTubeStreams {
    static let origin = "https://www.youtube.com"
    /// User-Agent Safari на iPhone (версию iOS WebKit «замораживает» — так пишет и настоящий Safari).
    static let iPhoneSafariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// Настройки клиента со страницы YouTube (контекст запроса, версия) — для внутреннего API.
    private struct Config {
        let context: [String: Any]
        let clientVersion: String
    }

    private static let lock = NSLock()
    private static var savedConfig: Config?
    private static var config: Config? {
        get { lock.lock(); defer { lock.unlock() }; return savedConfig }
        set { lock.lock(); savedConfig = newValue; lock.unlock() }
    }

    private static var webVersion: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "2." + formatter.string(from: Date().addingTimeInterval(-2 * 86400)) + ".01.00"
    }

    private static var fallbackConfig: Config {
        Config(context: ["client": ["clientName": "WEB", "clientVersion": webVersion, "hl": "ru", "gl": "RU"]],
               clientVersion: webVersion)
    }

    /// Настройки клиента со страницы видео (её загружает `DirectStream`) — для очереди микса.
    static func rememberConfig(from page: Data) {
        guard let context = jsonObject(in: page, after: "\"INNERTUBE_CONTEXT\":") else { return }
        let client = context["client"] as? [String: Any]
        config = Config(context: context, clientVersion: client?["clientVersion"] as? String ?? webVersion)
    }

    struct Result {
        var streams: [AudioStream] = []
        var title: String?
        var author: String?
        var channelID: String?
        /// Миниатюры кадров видео YouTube (`storyboards…spec`) — для живого фона плеера, отдельно от воспроизведения.
        var storyboard: String?
        /// Почему потока нет (для подсказки при переходе в веб-плеер).
        var reason: String?
        /// У форматов на странице не нашлось ссылок (повтор без cookies посетителя может помочь).
        var noLinks = false
        /// Адрес и настройки SABR со страницы — для устройств без обычных ссылок (`SabrEngine`).
        var sabr: SabrEngine.Source?
    }

    /// Очередь плейлиста или микса (`next`): треки по порядку.
    static func queue(videoID: String, playlistID: String) async -> [Track] {
        let cfg = config ?? fallbackConfig
        let body: [String: Any] = ["context": YouTubeAccount.context(cfg.context), "videoId": videoID, "playlistId": playlistID]
        guard let json = await post("next", body: body, config: cfg) else { return [] }
        return parseQueue(json)
    }

    /// Поиск видео (`search`, фильтр «Видео») — другие версии трека и «Добавить в очередь».
    /// `title` — название как на YouTube (для проверки «slowed»/«lyrics»), у трека — очищенное.
    /// `anonymous` — без входа в аккаунт: такой поиск не попадает в историю поиска YouTube. Другие версии ищутся
    /// сами, в фоне — в 1.83 их запросы («… slowed», «… sped up», «… lyrics») заполнили историю поиска владельца.
    static func search(_ query: String, anonymous: Bool = false) async -> [(track: Track, title: String)] {
        let cfg = config ?? fallbackConfig
        let context = anonymous ? cfg.context : YouTubeAccount.context(cfg.context)
        let body: [String: Any] = ["context": context, "query": query, "params": "EgIQAQ=="]
        guard let json = await post("search", body: body, config: cfg, signedIn: !anonymous) else { return [] }
        var seen = Set<String>()
        return findAll(json, key: "videoRenderer").compactMap { item in
            guard let video = item as? [String: Any], let id = video["videoId"] as? String, seen.insert(id).inserted else { return nil }
            let title = text(video["title"])
            let artist = text(video["ownerText"] ?? video["longBylineText"] ?? video["shortBylineText"])
            let clean = TrackTitle.clean(title: title, artist: artist)
            return (Track(id: id, title: clean.title, artist: clean.artist), title)
        }
    }

    /// Видео из поиска для подборок «Открытия» (`Discover`): просмотры, возраст, длительность, значок канала.
    struct FoundVideo {
        let track: Track
        let title: String
        let channel: String
        let views: Int?
        let ageDays: Int?
        let seconds: Int?
        /// Значок канала: подтверждённый / официальный исполнитель.
        let verified: Bool
    }

    /// Поиск для подборок — всегда без входа (не попадает в историю поиска владельца).
    /// `params`: «Видео за месяц» `EgQIBBAB`, «за год» `EgQIBRAB`, «за месяц по просмотрам» `CAMSBAgEEAE=`.
    static func searchVideos(_ query: String, params: String) async -> [FoundVideo] {
        let cfg = config ?? fallbackConfig
        let body: [String: Any] = ["context": cfg.context, "query": query, "params": params]
        guard let json = await post("search", body: body, config: cfg, signedIn: false) else { return [] }
        var seen = Set<String>()
        return findAll(json, key: "videoRenderer").compactMap { item in
            guard let video = item as? [String: Any], let id = video["videoId"] as? String, seen.insert(id).inserted else { return nil }
            let title = text(video["title"])
            let channel = text(video["ownerText"] ?? video["longBylineText"] ?? video["shortBylineText"])
            let clean = TrackTitle.clean(title: title, artist: channel)
            let badges = (video["ownerBadges"] as? [[String: Any]] ?? []).compactMap {
                ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String
            }
            return FoundVideo(track: Track(id: id, title: clean.title, artist: clean.artist), title: title, channel: channel,
                              views: Discover.number(text(video["viewCountText"])),
                              ageDays: Discover.ageDays(text(video["publishedTimeText"])),
                              seconds: Discover.seconds(text(video["lengthText"])),
                              verified: badges.contains { $0.contains("VERIFIED") })
        }
    }

    /// Просмотры и возраст видео (`next` без входа — `videoPrimaryInfoRenderer`; проверено из облака).
    static func videoInfo(_ id: String) async -> (views: Int?, ageDays: Int?)? {
        guard let info = await videoDetails(id) else { return nil }
        return (info.views, info.ageDays)
    }

    /// Название, канал, просмотры и возраст видео — один запрос `next` без входа (история не трогается).
    static func videoDetails(_ id: String) async -> (title: String, channel: String, views: Int?, ageDays: Int?)? {
        let cfg = config ?? fallbackConfig
        let body: [String: Any] = ["context": cfg.context, "videoId": id]
        guard let json = await post("next", body: body, config: cfg, signedIn: false),
              let primary = findAll(json, key: "videoPrimaryInfoRenderer").first as? [String: Any] else { return nil }
        let counter = (primary["viewCount"] as? [String: Any])?["videoViewCountRenderer"] as? [String: Any]
        let views = (counter?["originalViewCount"] as? String).flatMap { Int($0) } ?? Discover.number(text(counter?["viewCount"]))
        let owner = findAll(json, key: "videoOwnerRenderer").first as? [String: Any]
        return (text(primary["title"]), text(owner?["title"]), views, Discover.ageDays(text(primary["relativeDateText"])))
    }

    private static func parseQueue(_ json: [String: Any]) -> [Track] {
        var seen = Set<String>()
        return findAll(json, key: "playlistPanelVideoRenderer").compactMap { item in
            guard let video = item as? [String: Any], let id = video["videoId"] as? String, seen.insert(id).inserted else { return nil }
            let title = text(video["title"])
            let artist = text(video["shortBylineText"] ?? video["longBylineText"])
            let clean = TrackTitle.clean(title: title, artist: artist)
            return Track(id: id, title: clean.title, artist: clean.artist)
        }
    }

    private static func post(_ endpoint: String, body: [String: Any], config: Config, signedIn: Bool = true) async -> [String: Any]? {
        guard let url = URL(string: "\(origin)/youtubei/v1/\(endpoint)?prettyPrint=false"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = data
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        if let visitor = (config.context["client"] as? [String: Any])?["visitorData"] as? String {
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if signedIn, let cookie = YouTubeSession.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if signedIn, let auth = YouTubeSession.authorization(origin: origin) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            YouTubeAccount.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        guard let (reply, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    /// JSON-объект в HTML сразу после метки (с учётом строк и экранирования).
    static func jsonObject(in data: Data, after marker: String) -> [String: Any]? {
        guard let found = data.range(of: Data(marker.utf8)) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: Any]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = found.upperBound - data.startIndex
            while i < bytes.count, bytes[i] == 0x20 { i += 1 }
            guard i < bytes.count, bytes[i] == 0x7B else { return nil } // {
            let begin = i
            var depth = 0, inString = false, escaped = false
            while i < bytes.count {
                let c = bytes[i]
                if inString {
                    if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                } else if c == 0x22 {
                    inString = true
                } else if c == 0x7B {
                    depth += 1
                } else if c == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        let slice = Data(bytes[begin...i])
                        return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                    }
                }
                i += 1
            }
            return nil
        }
    }

    static func string(in data: Data, after marker: String) -> String? {
        guard let found = data.range(of: Data(marker.utf8)) else { return nil }
        let value = data[found.upperBound...].prefix { $0 != 0x22 }
        return String(decoding: value, as: UTF8.self)
    }

    private static func findAll(_ object: Any, key: String) -> [Any] {
        var out: [Any] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict {
                    if k == key { out.append(v) } else { walk(v) }
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return out
    }

    private static func text(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return "" }
        if let simple = dict["simpleText"] as? String { return simple }
        return (dict["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
}

/// Системный плеер режима музыки (настройка «Системный плеер»): AVPlayer, своя очередь (микс или
/// свой плейлист), экран блокировки через MPNowPlayingInfoCenter. Не нашлось потока для первого
/// трека — `onFallback` отдаёт ссылку, и PlayerView включает её в обычном веб-плеере.
final class NativeAudio: NSObject {
    static let shared = NativeAudio()

    struct State {
        let id: String
        let title: String
        let artist: String
        let paused: Bool
        let time: Double
        let duration: Double
        let loop: Bool
    }

    var onState: ((State) -> Void)?
    var onFallback: ((URL, String?) -> Void)?
    /// Трек, который системный плеер не смог сыграть и отдал веб-плееру: при возврате из режима видео в музыку
    /// его не забираем снова (жалоба после 1.108 на iPhone 17: переход музыка ↔ видео перезапускал трек — системный
    /// плеер пробовал заново, ~30 с не играл и опять перезагружал страницу).
    var fellBackID: String?
    /// Последняя причина, по которой системному плееру не удалось включить трек.
    private var lastReason: String?

    private(set) var active = false
    private let player = AVPlayer()
    /// Канал каждого сыгранного трека (id и название) — для перехода к исполнителю из плеера.
    private var channels: [String: (id: String, name: String)] = [:]
    func channel(for trackID: String) -> (id: String, name: String)? { channels[trackID] }
    /// Название трека как на YouTube (у очищенного «(Lyrics)» отрезано) — чтобы узнать, что играет не оригинал.
    private var rawTitles: [String: String] = [:]
    private var storyboards: [String: String] = [:]

    /// Миниатюры кадров видео трека (для фона плеера; к воспроизведению не относятся).
    func storyboard(for trackID: String) -> String? { storyboards[trackID] }
    func rawTitle(for trackID: String) -> String? { rawTitles[trackID] }
    /// Тот же плеер — для картинки в музыкальном плеере (файл 360p вместо обложки, просьба владельца).
    var output: AVPlayer { player }
    private var queue: [Track] = []
    private var index = 0
    private var playlistID: String?
    /// Список, из которого играем (для мини-плеера с последним треком при запуске).
    var listID: String? { playlistID }
    private var loop = false
    private var candidates: [AudioStream] = []
    /// Откуда играет текущий трек («Скачано» — файл на телефоне, в нём только звук).
    private var currentClient = ""
    private var triedDirect = false
    private var token = UUID()
    private var playedOnce = false
    private var failuresInRow = 0
    /// YouTube отдаёт этому устройству видео только своим протоколом (SABR, без ссылок — так на iPad владельца, 1.77):
    /// 6 часов сразу играем обычным плеером, без попыток и без окна; потом пробуем снова.
    var sabrOnly: Bool {
        // С 1.100 SABR играет системный плеер — отметка прошлых версий («6 ч только обычный плеер») больше не нужна.
        if !UserDefaults.standard.bool(forKey: "sabrFlagReset100") {
            UserDefaults.standard.set(true, forKey: "sabrFlagReset100")
            UserDefaults.standard.removeObject(forKey: "sabrOnlyUntil")
        }
        return (UserDefaults.standard.object(forKey: "sabrOnlyUntil") as? Date ?? .distantPast) > Date()
    }
    private var extending = false
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var controlObservation: NSKeyValueObservation?
    /// Пауза — от владельца (кнопка, экран блокировки, отключили наушники). Иначе остановку считаем случайной.
    private var userPaused = false
    /// Звонок или другое приложение забрали звук — сами не продолжаем, ждём конца прерывания.
    private var interrupted = false
    private var recoveries: [Date] = []
    private var stallTimer: Timer?
    private var watchdog: Timer?
    private var waitingSince: Date?
    private var refreshingStream = false
    private var triedCachedAudio = false
    /// Передача из веб-плеера (возврат в режим музыки): с какого места и на паузе ли.
    private var pendingStart: Double?
    private var pendingPaused = false
    private var startAt: CMTime?
    private var startPaused = false
    /// 30 с без звука — трек уходит в обычный плеер (в 1.59–1.60 владелец оставался без музыки).
    private var deadline: Timer?
    private var lastProgress = Date()
    private var listened: Double = 0
    private var recordedID: String?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkID: String?
    /// Потоки следующего трека, найденные заранее (за ~25 с до конца текущего) — без паузы между треками.
    private var prefetched: [String: YouTubeStreams.Result] = [:]
    private var prefetching = Set<String>()
    /// Потоки недавно сыгранных треков (ссылки живут часами): «назад» и возврат из режима видео — без нового поиска.
    private var recent: [String: (result: YouTubeStreams.Result, at: Date)] = [:]
    /// Следующий трек заранее открыт (AVURLAsset загрузил начало файла) — переход без ожидания.
    private var preparedAssets: [URL: AVURLAsset] = [:]
    /// Переход в режим видео без тишины (владелец после 1.110: «чтобы летало»): звук играет, пока не заиграет
    /// веб-плеер (`finishHandover`), но не дольше 20 с.
    private(set) var handingOver = false
    private var handoverID: String?
    private var handoverStarted = Date()
    private var handoverTimer: Timer?
    /// Сколько грузится страница видео (по прошлым переходам): ссылка веб-плееру — на столько впереди.
    private var handoverLead: Double = UserDefaults.standard.object(forKey: "handoverLead") as? Double ?? 2.5
    /// Обратный переход (видео → музыка): веб-плеер играет, пока системный ищет поток; его живое время —
    /// чтобы системный начал ровно с того места, где сейчас веб.
    var liveWebTime: ((String) -> Double?)?
    /// Пока ищем поток, звука нет — без фоновой задачи iOS усыпила бы приложение между треками.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = Float(Settings.youtubeVolume)
        NotificationCenter.default.addObserver(self, selector: #selector(itemEnded(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.tick()
        }
        // Плеер встал — экран узнаёт сразу (периодический наблюдатель молчит, пока время стоит: раньше на экране
        // «бежало» время при остановленном плеере — жалоба владельца), а случайная остановка — сразу продолжается.
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.statusChanged() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    private func statusChanged() {
        guard active else { return }
        publish()
        guard player.timeControlStatus == .paused, !userPaused, !interrupted, let item = player.currentItem,
              playedOnceCurrent else { return }
        let duration = item.duration.seconds
        if duration.isFinite, player.currentTime().seconds > duration - 1 { return } // доиграл — дальше itemEnded
        // Случайная пауза: скрытое окно, останавливая своё видео, отбирало звук у приложения (владелец: «играет
        // чуть-чуть, потом будто пауза»). Продолжаем сами — не чаще 3 раз за 15 с, чтобы не спорить с iOS.
        let now = Date()
        recoveries = recoveries.filter { now.timeIntervalSince($0) < 15 }
        guard recoveries.count < 3 else { return }
        recoveries.append(now)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    /// Звонок/другое приложение — не продолжаем сами до конца прерывания (продолжит MainViewController по
    /// `.shouldResume`).
    @objc private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.interrupted = true
            } else {
                self.interrupted = false
            }
        }
    }

    /// Можно ли играть эту ссылку системным плеером: трек, микс или свой список (watch_videos).
    static func canPlay(_ url: URL) -> Bool {
        url.path == "/watch_videos" || PlayerView.videoID(from: url) != nil
    }

    var currentTrack: Track? { queue.indices.contains(index) ? queue[index] : nil }

    /// Для диагностики: что сейчас у системного плеера.
    var debugState: String {
        let time = player.currentTime().seconds
        let length = player.currentItem?.duration.seconds ?? 0
        let status = ["пауза", "ждёт", "играет"][min(2, player.timeControlStatus.rawValue)]
        let position: String = queue.isEmpty ? "очереди нет" : "\(index + 1) из \(queue.count)"
        return "активен: \(active ? "да" : "нет"), трек \(currentTrack?.id ?? "—") (\(position)), поток: \(currentClient.isEmpty ? "—" : currentClient), "
            + "\(status), \(time.isFinite ? Int(time) : 0)/\(length.isFinite ? Int(length) : 0) с, громкость \(Int(player.volume * 100))%, "
            + "неудач подряд \(failuresInRow), заранее найдено \(prefetched.count), ожидание: \(player.reasonForWaitingToPlay?.rawValue ?? "—")"
            + (lastReason.map { ", последняя причина: \($0)" } ?? "")
    }

    // MARK: - Очередь «Далее» (свайп вверх по плееру, просьба владельца после 1.69)

    static let queueDidChange = Notification.Name("FonNativeQueueDidChange")

    /// Треки после текущего.
    var upcoming: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    func playUpcoming(at offset: Int) {
        guard active, queue.indices.contains(index + 1 + offset) else { return }
        index += 1 + offset
        playCurrent()
    }

    func removeUpcoming(at offset: Int) {
        guard queue.indices.contains(index + 1 + offset) else { return }
        queue.remove(at: index + 1 + offset)
        queueChanged()
    }

    /// Переставить трек очереди (перетаскивание в «Далее»).
    func moveUpcoming(from: Int, to: Int) {
        let i = index + 1 + from, j = index + 1 + to
        guard queue.indices.contains(i), queue.indices.contains(j) else { return }
        queue.insert(queue.remove(at: i), at: j)
        queueChanged()
    }

    /// Поставить трек в очередь: `offset` 0 — следующим. Если он уже ждёт дальше — переносится сюда.
    func insertUpcoming(_ track: Track, at offset: Int) {
        guard active else { return }
        if let old = queue.indices.first(where: { $0 > index && queue[$0].id == track.id }) { queue.remove(at: old) }
        queue.insert(track, at: min(queue.count, index + 1 + max(0, offset)))
        queueChanged()
    }

    /// Включить сразу (другая версия трека); предыдущий остаётся позади — ⏮ вернёт к нему.
    func playNow(_ track: Track) {
        guard active else { return }
        insertUpcoming(track, at: 0)
        index += 1
        playCurrent()
    }

    private func queueChanged() {
        NotificationCenter.default.post(name: Self.queueDidChange, object: nil)
        fillTitles()
    }

    private var namingIDs = Set<String>()

    /// Треки очереди без названия (в «Далее» были просто «Трек» — скриншот после 1.84): ближайшие 12 —
    /// узнать название и исполнителя (`next` без входа, по 4 сразу).
    private func fillTitles() {
        let ids = queue.dropFirst(max(0, index)).prefix(13).filter { $0.title.isEmpty && !namingIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        namingIDs.formUnion(ids)
        Task { [weak self] in
            var names: [String: Track] = [:]
            await withTaskGroup(of: (String, Track?).self) { group in
                for id in ids {
                    group.addTask {
                        guard let info = await YouTubeStreams.videoDetails(id), !info.title.isEmpty else { return (id, nil) }
                        let clean = TrackTitle.clean(title: info.title, artist: info.channel)
                        return (id, Track(id: id, title: clean.title, artist: clean.artist))
                    }
                }
                for await (id, track) in group { if let track { names[id] = track } }
            }
            let found = names
            await MainActor.run {
                guard let self, !found.isEmpty else { return }
                var changed = false
                for i in self.queue.indices where self.queue[i].title.isEmpty {
                    if let named = found[self.queue[i].id] { self.queue[i] = named; changed = true }
                }
                if changed { NotificationCenter.default.post(name: Self.queueDidChange, object: nil) }
            }
        }
    }

    // MARK: - Запуск

    /// `paused` — трек передан из веб-плеера на паузе: открыть на том же месте, не включая.
    func start(url: URL, queue ids: [String]?, paused: Bool = false) {
        activate()
        pendingPaused = paused
        // Cookies входа копирует сам поиск потока (`DirectStream.find` → `YouTubeSession.refreshed`) — здесь не ждём,
        // а скачанный трек и найденный раньше поток играют сразу.
        begin(url: url, queue: ids)
    }

    private func begin(url: URL, queue ids: [String]?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        playedOnce = false
        failuresInRow = 0
        loop = false
        pendingStart = value("t").flatMap { Double($0.replacingOccurrences(of: "s", with: "")) }.flatMap { $0 > 0 ? $0 : nil }
        if url.path == "/watch_videos", let list = value("video_ids") {
            // Названия — из скачанных (без сети иначе их не узнать), понравившихся и истории.
            let known = Dictionary((OfflineStore.shared.tracks + CloudLikes.shared.tracks + Library.shared.history + Discover.shared.allTracks).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
            queue = list.split(separator: ",").map { known[String($0)] ?? Track(id: String($0), title: "", artist: "") }
            index = 0
            playlistID = nil
        } else if let id = value("v") {
            if let ids, let at = ids.firstIndex(of: id) {
                // Свой список (понравившиеся, история): играем его с нажатого трека.
                // Названия — из понравившихся и истории, чтобы в «Далее» были видны.
                let known = Dictionary((CloudLikes.shared.tracks + Library.shared.history + OfflineStore.shared.tracks).map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
                queue = ids.map { known[$0] ?? Track(id: $0, title: "", artist: "") }
                index = at
                playlistID = nil
            } else {
                queue = [Track(id: id, title: "", artist: "")]
                index = 0
                playlistID = value("list") ?? "RD" + id
                loadQueue(seed: id, playlistID: playlistID!)
            }
        }
        playCurrent()
    }

    /// Очередь микса/плейлиста подгружается следом — текущий трек уже играет.
    private func loadQueue(seed: String, playlistID: String) {
        guard !extending else { return }
        extending = true
        Task { [weak self] in
            var tracks = await YouTubeStreams.queue(videoID: seed, playlistID: playlistID)
            if tracks.isEmpty, !playlistID.hasPrefix("RD" + seed) {
                tracks = await YouTubeStreams.queue(videoID: seed, playlistID: "RD" + seed) // «Мой микс» без входа не отдаётся
            }
            await MainActor.run {
                guard let self, self.active else { return }
                self.extending = false
                var known = Set(self.queue.map(\.id))
                // Микс YouTube — без того, что владелец обычно пропускает (`Taste`); свой плейлист — как есть.
                let mix = playlistID.hasPrefix("RD")
                for track in tracks where known.insert(track.id).inserted && !(mix && Taste.shared.isDisliked(track)) {
                    self.queue.append(track)
                }
                // Названия для уже стоящих в очереди треков.
                for (i, track) in self.queue.enumerated() where track.title.isEmpty {
                    if let named = tracks.first(where: { $0.id == track.id }) { self.queue[i] = named }
                }
                self.queueChanged()
                self.publish()
            }
        }
    }

    private func playCurrent() {
        guard let track = currentTrack else { return }
        AppJournal.add("системный плеер: трек \(track.id) «\(track.title.prefix(40))» (\(index + 1) из \(queue.count))")
        let current = UUID()
        token = current
        // Место и пауза из веб-плеера — только для первого трека после передачи.
        startAt = pendingStart.map { CMTime(seconds: $0, preferredTimescale: 600) }
        startPaused = pendingPaused
        pendingStart = nil
        pendingPaused = false
        candidates = []
        triedDirect = false
        triedCachedAudio = false
        userPaused = false
        stallTimer?.invalidate()
        player.replaceCurrentItem(with: nil)
        listened = 0
        deadline?.invalidate()
        let limit = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, self.token == current, self.active, !self.playedOnceCurrent else { return }
            self.trackFailed()
        }
        RunLoop.main.add(limit, forMode: .common)
        deadline = limit
        publish(loading: true)
        queueChanged()
        beginBackgroundTask()
        // Скачан (офлайн) — с телефона, но только без сети или когда видео на обложке выключено: в скачанном
        // файле только звук, и с 1.84 у скачанных треков пропало видео (жалоба владельца после 1.86).
        // С сетью файл — запасной вариант, если поток не заиграет (`use`).
        if let file = OfflineStore.shared.file(for: track.id), !OfflineStore.shared.online || !Settings.videoArtwork {
            if track.title.isEmpty, let saved = OfflineStore.shared.track(for: track.id), queue.indices.contains(index) {
                queue[index] = saved
                publish(loading: true)
                queueChanged()
            }
            candidates = [AudioStream(url: file, headers: [:], client: "Скачано")]
            triedDirect = true
            tryNextCandidate()
            return
        }
        // Поток следующего трека найден заранее — сразу его; иначе прямой путь (без окна), потом окно.
        if let ready = prefetched.removeValue(forKey: track.id) ?? recentResult(track.id) {
            use(ready, for: track)
            tryNextCandidate()
        } else {
            tryDirect()
        }
    }

    /// Поток трека, найденный за последний час (ссылки googlevideo живут ~6 ч; не заиграет — поищем заново).
    private func recentResult(_ id: String) -> YouTubeStreams.Result? {
        guard let entry = recent[id], Date().timeIntervalSince(entry.at) < 3600 else { return nil }
        return entry.result
    }

    private func remember(_ result: YouTubeStreams.Result, for id: String) {
        guard !result.streams.isEmpty else { return }
        recent[id] = (result, Date())
        if recent.count > 30, let oldest = recent.min(by: { $0.value.at < $1.value.at })?.key { recent[oldest] = nil }
    }

    /// Найденные потоки — в очередь попыток; название — треку, если его ещё не было.
    private func use(_ result: YouTubeStreams.Result, for track: Track) {
        remember(result, for: track.id)
        AppJournal.add("поток \(track.id): " + (result.streams.isEmpty ? "нет — \(result.reason ?? "?")" : result.streams.map(\.client).joined(separator: ", ") + (result.reason.map { " (\($0))" } ?? "")))
        if let title = result.title { rawTitles[track.id] = title }
        if let id = result.channelID { channels[track.id] = (id, result.author ?? track.artist) }
        if let spec = result.storyboard { storyboards[track.id] = spec }
        if queue.indices.contains(index), queue[index].id == track.id, queue[index].title.isEmpty, let title = result.title {
            let clean = TrackTitle.clean(title: title, artist: result.author ?? "")
            queue[index] = Track(id: track.id, title: clean.title, artist: clean.artist)
            publish(loading: true)
            queueChanged()
        }
        candidates += Self.ordered(result.streams)
        if let file = OfflineStore.shared.file(for: track.id) {
            candidates.append(AudioStream(url: file, headers: [:], client: "Скачано")) // поток не заиграл — скачанный файл
        }
        if result.streams.isEmpty, result.noLinks {
            UserDefaults.standard.set(Date().addingTimeInterval(6 * 3600), forKey: "sabrOnlyUntil")
            UserDefaults.standard.set(result.reason, forKey: "sabrOnlyReason") // для подписи в ⚙ (iPhone 17 после 1.97)
            // Ожидаемо — переходим тихо; но если не справился свой SABR — окно с причиной (iPhone 17 после 1.103).
            lastReason = result.reason?.contains("SABR:") == true ? result.reason : nil
        } else if result.streams.isEmpty, let reason = result.reason {
            lastReason = reason
        }
    }

    /// Следующий из найденных потоков; ни один не заиграл — трек не получился.
    private func tryNextCandidate() {
        guard active else { return }
        // Звук 140 качается файлом в фоне (`DirectStream.asFiles`) — если файл 360p не заиграл, он запасной.
        if candidates.isEmpty, !triedCachedAudio, let track = currentTrack, let file = SabrEngine.cached(track.id), currentClient != "Прямо звук" {
            triedCachedAudio = true
            candidates = [AudioStream(url: file, headers: [:], client: "Прямо звук")]
        }
        guard !candidates.isEmpty else { return !triedDirect ? tryDirect() : trackFailed() }
        let stream = candidates.removeFirst()
        currentClient = stream.client
        AppJournal.add("играем: \(stream.client)")
        // Поток оборвался посреди трека (например, отдельная звуковая дорожка) — следующий с того же места.
        let first = !playedOnceCurrent
        let resumeAt: CMTime? = playedOnceCurrent ? player.currentTime() : startAt
        let asset = preparedAssets.removeValue(forKey: stream.url)
            ?? AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        let current = token
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.token == current, item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    // Переход из режима видео: веб-плеер всё это время играл — начинаем с его текущего места.
                    if first, resumeAt != nil, let id = self.currentTrack?.id, let live = self.liveWebTime?(id) {
                        self.player.seek(to: CMTime(seconds: live, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    } else if let resumeAt {
                        self.player.seek(to: resumeAt)
                    }
                    if self.startPaused {
                        self.startPaused = false
                        self.deadline?.invalidate()
                        self.stallTimer?.invalidate()
                        self.pause()
                    } else {
                        // Сразу, не дожидаясь «запаса» буфера (иначе ~1 с тишины в начале трека); дальше AVPlayer
                        // ведёт себя как обычно и при нехватке данных сам подождёт.
                        self.player.playImmediately(atRate: 1)
                    }
                case .failed:
                    let text = (item.error as NSError?)?.localizedDescription ?? "?"
                    self.lastReason = "плеер iOS: " + String(text.prefix(70))
                    AppJournal.add("плеер iOS не смог (\(stream.client)): \(text.prefix(120))")
                    self.tryNextCandidate()
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        if !startPaused { player.play() }
        // Не заиграл за 10 с — пробуем следующий поток.
        lastProgress = Date()
        stallTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.token == current, !self.playedOnceCurrent else { return }
            self.tryNextCandidate()
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    /// Порядок потоков: главный — файл 360p с картинкой (как на телефоне владельца, где www другого не даёт),
    /// чистый звук — запасной. С 1.109 m.youtube отдаёт и чистый звук, он шёл первым — на iPhone 17 пропало видео
    /// на обложке; владелец: «если 360p сработал, пусть он останется главным». Показ видео — нажатием на обложку.
    static func ordered(_ streams: [AudioStream]) -> [AudioStream] {
        let video = streams.filter { $0.client != "Прямо звук" && $0.client != "SABR" }
        let audio = streams.filter { $0.client == "Прямо звук" || $0.client == "SABR" }
        return video + audio
    }

    /// На обложке включили видео, а играет скачанный файл (в нём только звук; владелец после 1.88: «не играет видео
    /// по нажатию на сохранённых») — с сетью переходим на поток с видео с того же места, пауза сохраняется.
    func videoWanted() {
        // Скачанный файл или чистый звук m.youtube — в них нет картинки.
        guard active, currentClient == "Скачано" || currentClient == "Прямо звук", OfflineStore.shared.online, let track = currentTrack else { return }
        let was = currentClient
        let current = token
        Task { [weak self] in
            let found = await DirectStream.find(track.id)
            await MainActor.run {
                guard let self, self.token == current, self.currentClient == was else { return }
                let video = found.streams.filter { $0.client != "Прямо звук" && $0.client != "SABR" }
                guard !video.isEmpty else { return }
                if let title = found.title { self.rawTitles[track.id] = title }
                if let spec = found.storyboard { self.storyboards[track.id] = spec }
                let file = OfflineStore.shared.file(for: track.id).map { AudioStream(url: $0, headers: [:], client: "Скачано") }
                self.candidates = video + (file.map { [$0] } ?? [])
                self.startPaused = self.player.timeControlStatus == .paused
                self.tryNextCandidate() // с того же места: `resumeAt` = текущее время
            }
        }
    }

    /// Поток трека (вариант 3 владельца): ссылка со страницы запросом приложения + «решатель» yt-dlp — без окна.
    private func tryDirect() {
        guard !triedDirect, let track = currentTrack else { return trackFailed() }
        // Нет сети, а трек не скачан — играем скачанное (следующее по очереди или вперемешку).
        if !OfflineStore.shared.online, playOfflineInstead() { return }
        triedDirect = true
        let current = token
        Task { [weak self] in
            let found = await DirectStream.find(track.id)
            await MainActor.run {
                guard let self, self.token == current, self.active else { return }
                self.use(found, for: track)
                self.tryNextCandidate()
            }
        }
    }

    private var playedOnceCurrent: Bool { player.currentTime().seconds > 0.5 }

    /// Трек не заиграл. На экране: первый трек (или два подряд) — в веб-плеер с этим же треком.
    /// В фоне веб-плеер не запустится (владелец: «переходит в обычный плеер и вообще останавливается») —
    /// там пропускаем трек, а после трёх неудач подряд (скорее всего, нет сети) встаём на паузу: ▶ попробует снова.
    private func trackFailed() {
        failuresInRow += 1
        AppJournal.add("трек не заиграл (подряд \(failuresInRow)), на экране: \(UIApplication.shared.applicationState == .active ? "да" : "нет"); \(lastReason ?? "")")
        if UIApplication.shared.applicationState == .active {
            if !playedOnce || failuresInRow >= 2 { fallBackToWeb() } else { next() }
        } else if failuresInRow < 3 {
            next() // один трек недоступен (возраст, регион, медленная сеть) — пропускаем
        } else {
            token = UUID()
            stallTimer?.invalidate()
            deadline?.invalidate()
            userPaused = true
            player.replaceCurrentItem(with: nil) // ▶ — заново этот трек
            publish()
            endBackgroundTask()
        }
    }

    /// Раз в секунду: поток посреди трека «грузится» дольше 10 с (сменилась сеть, ссылка устарела после
    /// долгой паузы) — берём новую ссылку и продолжаем с того же места (владелец: «в какой-то момент долго грузит»).
    private func watchStall() {
        guard active, !userPaused, !interrupted, !refreshingStream, playedOnceCurrent,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            waitingSince = nil
            return
        }
        let since = waitingSince ?? Date()
        waitingSince = since
        guard Date().timeIntervalSince(since) > 10, let track = currentTrack else { return }
        waitingSince = nil
        refreshingStream = true
        AppJournal.add("поток «грузится» >10 с — ищем новую ссылку")
        beginBackgroundTask()
        let current = token
        Task { [weak self] in
            let found = await DirectStream.find(track.id)
            await MainActor.run {
                guard let self else { return }
                self.refreshingStream = false
                guard self.token == current, self.active else { return }
                guard !found.streams.isEmpty else { return }
                self.candidates = Self.ordered(found.streams)
                self.tryNextCandidate() // с того же места (`resumeAt`)
            }
        }
    }

    /// Трек — в обычный веб-плеер (системный не справился).
    private func fallBackToWeb() {
        guard let track = currentTrack else { return }
        AppJournal.add("переход в обычный плеер YouTube: \(track.id)")
        fellBackID = track.id
        let url = YouTubeLinks.watch(track.id, list: playlistID) ?? YouTubeLinks.mix(track.id)
        let reason = lastReason
        lastReason = nil
        deactivate()
        if let url { onFallback?(url, reason) }
    }

    // MARK: - Команды

    func handle(_ command: String) {
        switch command {
        case "toggle": player.timeControlStatus == .paused ? play() : pause()
        case "play": play()
        case "pause": pause()
        case "next": next()
        case "prev": previous()
        case "loop":
            loop.toggle()
            publish()
        default: break
        }
    }

    func play() {
        userPaused = false
        if player.currentItem == nil {
            failuresInRow = 0 // после «3 трека подряд не заиграли» — пробуем заново
            playCurrent()
        } else {
            player.play()
        }
        publish()
    }

    func pause() {
        userPaused = true
        player.pause()
        publish()
    }

    /// Своя громкость (ползунок в плеере) — у системного плеера она работает, в отличие от веб-страницы.
    func setVolume(_ value: Double) {
        player.volume = Float(max(0, min(1, value)))
    }

    private var seekingTo: Double?
    private var seekStarted = Date.distantPast
    private var seekID = 0

    /// Время для ползунка: настоящее время плеера, а пока идёт перемотка — место, куда перематываем
    /// (сразу после `seek` плеер ещё сообщает старое время — ползунок отпрыгивал назад и обратно).
    /// Звук действительно идёт (не «ждёт данных»).
    var isPlaying: Bool { active && player.timeControlStatus == .playing }

    var displayTime: Double {
        if let target = seekingTo, Date().timeIntervalSince(seekStarted) < 4 { return target }
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    func seek(_ seconds: Double) {
        seekID += 1
        let id = seekID
        seekingTo = seconds
        seekStarted = Date()
        // Точно в выбранное место: по умолчанию AVPlayer прыгает к ближайшему ключевому кадру видео,
        // и после отпускания ползунок сдвигался на пару секунд.
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, id == self.seekID else { return }
                self.seekingTo = nil
                self.publish()
            }
        }
        publish()
    }

    /// Без сети: следующий скачанный трек очереди, а нет такого — все скачанные вперемешку («о, это моя любимая»).
    @discardableResult
    private func playOfflineInstead() -> Bool {
        let store = OfflineStore.shared
        if let i = queue.indices.first(where: { $0 > index && store.file(for: queue[$0].id) != nil }) {
            index = i
            playCurrent()
            return true
        }
        let pool = Array(store.tracks.filter { $0.id != currentTrack?.id }.shuffled().prefix(50))
        guard !pool.isEmpty else { return false }
        let start = queue.count
        queue += pool
        index = start
        playlistID = nil
        playCurrent()
        return true
    }

    func next() {
        guard active else { return }
        if !OfflineStore.shared.online, index + 1 >= queue.count || OfflineStore.shared.file(for: queue[index + 1].id) == nil {
            if playOfflineInstead() { return }
        }
        if index + 1 < queue.count {
            index += 1
            playCurrent()
        } else if let last = currentTrack {
            // Очередь кончилась — дальше похожие (микс по последнему треку), как делает YouTube.
            playlistID = playlistID ?? "RD" + last.id
            extending = false
            let before = queue.count
            loadQueue(seed: last.id, playlistID: playlistID!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.queue.count > before else { return }
                self.index = before
                self.playCurrent()
            }
        }
        if queue.count - index < 4, let seed = queue.last?.id, let list = playlistID { loadQueue(seed: seed, playlistID: list) }
    }

    func previous() {
        if player.currentTime().seconds > 3 || index == 0 {
            seek(0)
        } else {
            index -= 1
            playCurrent()
        }
    }

    @objc private func itemEnded(_ note: Notification) {
        guard active, (note.object as? AVPlayerItem) === player.currentItem else { return }
        if loop {
            seek(0)
            player.play()
        } else {
            next()
        }
    }

    /// Переход в режим видео: ссылка для веб-плеера и системный плеер выключается. Если звук идёт — он играет,
    /// пока веб-плеер грузит страницу (`finishHandover`), а ссылка — на время загрузки впереди: без тишины.
    func handOver() -> URL? {
        guard active, let track = currentTrack else { return nil }
        let playing = player.timeControlStatus == .playing && playedOnceCurrent
        let now = playedOnceCurrent ? player.currentTime().seconds : (startAt?.seconds ?? 0)
        let duration = player.currentItem?.duration.seconds ?? 0
        var at = now + (playing ? handoverLead : 0)
        if duration.isFinite, duration > 0, at > duration - 3 { at = now }
        let url = handoverURL(id: track.id, time: at)
        deactivate(keepSound: playing)
        if playing {
            handingOver = true
            handoverID = track.id
            handoverStarted = Date()
            let timer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in _ = self?.finishHandover() }
            RunLoop.main.add(timer, forMode: .common)
            handoverTimer = timer
        }
        return url
    }

    /// Веб-плеер заиграл (или прошло 20 с) — звук системного плеера выключается. Возвращает его время, чтобы веб-плеер
    /// догнал, если угадали с загрузкой неточно.
    func finishHandover(webID: String? = nil) -> Double? {
        guard handingOver else { return nil }
        if let webID, let handoverID, webID != handoverID { return nil }
        handingOver = false
        handoverTimer?.invalidate()
        handoverTimer = nil
        let time = player.currentTime().seconds
        if webID != nil {
            // Время загрузки страницы — на следующий раз (плавно, в пределах 1–6 с).
            let took = Date().timeIntervalSince(handoverStarted)
            handoverLead = min(6, max(1, handoverLead * 0.5 + took * 0.5))
            UserDefaults.standard.set(handoverLead, forKey: "handoverLead")
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        return time.isFinite ? time : nil
    }

    /// Время звука, который ещё играет при переходе в режим видео (nil — перехода нет).
    var handoverSeconds: Double? {
        guard handingOver else { return nil }
        let time = player.currentTime().seconds
        return time.isFinite ? time : nil
    }

    private func handoverURL(id: String, time: Double) -> URL? {
        var components = URLComponents(string: "https://m.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: id),
                                 URLQueryItem(name: "t", value: "\(time.safeInt)s")]
            + (playlistID.map { [URLQueryItem(name: "list", value: $0)] } ?? [])
        return components.url
    }

    // MARK: - Состояние

    private func tick() {
        guard active else { return }
        let t = player.currentTime().seconds
        if player.timeControlStatus == .playing, t > 0.5 {
            playedOnce = true
            failuresInRow = 0
            stallTimer?.invalidate()
            deadline?.invalidate()
            endBackgroundTask()
            listened += 0.5
            // Следующий трек — заранее, но только прямым путём: окно, останавливая своё видео посреди песни,
            // могло выключить звук приложения, а прямой путь звук не трогает.
            prefetchNextIfNeeded(time: t)
            // Другие версии (Slowed/Lyrics/Sped up) — заранее, пока приложение открыто: при свайпе вверх уже готовы.
            if listened >= 3, let track = currentTrack, UIApplication.shared.applicationState == .active {
                TrackVersions.prepare(track, rawTitle: rawTitles[track.id])
            }
            // «Недавно слушали» — после 20 с, как у веб-плеера.
            if listened >= 20, let track = currentTrack, recordedID != track.id, !track.title.isEmpty {
                recordedID = track.id
                Library.shared.recordPlay(track)
            }
        }
        publish()
    }

    private func prefetchNextIfNeeded(time: Double) {
        let duration = player.currentItem?.duration.seconds ?? 0
        // Заранее — уже после 5 с игры, а не за 25 с до конца: «следующий» по нажатию тоже сразу (iPhone 17 после
        // 1.109: на каждом переходе ждал поиска ссылки; там же двойная длина 140 не давала дойти до «за 25 с»).
        guard duration.isFinite, duration - time < 25 || time > 5, index + 1 < queue.count else { return }
        let id = queue[index + 1].id
        guard prefetched[id] == nil, !prefetching.contains(id) else { return }
        prefetching.insert(id)
        Task { [weak self] in
            let result = await DirectStream.find(id)
            await MainActor.run {
                guard let self else { return }
                self.prefetching.remove(id)
                guard !result.streams.isEmpty else { return }
                self.prefetched[id] = result
                // Первый поток открываем заранее: AVPlayer получит уже загруженное начало файла.
                if let stream = Self.ordered(result.streams).first, self.preparedAssets[stream.url] == nil {
                    let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                    asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) {}
                    if self.preparedAssets.count >= 3 { self.preparedAssets.removeAll() }
                    self.preparedAssets[stream.url] = asset
                }
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func publish(loading: Bool = false) {
        guard active, let track = currentTrack else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let waiting = !playedOnceCurrent
        let state = State(id: track.id, title: track.title.isEmpty && (loading || waiting) ? tr("Загрузка…") : track.title,
                          artist: track.artist, paused: player.timeControlStatus == .paused,
                          time: displayTime,
                          duration: duration.isFinite ? duration : 0, loop: loop)
        onState?(state)
        updateNowPlaying(state)
    }

    // MARK: - Экран блокировки

    /// Экран блокировки сам двигает ползунок по `PlaybackRate`, поэтому тикать в него дважды в секунду не нужно:
    /// обновляем при смене трека/паузы/длительности и когда время ушло от ожидаемого (перемотка).
    private var nowPlayingSignature = ""
    private var nowPlayingStamp: (time: Double, at: CFAbsoluteTime)?

    private func updateNowPlaying(_ state: State) {
        let command = MPRemoteCommandCenter.shared().likeCommand
        let liked = CloudLikes.shared.isLiked(state.id)
        if command.isActive != liked { command.isActive = liked }
        let signature = "\(state.id)|\(state.title)|\(state.artist)|\(state.paused)|\(state.duration.safeInt)"
        let now = CFAbsoluteTimeGetCurrent()
        var drift = Double.infinity
        if let last = nowPlayingStamp { drift = abs((state.paused ? last.time : last.time + (now - last.at)) - state.time) }
        guard signature != nowPlayingSignature || drift > 1.5 else { return }
        nowPlayingSignature = signature
        nowPlayingStamp = (state.time, now)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.time,
            MPNowPlayingInfoPropertyPlaybackRate: state.paused ? 0.0 : 1.0
        ]
        if state.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        let center = MPNowPlayingInfoCenter.default()
        if let artwork = center.nowPlayingInfo?[MPMediaItemPropertyArtwork], artworkID == state.id {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        guard artworkID != state.id else { return }
        artworkID = state.id
        let id = state.id
        var albumShown = false
        ArtworkLoader.shared.load(id, size: .player) { image, _ in
            guard let image, !albumShown, self.artworkID == id, var info = center.nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            center.nowPlayingInfo = info
        }
        // Обложка альбома (iTunes) — только на экран блокировки, поверх кадра YouTube, если нашлась.
        guard !state.title.isEmpty, state.title != tr("Загрузка…") else { artworkID = nil; return }
        AlbumCover.load(id: id, title: state.title, artist: state.artist) { image in
            guard let image, self.artworkID == id, var info = center.nowPlayingInfo else { return }
            albumShown = true
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            center.nowPlayingInfo = info
        }
    }

    private func activate() {
        if handingOver { _ = finishHandover() } // снова в музыку, пока веб-плеер ещё грузился
        guard !active else { return }
        active = true
        try? AVAudioSession.sharedInstance().setActive(true)
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.watchStall() }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: action)))
        }
        on(center.playCommand) { [weak self] _ in self?.play(); return .success }
        on(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        // Команда остаётся включённой: выключенную iOS заменяет на «пауза»/«играть», и касание всё равно сработает.
        on(center.togglePlayPauseCommand) { [weak self] _ in
            if Settings.ignoreHeadphoneTap { AppJournal.add("наушники: касание пропущено"); return .success }
            self?.handle("toggle")
            return .success
        }
        on(center.nextTrackCommand) { [weak self] _ in self?.next(); return .success }
        on(center.previousTrackCommand) { [weak self] _ in self?.previous(); return .success }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(event.positionTime)
            return .success
        }
        // ♡ на экране блокировки / в пункте управления (просьба владельца после 1.69; проба — покажет ли iOS).
        center.likeCommand.localizedTitle = tr("Понравившиеся")
        center.likeCommand.localizedShortTitle = "♡"
        on(center.likeCommand) { [weak self] _ in
            guard let track = self?.currentTrack, !track.title.isEmpty else { return .commandFailed }
            CloudLikes.shared.setLiked(track, !CloudLikes.shared.isLiked(track.id))
            self?.publish()
            return .success
        }
    }

    /// Отдать звук веб-плееру: остановиться и убрать свои кнопки с экрана блокировки (иначе спорим с WebKit).
    func deactivate(keepSound: Bool = false) {
        guard active else { return }
        active = false
        token = UUID()
        stallTimer?.invalidate()
        deadline?.invalidate()
        watchdog?.invalidate()
        refreshingStream = false
        if !keepSound {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        commandTargets.forEach { $0.0.removeTarget($0.1) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlayingSignature = ""
        nowPlayingStamp = nil
        artworkID = nil
        prefetched = [:]
        endBackgroundTask()
    }
}
