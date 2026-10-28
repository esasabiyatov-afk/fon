import AVFoundation
import MediaPlayer
import UIKit

/// Ссылка на поток трека и с какими заголовками её открывать.
struct AudioStream {
    let url: URL
    let headers: [String: String]
    let client: String
}

/// Внутренний API YouTube напрямую из приложения (URLSession, без веб-страницы — работает и в фоне).
/// Поток берём у клиентов, которые отдают готовые ссылки без расшифровки подписи: IOS и Safari — HLS,
/// Android VR — аудио m4a. YouTube периодически закрывает такие лазейки, поэтому клиентов несколько,
/// а если не сработал ни один — трек играет обычный веб-плеер.
enum YouTubeStreams {
    private struct Client {
        let name: String
        let headerID: String
        let version: String
        let userAgent: String
        let extra: [String: Any]
    }

    private static var webVersion: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "2." + formatter.string(from: Date().addingTimeInterval(-2 * 86400)) + ".01.00"
    }

    private static var clients: [Client] {
        [
            Client(name: "IOS", headerID: "5", version: "20.10.4",
                   userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                   extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]),
            Client(name: "WEB", headerID: "1", version: webVersion,
                   userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
                   extra: [:]),
            Client(name: "ANDROID_VR", headerID: "28", version: "1.62.27",
                   userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                   extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"])
        ]
    }

    struct Result {
        var streams: [AudioStream] = []
        var title: String?
        var author: String?
        var log: [String] = []
    }

    /// Все найденные потоки трека — по порядку предпочтения. Сначала — запросом самой страницы m.youtube
    /// (вход в аккаунт, Safari): так YouTube отвечает охотнее всего; затем — клиенты напрямую.
    static func resolve(_ videoID: String) async -> Result {
        var result = Result()
        if let page = await viaPage(videoID) {
            let headers = ["User-Agent": WebViewFactory.safariUserAgent()]
            if let hls = (page["hls"] as? String).flatMap(URL.init(string:)) {
                result.streams.append(AudioStream(url: hls, headers: headers, client: "MWEB HLS"))
            }
            for url in (page["audio"] as? [String] ?? []).prefix(1).compactMap(URL.init(string:)) {
                result.streams.append(AudioStream(url: url, headers: headers, client: "MWEB m4a"))
            }
            result.title = page["title"] as? String
            result.author = page["author"] as? String
            result.log.append("MWEB: " + (page["diag"] as? String ?? "?"))
        } else {
            result.log.append("MWEB: нет ответа")
        }
        for client in clients {
            var context: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "ru"]
            context.merge(client.extra) { $1 }
            let body: [String: Any] = ["context": ["client": context], "videoId": videoID,
                                       "contentCheckOk": true, "racyCheckOk": true]
            guard let json = await post("player", body: body, client: client) else {
                result.log.append("\(client.name): нет ответа")
                continue
            }
            let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
            if let details = json["videoDetails"] as? [String: Any] {
                result.title = result.title ?? details["title"] as? String
                result.author = result.author ?? details["author"] as? String
            }
            guard status == "OK", let data = json["streamingData"] as? [String: Any] else {
                result.log.append("\(client.name): \(status)")
                continue
            }
            let headers = ["User-Agent": client.userAgent]
            var found = 0
            if let hls = (data["hlsManifestUrl"] as? String).flatMap(URL.init(string:)) {
                result.streams.append(AudioStream(url: hls, headers: headers, client: client.name + " HLS"))
                found += 1
            }
            // Готовые ссылки на аудио (без signatureCipher): лучше всего m4a — его играет AVPlayer.
            let audio = (data["adaptiveFormats"] as? [[String: Any]] ?? []).filter {
                ($0["mimeType"] as? String ?? "").hasPrefix("audio/mp4") && $0["url"] is String
            }
            if let best = audio.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }),
               let url = (best["url"] as? String).flatMap(URL.init(string:)) {
                result.streams.append(AudioStream(url: url, headers: headers, client: client.name + " m4a"))
                found += 1
            }
            let kinds = result.streams.filter { $0.client.hasPrefix(client.name + " ") }.map { $0.client.replacingOccurrences(of: client.name + " ", with: "") }
            result.log.append("\(client.name): \(found == 0 ? "нет ссылок" : kinds.joined(separator: "+"))")
        }
        return result
    }

    /// Запрос из скрытого окна m.youtube (`__fonCloud.stream`). Не ответило за 10 с — nil.
    private static func viaPage(_ id: String) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                var done = false
                let finish: ([String: Any]?) -> Void = { value in
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: value)
                }
                HiddenPage.youtube.call("__fonCloud.stream(id)", { ["id": id] }) { result in
                    if case .success(let value) = result { finish(value as? [String: Any]) } else { finish(nil) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
            }
        }
    }

    /// Очередь плейлиста или микса (`next`): треки по порядку.
    static func queue(videoID: String, playlistID: String) async -> [Track] {
        guard let web = clients.first(where: { $0.name == "WEB" }) else { return [] }
        let body: [String: Any] = ["context": ["client": ["clientName": web.name, "clientVersion": web.version, "hl": "ru"]],
                                   "videoId": videoID, "playlistId": playlistID]
        guard let json = await post("next", body: body, client: web) else { return [] }
        var seen = Set<String>()
        return findAll(json, key: "playlistPanelVideoRenderer").compactMap { item in
            guard let video = item as? [String: Any], let id = video["videoId"] as? String, seen.insert(id).inserted else { return nil }
            let title = text(video["title"])
            let artist = text(video["shortBylineText"] ?? video["longBylineText"])
            let clean = TrackTitle.clean(title: title, artist: artist)
            return Track(id: id, title: clean.title, artist: clean.artist)
        }
    }

    private static func post(_ endpoint: String, body: [String: Any], client: Client) async -> [String: Any]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = data
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.headerID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        guard let (reply, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
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

    private let player = AVPlayer()
    private var queue: [Track] = []
    private var index = 0
    private var playlistID: String?
    private var loop = false
    private var candidates: [AudioStream] = []
    private var token = UUID()
    private var playedOnce = false
    private var failuresInRow = 0
    private var extending = false
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var stallTimer: Timer?
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
        NotificationCenter.default.addObserver(self, selector: #selector(itemEnded(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.tick()
        }
    }

    /// Можно ли играть эту ссылку системным плеером: трек, микс или свой список (watch_videos).
    static func canPlay(_ url: URL) -> Bool {
        url.path == "/watch_videos" || PlayerView.videoID(from: url) != nil
    }

    var currentTrack: Track? { queue.indices.contains(index) ? queue[index] : nil }

    // MARK: - Запуск

    func start(url: URL, queue ids: [String]?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        activate()
        playedOnce = false
        failuresInRow = 0
        loop = false
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
                let known = Set(self.queue.map(\.id))
                for track in tracks where !known.contains(track.id) { self.queue.append(track) }
                // Названия для уже стоящих в очереди треков.
                for (i, track) in self.queue.enumerated() where track.title.isEmpty {
                    if let named = tracks.first(where: { $0.id == track.id }) { self.queue[i] = named }
                }
                self.publish()
            }
        }
    }

    private func playCurrent() {
        guard let track = currentTrack else { return }
        let current = UUID()
        token = current
        candidates = []
        stallTimer?.invalidate()
        player.replaceCurrentItem(with: nil)
        listened = 0
        publish(loading: true)
        beginBackgroundTask()
        let ready = prefetched.removeValue(forKey: track.id)
        Task { [weak self] in
            let result: YouTubeStreams.Result
            if let ready { result = ready } else { result = await YouTubeStreams.resolve(track.id) }
            await MainActor.run {
                guard let self, self.token == current, self.active else { return }
                NativeAudio.lastLog = result.log.joined(separator: "; ")
                if self.queue[self.index].title.isEmpty, let title = result.title {
                    let clean = TrackTitle.clean(title: title, artist: result.author ?? "")
                    self.queue[self.index] = Track(id: track.id, title: clean.title, artist: clean.artist)
                }
                self.candidates = result.streams
                self.tryNextCandidate()
            }
        }
    }

    /// Следующий из найденных потоков; ни один не заиграл — трек не получился.
    private func tryNextCandidate() {
        guard active else { return }
        guard !candidates.isEmpty else { return trackFailed() }
        let stream = candidates.removeFirst()
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredPeakBitRate = 400_000 // у HLS есть и видео — берём самый лёгкий вариант
        item.preferredMaximumResolution = CGSize(width: 256, height: 144)
        let current = token
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.token == current, item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    self.player.play()
                case .failed:
                    NativeAudio.lastLog += "; \(stream.client): \(Self.describe(item))"
                    self.tryNextCandidate()
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        // Не заиграл за 12 с — пробуем следующий поток.
        lastProgress = Date()
        stallTimer?.invalidate()
        let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
            guard let self, self.token == current, !self.playedOnceCurrent else { return }
            NativeAudio.lastLog += "; \(stream.client): не заиграл"
            self.tryNextCandidate()
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
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

    /// Первый трек не заиграл (или два подряд) — переходим на веб-плеер с этим же треком.
    private func trackFailed() {
        failuresInRow += 1
        if !playedOnce || failuresInRow >= 2 {
            guard let track = currentTrack else { return }
            let url = YouTubeLinks.watch(track.id, list: playlistID) ?? YouTubeLinks.mix(track.id)
            deactivate()
            if let url { onFallback?(url) }
            return
        } else {
            next() // один трек недоступен (возраст, регион) — пропускаем
        }
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
        if player.currentItem == nil { playCurrent() } else { player.play() }
        publish()
    }

    func pause() {
        player.pause()
        publish()
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
            endBackgroundTask()
            listened += 0.5
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
            let result = await YouTubeStreams.resolve(id)
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
        let state = State(id: track.id, title: loading && track.title.isEmpty ? "Загрузка…" : track.title,
                          artist: track.artist, paused: player.timeControlStatus == .paused,
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
