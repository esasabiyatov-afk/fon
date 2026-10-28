import Foundation
import JavaScriptCore

/// Прямой путь к звуку без окна (решение владельца 29.10.2026, вариант 3): та же страница, что открывало скрытое
/// окно (`www.youtube.com/watch?app=desktop`, Safari на iPhone, вход в аккаунт), но запросом самого приложения.
/// Ссылка на файл itag 18 там зашифрована (`signatureCipher`: подпись `s` + параметр `n`, без PO-токена — видно
/// по журналу 1.63). Расшифровывает «решатель» yt-dlp (`ChallengeSolver`) — тот же код, что выполнил бы браузер.
/// Запросы идут из приложения (URLSession + JavaScriptCore) — работают и в фоне, звук приложения не трогают.
enum DirectStream {
    static func find(_ videoID: String) async -> YouTubeStreams.Result {
        var result = YouTubeStreams.Result()
        guard let url = URL(string: "\(YouTubeStreams.origin)/watch?app=desktop&v=\(videoID)&hl=ru") else { return result }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let cookie = YouTubeSession.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, reply) = try? await URLSession.shared.data(for: request) else {
            result.log.append("прямо: нет ответа")
            return result
        }
        let http = reply as? HTTPURLResponse
        if let final = http?.url, final.path.hasPrefix("/sorry") || final.host != url.host {
            result.log.append("прямо: перекинуло на \(final.host ?? "?")\(final.path)")
            return result
        }
        guard let response = YouTubeStreams.jsonObject(in: data, after: "ytInitialPlayerResponse = ") else {
            result.log.append("прямо: HTTP \(http?.statusCode ?? 0), нет ответа плеера")
            return result
        }
        if let details = response["videoDetails"] as? [String: Any] {
            result.title = details["title"] as? String
            result.author = details["author"] as? String
        }
        let status = (response["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        let formats = streaming["formats"] as? [[String: Any]] ?? []
        guard status == "OK", let format = formats.first(where: { ($0["itag"] as? Int) == 18 }) ?? formats.first else {
            result.log.append("прямо: \(status), файлов нет")
            return result
        }
        guard let jsPath = YouTubeStreams.string(in: data, after: "\"jsUrl\":\""),
              let playerURL = URL(string: YouTubeStreams.origin + jsPath.replacingOccurrences(of: "\\/", with: "/")) else {
            result.log.append("прямо: нет кода плеера")
            return result
        }
        // Ссылка + что расшифровать: подпись (из signatureCipher) и n (в самой ссылке).
        var base: String?
        var signature: String?
        var signatureParam = "signature"
        if let direct = format["url"] as? String {
            base = direct
        } else if let cipher = format["signatureCipher"] as? String {
            let items = URLComponents(string: "?" + cipher)?.queryItems ?? []
            base = items.first { $0.name == "url" }?.value
            signature = items.first { $0.name == "s" }?.value
            signatureParam = items.first { $0.name == "sp" }?.value ?? "signature"
        }
        guard let base, var components = URLComponents(string: base) else {
            result.log.append("прямо: нет ссылки в ответе")
            return result
        }
        let n = components.queryItems?.first { $0.name == "n" }?.value
        let started = Date()
        do {
            let solved = try await ChallengeSolver.shared.solve(playerURL: playerURL, n: n, signature: signature)
            var items = components.percentEncodedQueryItems ?? []
            if n != nil, let solvedN = solved.n {
                items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: encode(solvedN)) : $0 }
            }
            if let solvedSignature = solved.signature {
                items.append(URLQueryItem(name: signatureParam, value: encode(solvedSignature)))
            }
            components.percentEncodedQueryItems = items
            guard let final = components.url else { throw SolverError.message("ссылка не собралась") }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            result.log.append("прямо: itag \(format["itag"] as? Int ?? 0), расшифровано за \(ms) мс\(solved.note)")
            result.streams = [AudioStream(url: final, headers: ["User-Agent": YouTubeStreams.iPhoneSafariUserAgent],
                                          client: "Прямо файл")]
        } catch {
            result.log.append("прямо: решатель — \(error)")
        }
        return result
    }

    /// Значения подписи и n — в ссылку как есть, кроме символов, ломающих параметры.
    private static func encode(_ value: String) -> String {
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

    struct Solved {
        var n: String?
        var signature: String?
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

    func solve(playerURL: URL, n: String?, signature: String?) async throws -> Solved {
        let player = try await playerCode(playerURL)
        do {
            return try await run(player: player, n: n, signature: signature)
        } catch {
            // Возможно, YouTube поменял код, а в yt-dlp уже поправили решатель — берём свежий (не чаще раза в час).
            guard await updateScripts() else { throw error }
            var solved = try await run(player: player, n: n, signature: signature)
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

    private func run(player: Player, n: String?, signature: String?) async throws -> Solved {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Solved, Error>) in
            let thread = Thread {
                self.runLock.lock()
                defer { self.runLock.unlock() }
                do {
                    continuation.resume(returning: try self.runSync(player: player, n: n, signature: signature))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func runSync(player: Player, n: String?, signature: String?) throws -> Solved {
        let context = try loadContext()
        var requests: [[String: Any]] = []
        if let n { requests.append(["type": "n", "challenges": [n]]) }
        if let signature { requests.append(["type": "sig", "challenges": [signature]]) }
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
            let challenge = (request["challenges"] as? [String])?.first ?? ""
            if request["type"] as? String == "n" { solved.n = data[challenge] } else { solved.signature = data[challenge] }
        }
        if n != nil, solved.n == nil { throw SolverError.message("n не решён") }
        if signature != nil, solved.signature == nil { throw SolverError.message("подпись не решена") }
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
