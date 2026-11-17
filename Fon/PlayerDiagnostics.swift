import AVFoundation
import os
import Network
import UIKit
import WebKit

/// Полная диагностика системного плеера — один снимок «от начала до конца» (владелец после 1.105: «пиши полную
/// диагностику, даже то, что кажется ненужным, все варианты, и которые предполагаешь»). Зачем: на iPhone 17 YouTube
/// не даёт обычных ссылок (ни со входом, ни без), а свой SABR упирается в «защиту потока: 2»; на iPad и телефоне
/// владельца тот же код получает ссылки. Здесь — всё, чем устройства могут отличаться, и все пути к звуку:
/// A) устройство и приложение; B) сеть (VPN, прокси, интерфейсы, экономия данных); C) аккаунт и cookies;
/// D) как YouTube видит устройство (контекст клиента, страна, IP — частично скрыт, эксперименты SABR);
/// E) варианты запроса страницы (подпись браузера, cookies, страницы, отдельная сессия, API плеера страницы);
/// F) настоящий WebKit (скрытые окна — как Safari); G) обычные ссылки как у плеера + проба каждой;
/// H) PO-токен (с нуля); I) свой SABR без токена и с токеном; J) SABR с видео; K) настройки Fon.
enum PlayerDiagnostics {
    typealias Progress = @MainActor (String) -> Void

    static func run(videoID: String, progress: @escaping Progress) async -> String {
        var all: [String] = []
        func say(_ line: String) async {
            all.append(line)
            await progress(line)
        }
        let started = Date()
        await YouTubeSession.refreshed()

        // A. Устройство и приложение.
        await say("Полная диагностика Fon — \(stamp(Date()))")
        await say("Видео: \(videoID)")
        await say("A. Устройство")
        for line in await deviceLines() { await say("   " + line) }

        // B. Сеть.
        await say("B. Сеть")
        for line in await networkLines() { await say("   " + line) }

        // C. Аккаунт и cookies.
        await say("C. Аккаунт и cookies")
        await say("   " + YouTubeSession.summary + ", аккаунт №\(YouTubeAccount.index)" + (YouTubeAccount.pageID != nil ? " (канал бренда)" : ""))
        let names = YouTubeSession.cookieNames
        await say("   имена (\(names.count)): " + names.joined(separator: ", "))
        await say("   PREF: \(YouTubeSession.cookieValue("PREF") ?? "нет"); согласие (SOCS/CONSENT): "
                  + (names.contains("SOCS") || names.contains("CONSENT") ? "есть" : "нет"))

        // D. Как YouTube видит устройство — основная страница (как у плеера: app=desktop, подпись iOS 18.6, вход).
        await say("D. Как YouTube видит это устройство (страница как у плеера)")
        let main = await fetchPage(videoID, host: "www.youtube.com", desktop: true, agent: YouTubeStreams.iPhoneSafariUserAgent,
                                   cookie: YouTubeSession.cookieHeader)
        for line in pageDetails(main) { await say("   " + line) }

        // E. Варианты запроса страницы.
        await say("E. Варианты запроса страницы (ссылки N из M — у скольких форматов есть обычная ссылка)")
        let realUA = WebViewFactory.safariUserAgent()
        let version = await MainActor.run { UIDevice.current.systemVersion }
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        let shortVersion = version.split(separator: ".").prefix(2).joined(separator: ".")
        let agents: [(String, String)] = [
            ("iPhone iOS 18.6 (как сейчас)", YouTubeStreams.iPhoneSafariUserAgent),
            ("iPhone, настоящая iOS \(version)", realUA),
            ("iPad Safari (мобильная подпись)", "Mozilla/5.0 (iPad; CPU OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(shortVersion) Mobile/15E148 Safari/604.1"),
            ("Safari на iPad/Mac (как Mac)", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(shortVersion) Safari/605.1.15"),
            ("Chrome на iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1"),
            ("Chrome на Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
        ]
        let login = YouTubeSession.cookieHeader
        let loginNames: Set<String> = ["SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "SIDCC",
                                       "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
                                       "__Secure-1PSIDCC", "__Secure-3PSIDCC", "__Secure-1PSIDTS", "__Secure-3PSIDTS"]
        let visitorOnly = YouTubeSession.cookieHeaderWithout(loginNames)
        await say("   — www, app=desktop, со входом, разные подписи браузера:")
        for (label, agent) in agents {
            let page = await fetchPage(videoID, host: "www.youtube.com", desktop: true, agent: agent, cookie: login)
            await say("   \(label): " + short(page))
        }
        await say("   — разные cookies (подпись как сейчас):")
        await say("   без входа (только посетитель): " + short(await fetchPage(videoID, host: "www.youtube.com", desktop: true, agent: YouTubeStreams.iPhoneSafariUserAgent, cookie: visitorOnly)))
        await say("   без cookies: " + short(await fetchPage(videoID, host: "www.youtube.com", desktop: true, agent: YouTubeStreams.iPhoneSafariUserAgent, cookie: nil)))
        await say("   без cookies, как Mac: " + short(await fetchPage(videoID, host: "www.youtube.com", desktop: true, agent: agents[3].1, cookie: nil)))
        await say("   — другие страницы:")
        await say("   www без app=desktop, iOS \(version): " + short(await fetchPage(videoID, host: "www.youtube.com", desktop: false, agent: realUA, cookie: login)))
        await say("   www без app=desktop, как Mac: " + short(await fetchPage(videoID, host: "www.youtube.com", desktop: false, agent: agents[3].1, cookie: login)))
        let mobile = await fetchPage(videoID, host: "m.youtube.com", desktop: false, agent: realUA, cookie: login)
        await say("   m.youtube, iOS \(version): " + short(mobile))
        await say("   m.youtube без cookies: " + short(await fetchPage(videoID, host: "m.youtube.com", desktop: false, agent: realUA, cookie: nil)))
        await say("   — отдельная сетевая сессия (новое соединение, без кэша и HTTP/3):")
        await say("   как сейчас: " + short(await fetchPage(videoID, host: "www.youtube.com", desktop: true, agent: YouTubeStreams.iPhoneSafariUserAgent, cookie: login, ephemeral: true)))
        await say("   — API плеера тем же клиентом, что дала страница (так делает сама страница YouTube):")
        await say("   www (\(clientLabel(main))): " + (await playerAPI(videoID, page: main, origin: "https://www.youtube.com", agent: YouTubeStreams.iPhoneSafariUserAgent)).text)
        let mweb = await playerAPI(videoID, page: mobile, origin: "https://m.youtube.com", agent: realUA)
        await say("   m.youtube (\(clientLabel(mobile))): " + mweb.text)

        // F. Настоящий WebKit.
        await say("F. Встроенный браузер (WebKit — как Safari на этом устройстве)")
        await say("   запрос из окна m.youtube: " + (await webFetch(videoID)))
        await say("   страница www (app=desktop) в окне: " + (await webPage("https://www.youtube.com/watch?app=desktop&v=\(videoID)")))
        await say("   страница m.youtube в окне: " + (await webPage("https://m.youtube.com/watch?v=\(videoID)")))

        // G. Обычные ссылки — как у плеера.
        await say("G. Обычные ссылки (как ищет системный плеер, все попытки)")
        var mark = Date()
        let plain = await DirectStream.find(videoID, sabr: false)
        if plain.streams.isEmpty {
            await say("   нет (\(seconds(since: mark))) — \(plain.reason ?? "?")")
        } else {
            await say("   есть (\(seconds(since: mark))): \(plain.streams.map(\.client).joined(separator: ", "))" + (plain.reason.map { " (\($0))" } ?? ""))
            for stream in plain.streams {
                await say("   \(stream.client): HTTP " + (await rangeCheck(stream.url, headers: stream.headers)) + "; плеер iOS: " + (await playTest(stream.url, headers: stream.headers)))
            }
        }
        // Ссылки m.youtube (MWEB — как Safari на этом устройстве): там они есть у всех форматов, и у звука 140.
        // В 1.108 на iPhone 17 — 403 (запрос без токена видео и без отметки подписи STS); с 1.109 — как у страницы.
        await say("   — m.youtube (MWEB) с токеном видео и STS, как страница Safari:")
        mark = Date()
        let mobileTry = await DirectStream.mobileAttempt(videoID, fallbackPlayer: nil)
        await say("   итог (\(seconds(since: mark))): " + (mobileTry.streams.isEmpty ? "не пустили — " : "есть — ") + mobileTry.reason
                  + "; SABR из ответа: " + (mobileTry.sabr != nil ? "есть" : "нет"))
        for stream in mobileTry.streams {
            await say("   \(stream.client): HTTP " + (await rangeCheck(stream.url, headers: stream.headers)) + "; плеер iOS: " + (await playTest(stream.url, headers: stream.headers)))
        }

        // H–J. SABR.
        await say("H. PO-токен")
        let info = await DirectStream.sabrSource(videoID)
        guard let source = info.source else {
            await say("   SABR на странице нет (\(info.reason ?? "?")) — дальше не проверить")
            return finish(all, started: started)
        }
        let audio = source.formats.filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true }.count
        await say("   SABR на странице: форматов \(source.formats.count) (звук mp4: \(audio)), клиент \(source.clientName) \(source.clientVersion), n: "
                  + (source.url.contains("&n=") || source.url.contains("?n=") ? "есть" : "нет"))
        if let binding = source.poBinding, !binding.isEmpty {
            let kind = binding.hasPrefix("Cg") ? "VISITOR_DATA (без входа)" : "DATASYNC_ID (вход)"
            await say("   привязка: \(kind), длина \(binding.count); в кэше токен: \(PoToken.cached(for: binding) != nil ? "есть" : "нет")")
            mark = Date()
            let token = await PoToken.shared.fresh(for: binding)
            let report = await PoToken.shared.lastReport
            let until = await PoToken.shared.minterValidUntil
            await say("   с нуля: " + (token != nil ? "получен" : "НЕ получен") + " (\(seconds(since: mark))) — \(report)"
                      + (token != nil ? "; годен до \(stamp(until))" : ""))
        } else {
            await say("   привязки нет (на странице ни DATASYNC_ID, ни VISITOR_DATA)")
        }

        await say("I. Свой SABR (звук)")
        for (label, usePo) in [("без PO-токена", false), ("с PO-токеном", true)] {
            if let cached = SabrEngine.cached(videoID) { try? FileManager.default.removeItem(at: cached) }
            mark = Date()
            do {
                let file = try await SabrEngine.shared.download(source, usePoToken: usePo, timeout: 45)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                await say("   \(label): скачано \(size / 1024) КБ за \(seconds(since: mark)); плеер iOS: " + (await playTest(file, headers: [:])))
            } catch {
                await say("   \(label): не скачалось (\(seconds(since: mark))): \(error.localizedDescription)")
            }
            await say("     " + SabrEngine.shared.lastReport)
        }

        if var mobileSource = mobileTry.sabr {
            if let cached = SabrEngine.cached(videoID) { try? FileManager.default.removeItem(at: cached) }
            mobileSource.poToken = nil
            mark = Date()
            do {
                let file = try await SabrEngine.shared.download(mobileSource, usePoToken: true, timeout: 45)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                await say("   m.youtube (токен видео в запросе плеера): скачано \(size / 1024) КБ за \(seconds(since: mark)); плеер iOS: " + (await playTest(file, headers: [:])))
            } catch {
                await say("   m.youtube (токен видео в запросе плеера): не скачалось (\(seconds(since: mark))): \(error.localizedDescription)")
            }
            await say("     " + SabrEngine.shared.lastReport)
        }

        await say("J. SABR с видео (360p + звук через свой поток; в музыке не используется)")
        mark = Date()
        let video = await SabrMusicVideo.start(source)
        if let url = video.url {
            await say("   начало за \(seconds(since: mark)); плеер iOS: " + (await playTest(url, headers: [:])))
        } else {
            await say("   не вышло (\(seconds(since: mark))): \(video.reason ?? "?")")
        }

        // K. Настройки Fon.
        await say("K. Настройки Fon")
        for line in settingsLines() { await say("   " + line) }
        await appSections(say)
        return finish(all, started: started)
    }

    /// L–N: как работает само приложение (состояние, данные, кэши, система) и журнал событий — для доработок.
    private static func appSections(_ say: (String) async -> Void) async {
        await say("L. Приложение сейчас")
        for line in await appLines() { await say("   " + line) }
        await say("M. Хранилище и кэши")
        for line in storageLines() { await say("   " + line) }
        let journal = AppJournal.all
        await say("N. Журнал событий (последние \(journal.count))")
        for line in journal { await say("   " + line) }
    }

    @MainActor
    private static func appLines() -> [String] {
        var lines: [String] = []
        let process = ProcessInfo.processInfo
        let thermal = ["норма", "тёплый", "горячий", "перегрев"][min(3, process.thermalState.rawValue)]
        let memory = os_proc_available_memory()
        lines.append(String(format: "работает %.0f мин, температура: %@, доступно памяти: %ld МБ, ядер: %ld", Date().timeIntervalSince(AppJournal.launchedAt) / 60,
                            thermal, Int(memory / 1_048_576), process.activeProcessorCount))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow }
        let traits = window?.traitCollection
        let orientation: String = {
            switch scene?.interfaceOrientation {
            case .portrait?: return "вертикально"
            case .portraitUpsideDown?: return "вверх ногами"
            case .landscapeLeft?, .landscapeRight?: return "горизонтально"
            default: return "?"
            }
        }()
        lines.append("окно \(Int(window?.bounds.width ?? 0))×\(Int(window?.bounds.height ?? 0)), \(orientation), безопасная область "
                     + "\(Int(window?.safeAreaInsets.top ?? 0))/\(Int(window?.safeAreaInsets.bottom ?? 0)), тема \(traits?.userInterfaceStyle == .dark ? "тёмная" : "светлая"), "
                     + "размер шрифта \(traits?.preferredContentSizeCategory.rawValue ?? "?"), сцен \(UIApplication.shared.connectedScenes.count)")
        lines.append("доступность: VoiceOver \(UIAccessibility.isVoiceOverRunning ? "вкл" : "выкл"), меньше движения \(UIAccessibility.isReduceMotionEnabled ? "вкл" : "выкл"), "
                     + "меньше прозрачности \(UIAccessibility.isReduceTransparencyEnabled ? "вкл" : "выкл"), жирный шрифт \(UIAccessibility.isBoldTextEnabled ? "вкл" : "выкл")")
        let audio = AVAudioSession.sharedInstance()
        let outputs = audio.currentRoute.outputs.map { "\($0.portType.rawValue) «\($0.portName)»" }.joined(separator: ", ")
        lines.append("звук: \(audio.category.rawValue), \(audio.mode.rawValue), выход: \(outputs.isEmpty ? "нет" : outputs), громкость телефона \(Int(audio.outputVolume * 100))%, "
                     + "другой звук играет: \(audio.isOtherAudioPlaying ? "да" : "нет")")
        lines.append("системный плеер: " + NativeAudio.shared.debugState)
        lines.append("плеер на экране: что-то открыто \(PlayerView.hasMedia ? "да" : "нет"), развёрнут \(PlayerView.coversContent ? "да" : "нет")")
        let likes = CloudLikes.shared
        lines.append("«Понравившиеся» (облако): загружены \(likes.loaded ? "да" : "нет"), треков \(likes.tracks.count)" + (likes.lastError.map { ", ошибка: \($0)" } ?? "")
                     + "; старые локальные: \(Library.shared.legacyLiked.count)")
        lines.append("«Недавно слушали»: \(Library.shared.history.count); поиск — недавних запросов: \((UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []).count)")
        let offline = OfflineStore.shared
        lines.append("«Скачанные»: \(offline.tracks.count) треков, \(offline.totalSize / 1_048_576) МБ, в очереди \(offline.waitingCount), качается: \(offline.downloading?.id ?? "—"), "
                     + "сеть: \(offline.online ? (offline.onWiFi ? "Wi-Fi" : "сотовая") : "нет"), ждёт Wi-Fi: \(offline.waitsForWiFi ? "да" : "нет")")
        let feed = MusicFeed.shared
        lines.append("главная музыки: полок \(feed.shelves.count) (\(feed.shelves.map { "\($0.title.prefix(20))·\($0.items.count)" }.prefix(8).joined(separator: ", "))), "
                     + "исполнителей \(feed.artists.count), лента: миксов \(feed.feedMixes.count), видео \(feed.feedVideos.count), не вошёл: \(feed.signedOut ? "да" : "нет")"
                     + (feed.homeError.map { ", ошибка главной: \($0)" } ?? "") + (feed.feedError.map { ", ошибка ленты: \($0)" } ?? ""))
        let shelves = Discover.shared.shelves
        lines.append("«Открытия»: дня \(shelves.daily.count), новое \(shelves.fresh.count), ниша \(shelves.niche.count), тренды \(shelves.trending.count), собраны \(shelves.built.map(stamp) ?? "никогда")")
        lines.append("вкус: исполнителей с оценкой \(Taste.shared.artistScores.count), обычно пропускаемых треков \(Taste.shared.dislikedIDs.count)")
        lines.append("оформление: фон \(Settings.backdropStyle), подложка \(Settings.panelStyle), ореол \(Settings.artworkGlow ? "вкл" : "выкл"), живой фон везде \(Settings.ambientEverywhere ? "вкл" : "выкл"), "
                     + "громкость YouTube \(Int(Settings.youtubeVolume * 100))%; свой видеоплеер: \(Settings.sabrVideoHeight)p, ×\(Settings.sabrVideoSpeed), субтитры \(Settings.sabrSubtitles ?? "выкл")")
        return lines
    }

    private static func storageLines() -> [String] {
        let manager = FileManager.default
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        func size(_ url: URL) -> (files: Int, bytes: Int64) {
            // Отдельный файл (likes.json, journal.txt…) — его размер; в 1.107 такие показывались «0 ф. 0 КБ».
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                return (1, Int64(values.fileSize ?? 0))
            }
            guard let items = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, 0) }
            var files = 0, bytes: Int64 = 0
            for case let item as URL in items {
                let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
            return (files, bytes)
        }
        func folder(_ url: URL) -> String {
            let children = ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            return children.map { child in
                let info = size(child)
                return "\(child.lastPathComponent) \(info.files) ф. \(info.bytes / 1024) КБ"
            }.joined(separator: "; ")
        }
        let cache = URLCache.shared
        return [
            "Caches: " + folder(caches),
            "Application Support: " + folder(support),
            "кэш сети: память \(cache.currentMemoryUsage / 1_048_576)/\(cache.memoryCapacity / 1_048_576) МБ, диск \(cache.currentDiskUsage / 1_048_576)/\(cache.diskCapacity / 1_048_576) МБ",
            "ключи настроек: " + UserDefaults.standard.dictionaryRepresentation().keys.filter { !$0.hasPrefix("Apple") && !$0.hasPrefix("NS") && !$0.hasPrefix("com.apple") && !$0.hasPrefix("AK") }.sorted().joined(separator: ", ")
        ]
    }

    private static func finish(_ lines: [String], started: Date) -> String {
        (lines + ["Готово за \(seconds(since: started))"]).joined(separator: "\n")
    }

    // MARK: - A. Устройство

    @MainActor
    private static func deviceLines() -> [String] {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let locale = Locale.current
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { "\($0 / 1_000_000_000) ГБ" } ?? "?"
        let screen = UIScreen.main
        return [
            "Fon \(version) (сборка \(build)), \(Bundle.main.bundleIdentifier ?? "?")",
            "\(device.model) \(machine), \(device.systemName) \(device.systemVersion), \(device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"), экран \(Int(screen.bounds.width))×\(Int(screen.bounds.height)) @\(Int(screen.scale))x",
            "язык/регион: \(locale.identifier), регион \(locale.region?.identifier ?? "?"), языки \(Locale.preferredLanguages.prefix(3).joined(separator: ",")), пояс \(TimeZone.current.identifier)",
            "экономия энергии: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "вкл" : "выкл"), свободно \(free), подпись до \(Signature.expiration.map(stamp) ?? "?")",
            "подпись браузера Fon (окна): \(WebViewFactory.safariUserAgent())"
        ]
    }

    // MARK: - B. Сеть

    private static func networkLines() async -> [String] {
        var lines: [String] = []
        let path: NWPath? = await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.first() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "fon.diag.net"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard once.first() else { return }
                monitor.cancel()
                continuation.resume(returning: nil)
            }
        }
        if let path {
            let kinds = path.availableInterfaces.map { "\($0.name)(\(kind($0.type)))" }.joined(separator: ", ")
            lines.append("статус \(path.status == .satisfied ? "есть сеть" : "\(path.status)"), через: \(kinds)")
            lines.append("дорогая (сотовая/точка): \(path.isExpensive ? "да" : "нет"), экономия данных: \(path.isConstrained ? "да" : "нет"), IPv4: \(path.supportsIPv4 ? "да" : "нет"), IPv6: \(path.supportsIPv6 ? "да" : "нет"), DNS: \(path.supportsDNS ? "да" : "нет")")
        } else {
            lines.append("состояние сети не пришло за 3 с")
        }
        // VPN (у владельца LocalDevVPN для SideStore) и прокси — другой адрес для YouTube.
        let proxy = (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
        let scoped = (proxy["__SCOPED__"] as? [String: Any])?.keys.sorted() ?? []
        let vpn = scoped.filter { key in ["utun", "ipsec", "ppp", "tap", "tun"].contains { key.hasPrefix($0) } }
        lines.append("VPN (по настройкам сети): \(vpn.isEmpty ? "нет" : vpn.joined(separator: ", ")); все области: \(scoped.joined(separator: ", "))")
        let http = (proxy["HTTPEnable"] as? Int ?? 0) == 1, https = (proxy["HTTPSEnable"] as? Int ?? 0) == 1, pac = (proxy["ProxyAutoConfigEnable"] as? Int ?? 0) == 1
        lines.append("прокси: HTTP \(http ? "да" : "нет"), HTTPS \(https ? "да" : "нет"), авто (PAC) \(pac ? "да" : "нет")")
        lines.append("интерфейсы с адресом: " + interfaces())
        return lines
    }

    private static func kind(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "сотовая"
        case .wiredEthernet: return "кабель"
        case .loopback: return "локальная"
        case .other: return "другое (VPN?)"
        @unknown default: return "?"
        }
    }

    /// Имена работающих интерфейсов и есть ли у них IPv4/IPv6 (сами адреса не пишем).
    private static func interfaces() -> String {
        var result: [String: Set<String>] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "?" }
        defer { freeifaddrs(head) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let item = pointer?.pointee {
            defer { pointer = item.ifa_next }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = item.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            result[String(cString: item.ifa_name), default: []].insert(family == AF_INET ? "4" : "6")
        }
        return result.keys.sorted().map { "\($0)[v\(result[$0]!.sorted().joined(separator: "/"))]" }.joined(separator: ", ")
    }

    // MARK: - D/E. Страница видео

    private struct Page {
        var data: Data?
        var status = 0
        var error: String?
        var finalHost: String?
        var serverDate: Date?
        var time: Double = 0
        let host: String
    }

    private static func fetchPage(_ videoID: String, host: String, desktop: Bool, agent: String, cookie: String?, ephemeral: Bool = false) async -> Page {
        var page = Page(host: host)
        guard let url = URL(string: "https://\(host)/watch?\(desktop ? "app=desktop&" : "")v=\(videoID)&hl=ru") else { page.error = "плохая ссылка"; return page }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let session: URLSession = ephemeral ? URLSession(configuration: .ephemeral) : .shared
        let started = Date()
        do {
            let (data, reply) = try await session.data(for: request)
            let http = reply as? HTTPURLResponse
            page.data = data
            page.status = http?.statusCode ?? 0
            page.finalHost = http?.url?.host
            if http?.url?.path.hasPrefix("/sorry") == true { page.error = "капча" }
            if let date = http?.value(forHTTPHeaderField: "Date") {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                page.serverDate = formatter.date(from: date)
            }
        } catch {
            page.error = "нет ответа: \(error.localizedDescription)"
        }
        page.time = Date().timeIntervalSince(started)
        if ephemeral { session.finishTasksAndInvalidate() }
        return page
    }

    private static func context(_ page: Page) -> [String: Any] {
        page.data.flatMap { YouTubeStreams.jsonObject(in: $0, after: "\"INNERTUBE_CONTEXT\":") } ?? [:]
    }

    private static func clientLabel(_ page: Page) -> String {
        let client = context(page)["client"] as? [String: Any] ?? [:]
        return "\(client["clientName"] as? String ?? "?") \(client["clientVersion"] as? String ?? "")"
    }

    /// Одна строка: ответ, ссылки, SABR, кем YouTube считает устройство.
    private static func short(_ page: Page) -> String {
        if let error = page.error { return error }
        guard let data = page.data else { return "пусто" }
        let client = context(page)["client"] as? [String: Any] ?? [:]
        let device = [client["clientName"], client["deviceMake"], client["deviceModel"], client["osName"], client["osVersion"], client["clientFormFactor"]]
            .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " ")
        return "HTTP \(page.status), " + DirectStream.summary(of: data) + "; видит: \(device.isEmpty ? "?" : device)"
            + (page.finalHost != nil && page.finalHost != page.host ? " [→ \(page.finalHost!)]" : "")
            + String(format: " (%.1f с)", page.time)
    }

    /// Подробно об основной странице: контекст клиента, страна, вход, эксперименты SABR, поля форматов, часы.
    private static func pageDetails(_ page: Page) -> [String] {
        if let error = page.error { return ["страница: \(error)"] }
        guard let data = page.data else { return ["страница пустая"] }
        var lines = ["HTTP \(page.status), \(data.count / 1024) КБ за \(String(format: "%.1f", page.time)) с; " + DirectStream.summary(of: data)]
        let client = context(page)["client"] as? [String: Any] ?? [:]
        let keys = ["clientName", "clientVersion", "platform", "clientFormFactor", "deviceMake", "deviceModel", "osName", "osVersion",
                    "browserName", "browserVersion", "gl", "hl", "timeZone", "userInterfaceTheme", "acceptHeader"]
        lines.append("клиент: " + keys.compactMap { key in (client[key] as? String).map { "\(key)=\($0)" } }.joined(separator: ", "))
        if let ip = client["remoteHost"] as? String { lines.append("адрес, как его видит YouTube: \(maskIP(ip))") }
        lines.append("visitorData: \((client["visitorData"] as? String).map { "есть (\($0.count))" } ?? "нет"), LOGGED_IN: "
                     + (data.range(of: Data("\"LOGGED_IN\":true".utf8)) != nil ? "да" : "нет")
                     + ", SESSION_INDEX: \(YouTubeStreams.string(in: data, after: "\"SESSION_INDEX\":\"") ?? "?")"
                     + ", DATASYNC_ID: \(YouTubeStreams.string(in: data, after: "\"DATASYNC_ID\":\"").map { "есть (\($0.count))" } ?? "нет")")
        if let date = page.serverDate {
            lines.append(String(format: "часы телефона против YouTube: %+.0f с", Date().timeIntervalSince(date)))
        }
        if let player = YouTubeStreams.string(in: data, after: "\"jsUrl\":\"") { lines.append("код плеера: \(player.replacingOccurrences(of: "\\/", with: "/"))") }
        if let response = YouTubeStreams.jsonObject(in: data, after: "ytInitialPlayerResponse = ") {
            let playability = response["playabilityStatus"] as? [String: Any] ?? [:]
            lines.append("доступность: \(playability["status"] as? String ?? "?") \((playability["reason"] as? String).map { "— \($0)" } ?? "")")
            let streaming = response["streamingData"] as? [String: Any] ?? [:]
            lines.append("streamingData: " + streaming.keys.sorted().joined(separator: ", "))
            let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
            if let audio = adaptive.first(where: { ($0["itag"] as? Int) == 140 }) ?? adaptive.first {
                lines.append("поля формата \(audio["itag"] as? Int ?? 0): " + audio.keys.sorted().joined(separator: ","))
            }
            let itags = adaptive.compactMap { $0["itag"] as? Int }.map(String.init).joined(separator: ",")
            lines.append("форматы (itag): \(itags.isEmpty ? "нет" : itags)")
            let playerConfig = response["playerConfig"] as? [String: Any] ?? [:]
            lines.append("playerConfig: " + playerConfig.keys.sorted().joined(separator: ", "))
            if let micro = (response["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any] {
                lines.append("видео: \(micro["category"] as? String ?? "?"), семейно: \(micro["isFamilySafe"] as? Bool == true ? "да" : "нет"), стран доступно: \((micro["availableCountries"] as? [Any])?.count ?? 0)")
            }
        } else {
            lines.append("данных плеера (ytInitialPlayerResponse) на странице нет")
        }
        // Флаги экспериментов, где есть sabr/abr/ump/po — включил ли YouTube этому посетителю что-то особое.
        let text = String(decoding: data, as: UTF8.self)
        if let range = text.range(of: "\"EXPERIMENT_FLAGS\":{") {
            let tail = text[range.upperBound...].prefix(60_000)
            let body = tail.prefix { $0 != "}" }
            let flags = body.components(separatedBy: ",").filter { item in
                let name = item.lowercased()
                return ["sabr", "server_abr", "ump", "po_token", "potoken", "attestation", "botguard", "html5_sabr"].contains { name.contains($0) }
            }
            lines.append("флаги (sabr/ump/po): \(flags.isEmpty ? "нет" : flags.prefix(40).joined(separator: ", "))")
        }
        return lines
    }

    /// Последняя часть адреса скрыта (адрес — для сравнения устройств, не для публикации).
    private static func maskIP(_ ip: String) -> String {
        if ip.contains(":") { return ip.components(separatedBy: ":").prefix(3).joined(separator: ":") + ":…" }
        let parts = ip.components(separatedBy: ".")
        return parts.count == 4 ? parts.prefix(3).joined(separator: ".") + ".x" : "?"
    }

    /// youtubei/v1/player тем же клиентом и версией, что дала страница (со входом, как запрос страницы YouTube).
    private static func playerAPI(_ videoID: String, page: Page, origin: String, agent: String) async -> (text: String, response: [String: Any]?) {
        let context = context(page)
        guard !context.isEmpty, let client = context["client"] as? [String: Any] else { return ("нет контекста клиента на странице", nil) }
        guard let url = URL(string: "\(origin)/youtubei/v1/player?prettyPrint=false") else { return ("?", nil) }
        let body: [String: Any] = ["context": context, "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
                                   "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]]]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return ("?", nil) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = json
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue(page.data.flatMap { YouTubeStreams.string(in: $0, after: "\"INNERTUBE_CONTEXT_CLIENT_NAME\":") }.map { String($0.prefix { $0.isNumber }) } ?? "1",
                         forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client["clientVersion"] as? String ?? "", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        if let visitor = client["visitorData"] as? String { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let cookie = YouTubeSession.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let auth = YouTubeSession.authorization(origin: origin) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            YouTubeAccount.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        guard let (data, reply) = try? await URLSession.shared.data(for: request) else { return ("нет ответа", nil) }
        let status = (reply as? HTTPURLResponse)?.statusCode ?? 0
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("HTTP \(status), не JSON", nil) }
        let playability = response["playabilityStatus"] as? [String: Any] ?? [:]
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        let formats = (streaming["formats"] as? [[String: Any]] ?? []) + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])
        let linked = formats.filter { $0["url"] != nil || $0["signatureCipher"] != nil || $0["cipher"] != nil }.count
        let state = playability["status"] as? String ?? "?"
        let why = (playability["reason"] as? String).map { " (\($0.prefix(60)))" } ?? ""
        let sabr = streaming["serverAbrStreamingUrl"] != nil ? "да" : "нет"
        let text: String = "HTTP \(status), \(state)\(why), ссылки \(linked) из \(formats.count), SABR: \(sabr)"
        return (text, response)
    }

    // MARK: - F. WebKit

    /// Запрос страницы из скрытого окна m.youtube (cookies окна) — подсчёт по тексту.
    @MainActor
    private static func webFetch(_ videoID: String) async -> String {
        let expression = """
        (async () => { const r = await fetch('/watch?v=' + vid + '&hl=ru', { credentials: 'include' }); const t = await r.text();
          const c = (w) => t.split(w).length - 1;
          return 'HTTP ' + r.status + ', signatureCipher ' + c('signatureCipher') + ', videoplayback ' + c('videoplayback') +
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

    /// Настоящая страница в скрытом окне (вход общий с приложением, видео не запускается): что в данных плеера.
    @MainActor
    private static func webPage(_ address: String) async -> String {
        guard let url = URL(string: address) else { return "?" }
        let loader = PageLoader()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        webView.customUserAgent = WebViewFactory.safariUserAgent()
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = loader
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first
        window?.insertSubview(webView, at: 0)
        defer { webView.stopLoading(); webView.removeFromSuperview() }
        let loaded = await loader.load(url, in: webView, timeout: 20)
        try? await Task.sleep(nanoseconds: 2_000_000_000) // данные плеера ставит скрипт страницы
        let script = """
        (() => { const p = document.getElementById('movie_player');
          const r = window.ytInitialPlayerResponse || (p && p.getPlayerResponse && p.getPlayerResponse());
          const cfg = (window.ytcfg && ytcfg.get && ytcfg.get('INNERTUBE_CONTEXT')) || {}; const c = cfg.client || {};
          const who = [c.clientName, c.clientVersion, c.deviceMake, c.deviceModel, c.osName, c.osVersion, c.clientFormFactor].filter(Boolean).join(' ');
          if (!r) return 'данных плеера нет (' + location.host + location.pathname + ', «' + document.title.slice(0, 40) + '»); видит: ' + who;
          const sd = r.streamingData || {}; const all = (sd.formats || []).concat(sd.adaptiveFormats || []);
          const linked = all.filter((f) => f.url || f.signatureCipher || f.cipher).length;
          return ((r.playabilityStatus || {}).status) + ', ссылки ' + linked + ' из ' + all.length + ', SABR: ' + (sd.serverAbrStreamingUrl ? 'да' : 'нет') + '; видит: ' + who; })()
        """
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(script) { result, error in
                continuation.resume(returning: (result as? String) ?? "ошибка скрипта: \(error?.localizedDescription ?? "?")")
            }
        }
        return (loaded ? "" : "(не догрузилась за 20 с) ") + value
    }

    private final class PageLoader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?

        @MainActor
        func load(_ url: URL, in webView: WKWebView, timeout: Double) async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.load(URLRequest(url: url))
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
            }
        }

        private func finish(_ ok: Bool) {
            continuation?.resume(returning: ok)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }

    // MARK: - G. Ссылки

    /// Первые 1 КБ ссылки: код ответа и размер (403 — ссылка есть, но не пускают).
    private static func rangeCheck(_ url: URL, headers: [String: String]) async -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        guard let (data, reply) = try? await URLSession.shared.data(for: request) else { return "нет ответа" }
        let http = reply as? HTTPURLResponse
        return "\(http?.statusCode ?? 0), \(data.count) байт, всего \(http?.value(forHTTPHeaderField: "Content-Range")?.components(separatedBy: "/").last ?? "?")"
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
                let size = item.presentationSize
                return "играет (длина \(length.isFinite ? "\(Int(length)) с" : "?")" + (size.width > 0 ? ", видео \(Int(size.width))×\(Int(size.height))" : ", без видео") + ")"
            }
        }
        return "не заиграл за 12 с (статус \(item.status.rawValue), буфер пуст: \(item.isPlaybackBufferEmpty))"
    }

    // MARK: - K. Настройки

    private static func settingsLines() -> [String] {
        var lines = ["системный плеер: \(Settings.nativeAudio ? "вкл" : "выкл"), режим музыки: \(Settings.musicMode ? "вкл" : "выкл"), видео на обложке: \(Settings.videoArtwork ? "вкл" : "выкл"), язык: \(AppLanguage.current)"]
        if let until = UserDefaults.standard.object(forKey: "sabrOnlyUntil") as? Date, until > Date() {
            lines.append("отметка «только SABR» до \(stamp(until)): \(UserDefaults.standard.string(forKey: "sabrOnlyReason") ?? "?")")
        } else {
            lines.append("отметки «только SABR» нет")
        }
        return lines
    }

    // MARK: - Общее

    private static func seconds(since date: Date) -> String {
        String(format: "%.1f с", Date().timeIntervalSince(date))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter.string(from: date)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Модель устройства («iPhone18,1»).
    private static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Экран диагностики: строки появляются по ходу, «Скопировать» и «Поделиться» — когда всё готово (и раньше — то, что есть).
final class DiagnosticsViewController: UIViewController {
    private let videoID: String
    private let textView = UITextView()
    private var text = ""
    private var done = false

    init(videoID: String) {
        self.videoID = videoID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Диагностика…"
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(share)),
            UIBarButtonItem(title: tr("Скопировать"), style: .done, target: self, action: #selector(copyText))
        ]
        UIApplication.shared.isIdleTimerDisabled = true // экран не гаснет, пока идёт проверка (до нескольких минут)
        Task { [weak self] in
            guard let self else { return }
            let result = await PlayerDiagnostics.run(videoID: self.videoID) { [weak self] line in self?.append(line) }
            self.text = result
            self.textView.text = result
            self.done = true
            self.title = "Диагностика готова"
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func append(_ line: String) {
        text += (text.isEmpty ? "" : "\n") + line
        textView.text = text + "\n…"
        textView.scrollRangeToVisible(NSRange(location: (textView.text as NSString).length - 1, length: 1))
    }

    @objc private func copyText() {
        UIPasteboard.general.string = text
        title = done ? "Скопировано" : "Скопировано (не всё)"
    }

    @objc private func share() {
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    @objc private func close() {
        UIApplication.shared.isIdleTimerDisabled = false
        dismiss(animated: true)
    }
}
