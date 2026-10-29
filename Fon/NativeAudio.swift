import AVFoundation
import CryptoKit
import MediaPlayer
import UIKit
import WebKit

/// Ссылка на поток трека и с какими заголовками её открывать.
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
            let youtube = all.filter { $0.domain.hasSuffix("youtube.com") }
            lock.lock()
            cookies = youtube
            lock.unlock()
            completion?()
        }
    }

    /// Свежая копия перед каждым поиском потока: Google время от времени обновляет cookies входа, и за час-другой
    /// игры старая копия могла устареть (страница видео отвечала бы как без входа).
    static func refreshed() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { refresh { done.resume() } }
        }
    }

    static var cookieHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
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
        var log: [String] = []
    }

    /// Очередь плейлиста или микса (`next`): треки по порядку.
    /// Трек очереди и аудиотрек ли он (обложка + звук от дистрибьютора, канал «Исполнитель - Topic»),
    /// а не клип или выступление.
    struct QueueItem {
        let track: Track
        let audioTrack: Bool
    }

    static func queue(videoID: String, playlistID: String) async -> [QueueItem] {
        let cfg = config ?? fallbackConfig
        let body: [String: Any] = ["context": YouTubeAccount.context(cfg.context), "videoId": videoID, "playlistId": playlistID]
        guard let json = await post("next", body: body, config: cfg) else { return [] }
        var seen = Set<String>()
        return findAll(json, key: "playlistPanelVideoRenderer").compactMap { item in
            guard let video = item as? [String: Any], let id = video["videoId"] as? String, seen.insert(id).inserted else { return nil }
            let title = text(video["title"])
            let artist = text(video["shortBylineText"] ?? video["longBylineText"])
            let clean = TrackTitle.clean(title: title, artist: artist)
            // Тип от YouTube (MUSIC_VIDEO_TYPE_ATV — аудиотрек, OMV — клип, UGC — прочее); нет типа — по каналу «… - Topic».
            let type = findAll(video, key: "musicVideoType").first as? String
            return QueueItem(track: Track(id: id, title: clean.title, artist: clean.artist),
                             audioTrack: type.map { $0 == "MUSIC_VIDEO_TYPE_ATV" } ?? isTopicChannel(artist))
        }
    }

    private static func isTopicChannel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["- topic", "– topic", "- тема", "– тема"].contains { lower.hasSuffix($0) }
    }

    private static func post(_ endpoint: String, body: [String: Any], config: Config) async -> [String: Any]? {
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
        if let cookie = YouTubeSession.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let auth = YouTubeSession.authorization(origin: origin) {
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
    var onFallback: ((URL) -> Void)?

    private(set) var active = false
    /// Что ответили клиенты YouTube в последний раз — показываем в настройках.
    static var lastLog: String {
        get { UserDefaults.standard.string(forKey: "nativeAudioLog") ?? "ещё не было" }
        set { UserDefaults.standard.set(newValue, forKey: "nativeAudioLog") }
    }

    /// Прошлые попытки (до 10, новые сверху) — для кнопки «Скопировать журнал» в настройках.
    static var logHistory: [String] {
        get { UserDefaults.standard.stringArray(forKey: "nativeAudioLogHistory") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: "nativeAudioLogHistory") }
    }

    /// Весь журнал одним текстом: текущая попытка и прошлые.
    static var fullLog: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return (["Fon \(version), iOS \(UIDevice.current.systemVersion)", lastLog] + logHistory).joined(separator: "\n\n")
    }

    /// Новая попытка: прошлая уходит в историю (с временем и id трека).
    private static func startLog(for id: String) {
        let previous = lastLog
        if !previous.isEmpty, previous != "ещё не было" { logHistory = [previous] + logHistory }
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lastLog = "[\(time)] \(id)"
    }

    private let player = AVPlayer()
    /// Тот же плеер — для картинки в музыкальном плеере (файл 360p вместо обложки, просьба владельца).
    var output: AVPlayer { player }
    private var queue: [Track] = []
    private var index = 0
    private var playlistID: String?
    private var loop = false
    private var candidates: [AudioStream] = []
    private var triedDirect = false
    /// Журнал этой попытки уже ушёл на GitHub (`LogUploader`).
    private var reported = false
    private var token = UUID()
    private var playedOnce = false
    private var failuresInRow = 0
    private var extending = false
    /// Микс, который приложение собрало само от трека (`RD<id>`, или очередь кончилась), — не выбранный плейлист.
    private var autoMix = false
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
    /// Передача из веб-плеера (возврат в режим музыки): с какого места и на паузе ли.
    private var pendingStart: Double?
    private var pendingPaused = false
    private var startAt: CMTime?
    private var startPaused = false
    /// 30 с без звука — трек уходит в обычный плеер (в 1.59–1.60 владелец оставался без музыки).
    private var deadline: Timer?
    /// Текущий шаг поиска потока — виден в плеере вместо исполнителя, пока звука нет.
    private var step: String?
    private var lastProgress = Date()
    private var listened: Double = 0
    private var recordedID: String?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkID: String?
    /// Потоки следующего трека, найденные заранее (за ~25 с до конца текущего) — без паузы между треками.
    private var prefetched: [String: YouTubeStreams.Result] = [:]
    private var prefetching = Set<String>()
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
        NativeAudio.lastLog += "; пауза не от вас — продолжил"
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

    // MARK: - Запуск

    /// `paused` — трек передан из веб-плеера на паузе: открыть на том же месте, не включая.
    func start(url: URL, queue ids: [String]?, paused: Bool = false) {
        activate()
        pendingPaused = paused
        // Свежий вход в аккаунт (cookies WebKit) — дальше запросы идут без WebKit, в том числе в фоне.
        YouTubeSession.refresh { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                self.begin(url: url, queue: ids)
            }
        }
    }

    private func begin(url: URL, queue ids: [String]?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        playedOnce = false
        failuresInRow = 0
        loop = false
        autoMix = false
        pendingStart = value("t").flatMap { Double($0.replacingOccurrences(of: "s", with: "")) }.flatMap { $0 > 0 ? $0 : nil }
        if url.path == "/watch_videos", let list = value("video_ids") {
            queue = list.split(separator: ",").map { Track(id: String($0), title: "", artist: "") }
            index = 0
            playlistID = nil
        } else if let id = value("v") {
            if let ids, let at = ids.firstIndex(of: id) {
                // Свой список (понравившиеся, история): играем его с нажатого трека.
                queue = ids.map { Track(id: $0, title: "", artist: "") }
                index = at
                playlistID = nil
            } else {
                queue = [Track(id: id, title: "", artist: "")]
                index = 0
                playlistID = value("list") ?? "RD" + id
                autoMix = playlistID == "RD" + id
                loadQueue(seed: id, playlistID: playlistID!)
            }
        }
        playCurrent()
    }

    /// Очередь микса/плейлиста подгружается следом — текущий трек уже играет.
    /// В миксе от трека (`autoMix`) — только аудиотреки (просьба владельца: клипы и выступления — когда включил сам
    /// или в выбранных миксах); новых мало — микс от последнего аудиотрека (там их больше).
    private func loadQueue(seed: String, playlistID: String, reseeded: Bool = false) {
        guard !extending else { return }
        extending = true
        let filter = autoMix
        Task { [weak self] in
            var items = await YouTubeStreams.queue(videoID: seed, playlistID: playlistID)
            if items.isEmpty, !playlistID.hasPrefix("RD" + seed) {
                items = await YouTubeStreams.queue(videoID: seed, playlistID: "RD" + seed) // «Мой микс» без входа не отдаётся
            }
            await MainActor.run {
                guard let self, self.active else { return }
                self.extending = false
                let audio = items.filter(\.audioTrack)
                // Аудиотреков нет совсем — лучше играть что есть, чем остановиться.
                let chosen = filter && !audio.isEmpty ? audio : items
                var known = Set(self.queue.map(\.id))
                var added = 0
                for item in chosen where known.insert(item.track.id).inserted {
                    self.queue.append(item.track)
                    added += 1
                }
                if filter { NativeAudio.lastLog += "; очередь: \(items.count), аудиотреков \(audio.count)" }
                // Названия для уже стоящих в очереди треков.
                for (i, track) in self.queue.enumerated() where track.title.isEmpty {
                    if let named = items.first(where: { $0.track.id == track.id }) { self.queue[i] = named.track }
                }
                self.publish()
                if filter, !reseeded, added < 5, let last = audio.last(where: { $0.track.id != seed })?.track.id {
                    self.playlistID = "RD" + last
                    self.loadQueue(seed: last, playlistID: "RD" + last, reseeded: true)
                }
            }
        }
    }

    private func playCurrent() {
        guard let track = currentTrack else { return }
        let current = UUID()
        token = current
        // Место и пауза из веб-плеера — только для первого трека после передачи.
        startAt = pendingStart.map { CMTime(seconds: $0, preferredTimescale: 600) }
        startPaused = pendingPaused
        pendingStart = nil
        pendingPaused = false
        candidates = []
        triedDirect = false
        userPaused = false
        stallTimer?.invalidate()
        player.replaceCurrentItem(with: nil)
        listened = 0
        NativeAudio.startLog(for: track.id)
        reported = false
        step = nil
        deadline?.invalidate()
        let limit = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, self.token == current, self.active, !self.playedOnceCurrent else { return }
            self.log("30 с без звука")
            self.trackFailed()
        }
        RunLoop.main.add(limit, forMode: .common)
        deadline = limit
        publish(loading: true)
        beginBackgroundTask()
        // Поток следующего трека найден заранее — сразу его; иначе прямой путь (без окна), потом окно.
        if let ready = prefetched.removeValue(forKey: track.id) {
            use(ready, for: track)
            tryNextCandidate()
        } else {
            tryDirect()
        }
    }

    /// Найденные потоки — в очередь попыток; название — треку, если его ещё не было.
    /// Журнал попытки (виден в ⚙) — по шагам, сразу, чтобы было видно, на чём остановилось.
    private func log(_ text: String) {
        NativeAudio.lastLog += (NativeAudio.lastLog.isEmpty ? "" : "; ") + text
        step = text
        publish(loading: true)
    }

    private func use(_ result: YouTubeStreams.Result, for track: Track) {
        if !result.log.isEmpty { log(result.log.joined(separator: "; ")) }
        if queue.indices.contains(index), queue[index].id == track.id, queue[index].title.isEmpty, let title = result.title {
            let clean = TrackTitle.clean(title: title, artist: result.author ?? "")
            queue[index] = Track(id: track.id, title: clean.title, artist: clean.artist)
            publish(loading: true)
        }
        candidates += result.streams
    }

    /// Следующий из найденных потоков; ни один не заиграл — трек не получился.
    private func tryNextCandidate() {
        guard active else { return }
        guard !candidates.isEmpty else { return !triedDirect ? tryDirect() : trackFailed() }
        let stream = candidates.removeFirst()
        log("\(stream.client): пробую")
        // Поток оборвался посреди трека (например, отдельная звуковая дорожка) — следующий с того же места.
        let resumeAt: CMTime? = playedOnceCurrent ? player.currentTime() : startAt
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        let current = token
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.token == current, item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    if let resumeAt { self.player.seek(to: resumeAt) }
                    if self.startPaused {
                        self.startPaused = false
                        self.deadline?.invalidate()
                        self.stallTimer?.invalidate()
                        self.pause()
                    } else {
                        self.player.play()
                    }
                case .failed:
                    NativeAudio.lastLog += "; \(stream.client): \(Self.describe(item))"
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
            NativeAudio.lastLog += "; \(stream.client): не заиграл"
            self.tryNextCandidate()
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    /// Поток трека (вариант 3 владельца): ссылка со страницы запросом приложения + «решатель» yt-dlp — без окна.
    private func tryDirect() {
        guard !triedDirect, let track = currentTrack else { return trackFailed() }
        triedDirect = true
        log("прямо: ищу ссылку…")
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

    /// Почему поток не открылся: код HTTP из журнала AVPlayer (403 — YouTube не пустил) или код ошибки.
    private static func describe(_ item: AVPlayerItem) -> String {
        if let event = item.errorLog()?.events.last, event.errorStatusCode != 0 {
            return "HTTP \(event.errorStatusCode)"
        }
        guard let error = item.error as NSError? else { return "ошибка" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(error.code)/\(underlying.code)"
        }
        return "\(error.code)"
    }

    /// Трек не заиграл. На экране: первый трек (или два подряд) — в веб-плеер с этим же треком.
    /// В фоне веб-плеер не запустится (владелец: «переходит в обычный плеер и вообще останавливается») —
    /// там пропускаем трек, а после трёх неудач подряд (скорее всего, нет сети) встаём на паузу: ▶ попробует снова.
    private func trackFailed() {
        failuresInRow += 1
        if UIApplication.shared.applicationState == .active {
            if !playedOnce || failuresInRow >= 2 { fallBackToWeb() } else { next() }
        } else if failuresInRow < 3 {
            next() // один трек недоступен (возраст, регион, медленная сеть) — пропускаем
        } else {
            log("3 трека подряд не заиграли — пауза")
            report()
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
        NativeAudio.lastLog += "; грузится >10 с на \(Int(player.currentTime().seconds)) с — новая ссылка"
        beginBackgroundTask()
        let current = token
        Task { [weak self] in
            let found = await DirectStream.find(track.id)
            await MainActor.run {
                guard let self else { return }
                self.refreshingStream = false
                guard self.token == current, self.active else { return }
                guard !found.streams.isEmpty else {
                    NativeAudio.lastLog += "; новой ссылки нет: " + found.log.joined(separator: "; ")
                    return
                }
                self.candidates = found.streams
                self.tryNextCandidate() // с того же места (`resumeAt`)
            }
        }
    }

    /// Трек — в обычный веб-плеер (системный не справился).
    private func fallBackToWeb() {
        guard let track = currentTrack else { return }
        let url = YouTubeLinks.watch(track.id, list: playlistID) ?? YouTubeLinks.mix(track.id)
        log("→ обычный плеер")
        report()
        deactivate()
        if let url { onFallback?(url) }
    }

    /// Итог попытки (заиграло или ушло в обычный плеер) — в обсуждение GitHub, если владелец включил.
    private func report() {
        guard !reported else { return }
        reported = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        LogUploader.send("Fon \(version), iOS \(UIDevice.current.systemVersion)\n" + NativeAudio.lastLog)
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

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        publish()
    }

    func next() {
        guard active else { return }
        if index + 1 < queue.count {
            index += 1
            playCurrent()
        } else if let last = currentTrack {
            // Очередь кончилась — дальше похожие (микс по последнему треку), как делает YouTube.
            if playlistID == nil {
                playlistID = "RD" + last.id
                autoMix = true
            }
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

    /// Ссылка для веб-плеера с текущего места — при переходе в режим видео.
    func handoverURL() -> URL? {
        guard let track = currentTrack else { return nil }
        var components = URLComponents(string: "https://m.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: track.id),
                                 URLQueryItem(name: "t", value: "\(Int(player.currentTime().seconds))s")]
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
            if !reported {
                // Размер картинки потока — чтобы решить, годится ли этот путь для режима видео (владелец спросил).
                let size = player.currentItem?.presentationSize ?? .zero
                log(size.width > 0 ? "играет ✓, картинка \(Int(size.width))×\(Int(size.height))" : "играет ✓")
                report()
            }
            endBackgroundTask()
            listened += 0.5
            // Следующий трек — заранее, но только прямым путём: окно, останавливая своё видео посреди песни,
            // могло выключить звук приложения, а прямой путь звук не трогает.
            prefetchNextIfNeeded(time: t)
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
        guard duration.isFinite, duration - time < 25, index + 1 < queue.count else { return }
        let id = queue[index + 1].id
        guard prefetched[id] == nil, !prefetching.contains(id) else { return }
        prefetching.insert(id)
        Task { [weak self] in
            let result = await DirectStream.find(id)
            await MainActor.run {
                guard let self else { return }
                self.prefetching.remove(id)
                if !result.streams.isEmpty { self.prefetched[id] = result }
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
        let state = State(id: track.id, title: track.title.isEmpty && (loading || waiting) ? "Загрузка…" : track.title,
                          artist: waiting ? (step ?? track.artist) : track.artist, paused: player.timeControlStatus == .paused,
                          time: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
                          duration: duration.isFinite ? duration : 0, loop: loop)
        onState?(state)
        updateNowPlaying(state)
    }

    // MARK: - Экран блокировки

    private func updateNowPlaying(_ state: State) {
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
        ArtworkLoader.shared.load(id, size: .player) { image, _ in
            guard let image, self.artworkID == id, var info = center.nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            center.nowPlayingInfo = info
        }
    }

    private func activate() {
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
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.handle("toggle"); return .success }
        on(center.nextTrackCommand) { [weak self] _ in self?.next(); return .success }
        on(center.previousTrackCommand) { [weak self] _ in self?.previous(); return .success }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(event.positionTime)
            return .success
        }
    }

    /// Отдать звук веб-плееру: остановиться и убрать свои кнопки с экрана блокировки (иначе спорим с WebKit).
    func deactivate() {
        guard active else { return }
        active = false
        token = UUID()
        stallTimer?.invalidate()
        deadline?.invalidate()
        watchdog?.invalidate()
        refreshingStream = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        commandTargets.forEach { $0.0.removeTarget($0.1) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artworkID = nil
        prefetched = [:]
        endBackgroundTask()
    }
}
