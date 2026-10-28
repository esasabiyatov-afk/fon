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
    /// Главный список HLS (со всеми качествами) — AVPlayer сам выбирает вариант, ограничиваем его.
    var isMaster = false
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

    static var signedIn: Bool { sapisid != nil }

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

/// Защитный токен YouTube (PO token) для потока: его выдаёт BotGuard в скрытом окне www.youtube.com
/// (`Scripts.potoken`). Токен живёт часами — храним в памяти, чтобы следующие треки (и в фоне, когда
/// WebKit может спать) обходились без окна.
enum PoToken {
    private static var cache: [String: (token: String, until: Date)] = [:] // только главный поток

    static func token(for identifier: String) async -> (token: String?, note: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                if let cached = cache[identifier], cached.until > Date() {
                    return continuation.resume(returning: (cached.token, "из памяти"))
                }
                var done = false
                let finish: (String?, String) -> Void = { token, note in
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: (token, note))
                }
                HiddenPage.desktop.call("__fonPot.mint(id)", { ["id": identifier] }) { result in
                    switch result {
                    case .success(let value):
                        guard let dict = value as? [String: Any], let token = dict["token"] as? String, !token.isEmpty else {
                            return finish(nil, "пустой ответ")
                        }
                        let ttl = (dict["ttl"] as? NSNumber)?.doubleValue ?? 3600
                        cache[identifier] = (token, Date().addingTimeInterval(max(300, ttl)))
                        finish(token, "получен")
                    case .failure(let error):
                        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                        finish(nil, "ошибка (\(message.prefix(80)))")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 45) { finish(nil, "нет ответа") }
            }
        }
    }
}

/// Поток трека для системного плеера. YouTube отдаёт готовый поток HLS (его AVPlayer играет сам,
/// без расшифровки подписи) браузеру Safari на Mac — как в yt-dlp клиент `web_safari`. Поэтому
/// запрашиваем страницу видео www.youtube.com с User-Agent Safari для Mac и cookies входа в аккаунт;
/// нет HLS в странице — тот же запрос через внутренний API (`player`). В 1.43–1.47 пробовали клиенты
/// IOS/WEB/ANDROID_VR/MWEB без входа и с мобильным Safari — рабочей ссылки не было.
enum YouTubeStreams {
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    private static let origin = "https://www.youtube.com"

    /// Настройки клиента со страницы YouTube (контекст запроса, версия плеера) — для внутреннего API.
    private struct Config {
        let context: [String: Any]
        let clientVersion: String
        let signatureTimestamp: Int?
        /// Для защитного токена: dataSyncId аккаунта (со входом) или visitorData (без входа).
        let identifier: String?
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
               clientVersion: webVersion, signatureTimestamp: nil, identifier: nil)
    }

    struct Result {
        var streams: [AudioStream] = []
        var title: String?
        var author: String?
        var log: [String] = []
    }

    /// Все найденные потоки трека — по порядку предпочтения.
    static func resolve(_ videoID: String) async -> Result {
        var result = Result()
        result.log.append(YouTubeSession.signedIn ? "вход: да" : "вход: нет")
        let page = await watchPage(videoID)
        result.log.append("страница: " + page.note)
        var response = page.response
        if hlsURL(response) == nil {
            let cfg = config ?? fallbackConfig
            var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
            if let sts = cfg.signatureTimestamp { playback["signatureTimestamp"] = sts }
            let body: [String: Any] = ["context": cfg.context, "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
                                       "playbackContext": ["contentPlaybackContext": playback]]
            if let api = await post("player", body: body, config: cfg) {
                result.log.append("API: " + describe(api))
                if response == nil || hlsURL(api) != nil { response = api }
            } else {
                result.log.append("API: нет ответа")
            }
        }
        if let details = response?["videoDetails"] as? [String: Any] {
            result.title = details["title"] as? String
            result.author = details["author"] as? String
        }
        guard var master = hlsURL(response) else { return result }
        // Защитный токен (без него куски потока — 403): как yt-dlp, дописываем /pot/<токен> к ссылке HLS.
        if let identifier = config?.identifier {
            let pot = await PoToken.token(for: identifier)
            result.log.append("токен: " + pot.note)
            if let token = pot.token, let url = URL(string: master.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/pot/" + token) {
                master = url
            }
        } else {
            result.log.append("токен: нет идентификатора")
        }
        let streams = await playlists(master: master)
        result.log.append("HLS: " + streams.map(\.client).joined(separator: ", "))
        if let first = streams.first { result.log.append("проверка: " + (await probe(first))) }
        result.streams = streams
        return result
    }

    /// Страница видео, как её получает Safari на Mac: ytInitialPlayerResponse + настройки клиента.
    private static func watchPage(_ id: String) async -> (response: [String: Any]?, note: String) {
        guard let url = URL(string: "\(origin)/watch?v=\(id)&has_verified=1&bpctr=9999999999&hl=ru") else { return (nil, "нет ссылки") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let cookie = YouTubeSession.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, reply) = try? await URLSession.shared.data(for: request) else { return (nil, "нет ответа") }
        let code = (reply as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return (nil, "HTTP \(code)") }
        if let context = jsonObject(in: data, after: "\"INNERTUBE_CONTEXT\":") {
            let client = context["client"] as? [String: Any]
            let dataSync = string(in: data, after: "\"DATASYNC_ID\":\"")?.components(separatedBy: "||").first
            let visitor = client?["visitorData"] as? String
            config = Config(context: context, clientVersion: client?["clientVersion"] as? String ?? webVersion,
                            signatureTimestamp: number(in: data, after: "\"STS\":"),
                            identifier: (dataSync?.isEmpty == false ? dataSync : nil) ?? visitor)
        }
        let response = jsonObject(in: data, after: "ytInitialPlayerResponse = ")
        return (response, response.map(describe) ?? "без ответа плеера")
    }

    private static func hlsURL(_ response: [String: Any]?) -> URL? {
        guard let data = response?["streamingData"] as? [String: Any] else { return nil }
        return (data["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
    }

    /// Коротко для журнала: статус, есть ли HLS, причина отказа.
    private static func describe(_ response: [String: Any]) -> String {
        let playability = response["playabilityStatus"] as? [String: Any]
        var text = playability?["status"] as? String ?? "?"
        if let reason = playability?["reason"] as? String { text += " (\(reason.prefix(60)))" }
        if let data = response["streamingData"] as? [String: Any] {
            text += data["hlsManifestUrl"] != nil ? ", HLS" : ", без HLS"
            if data["serverAbrStreamingUrl"] != nil { text += ", SABR" }
        }
        return text
    }

    /// Из главного списка HLS — сначала только звук (если YouTube дал отдельную дорожку), потом вариант
    /// 360p (в нём AAC 128 кбит/с; у 144p/240p звук 48 кбит/с), в конце сам главный список.
    private static func playlists(master: URL) async -> [AudioStream] {
        let headers = ["User-Agent": desktopUserAgent]
        let masterStream = AudioStream(url: master, headers: headers, client: "HLS", isMaster: true)
        var request = URLRequest(url: master, timeoutInterval: 15)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            return [masterStream]
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [AudioStream] = []
        // Отдельные звуковые дорожки (itag 234 — 128 кбит/с, 233 — 48 кбит/с).
        let audio = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") }.compactMap { line -> (Int, URL)? in
            guard let uri = attribute("URI", in: line), let url = URL(string: uri, relativeTo: master)?.absoluteURL else { return nil }
            let group = attribute("GROUP-ID", in: line) ?? ""
            let rank = group.contains("234") ? 3 : group.contains("140") ? 2 : group.contains("233") ? 0 : 1
            return (rank, url)
        }
        if let best = audio.max(by: { $0.0 < $1.0 }) {
            out.append(AudioStream(url: best.1, headers: headers, client: "HLS звук"))
        }
        var variants: [(height: Int, bandwidth: Int, url: URL)] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let uri = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: master)?.absoluteURL else { continue }
            let height = attribute("RESOLUTION", in: line).flatMap { Int($0.split(separator: "x").last ?? "") } ?? 0
            let bandwidth = attribute("BANDWIDTH", in: line).flatMap { Int($0) } ?? 0
            variants.append((height: height, bandwidth: bandwidth, url: url))
        }
        if audio.isEmpty, let v360 = variants.filter({ $0.height >= 360 }).min(by: { $0.bandwidth < $1.bandwidth }) {
            out.append(AudioStream(url: v360.url, headers: headers, client: "HLS \(v360.height)p"))
        }
        out.append(masterStream)
        return out
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) }
        }
        return String(rest.prefix { $0 != "," })
    }

    /// Очередь плейлиста или микса (`next`): треки по порядку.
    static func queue(videoID: String, playlistID: String) async -> [Track] {
        let cfg = config ?? fallbackConfig
        let body: [String: Any] = ["context": cfg.context, "videoId": videoID, "playlistId": playlistID]
        guard let json = await post("next", body: body, config: cfg) else { return [] }
        var seen = Set<String>()
        return findAll(json, key: "playlistPanelVideoRenderer").compactMap { item in
            guard let video = item as? [String: Any], let id = video["videoId"] as? String, seen.insert(id).inserted else { return nil }
            let title = text(video["title"])
            let artist = text(video["shortBylineText"] ?? video["longBylineText"])
            let clean = TrackTitle.clean(title: title, artist: artist)
            return Track(id: id, title: clean.title, artist: clean.artist)
        }
    }

    private static func post(_ endpoint: String, body: [String: Any], config: Config) async -> [String: Any]? {
        guard let url = URL(string: "\(origin)/youtubei/v1/\(endpoint)?prettyPrint=false"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = data
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
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
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        guard let (reply, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    /// JSON-объект в HTML сразу после метки (с учётом строк и экранирования).
    private static func jsonObject(in data: Data, after marker: String) -> [String: Any]? {
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

    /// Сами открываем список и первый кусок потока — в журнал: на каком шаге YouTube отказывает.
    private static func probe(_ stream: AudioStream) async -> String {
        func get(_ url: URL, range: Bool) async -> (Int, Data?) {
            var request = URLRequest(url: url, timeoutInterval: 10)
            stream.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            if range { request.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
            guard let (data, reply) = try? await URLSession.shared.data(for: request) else { return (0, nil) }
            return ((reply as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let (code, data) = await get(stream.url, range: false)
        var note = "список \(code)"
        guard code == 200, let text = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return note }
        note += text.contains("/pot/") || text.contains("pot=") ? " (с токеном)" : " (без токена)"
        var playlist = text, base = stream.url
        for _ in 0..<2 {
            guard let line = playlist.components(separatedBy: .newlines).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let next = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL else { return note }
            guard line.contains(".m3u8") || line.contains("/playlist") else {
                let (segmentCode, _) = await get(next, range: true)
                return note + ", кусок \(segmentCode)"
            }
            // Главный список — открываем вложенный (вариант качества) и берём его первый кусок.
            let (innerCode, innerData) = await get(next, range: false)
            note += ", вложенный \(innerCode)"
            guard innerCode == 200, let inner = innerData.flatMap({ String(data: $0, encoding: .utf8) }) else { return note }
            playlist = inner
            base = next
        }
        return note
    }

    private static func string(in data: Data, after marker: String) -> String? {
        guard let found = data.range(of: Data(marker.utf8)) else { return nil }
        let value = data[found.upperBound...].prefix { $0 != 0x22 }
        return String(decoding: value, as: UTF8.self)
    }

    private static func number(in data: Data, after marker: String) -> Int? {
        guard let found = data.range(of: Data(marker.utf8)) else { return nil }
        let digits = data[found.upperBound...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        return Int(String(decoding: digits, as: UTF8.self))
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

/// Поток по находке владельца (29.10.2026): www.youtube.com/watch?app=desktop в Safari на iPhone играет
/// системным плеером iOS — у видео обычная ссылка на поток, а не MediaSource. Скрытое окно открывает такую
/// страницу (со входом в аккаунт, UA как у Safari) и отдаёт ссылку AVPlayer. Окно **одно и постоянное**:
/// страница грузится один раз, следующие треки — командой плеера YouTube `__fonLoad(id)` (быстрее, меньше
/// запросов к Google — без капчи). Не вышло (нет плеера, капча, 15 с без ссылки) — страница грузится заново.
final class SafariStream: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Куда вставить скрытое окно (без родителя WebKit не работает) — задаёт MainViewController.
    static weak var host: UIView?
    /// Для проверки (просьба владельца): окно видно поверх приложения карточкой, можно нажимать.
    static let visible = false

    private static let shared = SafariStream()
    /// Когда окно последний раз останавливало своё видео — прерывание звука сразу после этого вызвано окном.
    static var lastStop = Date.distantPast

    private typealias Completion = (URL?, String, String?, String?) -> Void
    private var webView: WKWebView?
    private var card: UIView?
    private var cardLabel: UILabel?
    /// Страница загружена, плеер YouTube на ней — следующий трек можно включать без перезагрузки.
    private var pageReady = false
    private var queue: [(id: String, completion: Completion)] = []
    private var currentID: String?
    private var completion: Completion?
    private var attempt = 0

    /// Поток трека и его название.
    static func find(_ videoID: String) async -> YouTubeStreams.Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                shared.request(videoID) { url, note, title, userAgent in
                    var result = YouTubeStreams.Result()
                    result.log.append("Safari: " + note)
                    if let url {
                        let hls = url.absoluteString.contains("m3u8") || url.host?.hasPrefix("manifest") == true
                        result.streams = [AudioStream(url: url, headers: ["User-Agent": userAgent ?? WebViewFactory.safariUserAgent()],
                                                      client: hls ? "Safari HLS" : "Safari файл", isMaster: hls)]
                    }
                    let name = (title ?? "").replacingOccurrences(of: " - YouTube", with: "").trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, name != "YouTube" { result.title = name } // пока страница грузится, там просто «YouTube»
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Запросы — строго по одному (окно одно).
    private func request(_ videoID: String, completion: @escaping Completion) {
        queue.append((id: videoID, completion: completion))
        runNext()
    }

    private func runNext() {
        guard completion == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard let webView = ensureWebView() else { return next.completion(nil, "нет окна", nil, nil) }
        completion = next.completion
        currentID = next.id
        attempt += 1
        let current = attempt
        setCard("Ищу: \(next.id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.attempt == current else { return }
            self.timedOut()
        }
        guard pageReady else { return load(next.id) }
        let id = next.id.replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript("window.__fonLoad ? __fonLoad('\(id)') : false") { [weak self] value, _ in
            guard let self, self.attempt == current, self.completion != nil else { return }
            if value as? Bool != true { self.load(next.id) } // плеера на странице нет — грузим заново
        }
    }

    private func load(_ videoID: String) {
        pageReady = false
        // Компьютерная версия (`app=desktop`, не m.youtube): на iPhone её плеер играет системным плеером iOS
        // по обычной ссылке — владелец проверил в Safari, в том числе со входом в аккаунт.
        webView?.load(URLRequest(url: URL(string: "https://www.youtube.com/watch?app=desktop&v=\(videoID)")!))
    }

    private func ensureWebView() -> WKWebView? {
        if let webView { return webView }
        guard let host = Self.host else { return nil }
        let config = WKWebViewConfiguration()
        // С входом в аккаунт (общие cookies приложения): в 1.61 окно «без cookies» на каждый трек Google принял за бота
        // (google.com/sorry — капча). Владелец проверил: со входом в Safari системный плеер тоже работает.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [] // звук и так выключен скриптом; «play» нужен для ссылки
        // Именно как iPhone: с «Запросом версии для компьютера» (UA Mac) YouTube включает свой плеер (проверил
        // владелец). На iPad WebKit по умолчанию просит версию для компьютера — запрещаем.
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        // User-Agent ровно как у Safari: WebKit сам подставляет версию iOS так, как это делает Safari (в iOS 26 —
        // «iPhone OS 18_6»), а мы дописываем хвост Safari. Со своим UA («iPhone OS 26_…») YouTube давал свой плеер.
        let parts = UIDevice.current.systemVersion.split(separator: ".")
        config.applicationNameForUserAgent = "Version/\(parts.first ?? "18").\(parts.count > 1 ? parts[1] : "0") Mobile/15E148 Safari/604.1"
        config.userContentController.add(WeakScriptHandler(self), name: "fonSrc")
        config.userContentController.addUserScript(WKUserScript(source: Scripts.safariSource, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.navigationDelegate = self
        if Self.visible {
            let card = UIView(frame: CGRect(x: 12, y: host.safeAreaInsets.top + 8, width: host.bounds.width - 24,
                                            height: min(host.bounds.height * 0.5, 460)))
            card.backgroundColor = .black
            card.layer.cornerRadius = 14
            card.layer.borderWidth = 2
            card.layer.borderColor = PlayerView.accent.cgColor
            card.clipsToBounds = true
            let label = UILabel(frame: CGRect(x: 10, y: 0, width: card.bounds.width - 20, height: 26))
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            card.addSubview(label)
            webView.frame = CGRect(x: 0, y: 26, width: card.bounds.width, height: card.bounds.height - 26)
            card.addSubview(webView)
            host.addSubview(card)
            self.card = card
            cardLabel = label
        } else {
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
            host.insertSubview(webView, at: 0)
        }
        self.webView = webView
        return webView
    }

    private func setCard(_ text: String) {
        guard let card, let cardLabel, let host = Self.host else { return }
        cardLabel.text = text
        host.bringSubviewToFront(card)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard completion != nil, let body = message.body as? [String: Any], let text = body["src"] as? String,
              let url = URL(string: text) else { return }
        // Ссылка от прошлого трека (плеер ещё не переключился) — не та.
        if let id = body["id"] as? String, !id.isEmpty, let currentID, id != currentID { return }
        // Для оценки «можно ли без окна, одними запросами»: какие защиты в рабочей ссылке (только имена, без значений).
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        let marks = ["pot", "n", "sig", "lsig", "itag"].filter(names.contains).joined(separator: ",")
        let itag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itag" }?.value ?? "?"
        finish(url, (text.contains("m3u8") ? "ссылка HLS" : "ссылка на файл") + " (itag \(itag); \(marks))",
               title: body["title"] as? String, userAgent: body["ua"] as? String)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageReady = false
        finish(nil, "страница не открылась")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        finish(nil, "окно перезапущено")
    }

    /// На мобильной версии (m.youtube.com) системного плеера нет (проверил владелец) — туда не идём.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let main = navigationAction.targetFrame?.isMainFrame != false
        if main, navigationAction.request.url?.host == "m.youtube.com" {
            decisionHandler(.cancel)
            pageReady = false
            finish(nil, "YouTube перекинул на мобильную версию")
            return
        }
        if main, let url = navigationAction.request.url, url.host?.hasSuffix("google.com") == true, url.path.hasPrefix("/sorry") {
            decisionHandler(.cancel)
            pageReady = false
            finish(nil, "Google просит капчу (принял за бота)")
            return
        }
        decisionHandler(.allow)
    }

    /// За 15 с ссылки нет — в журнал то, что видно на странице; в следующий раз страница грузится заново.
    private func timedOut() {
        guard completion != nil, let webView else { return }
        let current = attempt
        pageReady = false
        webView.evaluateJavaScript("window.__fonDiag ? __fonDiag() : 'скрипт не работал'") { [weak self] value, _ in
            guard let self, self.attempt == current else { return }
            self.finish(nil, "ссылки нет (\(value as? String ?? "страница не ответила"))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.attempt == current else { return }
            self.finish(nil, "ссылки нет (страница не ответила)")
        }
    }

    private func finish(_ url: URL?, _ note: String, title: String? = nil, userAgent: String? = nil) {
        guard let completion else { return }
        self.completion = nil
        attempt += 1 // таймеры этой попытки больше не действуют
        setCard((url != nil ? "Найдено: " : "Нет: ") + note)
        // Сначала останавливаем видео окна и даём WebKit «отпустить» звук, потом отдаём ссылку плееру.
        // Иначе WebKit отпускал звук приложения уже после старта AVPlayer: время шло, звука не было (владелец).
        webView?.evaluateJavaScript("window.__fonStop && __fonStop()", completionHandler: nil)
        Self.lastStop = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            completion(url, note, title, userAgent)
            self?.runNext()
        }
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
    private var queue: [Track] = []
    private var index = 0
    private var playlistID: String?
    private var loop = false
    private var candidates: [AudioStream] = []
    private var triedSafari = false
    private var triedMain = false
    /// Журнал этой попытки уже ушёл на GitHub (`LogUploader`).
    private var reported = false
    private var token = UUID()
    private var playedOnce = false
    private var failuresInRow = 0
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
    /// `.shouldResume`). Прерывание сразу после остановки видео скрытого окна — это само окно, не звонок.
    @objc private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.interrupted = Date().timeIntervalSince(SafariStream.lastStop) > 3
                if !self.interrupted { self.statusChanged() }
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

    func start(url: URL, queue ids: [String]?) {
        activate()
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
        triedSafari = false
        triedMain = false
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
            self.fallBackToWeb()
        }
        RunLoop.main.add(limit, forMode: .common)
        deadline = limit
        publish(loading: true)
        beginBackgroundTask()
        // Поток следующего трека найден заранее — сразу его; иначе сначала компьютерная версия (Safari),
        // потом запасной путь через страницу и токен.
        if let ready = prefetched.removeValue(forKey: track.id) {
            use(ready, for: track)
            tryNextCandidate()
        } else {
            trySafari()
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

    /// Запасной путь: поток со страницы www.youtube.com + защитный токен (см. YouTubeStreams).
    /// Путь «страница + токен» (YouTubeStreams.resolve + PoToken): в 1.57–1.62 ни разу не заиграл (куски — 403),
    /// только оттягивал переход в обычный плеер — выключен. Код оставлен на случай, если пригодится.
    static let useStreamFallback = false

    private func tryMain() {
        guard Self.useStreamFallback, !triedMain, let track = currentTrack else { return trackFailed() }
        triedMain = true
        log("страница и токен: ищу…")
        let current = token
        Task { [weak self] in
            let result = await YouTubeStreams.resolve(track.id)
            await MainActor.run {
                guard let self, self.token == current, self.active else { return }
                self.use(result, for: track)
                self.tryNextCandidate()
            }
        }
    }

    /// Следующий из найденных потоков; ни один не заиграл — трек не получился.
    private func tryNextCandidate() {
        guard active else { return }
        guard !candidates.isEmpty else { return triedSafari ? tryMain() : trySafari() }
        let stream = candidates.removeFirst()
        log("\(stream.client): пробую")
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        if stream.isMaster {
            // В главном списке звук идёт вместе с видео: 360p — самый лёгкий вариант с нормальным звуком.
            item.preferredPeakBitRate = 1_500_000
            item.preferredMaximumResolution = CGSize(width: 640, height: 360)
        }
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

    /// Основной путь: ссылка HLS, которую компьютерная версия YouTube даёт системному плееру (один раз на трек).
    private func trySafari() {
        guard !triedSafari, let track = currentTrack else { return tryMain() }
        triedSafari = true
        log("Safari: ищу ссылку…")
        let current = token
        Task { [weak self] in
            let found = await SafariStream.find(track.id)
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

    /// Первый трек не заиграл (или два подряд) — переходим на веб-плеер с этим же треком.
    private func trackFailed() {
        failuresInRow += 1
        if !playedOnce || failuresInRow >= 2 {
            fallBackToWeb()
        } else {
            next() // один трек недоступен (возраст, регион) — пропускаем
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
        if player.currentItem == nil { playCurrent() } else { player.play() }
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
            deadline?.invalidate()
            if !reported {
                // Размер картинки потока — чтобы решить, годится ли этот путь для режима видео (владелец спросил).
                let size = player.currentItem?.presentationSize ?? .zero
                log(size.width > 0 ? "играет ✓, картинка \(Int(size.width))×\(Int(size.height))" : "играет ✓")
                report()
            }
            endBackgroundTask()
            listened += 0.5
            // Заранее следующий трек не ищем: скрытое окно, останавливая своё видео посреди песни, могло
            // выключить звук приложения; с постоянным окном поиск и так ~1–2 с.
            // prefetchNextIfNeeded(time: t)
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
            var result = await SafariStream.find(id)
            if result.streams.isEmpty, NativeAudio.useStreamFallback { result = await YouTubeStreams.resolve(id) }
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
