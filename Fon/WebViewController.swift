import UIKit
import WebKit
import AVFoundation

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let nowPlaying = NowPlayingController()
    private let homeURL = URL(string: "https://m.youtube.com/")!
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Сайты, которые открываются внутри приложения. Остальные ссылки уходят в Safari.
    private let internalHosts = ["youtube.com", "youtu.be", "google.com", "gstatic.com", "googleusercontent.com", "ytimg.com"]

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(source: BridgeScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        contentController.add(WeakScriptHandler(self), name: "fon")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.websiteDataStore = .default() // вход в аккаунт сохраняется между запусками

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent() // чтобы Google пускал войти в аккаунт
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        nowPlaying.onCommand = { [weak self] command, value in
            self?.send(command: command, value: value)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)

        webView.load(URLRequest(url: homeURL))
    }

    // MARK: - Сворачивание и возврат

    @objc private func willResignActive() {
        runJS("window.__fon && __fon.setBackground(true)")
    }

    @objc private func didEnterBackground() {
        try? AVAudioSession.sharedInstance().setActive(true)

        // Даём себе ~30 секунд, чтобы успеть снова запустить звук, если WebKit его остановил.
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runJS("window.__fon && __fon.resumeIfNeeded()")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.endBackgroundTask() }
    }

    @objc private func didBecomeActive() {
        runJS("window.__fon && __fon.setBackground(false)")
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Звонок, будильник, Siri: ставим на паузу, а после — продолжаем, если iOS разрешает.
    @objc private func audioInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            send(command: "pause", value: nil)
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                send(command: "play", value: nil)
            }
        @unknown default:
            break
        }
    }

    // MARK: - Связь с JavaScript

    private func send(command: String, value: Double?) {
        let arg = value.map { String($0) } ?? "undefined"
        runJS("window.__fon && __fon.cmd('\(command)', \(arg))")
    }

    private func runJS(_ code: String) {
        webView?.evaluateJavaScript("try { \(code) } catch (e) {} ; void 0", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "state" else { return }
        nowPlaying.update(from: body)
    }

    // MARK: - Навигация

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
            // youtube://, intent:// и т.п. — не уходим в официальное приложение
            return decisionHandler(.cancel)
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, navigationAction.navigationType == .linkActivated, let host = url.host?.lowercased(),
           !internalHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    /// Ссылки с target=_blank открываем в этом же окне.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// Если процесс страницы упал (бывает при нехватке памяти) — перезагружаем.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url { webView.load(URLRequest(url: url)) } else { webView.load(URLRequest(url: homeURL)) }
    }

    // MARK: - User-Agent как у Safari

    private static func safariUserAgent() -> String {
        let version = UIDevice.current.systemVersion
        let parts = version.split(separator: ".")
        let short = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : "\(parts.first ?? "17").0"
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(short) Mobile/15E148 Safari/604.1"
    }
}

/// Обёртка, чтобы WKUserContentController не держал контроллер в памяти вечно.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
