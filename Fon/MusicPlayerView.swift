import UIKit

/// Плеер в стиле музыкальных сервисов: большая обложка, фон под её цвет, лайк, плейлисты.
/// Сам звук играет веб-плеер YouTube, который лежит под этим экраном.
final class MusicPlayerView: UIView {
    var onCommand: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onCollapse: (() -> Void)?
    var onShowQueue: (() -> Void)?
    var onVideoMode: (() -> Void)?
    var onAddToPlaylist: ((Track) -> Void)?

    private(set) var track: Track?
    var sourceName: String = "YouTube" { didSet { sourceLabel.text = sourceName } }

    private let gradient = CAGradientLayer()
    private let collapseButton = UIButton(type: .system)
    private let headerLabel = UILabel()
    private let sourceLabel = UILabel()
    private let queueButton = UIButton(type: .system)
    private let videoButton = UIButton(type: .system)
    private let artworkContainer = UIView()
    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let likeButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let prevButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let loopButton = UIButton(type: .system)

    private var paused = true
    private var looping = false
    private var duration: Double = 0
    private var time: Double = 0
    private var stamp = CACurrentMediaTime()
    private var scrubbing = false
    private var ticker: Timer?
    private let panelHeight: CGFloat = 206

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
        addSubview(artworkContainer)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        artistLabel.font = .systemFont(ofSize: 16)
        artistLabel.textColor = UIColor(white: 1, alpha: 0.65)
        addSubview(titleLabel)
        addSubview(artistLabel)
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

        setup(addButton, "plus.circle", 22, #selector(addTapped))
        setup(prevButton, "backward.fill", 28, #selector(prevTapped))
        setup(playButton, "play.fill", 30, #selector(playTapped))
        setup(nextButton, "forward.fill", 28, #selector(nextTapped))
        setup(loopButton, "repeat.1", 20, #selector(loopTapped))
        addButton.accessibilityLabel = "Добавить в плейлист"
        loopButton.accessibilityLabel = "Повтор трека"
        playButton.backgroundColor = .white
        playButton.tintColor = .black
        updateButtons()
        showTimes(0)

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        NotificationCenter.default.addObserver(self, selector: #selector(updateLike), name: Library.didChange, object: nil)
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
        if let id { loadArtwork(id) } else { artworkView.image = nil }
        updateLike()
    }

    func update(id: String, title: String, artist: String, paused: Bool, time: Double, duration: Double, loop: Bool) {
        let isNew = track?.id != id
        track = Track(id: id, title: title, artist: artist)
        if isNew { loadArtwork(id) }
        if titleLabel.text != title { titleLabel.text = title }
        if artistLabel.text != artist { artistLabel.text = artist }
        self.time = time
        self.duration = duration
        stamp = CACurrentMediaTime()
        slider.maximumValue = Float(max(duration, 1))
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

    private func loadArtwork(_ id: String) {
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.contentMode = .center
        ArtworkLoader.shared.load(id, size: .large) { [weak self] image, color in
            guard let self, self.track == nil || self.track?.id == id else { return }
            if let image {
                UIView.transition(with: self.artworkView, duration: 0.3, options: .transitionCrossDissolve) {
                    self.artworkView.contentMode = .scaleAspectFill
                    self.artworkView.image = image
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
        let liked = track.map { Library.shared.isLiked($0.id) } ?? false
        setSymbol(likeButton, liked ? "heart.fill" : "heart", 22)
        likeButton.tintColor = liked ? PlayerView.accent : .white
        likeButton.isEnabled = track != nil
        addButton.isEnabled = track != nil
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

    /// Вертикальный свайп по ползунку не должен сворачивать плеер.
    func blocksDrag(at point: CGPoint) -> Bool {
        slider.frame.insetBy(dx: -8, dy: -16).contains(point)
    }

    // MARK: - Кнопки

    @objc private func collapseTapped() { onCollapse?() }
    @objc private func queueTapped() { onShowQueue?() }
    @objc private func videoTapped() { onVideoMode?() }
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
        Library.shared.toggleLike(track)
        UIView.animate(withDuration: 0.12, animations: { self.likeButton.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }) { _ in
            UIView.animate(withDuration: 0.2) { self.likeButton.transform = .identity }
        }
    }

    @objc private func addTapped() {
        if let track { onAddToPlaylist?(track) }
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
        let contentBottom = h - max(safe.bottom, 16) - 12

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
        artworkContainer.bounds = CGRect(x: 0, y: 0, width: art, height: art)
        artworkContainer.center = artCenter
        artworkView.frame = artworkContainer.bounds
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
        addButton.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        addButton.center = CGPoint(x: x + 18, y: cy)
        loopButton.bounds = addButton.bounds
        loopButton.center = CGPoint(x: x + width - 18, y: cy)
    }
}
