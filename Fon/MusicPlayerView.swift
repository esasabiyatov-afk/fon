import UIKit
import AVFoundation

/// Плеер в стиле музыкальных сервисов: большая обложка, фон под её цвет, лайк, плейлисты.
/// Сам звук играет веб-плеер YouTube, который лежит под этим экраном.
final class MusicPlayerView: UIView {
    var onCommand: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onCollapse: (() -> Void)?
    var onShowQueue: (() -> Void)?
    /// «Далее» системного плеера: другие версии трека и очередь (свайп вверх или кнопка списка).
    var onShowUpNext: (() -> Void)?
    var onVideoMode: (() -> Void)?
    /// Нажали на исполнителя — его музыка с канала.
    var onArtist: (() -> Void)?
    /// Своя громкость YouTube (0…1), отдельно от громкости телефона.
    var onVolume: ((Double) -> Void)?

    private(set) var track: Track?
    var sourceName: String = "YouTube" { didSet { sourceLabel.text = sourceName } }
    /// Играет системный плеер: кнопка списка открывает «Далее» (страница YouTube заиграла бы второй раз),
    /// и есть ползунок громкости — громкость работает только у системного плеера.
    var systemPlayer = false {
        didSet {
            [volumeSlider, volumeLow, volumeHigh].forEach { $0.isHidden = !systemPlayer }
            videoToggle.isHidden = !systemPlayer
            attachVideo()
        }
    }
    /// Системный плеер всё равно качает файл 360p — его картинка показывается вместо обложки (просьба владельца),
    /// в том же месте и размере; пока кадра нет (поиск, только звук) — обложка.
    var videoPlayer: AVPlayer? { didSet { attachVideo() } }

    private let gradient = CAGradientLayer()
    private let collapseButton = UIButton(type: .system)
    private let headerLabel = UILabel()
    private let sourceLabel = UILabel()
    private let queueButton = UIButton(type: .system)
    private let videoButton = UIButton(type: .system)
    private let artworkContainer = UIView()
    private let artworkSwipe = UIPanGestureRecognizer()
    private let upSwipe = UIPanGestureRecognizer()
    private let artworkView = UIImageView()
    private let videoView = UIView()
    private let videoLayer = AVPlayerLayer()
    /// Маленькая кнопка в углу обложки: видео ↔ просто обложка.
    private let videoToggle = UIButton(type: .system)
    private var readyObservation: NSKeyValueObservation?
    private var inBackground = false
    /// Ширина к высоте у текущей обложки: 1 — квадрат, 16/9 — кадр видео.
    private var artworkAspect: CGFloat = 1
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let likeButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let prevButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let loopButton = UIButton(type: .system)
    private let volumeSlider = UISlider()
    private let volumeLow = UIImageView(image: UIImage(systemName: "speaker.fill"))
    private let volumeHigh = UIImageView(image: UIImage(systemName: "speaker.wave.3.fill"))

    private var paused = true
    private var looping = false
    private var duration: Double = 0
    private var time: Double = 0
    private var stamp = CACurrentMediaTime()
    private var scrubbing = false
    private var ticker: Timer?
    private let panelHeight: CGFloat = 252

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        gradient.colors = [UIColor(white: 0.22, alpha: 1).cgColor, UIColor.black.cgColor]
        gradient.locations = [0, 0.9]
        layer.addSublayer(gradient)

        setup(collapseButton, "chevron.down", 20, #selector(collapseTapped))
        setup(queueButton, "list.bullet", 18, #selector(queueTapped))
        setup(videoButton, "play.rectangle", 18, #selector(videoTapped))
        queueButton.accessibilityLabel = "Очередь и похожие"
        videoButton.accessibilityLabel = "Режим видео"

        headerLabel.text = "ИГРАЕТ ИЗ"
        headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = UIColor(white: 1, alpha: 0.7)
        headerLabel.textAlignment = .center
        sourceLabel.text = sourceName
        sourceLabel.font = .systemFont(ofSize: 13, weight: .bold)
        sourceLabel.textColor = .white
        sourceLabel.textAlignment = .center
        addSubview(headerLabel)
        addSubview(sourceLabel)

        artworkContainer.layer.shadowColor = UIColor.black.cgColor
        artworkContainer.layer.shadowOpacity = 0.5
        artworkContainer.layer.shadowRadius = 24
        artworkContainer.layer.shadowOffset = CGSize(width: 0, height: 12)
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 10
        artworkView.backgroundColor = UIColor(white: 0.16, alpha: 1)
        artworkView.tintColor = UIColor(white: 0.4, alpha: 1)
        artworkContainer.addSubview(artworkView)
        videoView.clipsToBounds = true
        videoView.layer.cornerRadius = 10
        videoView.isUserInteractionEnabled = false
        videoView.alpha = 0
        videoLayer.videoGravity = .resizeAspectFill // как обложка: кадр 16:9 или квадрат альбома из середины
        videoView.layer.addSublayer(videoLayer)
        artworkContainer.addSubview(videoView)
        videoToggle.backgroundColor = UIColor(white: 0, alpha: 0.45)
        videoToggle.tintColor = .white
        videoToggle.layer.cornerRadius = 15
        videoToggle.addTarget(self, action: #selector(videoToggleTapped), for: .touchUpInside)
        videoToggle.isHidden = true
        artworkContainer.addSubview(videoToggle)
        updateVideoToggle()
        addSubview(artworkContainer)
        // Свайп обложки влево/вправо — следующий/предыдущий трек (просьба владельца после 1.69).
        artworkSwipe.addTarget(self, action: #selector(handleArtworkSwipe(_:)))
        artworkSwipe.delegate = self
        artworkContainer.addGestureRecognizer(artworkSwipe)
        // Свайп вверх — «Далее» (просьба владельца после 1.69).
        upSwipe.addTarget(self, action: #selector(handleUpSwipe(_:)))
        upSwipe.delegate = self
        addGestureRecognizer(upSwipe)
        readyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateVideoVisibility() }
        }
        // В фоне плеер с подключённой картинкой iOS ставит на паузу — на это время картинку отключаем.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = true
            self?.attachVideo()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = false
            self?.attachVideo()
        }

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.adjustsFontSizeToFitWidth = true // длинное название чуть уменьшается, а не обрезается сразу
        titleLabel.minimumScaleFactor = 0.7
        titleLabel.textColor = .white
        artistLabel.font = .systemFont(ofSize: 16)
        artistLabel.textColor = UIColor(white: 1, alpha: 0.65)
        addSubview(titleLabel)
        addSubview(artistLabel)
        artistLabel.isUserInteractionEnabled = true
        artistLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(artistTapped)))
        setup(likeButton, "heart", 22, #selector(likeTapped))

        let d: CGFloat = 13
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.25)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        addSubview(slider)
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = UIColor(white: 1, alpha: 0.6)
            addSubview(label)
        }
        remainingLabel.textAlignment = .right

        setup(prevButton, "backward.fill", 28, #selector(prevTapped))
        setup(playButton, "play.fill", 30, #selector(playTapped))
        setup(nextButton, "forward.fill", 28, #selector(nextTapped))
        setup(loopButton, "repeat.1", 20, #selector(loopTapped))
        loopButton.accessibilityLabel = "Повтор трека"
        // Громкость YouTube — отдельно от кнопок громкости телефона.
        let small: CGFloat = 9
        let knob = UIGraphicsImageRenderer(size: CGSize(width: small, height: small)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: small, height: small))
        }
        volumeSlider.setThumbImage(knob, for: .normal)
        volumeSlider.minimumTrackTintColor = UIColor(white: 1, alpha: 0.8)
        volumeSlider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.2)
        volumeSlider.value = Float(Settings.youtubeVolume)
        volumeSlider.accessibilityLabel = "Громкость YouTube"
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        for icon in [volumeLow, volumeHigh] {
            icon.tintColor = UIColor(white: 1, alpha: 0.6)
            icon.contentMode = .center
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            addSubview(icon)
        }
        addSubview(volumeSlider)
        [volumeSlider, volumeLow, volumeHigh].forEach { $0.isHidden = true } // до запуска системного плеера
        playButton.backgroundColor = .white
        playButton.tintColor = .black
        updateButtons()
        showTimes(0)

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        NotificationCenter.default.addObserver(self, selector: #selector(updateLike), name: CloudLikes.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { ticker?.invalidate() }

    private func setup(_ button: UIButton, _ symbol: String, _ size: CGFloat, _ action: Selector) {
        setSymbol(button, symbol, size)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func setSymbol(_ button: UIButton, _ symbol: String, _ size: CGFloat) {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    }

    // MARK: - Данные

    /// Новое видео начало грузиться: сбрасываем экран.
    func reset(id: String?) {
        track = nil
        titleLabel.text = "Загрузка…"
        artistLabel.text = nil
        time = 0
        duration = 0
        slider.value = 0
        showTimes(0)
        videoView.alpha = 0 // кадр прошлого трека не показываем
        if let id { loadArtwork(id) } else { artworkView.image = nil }
        updateLike()
    }

    func update(id: String, title rawTitle: String, artist rawArtist: String, paused: Bool, time: Double, duration: Double, loop: Bool) {
        let (title, artist) = TrackTitle.clean(title: rawTitle, artist: rawArtist)
        let isNew = track?.id != id
        track = Track(id: id, title: title, artist: artist)
        if isNew { loadArtwork(id) }
        if titleLabel.text != title { titleLabel.text = title }
        if artistLabel.text != artist { artistLabel.text = artist }
        self.time = time
        self.duration = duration
        stamp = CACurrentMediaTime()
        slider.maximumValue = Float(max(duration, 1))
        if duration <= 0 {
            // Новый трек ещё ищется: длины нет — ползунок в начало (иначе он оставался в конце от прошлого трека).
            slider.value = 0
            showTimes(0)
        }
        if paused != self.paused || loop != looping || isNew {
            let pauseChanged = paused != self.paused
            self.paused = paused
            looping = loop
            updateButtons()
            if pauseChanged { animateArtwork() }
            updateLike()
        }
        tick()
    }

    @objc private func artistTapped() {
        guard track != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onArtist?()
    }

    private func attachVideo() {
        let player = systemPlayer && !inBackground && Settings.videoArtwork ? videoPlayer : nil
        if videoLayer.player !== player { videoLayer.player = player }
        updateVideoVisibility()
    }

    @objc private func videoToggleTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Settings.videoArtwork.toggle()
        updateVideoToggle()
        attachVideo()
    }

    private func updateVideoToggle() {
        let symbol = Settings.videoArtwork ? "photo" : "play.rectangle"
        videoToggle.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        videoToggle.accessibilityLabel = Settings.videoArtwork ? "Показывать обложку" : "Показывать видео"
    }

    private func updateVideoVisibility() {
        let show = videoLayer.player != nil && videoLayer.isReadyForDisplay
        guard (videoView.alpha == 1) != show else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.videoView.alpha = show ? 1 : 0
        }
    }

    private func loadArtwork(_ id: String) {
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.contentMode = .center
        ArtworkLoader.shared.load(id, size: .player) { [weak self] image, color in
            guard let self, self.track == nil || self.track?.id == id else { return }
            if let image {
                // Обложка как есть: квадрат альбома или кадр видео 16:9 — без чёрных полей.
                let aspect = image.size.width > 0 ? min(2, max(1, image.size.width / image.size.height)) : 1
                UIView.transition(with: self.artworkView, duration: 0.3, options: .transitionCrossDissolve) {
                    self.artworkView.contentMode = .scaleAspectFill
                    self.artworkView.image = image
                }
                if aspect != self.artworkAspect {
                    self.artworkAspect = aspect
                    UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                        self.setNeedsLayout()
                        self.layoutIfNeeded()
                    }
                }
            }
            if let color { self.setTint(color) }
        }
    }

    /// Фон под цвет обложки, как в Spotify: сверху её цвет, книзу — чёрный.
    private func setTint(_ color: UIColor) {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let top = UIColor(hue: hue, saturation: min(1, sat * 1.15), brightness: min(0.5, max(0.22, bri)), alpha: 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        gradient.colors = [top.cgColor, UIColor.black.cgColor]
        CATransaction.commit()
    }

    private func updateButtons() {
        setSymbol(playButton, paused ? "play.fill" : "pause.fill", 30)
        loopButton.tintColor = looping ? PlayerView.accent : UIColor(white: 1, alpha: 0.7)
    }

    @objc private func updateLike() {
        let liked = track.map { CloudLikes.shared.isLiked($0.id) } ?? false
        setSymbol(likeButton, liked ? "heart.fill" : "heart", 22)
        likeButton.tintColor = liked ? PlayerView.accent : .white
        likeButton.isEnabled = track != nil
    }

    /// На паузе обложка чуть уменьшается — как в Apple Music.
    private func animateArtwork() {
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.artworkContainer.transform = self.paused ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
        }
    }

    /// Ползунок двигается плавно между сообщениями страницы (они приходят раз в секунду).
    private func tick() {
        guard !isHidden, window != nil, !scrubbing, duration > 0 else { return }
        let elapsed = paused ? 0 : CACurrentMediaTime() - stamp
        let t = min(duration, time + elapsed)
        slider.value = Float(t)
        showTimes(t)
    }

    private func showTimes(_ t: Double) {
        elapsedLabel.text = Self.format(t)
        remainingLabel.text = "-" + Self.format(max(0, duration - t))
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Вертикальный свайп по ползункам не должен сворачивать плеер.
    func blocksDrag(at point: CGPoint) -> Bool {
        slider.frame.insetBy(dx: -8, dy: -16).contains(point) || volumeSlider.frame.insetBy(dx: -8, dy: -16).contains(point)
    }

    // MARK: - Кнопки

    @objc private func collapseTapped() { onCollapse?() }
    @objc private func queueTapped() { systemPlayer ? onShowUpNext?() : onShowQueue?() }

    @objc private func handleUpSwipe(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        if pan.translation(in: self).y < -50 || pan.velocity(in: self).y < -600 { onShowUpNext?() }
    }
    @objc private func videoTapped() { onVideoMode?() }
    /// Свайп обложки — только горизонтальный; вертикальный вниз сворачивает плеер, вверх — «Далее».
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === upSwipe {
            let v = upSwipe.velocity(in: self)
            return systemPlayer && v.y < 0 && -v.y > abs(v.x) * 1.5 && !blocksDrag(at: upSwipe.location(in: self))
        }
        guard gestureRecognizer === artworkSwipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let v = artworkSwipe.velocity(in: self)
        return abs(v.x) > abs(v.y) * 1.2
    }

    @objc private func handleArtworkSwipe(_ pan: UIPanGestureRecognizer) {
        let scale = paused ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
        let tx = pan.translation(in: self).x
        let vx = pan.velocity(in: self).x
        switch pan.state {
        case .changed:
            artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: tx, y: 0))
            artworkContainer.alpha = 1 - min(0.5, abs(tx) / bounds.width)
        case .ended where abs(tx) > 80 || abs(vx) > 600:
            let forward = (abs(vx) > 600 ? vx : tx) < 0 // влево — следующий
            let out = forward ? -bounds.width : bounds.width
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onCommand?(forward ? "next" : "prev")
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn], animations: {
                self.artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: out, y: 0))
                self.artworkContainer.alpha = 0
            }) { _ in
                // Новая обложка въезжает с другой стороны.
                self.artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: -out * 0.5, y: 0))
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                    self.artworkContainer.transform = self.paused ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
                    self.artworkContainer.alpha = 1
                }
            }
        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                self.artworkContainer.transform = scale
                self.artworkContainer.alpha = 1
            }
        default:
            break
        }
    }

    @objc private func prevTapped() { onCommand?("prev") }
    @objc private func nextTapped() { onCommand?("next") }
    @objc private func loopTapped() { onCommand?("loop") }

    @objc private func playTapped() {
        paused.toggle() // сразу меняем иконку, страница подтвердит через секунду
        stamp = CACurrentMediaTime()
        updateButtons()
        animateArtwork()
        onCommand?("toggle")
    }

    @objc private func likeTapped() {
        guard let track else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        CloudLikes.shared.setLiked(track, !CloudLikes.shared.isLiked(track.id))
        UIView.animate(withDuration: 0.12, animations: { self.likeButton.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }) { _ in
            UIView.animate(withDuration: 0.2) { self.likeButton.transform = .identity }
        }
    }

    @objc private func volumeChanged() {
        Settings.youtubeVolume = Double(volumeSlider.value)
        onVolume?(Double(volumeSlider.value))
    }

    @objc private func sliderChanged() {
        scrubbing = true
        showTimes(Double(slider.value))
    }

    @objc private func sliderEnded() {
        let t = Double(slider.value)
        time = t
        stamp = CACurrentMediaTime()
        scrubbing = false
        onSeek?(t)
    }

    // MARK: - Раскладка

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let safe = safeAreaInsets
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()

        let side: CGFloat = w > 600 ? 40 : 24
        let top = safe.top
        collapseButton.frame = CGRect(x: safe.left + 8, y: top, width: 48, height: 44)
        videoButton.frame = CGRect(x: w - safe.right - 56, y: top, width: 48, height: 44)
        queueButton.frame = CGRect(x: w - safe.right - 100, y: top, width: 48, height: 44)
        headerLabel.frame = CGRect(x: 104, y: top + 5, width: max(0, w - 208), height: 14)
        sourceLabel.frame = CGRect(x: 104, y: top + 19, width: max(0, w - 208), height: 20)
        let contentTop = top + 56
        // Кнопки управления подняты повыше от нижнего края — так удобнее до них дотягиваться.
        let contentBottom = h - max(safe.bottom, 16) - (w > h * 1.15 ? 12 : 52)

        let art: CGFloat
        let artCenter: CGPoint
        if w > h * 1.15 {
            // Альбомная ориентация: обложка слева, управление справа.
            art = max(120, min(contentBottom - contentTop, w * 0.42))
            artCenter = CGPoint(x: safe.left + side + art / 2, y: (contentTop + contentBottom) / 2)
            let px = artCenter.x + art / 2 + side * 1.5
            let pw = min(520, w - px - side - safe.right)
            layoutPanel(x: px, y: (contentTop + contentBottom - panelHeight) / 2, width: pw)
        } else {
            let pw = min(560, w - side * 2)
            let px = (w - pw) / 2
            let py = contentBottom - panelHeight
            layoutPanel(x: px, y: py, width: pw)
            let space = py - contentTop - 24
            art = max(120, min(pw, space))
            artCenter = CGPoint(x: w / 2, y: contentTop + space / 2 + 4)
        }
        artworkContainer.bounds = CGRect(x: 0, y: 0, width: art, height: art / artworkAspect)
        artworkContainer.center = artCenter
        artworkView.frame = artworkContainer.bounds
        videoView.frame = artworkContainer.bounds
        videoToggle.frame = CGRect(x: artworkContainer.bounds.width - 38, y: artworkContainer.bounds.height - 38, width: 30, height: 30)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = videoView.bounds
        CATransaction.commit()
        artworkContainer.layer.shadowPath = UIBezierPath(roundedRect: artworkContainer.bounds, cornerRadius: 10).cgPath
    }

    private func layoutPanel(x: CGFloat, y: CGFloat, width: CGFloat) {
        titleLabel.frame = CGRect(x: x, y: y, width: width - 52, height: 28)
        artistLabel.frame = CGRect(x: x, y: y + 31, width: width - 52, height: 21)
        likeButton.frame = CGRect(x: x + width - 44, y: y + 4, width: 44, height: 44)
        slider.frame = CGRect(x: x, y: y + 66, width: width, height: 30)
        elapsedLabel.frame = CGRect(x: x, y: y + 96, width: 90, height: 16)
        remainingLabel.frame = CGRect(x: x + width - 90, y: y + 96, width: 90, height: 16)
        let cy = y + 166
        let cx = x + width / 2
        let offset = min(88, width * 0.27)
        playButton.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        playButton.center = CGPoint(x: cx, y: cy)
        playButton.layer.cornerRadius = 36
        prevButton.bounds = CGRect(x: 0, y: 0, width: 48, height: 56)
        prevButton.center = CGPoint(x: cx - offset, y: cy)
        nextButton.bounds = prevButton.bounds
        nextButton.center = CGPoint(x: cx + offset, y: cy)
        loopButton.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        loopButton.center = CGPoint(x: x + width - 18, y: cy)
        let vy = y + 222
        volumeLow.frame = CGRect(x: x, y: vy, width: 20, height: 30)
        volumeHigh.frame = CGRect(x: x + width - 24, y: vy, width: 24, height: 30)
        volumeSlider.frame = CGRect(x: x + 28, y: vy, width: max(0, width - 60), height: 30)
    }
}

extension MusicPlayerView: UIGestureRecognizerDelegate {}
