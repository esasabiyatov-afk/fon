import UIKit
import WebKit
import AVFoundation

/// Главный экран: лента YouTube, нижние вкладки и плеер поверх.
/// У каждой вкладки своё окно WKWebView, как в приложении YouTube: при переключении
/// страница не перезагружается, а остаётся там же, где её оставили.
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UITabBarDelegate {
    private enum PlayerState { case hidden, mini, expanded }

    private enum TabKind {
        case page(video: String, music: String) // путь в режиме видео и в режиме музыки
        case search
        case mode                               // переключатель «Видео / Музыка»
    }

    private let browseContainer = UIView()
    private var browseViews: [Int: WKWebView] = [:]
    private var browseRoots: [Int: String] = [:] // какой корневой путь загружен во вкладке
    private var urlObservations: [Int: NSKeyValueObservation] = [:]
    private var currentTab = 0
    private var browseBottomInset: CGFloat = 0

    private let tabBar = UITabBar()
    private let playerView = PlayerView()
    private var playerState: PlayerState = .hidden
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private let base = "https://m.youtube.com"
    /// Музыкальный раздел YouTube: подборки, чарты, плейлисты по настроению.
    private static let musicHome = "/channel/UC-9-kyTW8ZkZNDHQJ6FgpwQ"
    private let tabs: [(title: String, icon: String, kind: TabKind)] = [
        ("Главная", "house", .page(video: "/", music: MainViewController.musicHome)),
        ("Поиск", "magnifyingglass", .search),
        ("Подписки", "play.rectangle.on.rectangle", .page(video: "/feed/subscriptions", music: "/feed/subscriptions")),
        ("Вы", "person.crop.circle", .page(video: "/feed/library", music: "/feed/library")),
        ("Режим", "music.note", .mode)
    ]
    private var modeTabIndex: Int { tabs.count - 1 }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        browseContainer.backgroundColor = .black
        browseContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browseContainer)

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
        updateModeTab()

        NSLayoutConstraint.activate([
            browseContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            browseContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browseContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browseContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
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
            self?.currentBrowseView.load(URLRequest(url: url))
            self?.setPlayerState(.mini)
        }
        playerView.onMusicModeChanged = { [weak self] in self?.musicModeChanged() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)

        showTab(0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayer()
    }

    // MARK: - Плеер

    private func openInPlayer(_ url: URL) {
        let id = PlayerView.videoID(from: url)
        if id == nil || id != playerView.currentVideoID || playerState == .hidden {
            playerView.load(Self.withMix(url))
        }
        setPlayerState(.expanded)
    }

    /// В режиме музыки отдельный трек открываем вместе с его Mix-плейлистом (RD + id):
    /// YouTube сам подбирает похожую музыку, «следующий» идёт по этому списку.
    private static func withMix(_ url: URL) -> URL {
        guard Settings.musicMode,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = PlayerView.videoID(from: url) else { return url }
        var items = components.queryItems ?? []
        if items.contains(where: { $0.name == "list" }) { return url }
        items.append(URLQueryItem(name: "list", value: "RD" + id))
        components.queryItems = items
        return components.url ?? url
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
        browseBottomInset = inset
        browseViews.values.forEach { applyBottomInset(to: $0) }
    }

    private func applyBottomInset(to webView: WKWebView) {
        let scroll = webView.scrollView
        guard scroll.contentInset.bottom != browseBottomInset else { return }
        scroll.contentInset.bottom = browseBottomInset
        scroll.verticalScrollIndicatorInsets.bottom = browseBottomInset
    }

    // MARK: - Вкладки

    private var currentBrowseView: WKWebView { browseView(for: currentTab) }

    /// Окно вкладки создаётся при первом открытии и дальше живёт вместе со своей историей.
    private func browseView(for index: Int) -> WKWebView {
        if let existing = browseViews[index] { return existing }
        let webView = WebViewFactory.make(scripts: [Scripts.common, Scripts.browse], handler: self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.frame = browseContainer.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isHidden = true
        browseContainer.addSubview(webView)
        urlObservations[index] = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.browseURLChanged(webView) }
        }
        browseViews[index] = webView
        applyBottomInset(to: webView)
        return webView
    }

    private func rootPath(for index: Int) -> String? {
        guard case let .page(video, music) = tabs[index].kind else { return nil }
        return Settings.musicMode ? music : video
    }

    private func showTab(_ index: Int) {
        currentTab = index
        let webView = browseView(for: index)
        browseViews.forEach { $0.value.isHidden = $0.key != index }
        if let root = rootPath(for: index), browseRoots[index] != root {
            load(path: root, in: webView)
            browseRoots[index] = root
        }
    }

    private func load(path: String, in webView: WKWebView) {
        guard let url = URL(string: base + path) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Повторное нажатие на открытую вкладку: сначала наверх, потом к началу раздела.
    private func reselectTab(_ index: Int) {
        let webView = browseView(for: index)
        let scroll = webView.scrollView
        let top = -scroll.adjustedContentInset.top
        if scroll.contentOffset.y > top + 1 {
            scroll.setContentOffset(CGPoint(x: 0, y: top), animated: true)
        } else if let root = rootPath(for: index) {
            load(path: root, in: webView)
        }
    }

    private func search(_ query: String) {
        var components = URLComponents(string: base + "/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        if let url = components.url { currentBrowseView.load(URLRequest(url: url)) }
        if playerState == .expanded { setPlayerState(.mini) }
    }

    /// Запасной путь: если лента сама перешла на страницу видео — забираем её в плеер.
    private func browseURLChanged(_ webView: WKWebView) {
        guard let url = webView.url, WebViewFactory.isYouTube(url), url.path == "/watch" else { return }
        openInPlayer(url)
        if webView.canGoBack {
            webView.goBack()
        } else if let index = browseViews.first(where: { $0.value === webView })?.key, let root = rootPath(for: index) {
            load(path: root, in: webView)
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        let index = item.tag
        switch tabs[index].kind {
        case .page:
            if index == currentTab { reselectTab(index) } else { showTab(index) }
            if playerState == .expanded { setPlayerState(.mini) }
        case .search:
            tabBar.selectedItem = tabBar.items?[currentTab]
            let searchVC = SearchViewController()
            searchVC.onSearch = { [weak self] query in self?.search(query) }
            searchVC.modalPresentationStyle = .overFullScreen
            searchVC.modalTransitionStyle = .crossDissolve
            present(searchVC, animated: true)
        case .mode:
            tabBar.selectedItem = tabBar.items?[currentTab]
            Settings.musicMode.toggle()
            playerView.musicModeDidChange()
            musicModeChanged()
            view.showToast(Settings.musicMode ? "Режим музыки" : "Режим видео",
                           at: CGPoint(x: view.bounds.midX, y: tabBar.frame.minY - (playerState == .hidden ? 40 : PlayerView.miniHeight + 40)))
        }
    }

    /// Сменился режим (из вкладки или кнопкой ♪ в плеере): обновляем вкладку и главную.
    private func musicModeChanged() {
        updateModeTab()
        if currentTab == 0 {
            showTab(0)
        } else {
            browseRoots[0] = nil // главная перезагрузится при следующем открытии
        }
    }

    private func updateModeTab() {
        guard let item = tabBar.items?[modeTabIndex] else { return }
        if Settings.musicMode {
            item.title = "Музыка"
            let pink = UIColor(red: 1, green: 0.2, blue: 0.3, alpha: 1)
            item.image = UIImage(systemName: "music.note")?.withTintColor(pink, renderingMode: .alwaysOriginal)
        } else {
            item.title = "Видео"
            item.image = UIImage(systemName: "play.rectangle")
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
        if let url = webView.url {
            webView.load(URLRequest(url: url))
        } else if let index = browseViews.first(where: { $0.value === webView })?.key, let root = rootPath(for: index) {
            load(path: root, in: webView)
        }
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
