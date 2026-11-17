import AVFoundation
import UIKit

/// Диагностика системного плеера (просьба владельца после 1.103: на iPhone 17 системный плеер не играет, хотя
/// «Проверить SABR» говорит «работает», а на iPad играет даже видео). Проходит на одном треке весь путь, как при
/// воспроизведении: 1) обычные ссылки (все попытки: со входом, как без входа, без cookies посетителя, без входа)
/// и проба плеером iOS; 2) свой SABR принудительно — тем же движком, что музыка (`SabrEngine`), и проба файла.
/// Итог — текст для «Скопировать».
enum PlayerDiagnostics {
    static func run(videoID: String) async -> String {
        let device = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        await YouTubeSession.refreshed()
        var lines = ["Диагностика системного плеера, Fon \(version)",
                     "\(device.model) \(machine), \(device.systemName) \(device.systemVersion)",
                     YouTubeSession.summary + ", аккаунт №\(YouTubeAccount.index)" + (YouTubeAccount.pageID != nil ? " (канал бренда)" : ""),
                     "Видео: \(videoID)"]
        if let until = UserDefaults.standard.object(forKey: "sabrOnlyUntil") as? Date, until > Date() {
            lines.append("Отметка «только SABR» до \(clock(until)): \(UserDefaults.standard.string(forKey: "sabrOnlyReason") ?? "?")")
        }

        // 0. Варианты запроса страницы — какой из них YouTube отдаёт со ссылками (iPhone 17 после 1.105).
        lines.append("0. Варианты запроса (со входом):")
        let realUA = WebViewFactory.safariUserAgent()
        let macUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        let cookie = YouTubeSession.cookieHeader
        let variants: [(String, String, Bool, String)] = [
            ("как сейчас (iPhone iOS 18.6)", "www.youtube.com", true, YouTubeStreams.iPhoneSafariUserAgent),
            ("настоящая iOS \(device.systemVersion)", "www.youtube.com", true, realUA),
            ("как Safari на iPad (Mac)", "www.youtube.com", true, macUA),
            ("Mac без app=desktop", "www.youtube.com", false, macUA),
            ("m.youtube, настоящая iOS", "m.youtube.com", false, realUA)
        ]
        for (label, host, desktop, agent) in variants {
            lines.append("   \(label): " + (await DirectStream.probe(videoID, host: host, desktop: desktop, userAgent: agent, cookie: cookie)))
        }
        lines.append("   встроенный браузер (как Safari): " + (await webProbe(videoID)))

        // 1. Обычные ссылки.
        var started = Date()
        let plain = await DirectStream.find(videoID, sabr: false)
        if plain.streams.isEmpty {
            lines.append("1. Обычные ссылки (\(seconds(since: started))): нет — \(plain.reason ?? "?")")
        } else {
            lines.append("1. Обычные ссылки (\(seconds(since: started))): \(plain.streams.map(\.client).joined(separator: ", "))"
                         + (plain.reason.map { " (\($0))" } ?? ""))
            let stream = plain.streams[0]
            lines.append("   плеер iOS (\(stream.client)): " + (await playTest(stream.url, headers: stream.headers)))
        }

        // 2. Свой SABR — даже если обычные ссылки есть (проверяем сам движок).
        started = Date()
        let info = await DirectStream.sabrSource(videoID)
        guard let source = info.source else {
            lines.append("2. SABR: на странице нет (\(info.reason ?? "?"))")
            return lines.joined(separator: "\n")
        }
        let audio = source.formats.filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true }.count
        lines.append("2. SABR: страница ок (\(seconds(since: started))), форматов \(source.formats.count) (звук mp4: \(audio)), "
                     + "клиент \(source.clientName) \(source.clientVersion), n: \(source.url.contains("&n=") || source.url.contains("?n=") ? "есть" : "нет")")
        if let cached = SabrEngine.cached(videoID) { try? FileManager.default.removeItem(at: cached) } // качаем заново
        started = Date()
        do {
            let file = try await SabrEngine.shared.download(source)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            lines.append("   скачано \(size / 1024) КБ за \(seconds(since: started)); \(SabrEngine.shared.lastReport)")
            lines.append("   плеер iOS (файл SABR): " + (await playTest(file, headers: [:])))
        } catch {
            lines.append("   не скачалось (\(seconds(since: started))): \(error.localizedDescription)")
            lines.append("   \(SabrEngine.shared.lastReport)")
        }

        // 3. SABR с видео — как видео на обложке музыкального плеера (iPhone 17 после 1.105).
        started = Date()
        let video = await SabrMusicVideo.start(source)
        if let url = video.url {
            lines.append("3. SABR видео: начало за \(seconds(since: started)); плеер iOS: " + (await playTest(url, headers: [:])))
        } else {
            lines.append("3. SABR видео (\(seconds(since: started))): не вышло — \(video.reason ?? "?")")
        }
        return lines.joined(separator: "\n")
    }

    /// Та же страница запросом из скрытого окна m.youtube (WebKit, cookies окна, как в Safari) — подсчёт по тексту.
    @MainActor
    private static func webProbe(_ videoID: String) async -> String {
        let expression = """
        (async () => { const r = await fetch('/watch?v=' + vid + '&hl=ru', { credentials: 'include' }); const t = await r.text();
          const c = (w) => t.split(w).length - 1;
          return r.status + ', signatureCipher ' + c('signatureCipher') + ', videoplayback ' + c('videoplayback') +
            ', SABR: ' + (c('serverAbrStreamingUrl') > 0 ? 'да' : 'нет') + ', ' + Math.round(t.length / 1024) + ' КБ'; })()
        """
        return await withCheckedContinuation { continuation in
            let once = Once()
            HiddenPage.youtube.call(expression, { ["vid": videoID] }) { result in
                guard once.first() else { return }
                switch result {
                case .success(let value): continuation.resume(returning: (value as? String) ?? "пустой ответ")
                case .failure(let error): continuation.resume(returning: "ошибка: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if once.first() { continuation.resume(returning: "нет ответа за 20 с") } }
        }
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        func first() -> Bool { if done { return false }; done = true; return true }
    }

    /// Беззвучная проба: заиграл ли AVPlayer (до 12 с).
    @MainActor
    private static func playTest(_ url: URL, headers: [String: String]) async -> String {
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        for _ in 0..<48 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if item.status == .failed {
                let log = item.errorLog()?.events.last.map { " [\($0.errorStatusCode) \($0.errorComment ?? "")]" } ?? ""
                return "ошибка — " + (item.error?.localizedDescription ?? "?") + log
            }
            let time = CMTimeGetSeconds(player.currentTime())
            if time > 0.5 {
                let length = CMTimeGetSeconds(item.duration)
                return "играет (длина \(length.isFinite ? "\(Int(length)) с" : "?"))"
            }
        }
        return "не заиграл за 12 с (статус \(item.status.rawValue), буфер пуст: \(item.isPlaybackBufferEmpty))"
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.1f с", Date().timeIntervalSince(date))
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter.string(from: date)
    }

    /// Модель устройства («iPhone18,1»).
    private static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
