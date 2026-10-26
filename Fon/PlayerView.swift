import UIKit
import WebKit

/// Плеер: отдельное окно с видео. Бывает мини (полоска над вкладками) и развёрнутым (на весь экран).
final class PlayerView: UIView, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    enum Mode { case mini, expanded }

    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenInBrowse: ((URL) -> Void)?

    static let miniHeight: CGFloat = 64

    private(set) var mode: Mode = .expanded

    /// Режим музыки: самое низкое качество видео, вместо картинки — обложка. Запоминается.
    private(set) var musicMode: Bool = UserDefaults.standard.object(forKey: "musicMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(musicMode, forKey: "musicMode") }
    }
    private(set) var currentVideoID: String?
    private var webView: WKWebView!
    private var urlObservation: NSKeyValueObservation?

    // Мини-полоска
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let progressView = UIView()
    private var progress: CGFloat = 0

    // Шапка развёрнутого плеера
    private let topBar = UIView()
    private let collapseButton = UIButton(type: .system)
    private let topTitleLabel = UILabel()
    private let musicButton = UIButton(type: .system)
    private var miniGestures: [UIGestureRecognizer] = []

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
        progressView.backgroundColor = UIColor(red: 1, green: 0, blue: 0.2, alpha: 1)
        [titleLabel, subtitleLabel, playPauseButton, closeButton, progressView].forEach { addSubview($0) }

        // Шапка развёрнутого плеера
        topBar.backgroundColor = .black
        collapseButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: symbols), for: .normal)
        collapseButton.tintColor = .white
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        topTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        topTitleLabel.textColor = .white
        topTitleLabel.textAlignment = .center
        musicButton.addTarget(self, action: #selector(musicTapped), for: .touchUpInside)
        updateMusicButton()
        topBar.addSubview(collapseButton)
        topBar.addSubview(topTitleLabel)
        topBar.addSubview(musicButton)
        addSubview(topBar)

        // Жесты: нажатие или свайп вверх на мини — развернуть; свайп вниз по шапке — свернуть.
        let tap = UITapGestureRecognizer(target: self, action: #selector(miniTapped))
        addGestureRecognizer(tap)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(miniTapped))
        swipeUp.direction = .up
        addGestureRecognizer(swipeUp)
        miniGestures = [tap, swipeUp]
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(collapseTapped))
        swipeDown.direction = .down
        topBar.addGestureRecognizer(swipeDown)
        let tapTop = UITapGestureRecognizer(target: self, action: #selector(collapseTapped))
        topBar.addGestureRecognizer(tapTop)

        setMode(.expanded)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Управление

    func load(_ url: URL) {
        currentVideoID = Self.videoID(from: url)
        titleLabel.text = "Загрузка…"
        subtitleLabel.text = nil
        topTitleLabel.text = nil
        progress = 0
        webView.load(URLRequest(url: url))
    }

    func stop() {
        runJS("window.__fon && __fon.cmd('pause')")
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        currentVideoID = nil
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        let isMini = newMode == .mini
        applyPageState()
        webView.isUserInteractionEnabled = !isMini
        [titleLabel, subtitleLabel, playPauseButton, closeButton, progressView].forEach { $0.isHidden = !isMini }
        topBar.isHidden = isMini
        miniGestures.forEach { $0.isEnabled = isMini } // в развёрнутом виде не мешаем нажатиям на странице
        setNeedsLayout()
    }

    /// Передаём странице текущий вид: мини или нет, режим музыки или видео.
    private func applyPageState() {
        runJS("window.__fon && __fon.setMini && __fon.setMini(\(mode == .mini))")
        runJS("window.__fon && __fon.setMusic && __fon.setMusic(\(musicMode))")
    }

    private func updateMusicButton() {
        let symbols = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        musicButton.setImage(UIImage(systemName: musicMode ? "music.note" : "play.rectangle", withConfiguration: symbols), for: .normal)
        musicButton.tintColor = musicMode ? UIColor(red: 1, green: 0.2, blue: 0.3, alpha: 1) : .white
        musicButton.accessibilityLabel = musicMode ? "Режим музыки включён" : "Режим видео"
    }

    @objc private func musicTapped() {
        musicMode.toggle()
        updateMusicButton()
        applyPageState()
        let toast = UILabel()
        toast.text = musicMode ? "  Режим музыки: обложка, 144p  " : "  Режим видео  "
        toast.font = .systemFont(ofSize: 14, weight: .semibold)
        toast.textColor = .white
        toast.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        toast.layer.cornerRadius = 16
        toast.clipsToBounds = true
        toast.sizeToFit()
        toast.frame.size.height = 32
        toast.center = CGPoint(x: bounds.midX, y: topBar.frame.maxY + 40)
        addSubview(toast)
        UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { toast.alpha = 0 } completion: { _ in toast.removeFromSuperview() }
    }

    func command(_ name: String) {
        runJS("window.__fon && __fon.cmd && __fon.cmd('\(name)')")
    }

    /// После сворачивания приложения несколько раз пробуем продолжить, если WebKit поставил паузу.
    func kickResume() {
        for delay in [0.5, 1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runJS("window.__fon && __fon.resumeIfNeeded && __fon.resumeIfNeeded()")
            }
        }
    }

    // MARK: - Раскладка

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        switch mode {
        case .mini:
            let h = bounds.height
            let videoW = (h * 16 / 9).rounded()
            webView.frame = CGRect(x: 0, y: 0, width: videoW, height: h)
            let buttonW: CGFloat = 48
            closeButton.frame = CGRect(x: w - buttonW, y: 0, width: buttonW, height: h)
            playPauseButton.frame = CGRect(x: w - buttonW * 2, y: 0, width: buttonW, height: h)
            let textX = videoW + 12
            let textW = max(0, playPauseButton.frame.minX - textX - 4)
            titleLabel.frame = CGRect(x: textX, y: h / 2 - 19, width: textW, height: 20)
            subtitleLabel.frame = CGRect(x: textX, y: h / 2 + 1, width: textW, height: 18)
            progressView.frame = CGRect(x: 0, y: h - 2, width: w * progress, height: 2)
        case .expanded:
            let top = safeAreaInsets.top
            topBar.frame = CGRect(x: 0, y: 0, width: w, height: top + 44)
            collapseButton.frame = CGRect(x: 4, y: top, width: 48, height: 44)
            topTitleLabel.frame = CGRect(x: 56, y: top, width: w - 112, height: 44)
            musicButton.frame = CGRect(x: w - 52, y: top, width: 48, height: 44)
            webView.frame = CGRect(x: 0, y: topBar.frame.maxY, width: w, height: bounds.height - topBar.frame.maxY)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
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
            if let id = body["id"] as? String { currentVideoID = id }
            titleLabel.text = title
            subtitleLabel.text = artist
            topTitleLabel.text = title
            let symbols = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            playPauseButton.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: symbols), for: .normal)
            progress = duration > 0 ? CGFloat(min(1, max(0, time / duration))) : 0
            if mode == .mini { progressView.frame.size.width = bounds.width * progress }
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
