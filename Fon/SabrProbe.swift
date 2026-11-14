import AVFoundation
import UIKit
import WebKit

/// Проба протокола SABR (просьба владельца после 1.98: на iPad и iPhone 17 YouTube отдаёт звук только по SABR,
/// системный плеер там недоступен). Только проверка, обычное воспроизведение не трогает: ⚙ → «Проверить SABR».
/// Шаги: страница видео (как `DirectStream`) → адрес SABR (`serverAbrStreamingUrl`, его `n` — решателем),
/// настройки потока и форматы → в скрытом WKWebView библиотека googlevideo (MIT, `Solver/googlevideo.sabr.min.txt`)
/// ведёт протокол; сами запросы к googlevideo делает приложение (`fonFetch`, без ограничений CORS) →
/// первые ~20 с звука itag 140 → файл → AVPlayer пробует его играть. Итог — текст для владельца.
/// Работает и там, где системный плеер есть: страница всё равно содержит адрес SABR.
final class SabrProbe: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?
    private var lines: [String] = []

    static func run(videoID: String, in view: UIView) async -> String {
        let probe = SabrProbe()
        let text = await probe.start(videoID: videoID, in: view)
        await MainActor.run { probe.webView?.removeFromSuperview(); probe.webView = nil }
        return text
    }

    private func note(_ line: String) { lines.append(line) }

    private func start(videoID: String, in view: UIView) async -> String {
        let device = await MainActor.run { "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)" }
        note("Fon \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"), \(device)")
        note("видео \(videoID), \(YouTubeSession.summary)")
        await YouTubeSession.refreshed()
        // 1. Страница видео — тот же запрос, что у системного плеера.
        guard let url = URL(string: "\(YouTubeStreams.origin)/watch?app=desktop&v=\(videoID)&hl=ru") else { return finish("плохая ссылка") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ru-RU,ru;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let cookie = YouTubeSession.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return finish("YouTube не ответил (сеть)") }
        guard let response = YouTubeStreams.jsonObject(in: data, after: "ytInitialPlayerResponse = ") else { return finish("страница без данных плеера") }
        let status = (response["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "?"
        let streaming = response["streamingData"] as? [String: Any] ?? [:]
        let formats = streaming["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        note("страница: \(status), форматов \(formats.count)+\(adaptive.count)")
        guard var sabrURL = streaming["serverAbrStreamingUrl"] as? String else { return finish("адреса SABR нет") }
        let config = (((response["playerConfig"] as? [String: Any])?["mediaCommonConfig"] as? [String: Any])?["mediaUstreamerRequestConfig"] as? [String: Any])?["videoPlaybackUstreamerConfig"] as? String
        guard let config else { return finish("нет настроек потока (videoPlaybackUstreamerConfig)") }
        let clientVersion = YouTubeStreams.string(in: data, after: "\"INNERTUBE_CLIENT_VERSION\":\"") ?? "2.20251114.00.00"
        let clientName = Self.number(in: data, after: "\"INNERTUBE_CONTEXT_CLIENT_NAME\":") ?? 1
        note("клиент \(clientName) \(clientVersion)")

        // 2. Параметр n в адресе SABR — тем же решателем, что и обычные ссылки (иначе YouTube режет скорость/отказывает).
        if var parts = URLComponents(string: sabrURL), let n = parts.queryItems?.first(where: { $0.name == "n" })?.value {
            if let jsPath = YouTubeStreams.string(in: data, after: "\"jsUrl\":\""),
               let playerURL = URL(string: YouTubeStreams.origin + jsPath.replacingOccurrences(of: "\\/", with: "/")),
               let solved = try? await ChallengeSolver.shared.solve(playerURL: playerURL, n: [n], signatures: []),
               let value = solved.n[n] {
                parts.queryItems = parts.queryItems?.map { $0.name == "n" ? URLQueryItem(name: "n", value: value) : $0 }
                sabrURL = parts.url?.absoluteString ?? sabrURL
                note("n решён")
            } else {
                note("n не решился — пробуем как есть")
            }
        }

        // 3. Протокол — библиотека googlevideo в скрытом окне.
        guard let bundleURL = Bundle.main.url(forResource: "googlevideo.sabr.min", withExtension: "txt"),
              let library = try? String(contentsOf: bundleURL, encoding: .utf8) else { return finish("нет библиотеки SABR в приложении") }
        await prepareWebView(in: view)
        let args: [String: Any] = ["videoId": videoID, "url": sabrURL, "config": config, "clientName": clientName,
                                   "clientVersion": clientVersion, "rawFormats": adaptive, "seconds": 20]
        guard let webView = await MainActor.run(body: { self.webView }) else { return finish("окно не создалось") }
        let result: Result<Any, Error> = await withCheckedContinuation { done in
            DispatchQueue.main.async {
                webView.callAsyncJavaScript(library + "\n" + Self.script, arguments: args, in: nil, in: .page) { done.resume(returning: $0) }
            }
        }
        guard case .success(let value) = result, let json = value as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            if case .failure(let error) = result { return finish("скрипт: \(error.localizedDescription)") }
            return finish("скрипт ничего не вернул")
        }
        if let error = object["error"] as? String { (object["log"] as? [String])?.forEach(note); return finish(error) }
        let total = object["total"] as? Int ?? 0
        note("дорожка itag \(object["itag"] ?? "?") \(object["mime"] ?? "")")
        (object["log"] as? [String])?.forEach(note)
        note("запросов \(object["requests"] ?? 0), получено \(total / 1024) КБ за \((object["ms"] as? Int ?? 0) / 1000) с" + ((object["firstAt"] as? Int).map { ", первый кусок через \($0) мс" } ?? ""))
        guard total > 0, let encoded = object["data"] as? String, let audio = Data(base64Encoded: encoded) else {
            return finish("звук не пришёл")
        }
        // 4. Играет ли это системный плеер iOS.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sabr-probe.m4a")
        try? audio.write(to: file)
        return finish(await Self.tryPlay(file))
    }

    private func finish(_ last: String) -> String {
        note("ИТОГ: " + last)
        return lines.joined(separator: "\n")
    }

    private static func number(in data: Data, after marker: String) -> Int? {
        guard let found = data.range(of: Data(marker.utf8)) else { return nil }
        return Int(String(decoding: data[found.upperBound...].prefix { (0x30...0x39).contains($0) }, as: UTF8.self))
    }

    /// Беззвучно включаем файл на 4 с: пошло ли время — значит, системный плеер это понимает.
    private static func tryPlay(_ file: URL) async -> String {
        let player = await MainActor.run { () -> AVPlayer in
            let player = AVPlayer(url: file)
            player.volume = 0
            player.play()
            return player
        }
        return await player.waitResult()
    }

    @MainActor private func prepareWebView(in view: UIView) async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "fonFetch")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        view.insertSubview(webView, at: 0)
        self.webView = webView
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loaded = done
            webView.loadHTMLString("<!doctype html><title>Fon</title>", baseURL: URL(string: "https://www.youtube.com/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume()
        loaded = nil
    }

    /// Запрос библиотеки к googlevideo — делает приложение (страница не упирается в CORS) и отдаёт ответ целиком.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let urlString = body["url"] as? String, let url = URL(string: urlString) else {
            replyHandler(["error": "плохой запрос"], nil)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = body["method"] as? String ?? "GET"
        (body["headers"] as? [String: String])?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        if let encoded = body["body"] as? String { request.httpBody = Data(base64Encoded: encoded) }
        URLSession.shared.dataTask(with: request) { data, reply, error in
            DispatchQueue.main.async {
                if let error { replyHandler(["error": error.localizedDescription], nil); return }
                let data = data ?? Data()
                replyHandler(["status": (reply as? HTTPURLResponse)?.statusCode ?? 0,
                              "length": data.count, "body": data.base64EncodedString()], nil)
            }
        }.resume()
    }

    /// Тело для callAsyncJavaScript (аргументы — `args` выше). Проверено в node с заглушкой запросов.
    private static let script = #"""
// Тело для callAsyncJavaScript: аргументы videoId, url, config, clientName, clientVersion, rawFormats, seconds.
const S = FonSabr;
const log = [];
const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s) => { const bin = atob(s || ''); const u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i); return u8; };
let requests = 0;
let stopped = false;
const fetchFunction = async (input, init) => {
  init = init || {};
  if (stopped) throw new Error('проверка закончена');
  requests += 1;
  let body = null;
  if (init.body) body = b64(init.body instanceof Uint8Array ? init.body : new Uint8Array(init.body.buffer || init.body));
  // Не чаще раза в 200 мс: пустой ответ сервера иначе крутит цикл запросов без паузы и вешает страницу.
  await new Promise((ok) => setTimeout(ok, 200));
  const reply = await window.webkit.messageHandlers.fonFetch.postMessage({ url: String(input), method: init.method || 'GET', body: body, headers: init.headers || {} });
  if (!reply || reply.error) throw new Error((reply && reply.error) || 'нет ответа');
  if (requests <= 3) log.push('запрос ' + requests + ': HTTP ' + reply.status + ', ' + (reply.length || 0) + ' байт');
  return new Response(unb64(reply.body), { status: reply.status, headers: { 'content-type': 'application/vnd.yt-ump' } });
};
const formats = rawFormats.map((f) => { try { return S.buildSabrFormat(f); } catch (e) { return null; } }).filter(Boolean);
const audio = formats.find((f) => f.itag === 140) || formats.find((f) => f.hasAudio && !f.hasVideo && /mp4/.test(f.mimeType || ''));
if (!audio) return JSON.stringify({ error: 'нет звуковой дорожки mp4 среди ' + formats.length + ' форматов' });
const stream = new S.SabrStream({ videoId, serverAbrStreamingUrl: url, videoPlaybackUstreamerConfig: config,
  clientInfo: { clientName: clientName, clientVersion: clientVersion }, formats, fetchFunction });
stream.on('streamProtectionStatusUpdate', (s) => log.push('защита потока: ' + s.status + (s.maxRetries ? ' (повторов ' + s.maxRetries + ')' : '')));
stream.on('error', (e) => log.push('ошибка: ' + (e && e.message)));
stream.on('finish', () => log.push('поток закончился'));
let started;
try {
  started = stream.start({ audioFormat: audio, enabledTrackTypes: S.EnabledTrackTypes.AUDIO_ONLY, isPostLiveDvr: false, maxRetries: 2 });
} catch (e) { return JSON.stringify({ error: 'старт: ' + e.message, log }); }
const reader = started.audioStream.getReader();
const chunks = []; let total = 0; const t0 = Date.now(); const end = t0 + seconds * 1000; let firstAt = null;
while (Date.now() < end && total < 4000000) {
  const r = await Promise.race([reader.read().catch((e) => ({ err: e })), new Promise((ok) => setTimeout(() => ok({ timeout: true }), Math.max(10, end - Date.now())))]);
  if (r.timeout || r.done) break;
  if (r.err) { log.push('чтение: ' + (r.err && r.err.message)); break; }
  const v = r.value; const u8 = v instanceof Uint8Array ? v : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (firstAt === null) firstAt = Date.now() - t0;
  chunks.push(u8); total += u8.length;
}
stopped = true;
try { await Promise.race([stream.abort(), new Promise((ok) => setTimeout(ok, 1000))]); } catch (e) {}
const all = new Uint8Array(total); let off = 0; for (const c of chunks) { all.set(c, off); off += c.length; }
return JSON.stringify({ itag: audio.itag, mime: audio.mimeType, formats: formats.length, requests, total, firstAt, ms: Date.now() - t0, log, data: b64(all) });
"""#
}

private extension AVPlayer {
    /// Ждём до 6 с: готов ли элемент и идёт ли время.
    func waitResult() async -> String {
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let (status, time, error) = await MainActor.run { (currentItem?.status, currentTime().seconds, currentItem?.error) }
            if status == .failed {
                await MainActor.run { pause() }
                return "системный плеер не смог открыть: \(error?.localizedDescription ?? "?")"
            }
            if time > 1.5 {
                await MainActor.run { pause() }
                return "РАБОТАЕТ — системный плеер играет звук, полученный по SABR (\(String(format: "%.1f", time)) с)"
            }
        }
        let time = await MainActor.run { () -> Double in pause(); return currentTime().seconds }
        return "звук получен, но системный плеер не играет (время \(String(format: "%.1f", time)) с)"
    }
}
