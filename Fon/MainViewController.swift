import UIKit
import WebKit
import AVFoundation

/// Главный экран: лента YouTube, нижние вкладки и плеер поверх.
/// У каждой вкладки своё окно WKWebView, как в приложении YouTube: при переключении
/// страница не перезагружается, а остаётся там же, где её оставили.
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private enum PlayerState { case hidden, mini, expanded }

    private enum TabKind {
        /// Путь в режиме видео и в режиме музыки; nil в режиме музыки — нативная медиатека.
        case web(video: String, music: String?)
        case search
        case mode // переключатель «Видео / Музыка»
    }

    private enum TabContent { case web(String), library, none }

    private let browseContainer = UIView()
    private var browseViews: [Int: WKWebView] = [:]
    private var browseRoots: [Int: String] = [:] // какой корневой путь загружен во вкладке
    private var urlObservations: [Int: NSKeyValueObservation] = [:]
    private var libraryNav: UINavigationController?
    private var currentTab = 0
    private var browseBottomInset: CGFloat = 0

    private lazy var tabBar = TabBarView(items: tabs.map { (title: $0.title, icon: $0.icon) })
    private let playerView = PlayerView()
    private var playerState: PlayerState = .hidden
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private let base = "https://m.youtube.com"
    /// Главная в режиме музыки — обычные рекомендации, но с фильтром «Музыка» (его включает скрипт ленты).
    private let tabs: [(title: String, icon: String, kind: TabKind)] = [
        ("Главная", "house", .web(video: "/", music: "/#fon-music")),
        ("Поиск", "magnifyingglass", .search),
        ("Подписки", "play.rectangle.on.rectangle", .web(video: "/feed/subscriptions", music: "/feed/subscriptions")),
        ("Вы", "person.crop.circle", .web(video: "/feed/library", music: nil)),
        ("Режим", "music.note", .mode)
    ]
    private let libraryTabIndex = 3
    private var modeTabIndex: Int { tabs.count - 1 }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { playerState == .expanded && playerView.isFullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { playerState == .expanded && playerView.isFullscreen }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        browseContainer.backgroundColor = .black
        browseContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browseContainer)

        // Вкладки
        tabBar.onSelect = { [weak self] index in self?.tabSelected(index) }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        updateModeTabs()

        NSLayoutConstraint.activate([
            browseContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            browseContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browseContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browseContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -TabBarView.contentHeight)
        ])

        // Плеер
        playerView.isHidden = true
        view.addSubview(playerView)
        playerView.onExpand = { [weak self] in self?.setPlayerState(.expanded) }
        playerView.onCollapse = { [weak self] in self?.setPlayerState(.mini) }
        playerView.onClose = { [weak self] in self?.setPlayerState(.hidden) }
        playerView.onOpenInBrowse = { [weak self] url in
            self?.webViewForLoading().load(URLRequest(url: url))
            self?.setPlayerState(.mini)
        }
        playerView.onMusicModeChanged = { [weak self] in self?.musicModeChanged() }
        playerView.onAddToPlaylist = { [weak self] track in self?.presentAddToPlaylist(track) }
        playerView.onFullscreenChanged = { [weak self] on in self?.fullscreenChanged(on) }
        playerView.onSearch = { [weak self] query in self?.presentSearch(prefill: query) }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioRouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)

        showTab(0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Signature.warnIfNeeded(from: self)
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

    /// Свой плейлист играем через временный плейлист YouTube (watch_videos):
    /// тогда «следующий», экран блокировки и автопереход работают как у обычного плейлиста.
    private func playTracks(_ tracks: [Track], from start: Int, shuffle: Bool, name: String) {
        guard tracks.indices.contains(start) else { return }
        var list = Array(tracks[start...]) + Array(tracks[..<start])
        if shuffle { list.shuffle() }
        var components = URLComponents(string: base + "/watch_videos")!
        components.queryItems = [URLQueryItem(name: "video_ids", value: list.prefix(50).map(\.id).joined(separator: ","))]
        guard let url = components.url else { return }
        playerView.load(url, source: name, queue: list.prefix(50).map(\.id))
        setPlayerState(.expanded)
    }

    private func presentAddToPlaylist(_ track: Track) {
        let style: UIAlertController.Style = traitCollection.userInterfaceIdiom == .pad ? .alert : .actionSheet
        let sheet = UIAlertController(title: "Добавить в плейлист", message: track.title, preferredStyle: style)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        for playlist in Library.shared.playlists {
            let source = TrackListSource.playlist(playlist.id)
            let has = Library.shared.contains(track.id, in: source)
            sheet.addAction(UIAlertAction(title: (has ? "✓ " : "") + playlist.name, style: .default) { [weak self] _ in
                let added = Library.shared.add(track, to: source)
                self?.view.showToast(added ? "Добавлено в «\(playlist.name)»" : "Уже есть в «\(playlist.name)»", at: center)
            })
        }
        sheet.addAction(UIAlertAction(title: "Новый плейлист…", style: .default) { [weak self] _ in
            guard let self else { return }
            LibraryViewController.askName(title: "Новый плейлист", initial: "", from: self) { name in
                let playlist = Library.shared.createPlaylist(named: name)
                Library.shared.add(track, to: .playlist(playlist.id))
                self.view.showToast("Добавлено в «\(playlist.name)»", at: center)
            }
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(sheet, animated: true)
    }

    private func setPlayerState(_ state: PlayerState) {
        playerState = state
        switch state {
        case .hidden: break
        case .mini: playerView.setMode(.mini)
        case .expanded: playerView.setMode(.expanded)
        }
        // Развёрнутый плеер закрывает вкладки, а мини-полоска никогда не должна закрывать их иконки.
        if state == .expanded { view.bringSubviewToFront(playerView) } else { view.bringSubviewToFront(tabBar) }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
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
            playerView.transform = .identity // мог остаться сдвиг от перетаскивания
            let h = PlayerView.miniHeight
            playerView.frame = CGRect(x: 0, y: tabBar.frame.minY - h, width: bounds.width, height: h)
            setBrowseBottomInset(h)
        case .expanded:
            playerView.isHidden = false
            playerView.frame = bounds
            setBrowseBottomInset(PlayerView.miniHeight)
        }
    }

    /// Свой полный экран: прячем статус-бар, на iPhone поворачиваем экран горизонтально.
    private func fullscreenChanged(_ on: Bool) {
        if on && playerState != .expanded { setPlayerState(.expanded) }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        guard traitCollection.userInterfaceIdiom == .phone, let scene = view.window?.windowScene else { return }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait)) { _ in }
    }

    /// Чтобы мини-плеер не закрывал низ ленты.
    private func setBrowseBottomInset(_ inset: CGFloat) {
        browseBottomInset = inset
        browseViews.values.forEach { applyBottomInset(to: $0) }
        libraryNav?.additionalSafeAreaInsets.bottom = inset
    }

    private func applyBottomInset(to webView: WKWebView) {
        let scroll = webView.scrollView
        guard scroll.contentInset.bottom != browseBottomInset else { return }
        scroll.contentInset.bottom = browseBottomInset
        scroll.verticalScrollIndicatorInsets.bottom = browseBottomInset
    }

    // MARK: - Вкладки

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
        browseContainer.insertSubview(webView, at: 0)
        urlObservations[index] = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.browseURLChanged(webView) }
        }
        browseViews[index] = webView
        applyBottomInset(to: webView)
        return webView
    }

    private func libraryController() -> UINavigationController {
        if let libraryNav { return libraryNav }
        let library = LibraryViewController()
        library.onPlay = { [weak self] tracks, start, shuffle, name in
            self?.playTracks(tracks, from: start, shuffle: shuffle, name: name)
        }
        let nav = UINavigationController(rootViewController: library)
        nav.navigationBar.prefersLargeTitles = true
        nav.navigationBar.tintColor = PlayerView.accent
        nav.overrideUserInterfaceStyle = .dark
        nav.view.backgroundColor = .black
        addChild(nav)
        nav.view.frame = browseContainer.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        browseContainer.addSubview(nav.view)
        nav.didMove(toParent: self)
        nav.additionalSafeAreaInsets.bottom = browseBottomInset
        libraryNav = nav
        return nav
    }

    private func content(for index: Int) -> TabContent {
        guard case let .web(video, music) = tabs[index].kind else { return .none }
        guard Settings.musicMode else { return .web(video) }
        if let music { return .web(music) }
        return .library
    }

    private func showTab(_ index: Int) {
        currentTab = index
        tabBar.select(index)
        switch content(for: index) {
        case .library:
            let nav = libraryController()
            nav.view.isHidden = false
            browseViews.values.forEach { $0.isHidden = true }
        case .web(let root):
            libraryNav?.view.isHidden = true
            let webView = browseView(for: index)
            browseViews.forEach { $0.value.isHidden = $0.key != index }
            if browseRoots[index] != root {
                load(path: root, in: webView)
                browseRoots[index] = root
            }
        case .none:
            break
        }
    }

    /// Куда грузить ссылку или поиск: в текущую вкладку, а если открыта медиатека — на главную.
    private func webViewForLoading() -> WKWebView {
        if case .web = content(for: currentTab) { return browseView(for: currentTab) }
        showTab(0)
        return browseView(for: 0)
    }

    private func load(path: String, in webView: WKWebView) {
        guard let url = URL(string: base + path) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Повторное нажатие на открытую вкладку: сначала наверх, потом к началу раздела.
    private func reselectTab(_ index: Int) {
        switch content(for: index) {
        case .library:
            libraryNav?.popToRootViewController(animated: true)
        case .web(let root):
            let webView = browseView(for: index)
            let scroll = webView.scrollView
            let top = -scroll.adjustedContentInset.top
            if scroll.contentOffset.y > top + 1 {
                scroll.setContentOffset(CGPoint(x: 0, y: top), animated: true)
            } else {
                load(path: root, in: webView)
            }
        case .none:
            break
        }
    }

    private func search(_ query: String) {
        var components = URLComponents(string: base + "/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        if let url = components.url { webViewForLoading().load(URLRequest(url: url)) }
        if playerState == .expanded { setPlayerState(.mini) }
    }

    /// Запасной путь: если лента сама перешла на страницу видео — забираем её в плеер.
    private func browseURLChanged(_ webView: WKWebView) {
        guard let url = webView.url, WebViewFactory.isYouTube(url), url.path == "/watch" else { return }
        openInPlayer(url)
        if webView.canGoBack {
            webView.goBack()
        } else if let index = browseViews.first(where: { $0.value === webView })?.key, case let .web(root) = content(for: index) {
            load(path: root, in: webView)
        }
    }

    private func tabSelected(_ index: Int) {
        switch tabs[index].kind {
        case .web:
            if index == currentTab { reselectTab(index) } else { showTab(index) }
            if playerState == .expanded { setPlayerState(.mini) }
        case .search:
            presentSearch(prefill: nil)
        case .mode:
            Settings.musicMode.toggle()
            playerView.musicModeDidChange()
            musicModeChanged()
            view.showToast(Settings.musicMode ? "Режим музыки" : "Режим видео",
                           at: CGPoint(x: view.bounds.midX, y: tabBar.frame.minY - (playerState == .hidden ? 40 : PlayerView.miniHeight + 40)))
        }
    }

    /// Свой поиск — и из вкладки, и из лупы в шапке страницы YouTube (её мы перехватываем).
    private func presentSearch(prefill: String?) {
        guard presentedViewController == nil else { return }
        let searchVC = SearchViewController()
        searchVC.initialText = prefill
        searchVC.onSearch = { [weak self] query in self?.search(query) }
        searchVC.modalPresentationStyle = .overFullScreen
        searchVC.modalTransitionStyle = .crossDissolve
        present(searchVC, animated: true)
    }

    /// Сменился режим (из вкладки или кнопкой в плеере): обновляем вкладки и открытый раздел.
    private func musicModeChanged() {
        updateModeTabs()
        showTab(currentTab) // остальные вкладки обновятся при следующем открытии
    }

    private func updateModeTabs() {
        let music = Settings.musicMode
        if music {
            tabBar.setItem(modeTabIndex, title: "Музыка", icon: "music.note", color: PlayerView.accent)
        } else {
            tabBar.setItem(modeTabIndex, title: "Видео", icon: "play.rectangle")
        }
        tabBar.setItem(libraryTabIndex, title: music ? "Медиатека" : "Вы", icon: music ? "square.stack.fill" : "person.crop.circle")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s) { openInPlayer(url) }
        case "browsePlaying":
            playerView.command("pause")
        case "search":
            presentSearch(prefill: body["query"] as? String)
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
        } else if let index = browseViews.first(where: { $0.value === webView })?.key, case let .web(root) = content(for: index) {
            load(path: root, in: webView)
        }
    }

    // MARK: - Фон и прерывания

    @objc private func didEnterBackground() {
        try? AVAudioSession.sharedInstance().setActive(true)
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.playerView.stopBackgroundWatch()
            self?.endBackgroundTask()
        }
        // Держим приложение, пока видео не заиграет (или до лимита iOS).
        playerView.watchBackgroundStart { [weak self] in self?.endBackgroundTask() }
    }

    @objc private func willEnterForeground() {
        playerView.stopBackgroundWatch()
        endBackgroundTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            Signature.warnIfNeeded(from: self)
        }
    }

    @objc private func audioRouteChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { self.playerView.markUserPaused() }
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
