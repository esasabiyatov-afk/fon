import Foundation
import JavaScriptCore
import UIKit

/// Поток трека для системного плеера (решение владельца 29.10.2026, вариант 3; проверено в 1.64): страница
/// `www.youtube.com/watch?app=desktop` (Safari на iPhone, вход в аккаунт) запросом самого приложения — без окон.
/// Ссылки там зашифрованы (`signatureCipher`: подпись `s` + параметр `n`, без PO-токена — видно
/// по журналу 1.63). Расшифровывает «решатель» yt-dlp (`ChallengeSolver`) — тот же код, что выполнил бы браузер.
/// Запросы идут из приложения (URLSession + JavaScriptCore) — работают и в фоне, звук приложения не трогают.
enum DirectStream {
    /// На iPad (iPadOS 26.2, вход есть, 1.76) страница отдала форматы без ссылок — «ссылки не разобрались»: похоже, этому
    /// посетителю/аккаунту YouTube включил только свой протокол (SABR). Тогда пробуем ещё раз без cookies экспериментов
    /// посетителя (VISITOR_INFO1_LIVE, PREF…), а затем совсем без cookies — пока не найдётся обычная ссылка.
    /// `sabr: false` — нужен файл с видео (предпросмотр в ленте), звук по SABR не подходит.
    /// `sabrVideo` — по SABR не только звук, а видео 360p со звуком (для видео на обложке; iPhone 17 после 1.105:
    /// «сделай как у меня и на планшете, сразу с видео»); не вышло — звук файлом, как раньше.
    static func find(_ videoID: String, sabr allowSABR: Bool = true, sabrVideo: Bool = false) async -> YouTubeStreams.Result {
        await YouTubeSession.refreshed()
        let visitor: Set<String> = ["VISITOR_INFO1_LIVE", "VISITOR_PRIVACY_METADATA", "__Secure-ROLLOUT_TOKEN", "PREF", "YSC", "__Secure-YEC"]
        // Cookies входа: без них запрос выглядит как Safari без аккаунта, но со своим посетителем (после 1.98: на iPhone 17
        // с другим аккаунтом — «только SABR»; если YouTube включил SABR аккаунту, так найдётся обычная ссылка).
        let login: Set<String> = ["SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "SIDCC",
                                  "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
                                  "__Secure-1PSIDCC", "__Secure-3PSIDCC", "__Secure-1PSIDTS", "__Secure-3PSIDTS"]
        let attempts: [(label: String, cookie: String?)] = [
            ("", YouTubeSession.cookieHeader),
            ("как без входа", YouTubeSession.cookieHeaderWithout(login)),
            ("без cookies посетителя", YouTubeSession.cookieHeaderWithout(visitor)),
            ("без входа", nil)
        ]
        var reasons: [String] = []
        var triedSABR = false
        var last = YouTubeStreams.Result()
        for (index, attempt) in attempts.enumerated() {
            var result = await self.attempt(videoID, cookie: attempt.cookie)
            if !result.streams.isEmpty {
                var found = result
                if index > 0 { found.reason = "сработало \(attempt.label)" }
                return found
            }
            reasons.append(attempt.label.isEmpty ? (result.reason ?? "?") : "\(attempt.label): \(result.reason ?? "?")")
            AppJournal.add("страница \(videoID)\(attempt.label.isEmpty ? "" : " (\(attempt.label))"): \(result.reason ?? "?")")
            // www без ссылок (iPhone 17, iPad) — страница m.youtube, как у Safari на этом телефоне: до SABR.
            if index == 0, result.noLinks {
                let mobile = await mobileAttempt(videoID, fallbackPlayer: result.sabr?.playerURL)
                let clients: String = mobile.streams.map(\.client).joined(separator: ", ")
                let outcome: String = mobile.streams.isEmpty ? mobile.reason : "есть (\(clients)) \(mobile.reason)"
                AppJournal.add("m.youtube \(videoID): " + outcome)
                if let sabr = mobile.sabr { result.sabr = sabr } // SABR из ответа с токеном видео — как у Safari
                if !mobile.streams.isEmpty {
                    var found = result
                    found.streams = mobile.streams
                    found.noLinks = false
                    found.reason = "сработало m.youtube" + (mobile.reason.isEmpty ? "" : " (\(mobile.reason))")
                    return found
                }
                reasons.append("m.youtube: \(mobile.reason)")
            }
            // Обычных ссылок нет (iPad, iPhone 17) — звук по SABR внутри приложения (с 1.100; проба 1.99 — работает).
            if allowSABR, !triedSABR, result.noLinks, let source = result.sabr {
                triedSABR = true // один раз: повтор с другими cookies SABR не поможет, а ждать долго
                if sabrVideo {
                    let video = await SabrMusicVideo.start(source)
                    if let url = video.url {
                        var found = result
                        found.streams = [AudioStream(url: url, headers: [:], client: "SABR видео")]
                        found.noLinks = false
                        found.reason = nil
                        return found
                    }
                    reasons.append("SABR видео: \(video.reason ?? "?")")
                }
                do {
                    let file = try await SabrEngine.shared.download(source)
                    var found = result
                    found.streams = [AudioStream(url: file, headers: [:], client: "SABR")]
                    found.noLinks = false
                    found.reason = nil
                    return found
                } catch {
                    reasons.append(error.localizedDescription)
                }
            }
            // Повтор помогает только когда у форматов нет ссылок; сеть, капча, вход — не лечатся.
            last = result
            last.reason = reasons.joined(separator: "; ")
            guard result.noLinks else { break }
        }
        return last
    }

    /// Данные SABR для своего видеоплеера (`SabrVideo`): страница видео со входом, а нет — как без входа и без cookies.
    static func sabrSource(_ videoID: String) async -> (source: SabrEngine.Source?, title: String?, author: String?, reason: String?) {
        await YouTubeSession.refreshed()
        var reasons: [String] = []
        for cookie in [YouTubeSession.cookieHeader, nil] {
            let result = await attempt(videoID, cookie: cookie)
            if let source = result.sabr { return (source, result.title, result.author, nil) }
            reasons.append(result.reason ?? "нет SABR на странице")
        }
        return (nil, nil, nil, reasons.joined(separator: "; "))
    }

    /// Что в странице видео: разбор ytInitialPlayerResponse, а не нашёлся (m.youtube) — подсчёт по тексту.
    static func summary(of data: Data) -> String {
        if let response = YouTubeStreams.jsonObject(in: data, after: "ytInitialPlayerResponse = ") {
            let status = (response["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
            let streaming = response["streamingData"] as? [String: Any] ?? [:]
            let all = (streaming["formats"] as? [[String: Any]] ?? []) + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])
            let linked = all.filter { $0["url"] != nil || $0["signatureCipher"] != nil || $0["cipher"] != nil }.count
            return "\(status), ссылки \(linked) из \(all.count), SABR: \(streaming["serverAbrStreamingUrl"] != nil ? "да" : "нет")"
        }
        let text = String(decoding: data, as: UTF8.self)
        func count(_ word: String) -> Int { text.components(separatedBy: word).count - 1 }
        return "без разбора: signatureCipher \(count("signatureCipher")), videoplayback \(count("videoplayback")), SABR: \(count("serverAbrStreamingUrl") > 0 ? "да" : "нет"), \(data.count / 1024) КБ"
    }

    /// Итог попытки m.youtube: ссылки (если пустили), данные SABR из того же ответа и что произошло.
    struct Mobile {
        var streams: [AudioStream] = []
        var sabr: SabrEngine.Source?
        var reason = ""
    }

    /// m.youtube (MWEB — то, что открывает Safari на этом телефоне). Диагностика 1.107 на iPhone 17: у www
    /// (app=desktop) ссылок нет ни в одном варианте (0 из 22, только SABR, а свой SABR стоит на «защите потока: 2»
    /// и с PO-токеном), а `youtubei/v1/player` клиентом страницы m.youtube со входом — 26 из 26, и у звука 140.
    /// 1.108: эти ссылки — 403 и без токена, и с `pot=`. Страница YouTube в Safari кладёт в сам запрос плеера ещё
    /// и токен **видео** (`serviceIntegrityDimensions.poToken`, привязка — id видео; токен сессии — для googlevideo).
    /// Поэтому с 1.109 запрос плеера — с токеном видео (если окно проверки может его выдать — на экране), ссылки
    /// проверяются первым 1 КБ (без `pot=`, затем с токеном сессии), а SABR из этого же ответа уходит дальше (`sabr`).
    static func mobileAttempt(_ videoID: String, fallbackPlayer: URL?) async -> Mobile {
        var outcome = Mobile()
        let agent = await MainActor.run { WebViewFactory.safariUserAgent() }
        let origin = "https://m.youtube.com"
        guard let pageURL = URL(string: "\(origin)/watch?v=\(videoID)&hl=ru"),
              let apiURL = URL(string: "\(origin)/youtubei/v1/player?prettyPrint=false") else { outcome.reason = "плохая ссылка"; return outcome }
        var request = URLRequest(url: pageURL, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let cookie = YouTubeSession.cookieHeader
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (page, _) = try? await URLSession.shared.data(for: request) else { outcome.reason = "страница не ответила"; return outcome }
        guard let context = YouTubeStreams.jsonObject(in: page, after: "\"INNERTUBE_CONTEXT\":"),
              let client = context["client"] as? [String: Any] else { outcome.reason = "на странице нет клиента"; return outcome }
        let jsPath = YouTubeStreams.string(in: page, after: "\"jsUrl\":\"") ?? YouTubeStreams.string(in: page, after: "\"PLAYER_JS_URL\":\"")
        guard let playerURL = jsPath.flatMap({ URL(string: YouTubeStreams.origin + $0.replacingOccurrences(of: "\\/", with: "/")) }) ?? fallbackPlayer else {
            outcome.reason = "нет кода плеера"
            return outcome
        }
        // Привязка токена сессии: со входом — DATASYNC_ID до «||», без входа — VISITOR_DATA.
        let unescape = { (text: String) in text.replacingOccurrences(of: "\\u003d", with: "=").replacingOccurrences(of: "\\u0026", with: "&") }
        let loggedIn = page.range(of: Data("\"LOGGED_IN\":true".utf8)) != nil
        let sync = YouTubeStreams.string(in: page, after: "\"DATASYNC_ID\":\"").map(unescape)?.components(separatedBy: "||").first { !$0.isEmpty }
        let visitor = YouTubeStreams.string(in: page, after: "\"VISITOR_DATA\":\"").map(unescape)
        let binding = loggedIn ? (sync ?? visitor) : visitor
        // Токен видео — только на экране (окно проверки в фоне может не ответить); готовый из кэша — всегда.
        var videoToken = PoToken.cached(for: videoID)
        if videoToken == nil, await MainActor.run(body: { UIApplication.shared.applicationState != .background }) {
            videoToken = await PoToken.shared.token(for: videoID)
        }
        var playback: [String: Any] = ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]]
        // Отметка версии подписи: без неё YouTube шифрует ссылки под другую версию плеера, и расшифровка даёт
        // неверную подпись (403) — вероятная причина 403 в 1.108. Страница отдаёт её в ytcfg (`STS`).
        let sts = number(in: page, after: "\"STS\":") ?? number(in: page, after: "\"signatureTimestamp\":")
        if let sts { playback["contentPlaybackContext"] = ["html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": sts] }
        var body: [String: Any] = ["context": context, "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true, "playbackContext": playback]
        if let videoToken { body["serviceIntegrityDimensions"] = ["poToken": videoToken] }
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { outcome.reason = "?"; return outcome }
        var api = URLRequest(url: apiURL, timeoutInterval: 15)
        api.httpMethod = "POST"
        api.httpBody = json
        api.httpShouldHandleCookies = false
        api.setValue("application/json", forHTTPHeaderField: "Content-Type")
        api.setValue(agent, forHTTPHeaderField: "User-Agent")
        let clientNumber = number(in: page, after: "\"INNERTUBE_CONTEXT_CLIENT_NAME\":") ?? 2
        let clientVersion = client["clientVersion"] as? String ?? ""
        api.setValue(String(clientNumber), forHTTPHeaderField: "X-Youtube-Client-Name")
        api.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        api.setValue(origin, forHTTPHeaderField: "Origin")
        api.setValue(origin + "/watch?v=" + videoID, forHTTPHeaderField: "Referer")
        if let visitorID = client["visitorData"] as? String { api.setValue(visitorID, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let cookie { api.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let auth = YouTubeSession.authorization(origin: origin) {
            api.setValue(auth, forHTTPHeaderField: "Authorization")
            YouTubeAccount.headers.forEach { api.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        let tokenNote: String = (videoToken != nil ? "токен видео: да" : "токен видео: нет") + (sts != nil ? ", STS \(sts!)" : ", STS нет")
        guard let (data, _) = try? await URLSession.shared.data(for: api),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { outcome.reason = "плеер не ответил (\(tokenNote))"; return outcome }
        let playability = response["playabilityStatus"] as? [String: Any] ?? [:]
        let status = playability["status"] as? String ?? "?"
        guard status == "OK" else {
            outcome.reason = "\(status) \(((playability["reason"] as? String) ?? "").prefix(60)) (\(tokenNote))"
            return outcome
        }
        // SABR из этого же ответа — на случай, если ссылки не пустят.
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        if let sabrURL = streaming["serverAbrStreamingUrl"] as? String,
           let config = (((response["playerConfig"] as? [String: Any])?["mediaCommonConfig"] as? [String: Any])?["mediaUstreamerRequestConfig"] as? [String: Any])?["videoPlaybackUstreamerConfig"] as? String {
            var source = SabrEngine.Source(videoID: videoID, url: sabrURL, config: config, clientName: clientNumber,
                                           clientVersion: clientVersion, formats: streaming["adaptiveFormats"] as? [[String: Any]] ?? [],
                                           playerURL: playerURL)
            source.poBinding = binding
            source.duration = Double((response["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String ?? "") ?? 0
            if videoToken != nil { outcome.sabr = source } // без токена видео он не лучше SABR со страницы www
        }
        let found = await streams(from: response, playerURL: playerURL, agent: agent)
        guard let first = found.streams.first else { outcome.reason = found.note + " (\(tokenNote))"; return outcome }
        if await opens(first) {
            outcome.streams = await asFiles(found.streams, videoID: videoID)
            outcome.reason = tokenNote
            return outcome
        }
        guard let binding, let token = await SabrEngine.poToken(for: binding) else {
            outcome.reason = "ссылки не пускают, токена сессии нет (\(tokenNote))"
            return outcome
        }
        let signed = found.streams.map { AudioStream(url: adding(poToken: token, to: $0.url), headers: $0.headers, client: $0.client) }
        if await opens(signed[0]) {
            outcome.streams = await asFiles(signed, videoID: videoID)
            outcome.reason = "с pot, " + tokenNote
            return outcome
        }
        outcome.reason = "ссылки не пускают и с pot (\(tokenNote))"
        return outcome
    }

    /// Звук 140 по ссылке — файлом (диагностика 1.109 на iPhone 17: плеер iOS видел у потока 346 с вместо 173 —
    /// в moov дорожки уже стоит длина трека, и AVPlayer прибавлял к ней фрагменты, как у SABR в 1.104). Трек
    /// ~3 МБ качается за 1–2 с кусками по 4 МБ, длины в moov обнуляются (`SabrEngine.zeroMoovDurations`), файл —
    /// в `Caches/sabr` (как у SABR: «Скачанные» его копируют). Не скачался — ссылка без звука убирается, остаётся файл 360p.
    private static func asFiles(_ streams: [AudioStream], videoID: String) async -> [AudioStream] {
        var result: [AudioStream] = []
        for stream in streams {
            guard stream.client == "Прямо звук" else { result.append(stream); continue }
            if let file = SabrEngine.cached(videoID) { result.append(AudioStream(url: file, headers: [:], client: stream.client)); continue }
            if let file = await downloadAudio(stream, videoID: videoID) {
                result.append(AudioStream(url: file, headers: [:], client: stream.client))
            } else {
                AppJournal.add("m.youtube \(videoID): звук не скачался файлом — играет файл 360p")
            }
        }
        return result
    }

    private static func downloadAudio(_ stream: AudioStream, videoID: String) async -> URL? {
        let manager = FileManager.default
        let file = SabrEngine.folder.appendingPathComponent(videoID + ".m4a")
        let temp = file.appendingPathExtension("direct")
        manager.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return nil }
        let chunk: Int64 = 4 * 1024 * 1024
        var offset: Int64 = 0
        var total: Int64?
        while total.map({ offset < $0 }) ?? true {
            var request = URLRequest(url: stream.url, timeoutInterval: 20)
            stream.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            guard let (data, reply) = try? await URLSession.shared.data(for: request),
                  let http = reply as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                try? handle.close()
                try? manager.removeItem(at: temp)
                return nil
            }
            handle.write(data)
            offset += Int64(data.count)
            if http.statusCode == 200 { total = offset; break } // отдали целиком
            total = http.value(forHTTPHeaderField: "Content-Range")?.components(separatedBy: "/").last.flatMap { Int64($0) } ?? offset
            if offset > 80 * 1024 * 1024 { break }
        }
        try? handle.close()
        guard offset > 10_000, offset == total else { try? manager.removeItem(at: temp); return nil }
        _ = SabrEngine.zeroMoovDurations(temp)
        try? manager.removeItem(at: file)
        guard (try? manager.moveItem(at: temp, to: file)) != nil else { try? manager.removeItem(at: temp); return nil }
        SabrEngine.cleanUp()
        return file
    }

    /// Первый 1 КБ ссылки: пускает ли googlevideo (200/206).
    private static func opens(_ stream: AudioStream) async -> Bool {
        var request = URLRequest(url: stream.url, timeoutInterval: 10)
        stream.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        guard let (_, reply) = try? await URLSession.shared.data(for: request) else { return false }
        let code = (reply as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 206
    }

    /// Для диагностики: звук 140 и файл 18 из готового ответа плеера (например, m.youtube — MWEB отдаёт ссылки всем
    /// форматам, диагностика 1.107 на телефоне владельца: 26 из 26) — расшифровать так же, как обычные.
    static func streams(from response: [String: Any], playerURL: URL, agent: String) async -> (streams: [AudioStream], note: String) {
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        let formats = streaming["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        var picked: [[String: Any]] = []
        if let audio = adaptive.first(where: { ($0["itag"] as? Int) == 140 }) { picked.append(audio) }
        if let file = formats.first(where: { ($0["itag"] as? Int) == 18 }) { picked.append(file) }
        let links = picked.compactMap(Link.init)
        guard !links.isEmpty else { return ([], "у форматов 140/18 нет ссылок") }
        let note = links.map { link in
            "\(link.itag): подпись \(link.signature != nil ? "да" : "нет"), n \(link.n != nil ? "да" : "нет")"
        }.joined(separator: "; ")
        do {
            let solved = try await ChallengeSolver.shared.solve(playerURL: playerURL,
                                                                n: Array(Set(links.compactMap(\.n))),
                                                                signatures: links.compactMap(\.signature))
            let streams = links.compactMap { link in
                link.url(solved).map { AudioStream(url: $0, headers: ["User-Agent": agent], client: link.audioOnly ? "Прямо звук" : "Прямо файл") }
            }
            return (streams, note)
        } catch {
            return ([], note + "; решатель: " + String(String(describing: error).prefix(80)))
        }
    }

    /// Ссылка с PO-токеном (`pot=`), как её дополняет плеер YouTube в браузере.
    static func adding(poToken token: String, to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != "pot" }
        items.append(URLQueryItem(name: "pot", value: encode(token)))
        components.percentEncodedQueryItems = items
        return components.url ?? url
    }

    private static func number(in data: Data, after marker: String) -> Int? {
        guard let found = data.range(of: Data(marker.utf8)) else { return nil }
        return Int(String(decoding: data[found.upperBound...].prefix { (0x30...0x39).contains($0) }, as: UTF8.self))
    }

    private static func attempt(_ videoID: String, cookie: String?) async -> YouTubeStreams.Result {
        var result = YouTubeStreams.Result()
        func fail(_ reason: String) -> YouTubeStreams.Result {
            result.reason = reason
            return result
        }
        guard let url = URL(string: "\(YouTubeStreams.origin)/watch?app=desktop&v=\(videoID)&hl=ru") else { return fail("плохая ссылка") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, reply) = try? await URLSession.shared.data(for: request) else { return fail("YouTube не ответил (сеть)") }
        let http = reply as? HTTPURLResponse
        if let final = http?.url, final.path.hasPrefix("/sorry") || final.host != url.host { return fail("YouTube просит проверку (капча)") }
        guard let response = YouTubeStreams.jsonObject(in: data, after: "ytInitialPlayerResponse = ") else { return fail("страница без данных плеера") }
        if let details = response["videoDetails"] as? [String: Any] {
            result.title = details["title"] as? String
            result.author = details["author"] as? String
            result.channelID = details["channelId"] as? String
        }
        result.storyboard = ((response["storyboards"] as? [String: Any])?["playerStoryboardSpecRenderer"] as? [String: Any])?["spec"] as? String
        let status = (response["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        let formats = streaming["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        // Сначала только звук (itag 140 — AAC ~128 кбит/с), если у него есть ссылка, иначе файл 360p (itag 18).
        // В 1.66 проверено: у отдельных дорожек ссылок нет — YouTube отдаёт их только по своему протоколу (SABR,
        // serverAbrStreamingUrl), так что играет itag 18; звук тот же, трафик ~4× больше. Свой SABR не делаем.
        var picked: [[String: Any]] = []
        if let audio = adaptive.first(where: { ($0["itag"] as? Int) == 140 }) { picked.append(audio) }
        if let file = formats.first(where: { ($0["itag"] as? Int) == 18 }) ?? formats.first { picked.append(file) }
        if status != "OK" {
            let why = ((response["playabilityStatus"] as? [String: Any])?["reason"] as? String) ?? ""
            return fail("YouTube: \(status) \(why.prefix(60))")
        }
        if let sabrURL = streaming["serverAbrStreamingUrl"] as? String,
           let config = (((response["playerConfig"] as? [String: Any])?["mediaCommonConfig"] as? [String: Any])?["mediaUstreamerRequestConfig"] as? [String: Any])?["videoPlaybackUstreamerConfig"] as? String {
            let js = YouTubeStreams.string(in: data, after: "\"jsUrl\":\"").flatMap { URL(string: YouTubeStreams.origin + $0.replacingOccurrences(of: "\\/", with: "/")) }
            result.sabr = SabrEngine.Source(videoID: videoID, url: sabrURL, config: config,
                                            clientName: number(in: data, after: "\"INNERTUBE_CONTEXT_CLIENT_NAME\":") ?? 1,
                                            clientVersion: YouTubeStreams.string(in: data, after: "\"INNERTUBE_CLIENT_VERSION\":\"") ?? "2.20261112.10.00",
                                            formats: adaptive, playerURL: js)
            // Привязка PO-токена (`PoToken`): со входом — DATASYNC_ID (до «||»), без входа — VISITOR_DATA.
            let unescape = { (text: String) in text.replacingOccurrences(of: "\\u003d", with: "=").replacingOccurrences(of: "\\u0026", with: "&") }
            let loggedIn = data.range(of: Data("\"LOGGED_IN\":true".utf8)) != nil
            let sync = YouTubeStreams.string(in: data, after: "\"DATASYNC_ID\":\"").map(unescape)?
                .components(separatedBy: "||").first { !$0.isEmpty }
            let visitorData = YouTubeStreams.string(in: data, after: "\"VISITOR_DATA\":\"").map(unescape)
            result.sabr?.poBinding = loggedIn ? (sync ?? visitorData) : visitorData
            result.sabr?.duration = Double((response["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String ?? "") ?? 0
            let tracks = ((response["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"] as? [[String: Any]] ?? []
            result.sabr?.captions = tracks.compactMap { track in
                guard let url = track["baseUrl"] as? String else { return nil }
                let name = track["name"] as? [String: Any]
                let title = name?["simpleText"] as? String
                    ?? (name?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                let language = track["languageCode"] as? String ?? ""
                return SabrEngine.Caption(url: url.hasPrefix("/") ? YouTubeStreams.origin + url : url,
                                          name: title.isEmpty ? language : title, language: language,
                                          translatable: track["isTranslatable"] as? Bool ?? false)
            }
        }
        // Для диагностики: есть ли у ответа свой протокол YouTube и какие поля у выбранного формата.
        let sabr = streaming["serverAbrStreamingUrl"] != nil ? "SABR: да" : "SABR: нет"
        let fields = (picked.last ?? [:]).keys.filter { !["itag", "mimeType", "bitrate", "width", "height"].contains($0) }.sorted()
        let detail = "форматов \(formats.count)+\(adaptive.count), \(sabr), поля: \(fields.prefix(12).joined(separator: ","))"
        guard !picked.isEmpty else {
            result.noLinks = true
            return fail("нет подходящего формата (\(detail))")
        }
        YouTubeStreams.rememberConfig(from: data) // для очереди микса
        guard let jsPath = YouTubeStreams.string(in: data, after: "\"jsUrl\":\""),
              let playerURL = URL(string: YouTubeStreams.origin + jsPath.replacingOccurrences(of: "\\/", with: "/")) else {
            return fail("нет ссылки на код плеера")
        }
        // Ссылки + что расшифровать: подпись (из signatureCipher) и n (в самой ссылке).
        let links = picked.compactMap(Link.init)
        guard !links.isEmpty else {
            result.noLinks = true
            return fail("ссылки не разобрались (\(detail))")
        }
        let solved: ChallengeSolver.Solved
        do {
            solved = try await ChallengeSolver.shared.solve(playerURL: playerURL,
                                                            n: Array(Set(links.compactMap(\.n))),
                                                            signatures: links.compactMap(\.signature))
        } catch {
            return fail("решатель: " + String(String(describing: error).prefix(80)))
        }
        result.streams = links.compactMap { link in
            guard let url = link.url(solved) else { return nil }
            return AudioStream(url: url, headers: ["User-Agent": YouTubeStreams.iPhoneSafariUserAgent],
                               client: link.audioOnly ? "Прямо звук" : "Прямо файл")
        }
        if result.streams.isEmpty { result.reason = "ссылки не собрались" }
        return result
    }

    /// Ссылка формата до расшифровки.
    private struct Link {
        let itag: Int
        let audioOnly: Bool
        let components: URLComponents
        let n: String?
        let signature: String?
        let signatureParam: String

        init?(_ format: [String: Any]) {
            var base: String?
            var signature: String?
            var param = "signature"
            if let direct = format["url"] as? String {
                base = direct
            } else if let cipher = (format["signatureCipher"] ?? format["cipher"]) as? String {
                let items = URLComponents(string: "?" + cipher)?.queryItems ?? []
                base = items.first { $0.name == "url" }?.value
                signature = items.first { $0.name == "s" }?.value
                param = items.first { $0.name == "sp" }?.value ?? "signature"
            }
            guard let base, let components = URLComponents(string: base) else { return nil }
            itag = format["itag"] as? Int ?? 0
            audioOnly = (format["mimeType"] as? String ?? "").hasPrefix("audio/")
            self.components = components
            n = components.queryItems?.first { $0.name == "n" }?.value
            self.signature = signature
            signatureParam = param
        }

        func url(_ solved: ChallengeSolver.Solved) -> URL? {
            var components = components
            var items = components.percentEncodedQueryItems ?? []
            if let n, let solvedN = solved.n[n] {
                items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: DirectStream.encode(solvedN)) : $0 }
            }
            if let signature {
                guard let solvedSignature = solved.signatures[signature] else { return nil }
                items.append(URLQueryItem(name: signatureParam, value: DirectStream.encode(solvedSignature)))
            }
            components.percentEncodedQueryItems = items
            return components.url
        }
    }

    /// Значения подписи и n — в ссылку как есть, кроме символов, ломающих параметры.
    fileprivate static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum SolverError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "?" }
}

/// «Решатель» yt-dlp (github.com/yt-dlp/ejs, Unlicense; внутри meriyah — ISC, astring — MIT) в JavaScriptCore.
/// Код плеера YouTube (base.js, ~3 МБ) разбирается один раз на версию плеера; разобранный вариант хранится в
/// Caches/solver (дальше трек расшифровывается за доли секунды). Свой экземпляр решателя лежит в приложении
/// (Fon/Solver/*.txt); не справился — скачиваем свежий из релизов yt-dlp/ejs и пробуем ещё раз.
final class ChallengeSolver {
    static let shared = ChallengeSolver()

    /// Ответы: исходный вызов → решение.
    struct Solved {
        var n: [String: String] = [:]
        var signatures: [String: String] = [:]
        var note = ""
    }

    /// Состояние — под замком; сам разбор — по одному, в своём потоке с большим стеком (разбор base.js
    /// рекурсивный, а у фоновых потоков iOS стек всего 512 КБ).
    private let lock = NSLock()
    private let runLock = NSLock()
    private var context: JSContext?
    private var loadedScripts: String?
    private var preprocessed: (key: String, code: String)?
    private var lastUpdateAttempt = Date.distantPast

    private let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("solver", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    func solve(playerURL: URL, n: [String], signatures: [String]) async throws -> Solved {
        let player = try await playerCode(playerURL)
        do {
            return try await run(player: player, n: n, signatures: signatures)
        } catch {
            // Возможно, YouTube поменял код, а в yt-dlp уже поправили решатель — берём свежий (не чаще раза в час).
            guard await updateScripts() else { throw error }
            // Разобранный старым решателем плеер выброшен — берём исходный код заново.
            let fresh = try await playerCode(playerURL)
            var solved = try await run(player: fresh, n: n, signatures: signatures)
            solved.note += ", решатель обновлён"
            return solved
        }
    }

    // MARK: - Код плеера

    private struct Player {
        let key: String
        let raw: String?          // исходный base.js, если разобранного ещё нет
        let preprocessed: String? // разобранный решателем
    }

    private func playerCode(_ url: URL) async throws -> Player {
        let key = url.path.components(separatedBy: "/").dropFirst(3).first ?? String(url.path.hashValue)
        lock.lock()
        let cached = preprocessed
        lock.unlock()
        if let cached, cached.key == key {
            return Player(key: key, raw: nil, preprocessed: cached.code)
        }
        let file = folder.appendingPathComponent("player-\(key).js")
        if let code = try? String(contentsOf: file, encoding: .utf8) {
            return Player(key: key, raw: nil, preprocessed: code)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, reply) = try await URLSession.shared.data(for: request)
        guard (reply as? HTTPURLResponse)?.statusCode == 200, let code = String(data: data, encoding: .utf8) else {
            throw SolverError.message("код плеера не скачался")
        }
        return Player(key: key, raw: code, preprocessed: nil)
    }

    // MARK: - Запуск

    private func run(player: Player, n: [String], signatures: [String]) async throws -> Solved {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Solved, Error>) in
            let thread = Thread {
                self.runLock.lock()
                defer { self.runLock.unlock() }
                do {
                    continuation.resume(returning: try self.runSync(player: player, n: n, signatures: signatures))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func runSync(player: Player, n: [String], signatures: [String]) throws -> Solved {
        let context = try loadContext()
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !signatures.isEmpty { requests.append(["type": "sig", "challenges": signatures]) }
        guard !requests.isEmpty else { return Solved() }
        let requestsJSON = String(data: try JSONSerialization.data(withJSONObject: requests), encoding: .utf8) ?? "[]"
        context.setObject(requestsJSON, forKeyedSubscript: "__fonRequests" as NSString)
        let script: String
        if let code = player.preprocessed {
            context.setObject(code, forKeyedSubscript: "__fonPlayer" as NSString)
            script = "JSON.stringify(jsc({type: 'preprocessed', preprocessed_player: __fonPlayer, requests: JSON.parse(__fonRequests)}))"
        } else {
            context.setObject(player.raw ?? "", forKeyedSubscript: "__fonPlayer" as NSString)
            script = "JSON.stringify(jsc({type: 'player', player: __fonPlayer, output_preprocessed: true, requests: JSON.parse(__fonRequests)}))"
        }
        context.exception = nil
        let value = context.evaluateScript(script)?.toString() ?? ""
        context.setObject(nil, forKeyedSubscript: "__fonPlayer" as NSString)
        if let exception = context.exception { throw SolverError.message("ошибка JS: \(exception)") }
        guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw SolverError.message("пустой ответ")
        }
        guard json["type"] as? String == "result", let responses = json["responses"] as? [[String: Any]] else {
            throw SolverError.message(String((json["error"] as? String ?? "ошибка").prefix(120)))
        }
        if let code = json["preprocessed_player"] as? String {
            lock.lock(); preprocessed = (player.key, code); lock.unlock()
            try? code.write(to: folder.appendingPathComponent("player-\(player.key).js"), atomically: true, encoding: .utf8)
            cleanOldPlayers(keep: player.key)
        } else if let code = player.preprocessed {
            lock.lock(); preprocessed = (player.key, code); lock.unlock()
        }
        var solved = Solved()
        for (request, response) in zip(requests, responses) {
            guard response["type"] as? String == "result", let data = response["data"] as? [String: String] else {
                throw SolverError.message(String((response["error"] as? String ?? "не решено").prefix(120)))
            }
            if request["type"] as? String == "n" { solved.n = data } else { solved.signatures = data }
        }
        if n.contains(where: { solved.n[$0] == nil }) { throw SolverError.message("n не решён") }
        if signatures.contains(where: { solved.signatures[$0] == nil }) { throw SolverError.message("подпись не решена") }
        return solved
    }

    /// JSContext с решателем: скачанный свежий (если есть), иначе свой из приложения.
    private func loadContext() throws -> JSContext {
        let scripts = try solverScripts()
        lock.lock()
        let existing = loadedScripts == scripts.version ? context : nil
        lock.unlock()
        if let existing { return existing }
        guard let context = JSContext() else { throw SolverError.message("нет JavaScriptCore") }
        context.exceptionHandler = { context, exception in context?.exception = exception }
        context.evaluateScript(scripts.lib + "\nObject.assign(globalThis, lib);\n" + scripts.core + "\nglobalThis.jsc = jsc;")
        if let exception = context.exception { throw SolverError.message("решатель не загрузился: \(exception)") }
        lock.lock()
        self.context = context
        loadedScripts = scripts.version
        lock.unlock()
        return context
    }

    private func solverScripts() throws -> (lib: String, core: String, version: String) {
        let lib = folder.appendingPathComponent("yt.solver.lib.min.js")
        let core = folder.appendingPathComponent("yt.solver.core.min.js")
        if let l = try? String(contentsOf: lib, encoding: .utf8), let c = try? String(contentsOf: core, encoding: .utf8) {
            return (l, c, "скачанный \(c.count)")
        }
        guard let bl = Bundle.main.url(forResource: "yt.solver.lib.min", withExtension: "txt"),
              let bc = Bundle.main.url(forResource: "yt.solver.core.min", withExtension: "txt"),
              let l = try? String(contentsOf: bl, encoding: .utf8), let c = try? String(contentsOf: bc, encoding: .utf8) else {
            throw SolverError.message("нет решателя в приложении")
        }
        return (l, c, "свой")
    }

    /// Свежий решатель из релизов yt-dlp/ejs (не чаще раза в час). true — скачан, можно пробовать снова.
    private func updateScripts() async -> Bool {
        let now = Date()
        lock.lock()
        let allowed = now.timeIntervalSince(lastUpdateAttempt) > 3600
        if allowed { lastUpdateAttempt = now }
        lock.unlock()
        guard allowed else { return false }
        let base = "https://github.com/yt-dlp/ejs/releases/latest/download/"
        var files: [(String, String)] = []
        for name in ["yt.solver.lib.min.js", "yt.solver.core.min.js"] {
            guard let url = URL(string: base + name),
                  let (data, reply) = try? await URLSession.shared.data(from: url),
                  (reply as? HTTPURLResponse)?.statusCode == 200,
                  let code = String(data: data, encoding: .utf8), code.contains("yt-dlp") else { return false }
            files.append((name, code))
        }
        for (name, code) in files { try? code.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        // Разобранный старым решателем плеер — заново.
        lock.lock()
        context = nil
        preprocessed = nil
        lock.unlock()
        if let old = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            old.filter { $0.lastPathComponent.hasPrefix("player-") }.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        return true
    }

    private func cleanOldPlayers(keep key: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("player-") && file.lastPathComponent != "player-\(key).js" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
