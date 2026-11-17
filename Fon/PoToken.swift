import UIKit
import WebKit

/// PO-токен для SABR (после 1.105: на iPhone 17 «защита потока: 2» — YouTube отдаёт только начало трека, пока
/// клиент не подтвердит, что он браузер; владелец: «давай второй» — получать токен самим). Как страница YouTube:
/// проверка BotGuard Google (`api/jnn/v1/Create` → скрипт проверки в скрытом окне → `GenerateIT` → токен
/// целостности), затем «чеканка» токена для привязки — вход: DATASYNC_ID, без входа: VISITOR_DATA (по схеме
/// открытой библиотеки BgUtils, MIT). Запросы к Google — Swift, сама проверка — скрытый WKWebView (нужен браузер).
/// Токен привязан к сессии, а не к видео — живёт часы (кэш в памяти и UserDefaults), так что в фоне обычно берётся
/// готовый. Не вышло — SABR идёт без токена, как раньше.
@MainActor
final class PoToken: NSObject, WKNavigationDelegate {
    static let shared = PoToken()

    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let storeKey = "poTokens"

    private var webView: WKWebView?
    private var pageReady: CheckedContinuation<Void, Never>?
    /// Окно уже прошло проверку и умеет чеканить токены — до этого времени.
    private var minterUntil = Date.distantPast
    private var working: Task<String?, Never>?
    /// Итог последней попытки — для диагностики.
    private(set) var lastReport = ""

    private struct Stored: Codable { let token: String; let until: Date }

    /// Готовый токен для привязки (без сети и окна) — если ещё живой.
    nonisolated static func cached(for binding: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let all = try? JSONDecoder().decode([String: Stored].self, from: data),
              let stored = all[binding], stored.until > Date() else { return nil }
        return stored.token
    }

    nonisolated private static func store(_ token: String, for binding: String, until: Date) {
        var all = (UserDefaults.standard.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) }) ?? [:]
        all = all.filter { $0.value.until > Date() }
        all[binding] = Stored(token: token, until: until)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

    /// Последняя привязка — чтобы при открытии приложения заранее обновить токен (в фоне окно может не ответить).
    nonisolated static func rememberBinding(_ binding: String) {
        UserDefaults.standard.set(binding, forKey: "poBinding")
    }

    /// При запуске и возврате в приложение: токен кончится в ближайший час — получаем новый заранее.
    func startWarmUp() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PoToken.shared.warmUp() }
        }
    }

    private func warmUp() {
        guard let binding = UserDefaults.standard.string(forKey: "poBinding"), working == nil else { return }
        let soon = (UserDefaults.standard.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) })?[binding]
        guard (soon?.until ?? .distantPast) < Date().addingTimeInterval(3600) else { return }
        Task { _ = await self.refresh(binding) }
    }

    /// Строго по одному: с 1.109 токены просят часто (токен видео на каждый трек — плеер, «заранее», «Скачанные»),
    /// и две проверки сразу создавали два окна — ожидание первой могло не закончиться никогда.
    private func refresh(_ binding: String) async -> String? {
        while let current = working {
            _ = await current.value
            if let token = Self.cached(for: binding) { return token }
            if working == current { working = nil } // та проверка закончилась — дальше своя
        }
        let task = Task { await self.make(binding) }
        working = task
        let token = await task.value
        if working == task { working = nil }
        return token
    }

    /// Диагностика: новый токен с полной проверкой (кэш и «чеканщик» сбрасываются).
    func fresh(for binding: String) async -> String? {
        if let working { _ = await working.value }
        var all = (UserDefaults.standard.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) }) ?? [:]
        all[binding] = nil
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        minterUntil = .distantPast
        return await refresh(binding)
    }

    /// До какого времени окно умеет чеканить токены (диагностика).
    var minterValidUntil: Date { minterUntil }

    /// Токен для привязки: из кэша, иначе проверка (до ~20 с). nil — не вышло (причина — `lastReport`).
    func token(for binding: String) async -> String? {
        if let token = Self.cached(for: binding) { lastReport = "из кэша"; return token }
        if let working { _ = await working.value; if let token = Self.cached(for: binding) { return token } }
        return await refresh(binding)
    }

    private func make(_ binding: String) async -> String? {
        let started = Date()
        do {
            if minterUntil < Date().addingTimeInterval(60) { try await attest() }
            let raw = try await evaluate("return await window.__fonPoMint(binding)", ["binding": binding], timeout: 10)
            let token = raw
            guard token.count > 20 else { throw Failure("пустой токен") }
            Self.store(token, for: binding, until: minterUntil)
            lastReport = String(format: "получен за %.1f с (длина %d)", Date().timeIntervalSince(started), token.count)
            AppJournal.add("PO-токен " + lastReport)
            return token
        } catch {
            lastReport = String(format: "не получен за %.1f с: %@", Date().timeIntervalSince(started), (error as? Failure)?.text ?? error.localizedDescription)
            minterUntil = .distantPast
            AppJournal.add("PO-токен " + lastReport)
            return nil
        }
    }

    /// Ответ или тайм-аут — что раньше (на главном потоке).
    private final class Once: @unchecked Sendable {
        private var done = false
        func first() -> Bool { if done { return false }; done = true; return true }
    }

    private struct Failure: Error { let text: String; init(_ text: String) { self.text = text } }

    /// Проверка BotGuard: вызов, скрипт в окне, токен целостности, «чеканщик» в окне.
    private func attest() async throws {
        let create = try await post("Create", body: [Self.requestKey])
        guard let challenge = Self.challenge(from: create) else { throw Failure("Create: не разобрался ответ") }
        var script = challenge.script
        if script == nil, let address = challenge.scriptURL,
           let url = URL(string: address.hasPrefix("//") ? "https:" + address : address) {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: request) { script = String(data: data, encoding: .utf8) }
        }
        guard let script, let program = challenge.program, let globalName = challenge.globalName else { throw Failure("Create: нет скрипта проверки") }
        try await loadPage()
        let answer = try await evaluate("return await window.__fonPoSnapshot(script, program, globalName)",
                                        ["script": script, "program": program, "globalName": globalName], timeout: 15)
        let botguard = answer
        guard !botguard.isEmpty else { throw Failure("проверка: пустой ответ") }
        let generated = try await post("GenerateIT", body: [Self.requestKey, botguard])
        guard let list = generated as? [Any], let integrity = list.first as? String else { throw Failure("GenerateIT: нет токена целостности") }
        let ttl = (list.count > 1 ? (list[1] as? NSNumber)?.doubleValue : nil) ?? 6 * 3600
        let ok = try await evaluate("return await window.__fonPoMinter(integrity)", ["integrity": integrity], timeout: 10)
        guard ok == "ok" else { throw Failure("чеканщик: \(ok)") }
        // Запас: токен перестаёт действовать раньше, чем обещано.
        minterUntil = Date().addingTimeInterval(max(600, ttl * 0.8))
    }

    private func post(_ method: String, body: [Any]) async throws -> Any {
        guard let url = URL(string: "https://www.youtube.com/api/jnn/v1/\(method)") else { throw Failure("адрес") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, reply) = try await URLSession.shared.data(for: request)
        let status = (reply as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure("\(method): ответ \(status) \(String(decoding: data.prefix(80), as: UTF8.self))")
        }
        return json
    }

    /// Ответ Create: либо массив данных, либо «перемешанная» строка base64 (каждый байт + 97).
    nonisolated static func challenge(from json: Any) -> (script: String?, scriptURL: String?, program: String?, globalName: String?)? {
        guard let raw = json as? [Any] else { return nil }
        var data: [Any] = []
        if raw.count > 1, let scrambled = raw[1] as? String, let bytes = Data(base64Encoded: websafe(scrambled)) {
            let text = String(decoding: bytes.map { $0 &+ 97 }, as: UTF8.self)
            data = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any]) ?? []
        } else if let first = raw.first as? [Any] {
            data = first
        }
        guard data.count > 5 else { return nil }
        let script = (data[1] as? [Any])?.first { ($0 as? String)?.isEmpty == false } as? String
        let url = (data[2] as? [Any])?.first { ($0 as? String)?.isEmpty == false } as? String
        return (script, url, data[4] as? String, data[5] as? String)
    }

    nonisolated static func websafe(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ".", with: "=")
        while value.count % 4 != 0 { value += "=" }
        return value
    }

    // MARK: - Окно

    private func loadPage() async throws {
        if let webView, webView.url != nil { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView.customUserAgent = WebViewFactory.safariUserAgent()
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        // В окне — чтобы iOS не усыпляла скрипты скрытой страницы.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first
        window?.insertSubview(webView, at: 0)
        self.webView = webView
        await withCheckedContinuation { continuation in
            pageReady = continuation
            webView.loadHTMLString("<!doctype html><html><head><meta charset=utf-8></head><body><script>\(Self.helpers)</script></body></html>",
                                   baseURL: URL(string: "https://www.youtube.com/"))
        }
        guard webView.url != nil else { self.webView = nil; throw Failure("окно не загрузилось") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady?.resume(); pageReady = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageReady?.resume(); pageReady = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageReady?.resume(); pageReady = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.webView?.removeFromSuperview()
        self.webView = nil
        minterUntil = .distantPast
    }

    /// Вызов скрипта окна. Ответ — всегда строка (async-версия callAsyncJavaScript падала на nil в части iOS).
    private func evaluate(_ body: String, _ arguments: [String: Any], timeout: Double) async throws -> String {
        if webView == nil { try await loadPage() }
        guard let webView else { throw Failure("нет окна") }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let finish: (Result<String, Error>) -> Void = { result in
                guard once.first() else { return }
                continuation.resume(with: result)
            }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): finish(.success((value as? String) ?? ""))
                case .failure(let error):
                    let message = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
                    finish(.failure(Failure(message)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(.failure(Failure("нет ответа за \(Int(timeout)) с"))) }
        }
    }

    /// Скрипт окна: запуск проверки BotGuard и чеканка (как BotGuardClient/WebPoMinter в BgUtils).
    private static let helpers = #"""
    (function () {
      const u8 = (b64) => { b64 = b64.replace(/-/g, '+').replace(/_/g, '/').replace(/\./g, '='); while (b64.length % 4) b64 += '=';
        const s = atob(b64); const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out; };
      const b64 = (bytes) => { let s = ''; for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s).replace(/\+/g, '-').replace(/\//g, '_'); };
      let signals = [];
      let mint = null;
      window.__fonPoSnapshot = async function (script, program, globalName) {
        new Function(script)();
        const vm = window[globalName];
        if (!vm || typeof vm.a !== 'function') throw new Error('нет BotGuard (' + globalName + ')');
        let snapshot = null;
        const ready = new Promise((ok) => {
          const callback = (asyncSnapshot) => { snapshot = asyncSnapshot; ok(); };
          vm.a(program, callback, true, undefined, () => {}, [[], []]);
        });
        await Promise.race([ready, new Promise((_, no) => setTimeout(() => no(new Error('BotGuard не ответил')), 10000))]);
        if (typeof snapshot !== 'function') throw new Error('нет функции снимка');
        signals = [];
        return await new Promise((ok) => snapshot((response) => ok(response), [undefined, undefined, signals, undefined]));
      };
      window.__fonPoMinter = async function (integrity) {
        const getMinter = signals[0];
        if (typeof getMinter !== 'function') return 'нет getMinter';
        const callback = await getMinter(u8(integrity));
        if (typeof callback !== 'function') return 'нет функции чеканки';
        mint = callback;
        return 'ok';
      };
      window.__fonPoMint = async function (binding) {
        if (!mint) throw new Error('нет чеканщика');
        const result = await mint(new TextEncoder().encode(binding));
        if (!(result instanceof Uint8Array)) throw new Error('чеканка: не байты');
        return b64(result);
      };
    })();
    """#
}
