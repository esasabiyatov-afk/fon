import UIKit
import WebKit
import AVFoundation

/// Главный экран: лента YouTube, нижние вкладки и плеер поверх.
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UITabBarDelegate {
    private enum PlayerState { case hidden, mini, expanded }

    private var browseView: WKWebView!
    private let tabBar = UITabBar()
    private let playerView = PlayerView()
    private var playerState: PlayerState = .hidden
    private var urlObservation: NSKeyValueObservation?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private let base = "https://m.youtube.com"
    private let tabs: [(title: String, icon: String, path: String?)] = [
        ("Главная", "house", "/"),
        ("Поиск", "magnifyingglass", nil),
        ("Подписки", "play.rectangle.on.rectangle", "/feed/subscriptions"),
        ("Вы", "person.crop.circle", "/feed/library")
    ]

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Лента
        browseView = WebViewFactory.make(scripts: [Scripts.common, Scripts.browse], handler: self)
        browseView.navigationDelegate = self
        browseView.uiDelegate = self
        browseView.allowsBackForwardNavigationGestures = true
        browseView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browseView)

        urlObservation = browseView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.browseURLChanged(webView.url) }
        }

        // Вкладки
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(white: 0.06, alpha: 1)
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .white
        tabBar.unselectedItemTintColor = UIColor(white: 0.6, alpha: 1)
        tabBar.items = tabs.enumerated().map { index, tab in
            UITabBarItem(title: tab.title, image: UIImage(systemName: tab.icon), tag: index)
        }
        tabBar.selectedItem = tabBar.items?.first
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        NSLayoutConstraint.activate([
            browseView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            browseView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browseView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browseView.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Плеер
        playerView.isHidden = true
        view.addSubview(playerView)
        playerView.onExpand = { [weak self] in self?.setPlayerState(.expanded) }
        playerView.onCollapse = { [weak self] in self?.setPlayerState(.mini) }
        playerView.onClose = { [weak self] in self?.setPlayerState(.hidden) }
        playerView.onOpenInBrowse = { [weak self] url in
            self?.browseView.load(URLRequest(url: url))
            self?.setPlayerState(.mini)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)

        loadBrowse(path: "/")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayer()
    }

    // MARK: - Плеер

    private func openInPlayer(_ url: URL) {
        let id = PlayerView.videoID(from: url)
        if id == nil || id != playerView.currentVideoID || playerState == .hidden {
            playerView.load(url)
        }
        setPlayerState(.expanded)
    }

    private func setPlayerState(_ state: PlayerState) {
        playerState = state
        switch state {
        case .hidden: break
        case .mini: playerView.setMode(.mini)
        case .expanded: playerView.setMode(.expanded)
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.layoutPlayer()
            self.playerView.layoutIfNeeded()
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func layoutPlayer() {
        let bounds = view.bounds
        switch playerState {
        case .hidden:
            playerView.isHidden = true
            setBrowseBottomInset(0)
        case .mini:
            playerView.isHidden = false
            let h = PlayerView.miniHeight
            playerView.frame = CGRect(x: 0, y: tabBar.frame.minY - h, width: bounds.width, height: h)
            setBrowseBottomInset(h)
        case .expanded:
            playerView.isHidden = false
            playerView.frame = bounds
            setBrowseBottomInset(PlayerView.miniHeight)
        }
    }

    /// Чтобы мини-плеер не закрывал низ ленты.
    private func setBrowseBottomInset(_ inset: CGFloat) {
        guard let scroll = browseView?.scrollView, scroll.contentInset.bottom != inset else { return }
        scroll.contentInset.bottom = inset
        scroll.verticalScrollIndicatorInsets.bottom = inset
    }

    // MARK: - Лента

    private func loadBrowse(path: String) {
        guard let url = URL(string: base + path) else { return }
        browseView.load(URLRequest(url: url))
    }

    private func search(_ query: String) {
        var components = URLComponents(string: base + "/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        if let url = components.url { browseView.load(URLRequest(url: url)) }
        if playerState == .expanded { setPlayerState(.mini) }
    }

    /// Запасной путь: если лента сама перешла на страницу видео — забираем её в плеер.
    private func browseURLChanged(_ url: URL?) {
        guard let url, WebViewFactory.isYouTube(url), url.path == "/watch" else { return }
        openInPlayer(url)
        if browseView.canGoBack { browseView.goBack() } else { loadBrowse(path: "/") }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        let tab = tabs[item.tag]
        if let path = tab.path {
            loadBrowse(path: path)
            if playerState == .expanded { setPlayerState(.mini) }
        } else {
            let searchVC = SearchViewController()
            searchVC.onSearch = { [weak self] query in self?.search(query) }
            searchVC.modalPresentationStyle = .overFullScreen
            searchVC.modalTransitionStyle = .crossDissolve
            present(searchVC, animated: true)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s) { openInPlayer(url) }
        case "browsePlaying":
            playerView.command("pause")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(WebViewFactory.policy(for: navigationAction))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url { webView.load(URLRequest(url: url)) } else { loadBrowse(path: "/") }
    }

    // MARK: - Фон и прерывания

    @objc private func didEnterBackground() {
        try? AVAudioSession.sharedInstance().setActive(true)
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
        playerView.kickResume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.endBackgroundTask() }
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Звонок, будильник, Siri: после них продолжаем, если iOS разрешает.
    @objc private func audioInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
            try? AVAudioSession.sharedInstance().setActive(true)
            playerView.command("play")
        }
    }
}
