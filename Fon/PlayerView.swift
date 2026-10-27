import UIKit
import WebKit

/// Плеер: отдельное окно с видео. Бывает мини (полоска над вкладками) и развёрнутым (на весь экран).
/// В режиме музыки развёрнутый плеер — нативный экран `MusicPlayerView`, а веб-плеер играет под ним.
final class PlayerView: UIView, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    enum Mode { case mini, expanded }

    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenInBrowse: ((URL) -> Void)?
    var onMusicModeChanged: (() -> Void)?
    var onAddToPlaylist: ((Track) -> Void)?
    var onFullscreenChanged: ((Bool) -> Void)?
    var onSearch: ((String?) -> Void)?

    static let miniHeight: CGFloat = 64
    static let accent = UIColor(red: 1, green: 0.2, blue: 0.3, alpha: 1)

    private(set) var mode: Mode = .expanded
    /// Полноэкранное видео — наше собственное, а не системное: остаются субтитры и настройки YouTube.
    private(set) var isFullscreen = false
    /// В режиме музыки открыта страница YouTube (очередь, похожие) вместо нативного плеера.
    private var showingPage = false
    private var musicMode: Bool { Settings.musicMode }
    private var nativeMusic: Bool { mode == .expanded && musicMode && !showingPage && !isFullscreen }
    private(set) var currentVideoID: String?
    private var webView: WKWebView!
    private var urlObservation: NSKeyValueObservation?
    private let musicView = MusicPlayerView()
    private var queueIDs: Set<String>?

    // Мини-полоска
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let progressView = UIView()
    private let miniArtwork = UIImageView()
    private var miniArtworkID: String?
    private var progress: CGFloat = 0

    // Шапка развёрнутого плеера (режим видео или страница YouTube в режиме музыки)
    private let topBar = UIView()
    private let collapseButton = UIButton(type: .system)
    private let topTitleLabel = UILabel()
    private let musicButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private var miniGestures: [UIGestureRecognizer] = []
    private let dragGesture = UIPanGestureRecognizer()
    private var backgroundWatch: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.09, alpha: 1)
        clipsToBounds = true

        webView = WebViewFactory.make(scripts: [Scripts.common, Scripts.player], handler: self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(webView)

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.urlChanged(webView.url) }
        }

        // Мини-полоска
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = UIColor(white: 0.67, alpha: 1)
        let symbols = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: symbols), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: symbols), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        progressView.backgroundColor = Self.accent
        miniArtwork.contentMode = .scaleAspectFill
        miniArtwork.clipsToBounds = true
        miniArtwork.layer.cornerRadius = 6
        miniArtwork.backgroundColor = UIColor(white: 0.18, alpha: 1)
        [miniArtwork, titleLabel, subtitleLabel, playPauseButton, closeButton, progressView].forEach { addSubview($0) }

        // Нативный музыкальный плеер
        musicView.onCommand = { [weak self] name in self?.command(name) }
        musicView.onSeek = { [weak self] t in self?.runJS("window.__fon && __fon.cmd && __fon.cmd('seek', \(t))") }
        musicView.onCollapse = { [weak self] in self?.onCollapse?() }
        musicView.onShowQueue = { [weak self] in self?.setShowingPage(true) }
        musicView.onVideoMode = { [weak self] in self?.toggleMusicMode() }
        musicView.onAddToPlaylist = { [weak self] track in self?.onAddToPlaylist?(track) }
        addSubview(musicView)

        // Шапка развёрнутого плеера
        topBar.backgroundColor = .black
        collapseButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: symbols), for: .normal)
        collapseButton.tintColor = .white
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        topTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        topTitleLabel.textColor = .white
        topTitleLabel.textAlignment = .center
        musicButton.addTarget(self, action: #selector(musicTapped), for: .touchUpInside)
        pipButton.setImage(UIImage(systemName: "pip.enter", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        pipButton.tintColor = .white
        pipButton.accessibilityLabel = "Картинка в картинке"
        pipButton.addTarget(self, action: #selector(pipTapped), for: .touchUpInside)
        [collapseButton, pipButton, topTitleLabel, musicButton].forEach { topBar.addSubview($0) }
        addSubview(topBar)

        // Мини: нажатие или свайп вверх — развернуть.
        let tap = UITapGestureRecognizer(target: self, action: #selector(miniTapped))
        addGestureRecognizer(tap)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(miniTapped))
        swipeUp.direction = .up
        addGestureRecognizer(swipeUp)
        miniGestures = [tap, swipeUp]

        // Развёрнутый: тянем видео (или обложку) вниз — плеер едет за пальцем и сворачивается, как в YouTube.
        dragGesture.addTarget(self, action: #selector(handleDrag(_:)))
        dragGesture.delegate = self
        addGestureRecognizer(dragGesture)

        setMode(.expanded)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Управление

    /// source — откуда играем (название плейлиста); без него «Микс» или «YouTube».
    /// queue — id треков своего плейлиста: когда YouTube доиграет их и включит что-то своё,
    /// подпись «Играет из» сменится на «Похожие треки».
    func load(_ url: URL, source: String? = nil, queue: [String]? = nil) {
        queueIDs = queue.map { Set($0) }
        currentVideoID = Self.videoID(from: url)
        let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "list" }?.value
        musicView.sourceName = source ?? (list?.hasPrefix("RD") == true ? "Микс" : "YouTube")
        musicView.reset(id: currentVideoID)
        showingPage = false
        titleLabel.text = "Загрузка…"
        subtitleLabel.text = nil
        topTitleLabel.text = nil
        progress = 0
        if let id = currentVideoID { updateMiniArtwork(id) }
        updateVisibility()
        webView.load(URLRequest(url: url))
    }

    func stop() {
        runJS("window.__fon && __fon.cmd('pause')")
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        currentVideoID = nil
    }

    func setMode(_ newMode: Mode) {
        if newMode == .mini {
            if isFullscreen { exitFullscreen() }
            showingPage = false // при следующем открытии — снова нативный плеер
        }
        mode = newMode
        let isMini = newMode == .mini
        applyPageState()
        // Пока плеер разворачивается, страница не принимает нажатий: иначе тап по мини-полоске
        // (или второй тап) «проваливается» в страницу и открывает, например, описание видео.
        webView.isUserInteractionEnabled = false
        if !isMini {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.mode == .expanded else { return }
                self.webView.isUserInteractionEnabled = true
            }
        }
        miniGestures.forEach { $0.isEnabled = isMini } // в развёрнутом виде не мешаем нажатиям на странице
        updateVisibility()
        setNeedsLayout()
    }

    private func updateVisibility() {
        let isMini = mode == .mini
        [titleLabel, subtitleLabel, playPauseButton, closeButton, progressView].forEach { $0.isHidden = !isMini }
        miniArtwork.isHidden = !(isMini && musicMode)
        musicView.isHidden = !nativeMusic
        topBar.isHidden = isMini || nativeMusic || isFullscreen
        pipButton.isHidden = musicMode
        updateMusicButton()
    }

    /// Передаём странице текущий вид: мини или нет, режим музыки или видео.
    private func applyPageState() {
        runJS("window.__fon && __fon.setMini && __fon.setMini(\(mode == .mini))")
        runJS("window.__fon && __fon.setMusic && __fon.setMusic(\(musicMode))")
    }

    private func updateMusicButton() {
        let symbols = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        musicButton.setImage(UIImage(systemName: musicMode ? "music.note" : "play.rectangle", withConfiguration: symbols), for: .normal)
        musicButton.tintColor = musicMode ? Self.accent : .white
        musicButton.accessibilityLabel = musicMode ? "Вернуться к плееру" : "Режим видео"
    }

    @objc private func musicTapped() {
        if musicMode && showingPage {
            setShowingPage(false)
        } else {
            toggleMusicMode()
        }
    }

    private func toggleMusicMode() {
        Settings.musicMode.toggle()
        showingPage = false
        musicModeDidChange()
        onMusicModeChanged?()
        showToast(musicMode ? "Режим музыки" : "Режим видео", at: CGPoint(x: bounds.midX, y: safeAreaInsets.top + 90))
    }

    /// Режим сменили (здесь или во вкладке приложения) — обновляем экран и страницу.
    func musicModeDidChange() {
        UIView.transition(with: self, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.updateVisibility()
        }
        if let id = currentVideoID { updateMiniArtwork(id) }
        applyPageState()
        setNeedsLayout()
    }

    private func setShowingPage(_ on: Bool) {
        showingPage = on
        UIView.transition(with: self, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.updateVisibility()
        }
    }

    /// «Картинка в картинке». Вызов из приложения WebKit считает нажатием пользователя, поэтому PiP разрешён.
    @objc private func pipTapped() {
        command("pip")
    }

    func command(_ name: String) {
        runJS("window.__fon && __fon.cmd && __fon.cmd('\(name)')")
    }

    /// Приложение ушло в фон. Пока звук не пошёл (видео ещё грузится или WebKit поставил паузу),
    /// iOS усыпляет и приложение, и WebKit — видео так и не начнёт играть. Поэтому раз в секунду
    /// (до ~25 с, сколько iOS даёт фоновой задаче) зовём страницу: вызов будит WebKit, а страница
    /// помогает видео стартовать. Когда звук идёт, iOS уже не усыпляет приложение — done().
    func watchBackgroundStart(done: @escaping () -> Void) {
        stopBackgroundWatch()
        guard let url = webView.url, WebViewFactory.isYouTube(url) else { return done() }
        var tick = 0
        var playingTicks = 0
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.stopBackgroundWatch()
            done()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return finish() }
            tick += 1
            let js = "window.__fon && __fon.backgroundTick ? __fon.backgroundTick(\(tick == 1)) : 'none'"
            self.webView.evaluateJavaScript(js) { result, _ in
                let state = result as? String ?? "none"
                playingTicks = state == "playing" ? playingTicks + 1 : 0
                if playingTicks >= 2 || state == "idle" || tick >= 25 { finish() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundWatch = timer
    }

    func stopBackgroundWatch() {
        backgroundWatch?.invalidate()
        backgroundWatch = nil
    }

    /// Наушники отключили: это пауза, в фоне сами звук не включаем.
    func markUserPaused() {
        stopBackgroundWatch()
        runJS("window.__fon && __fon.markUserPaused && __fon.markUserPaused()")
    }

    // MARK: - Полный экран

    private func setFullscreen(_ on: Bool) {
        guard on != isFullscreen else { return }
        isFullscreen = on
        updateVisibility()
        setNeedsLayout()
        onFullscreenChanged?(on)
    }

    func exitFullscreen() {
        runJS("window.__fon && __fon.setFull && __fon.setFull(false)")
    }

    // MARK: - Перетаскивание вниз

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dragGesture else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard mode == .expanded else { return false }
        let v = dragGesture.velocity(in: self)
        guard v.y > 0, v.y > abs(v.x) * 1.5 else { return false }
        if isFullscreen { return true }
        let p = dragGesture.location(in: self)
        if nativeMusic { return !musicView.blocksDrag(at: convert(p, to: musicView)) }
        // На странице — только по самому видео (и шапке над ним), чтобы не мешать прокрутке.
        let videoHeight = min(bounds.width, bounds.height * 1.4) * 9 / 16
        return p.y < webView.frame.minY + videoHeight
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleDrag(_ pan: UIPanGestureRecognizer) {
        let ty = max(0, pan.translation(in: superview).y)
        let velocity = pan.velocity(in: superview).y

        if isFullscreen {
            if pan.state == .ended, ty > 80 || velocity > 800 { exitFullscreen() }
            return
        }

        switch pan.state {
        case .began:
            // Страница не должна прокручиваться вместе с плеером.
            webView.scrollView.panGestureRecognizer.isEnabled = false
            webView.scrollView.panGestureRecognizer.isEnabled = true
        case .changed:
            transform = CGAffineTransform(translationX: 0, y: ty)
            layer.cornerRadius = min(18, ty / 8)
        case .ended, .cancelled, .failed:
            if pan.state == .ended, ty > 140 || velocity > 900 {
                let current = frame
                transform = .identity
                layer.cornerRadius = 0
                frame = current
                onCollapse?()
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.transform = .identity
                    self.layer.cornerRadius = 0
                }
            }
        default:
            break
        }
    }

    // MARK: - Раскладка

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        musicView.frame = bounds
        switch mode {
        case .mini:
            let h = bounds.height
            let leftWidth: CGFloat
            if musicMode {
                // Обложка трека; маленький веб-плеер прячется под ней и продолжает играть.
                let side = h - 16
                miniArtwork.frame = CGRect(x: 8, y: 8, width: side, height: side)
                webView.frame = miniArtwork.frame
                leftWidth = 8 + side
            } else {
                let videoW = (h * 16 / 9).rounded()
                webView.frame = CGRect(x: 0, y: 0, width: videoW, height: h)
                leftWidth = videoW
            }
            let buttonW: CGFloat = 48
            closeButton.frame = CGRect(x: w - buttonW, y: 0, width: buttonW, height: h)
            playPauseButton.frame = CGRect(x: w - buttonW * 2, y: 0, width: buttonW, height: h)
            let textX = leftWidth + 12
            let textW = max(0, playPauseButton.frame.minX - textX - 4)
            titleLabel.frame = CGRect(x: textX, y: h / 2 - 19, width: textW, height: 20)
            subtitleLabel.frame = CGRect(x: textX, y: h / 2 + 1, width: textW, height: 18)
            progressView.frame = CGRect(x: 0, y: h - 2, width: w * progress, height: 2)
        case .expanded:
            if isFullscreen {
                webView.frame = bounds
                return
            }
            let top = safeAreaInsets.top
            topBar.frame = CGRect(x: 0, y: 0, width: w, height: top + 44)
            collapseButton.frame = CGRect(x: safeAreaInsets.left + 4, y: top, width: 48, height: 44)
            pipButton.frame = CGRect(x: w - safeAreaInsets.right - 100, y: top, width: 48, height: 44)
            musicButton.frame = CGRect(x: w - safeAreaInsets.right - 52, y: top, width: 48, height: 44)
            topTitleLabel.frame = CGRect(x: 104, y: top, width: max(0, w - 208), height: 44)
            webView.frame = CGRect(x: 0, y: topBar.frame.maxY, width: w, height: bounds.height - topBar.frame.maxY)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func updateMiniArtwork(_ id: String) {
        guard id != miniArtworkID else { return }
        miniArtworkID = id
        ArtworkLoader.shared.load(id, size: .small) { [weak self] image, _ in
            guard self?.miniArtworkID == id else { return }
            self?.miniArtwork.image = image
        }
    }

    // MARK: - Кнопки

    @objc private func togglePlay() { command("toggle") }

    @objc private func closeTapped() {
        stop()
        onClose?()
    }

    @objc private func miniTapped() {
        if mode == .mini { onExpand?() }
    }

    @objc private func collapseTapped() {
        if mode == .expanded { onCollapse?() }
    }

    // MARK: - JavaScript

    private func runJS(_ code: String) {
        webView?.evaluateJavaScript("try { \(code) } catch (e) {} ; void 0", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "state":
            guard body["active"] as? Bool == true else { return }
            let title = body["title"] as? String ?? ""
            let artist = body["artist"] as? String ?? ""
            let paused = body["paused"] as? Bool ?? true
            let time = (body["time"] as? NSNumber)?.doubleValue ?? 0
            let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
            titleLabel.text = title
            subtitleLabel.text = artist
            topTitleLabel.text = title
            let symbols = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            playPauseButton.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: symbols), for: .normal)
            progress = duration > 0 ? CGFloat(min(1, max(0, time / duration))) : 0
            if mode == .mini { progressView.frame.size.width = bounds.width * progress }
            if let id = body["id"] as? String {
                currentVideoID = id
                if let queue = queueIDs, !queue.contains(id) {
                    queueIDs = nil
                    musicView.sourceName = "Похожие треки"
                }
                updateMiniArtwork(id)
                musicView.update(id: id, title: title, artist: artist, paused: paused, time: time,
                                 duration: duration, loop: body["loop"] as? Bool ?? false)
            }
        case "search":
            onSearch?(body["query"] as? String)
        case "fullscreen":
            setFullscreen(body["on"] as? Bool == true)
        case "browse":
            if let s = body["url"] as? String, let url = URL(string: s) { onOpenInBrowse?(url) }
        default:
            break
        }
    }

    /// Если внутри плеера всё-таки открылась не страница видео — переносим её в основное окно.
    private func urlChanged(_ url: URL?) {
        guard let url, WebViewFactory.isYouTube(url) else { return }
        if url.path == "/watch" {
            currentVideoID = Self.videoID(from: url) ?? currentVideoID
            return
        }
        if url.path == "/watch_videos" { return } // свой плейлист: YouTube сейчас перенаправит на /watch
        onOpenInBrowse?(url)
        if webView.canGoBack { webView.goBack() }
    }

    static func videoID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(WebViewFactory.policy(for: navigationAction))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyPageState() // повторно применяем режимы после перезагрузки страницы
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onOpenInBrowse?(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url { webView.load(URLRequest(url: url)) }
    }
}

extension UIView {
    /// Короткая подсказка поверх экрана, сама исчезает.
    func showToast(_ text: String, at center: CGPoint) {
        let toast = UILabel()
        toast.text = "  \(text)  "
        toast.font = .systemFont(ofSize: 14, weight: .semibold)
        toast.textColor = .white
        toast.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        toast.layer.cornerRadius = 16
        toast.clipsToBounds = true
        toast.sizeToFit()
        toast.frame.size.height = 32
        toast.center = center
        addSubview(toast)
        UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { toast.alpha = 0 } completion: { _ in toast.removeFromSuperview() }
    }
}
