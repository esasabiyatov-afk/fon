import UIKit
import WebKit

/// Скрытое окно с крошечной страницей YouTube (robots.txt — без тяжёлой вёрстки, тот же вход в Google,
/// что в приложении). Из него скрипт зовёт внутренний API YouTube. Запросы идут строго по одному:
/// иначе два одновременных «плейлиста ещё нет» создавали два плейлиста.
final class HiddenPage: NSObject, WKNavigationDelegate {
    /// m.youtube.com — облачные «Понравившиеся», лента подписок.
    static let youtube = HiddenPage(url: "https://m.youtube.com/robots.txt", script: Scripts.cloud)
    /// music.youtube.com — подборки и исполнители YouTube Music.
    static let music = HiddenPage(url: "https://music.youtube.com/robots.txt", script: Scripts.music)
    /// www.youtube.com как Safari на Mac — защитный токен (BotGuard) для потока системного плеера.
    static let desktop = HiddenPage(url: "https://www.youtube.com/robots.txt", script: Scripts.potoken,
                                    userAgent: YouTubeStreams.desktopUserAgent)

    private struct Job {
        let run: () -> Void
        let fail: (Error) -> Void
    }

    private let url: URL
    private let script: String
    private let userAgent: String?
    private var webView: WKWebView?
    private var ready = false
    private var loading = false
    private var pending: [Job] = []
    private var running = false

    private init(url: String, script: String, userAgent: String? = nil) {
        self.url = URL(string: url)!
        self.script = script
        self.userAgent = userAgent
    }

    func start(in view: UIView) {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView.customUserAgent = userAgent ?? WebViewFactory.safariUserAgent()
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        view.insertSubview(webView, at: 0)
        self.webView = webView
        load()
    }

    private func load() {
        guard let webView, !loading else { return }
        loading = true
        webView.load(URLRequest(url: url))
    }

    /// arguments считаются в момент запуска — так запрос из очереди видит результат предыдущего.
    func call(_ expression: String, _ arguments: @escaping () -> [String: Any],
              completion: @escaping (Result<Any, Error>) -> Void) {
        let job = Job(run: { [weak self] in
            guard let self, let webView = self.webView else { return }
            webView.callAsyncJavaScript(self.script + "\nreturn await " + expression,
                                        arguments: arguments(), in: nil, in: .page) { [weak self] result in
                completion(result)
                self?.running = false
                self?.runNext()
            }
        }, fail: { completion(.failure($0)) })
        pending.append(job)
        if !ready { load() } // страница не загрузилась (не было сети) — пробуем снова
        runNext()
    }

    private func runNext() {
        guard ready, !running, !pending.isEmpty else { return }
        running = true
        pending.removeFirst().run()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        ready = true
        runNext()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// Без страницы запросы не выполнить — сообщаем ожидающим об ошибке, следующий запрос загрузит её снова.
    private func loadFailed(_ error: Error) {
        loading = false
        guard !ready else { return }
        let failed = pending
        pending = []
        failed.forEach { $0.fail(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        loading = false
        load()
    }
}
