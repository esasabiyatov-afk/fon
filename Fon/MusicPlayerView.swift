import UIKit
import AVFoundation
import AVKit

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
            attachVideo()
        }
    }
    /// Системный плеер всё равно качает файл 360p — его картинка показывается вместо обложки (просьба владельца),
    /// в том же месте и размере; пока кадра нет (поиск, только звук) — обложка.
    var videoPlayer: AVPlayer? {
        didSet {
            attachVideo()
        }
    }

    private let gradient = CAGradientLayer()
    /// Фон как в Apple Music: размытая обложка (пока её нет — градиент под цвет).
    /// «Живой» фон: размытая обложка вращается, пятна её цветов плывут; при видео — цвета из кадров (`LiveBackdrop`).
    private let live = LiveBackdrop()
    /// Подложка под названием и кнопками — полупрозрачное размытие (как стеклянные карточки на референсах владельца).
    private let panelGlass = GlassPanel()
    /// AirPlay — в нижнем ряду, как в Apple Music.
    private let routeButton = AVRoutePickerView()
    private let collapseButton = UIButton(type: .system)
    private let headerLabel = UILabel()
    private let sourceLabel = UILabel()
    private let queueButton = UIButton(type: .system)
    private let videoButton = UIButton(type: .system)
    /// ↓ — скачать трек для прослушивания без интернета; зажать — весь микс по нему (просьба владельца после 1.83).
    private let downloadButton = UIButton(type: .system)
    private let artworkContainer = UIView()
    private let artworkSwipe = UIPanGestureRecognizer()
    private let upSwipe = UIPanGestureRecognizer()
    private let artworkView = UIImageView()
    private let videoView = UIView()
    private let videoLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?
    private var inBackground = false
    /// Ширина к высоте у текущей обложки (кадр 16:9; квадрат — только у картинки по ссылке).
    private var artworkAspect: CGFloat = 16.0 / 9
    /// Форма обложки и видео — своя у каждого (вертикальное, квадратное, 16:9; просьба владельца после 1.83: «оригинал»).
    private var imageAspect: CGFloat = 16.0 / 9
    private var videoAspect: CGFloat?
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
    private var scrubTouched = Date.distantPast
    private var ticker: Timer?
    private let panelHeight: CGFloat = 304

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        gradient.colors = [UIColor(white: 0.22, alpha: 1).cgColor, UIColor.black.cgColor]
        gradient.locations = [0, 0.9]
        layer.addSublayer(gradient)
        addSubview(live)
        addSubview(panelGlass)
        // Ореол обложки — цвета фона (меняется вместе с ним, в том числе по кадрам видео).
        live.onColors = { [weak self] colors in
            self?.setGlow(colors.first)
            self?.panelGlass.setTint(colors.first)
        }

        // Дизайн Apple Music (просьба владельца после 1.77): «язычок» сверху, обложка (у нас — видео 16:9),
        // название слева и ♡, ползунок, крупные ⏮ ▶ ⏭ без подложки, громкость, внизу — повтор, режим видео, AirPlay, очередь.
        setup(collapseButton, "chevron.compact.down", 26, #selector(collapseTapped))
        collapseButton.tintColor = UIColor(white: 1, alpha: 0.6)
        collapseButton.accessibilityLabel = "Свернуть"
        setup(queueButton, "list.bullet", 18, #selector(queueTapped))
        setup(videoButton, "play.rectangle", 18, #selector(videoTapped))
        queueButton.accessibilityLabel = "Очередь и похожие"
        videoButton.accessibilityLabel = "Режим видео"
        setup(downloadButton, "arrow.down.circle", 18, #selector(downloadTapped))
        downloadButton.menu = UIMenu(children: [
            UIAction(title: "Скачать трек", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in self?.downloadTapped() },
            UIAction(title: "Скачать микс по этому треку", image: UIImage(systemName: "square.stack")) { [weak self] _ in self?.downloadMix() }
        ])
        downloadButton.showsMenuAsPrimaryAction = false // нажатие — трек, долгое нажатие — меню
        NotificationCenter.default.addObserver(self, selector: #selector(updateDownload), name: OfflineStore.didChange, object: nil)

        headerLabel.text = "ИГРАЕТ ИЗ"
        headerLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = UIColor(white: 1, alpha: 0.7)
        headerLabel.textAlignment = .center
        headerLabel.isHidden = true
        sourceLabel.text = sourceName
        sourceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sourceLabel.textColor = UIColor(white: 1, alpha: 0.55)
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
        videoLayer.videoGravity = .resizeAspectFill // рамка — по форме кадра (applyAspect), так что без обрезки
        videoView.layer.addSublayer(videoLayer)
        artworkContainer.addSubview(videoView)
        // Нажатие на обложку или видео — переключает одно на другое (просьба владельца после 1.71).
        artworkContainer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(videoToggleTapped)))
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

        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        titleLabel.adjustsFontSizeToFitWidth = true // длинное название чуть уменьшается, а не обрезается сразу
        titleLabel.minimumScaleFactor = 0.7
        titleLabel.textColor = .white
        artistLabel.font = .systemFont(ofSize: 19)
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
        slider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        addSubview(slider)
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = UIColor(white: 1, alpha: 0.6)
            addSubview(label)
        }
        remainingLabel.textAlignment = .right

        setup(prevButton, "backward.fill", 32, #selector(prevTapped))
        setup(playButton, "play.fill", 44, #selector(playTapped))
        setup(nextButton, "forward.fill", 32, #selector(nextTapped))
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
        routeButton.tintColor = UIColor(white: 1, alpha: 0.7)
        routeButton.activeTintColor = PlayerView.accent
        routeButton.prioritizesVideoDevices = false
        addSubview(routeButton)
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
        if isNew { loadArtwork(id); updateDownload() }
        // Форма кадра нового трека становится известна не сразу — сверяем при каждом обновлении.
        if videoView.alpha == 1 { applyAspect(showingVideo: true) }
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
        // Фон догоняет видео по миниатюрам кадров YouTube (не трогая плеер), пока видео на месте обложки.
        if systemPlayer, videoView.alpha == 1 {
            live.follow(storyboard: NativeAudio.shared.storyboard(for: id), time: time, duration: duration)
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
        guard systemPlayer else { return } // у веб-плеера видео на месте обложки нет
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Settings.videoArtwork.toggle()
        attachVideo()
        if Settings.videoArtwork { NativeAudio.shared.videoWanted() } // скачанный трек — на поток с видео
    }

    private func updateVideoVisibility() {
        let show = videoLayer.player != nil && videoLayer.isReadyForDisplay
        applyAspect(showingVideo: show)
        guard (videoView.alpha == 1) != show else { return }
        if !show {
            // Видео убрали — фон снова по обложке.
            live.stopFollowing()
            if artworkView.contentMode == .scaleAspectFill, let image = artworkView.image { live.setImage(image) }
        }
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
                // Обложка в своей форме — без чёрных полей.
                let aspect = image.size.height > 0 ? min(2.2, max(0.45, image.size.width / image.size.height)) : 16.0 / 9
                UIView.transition(with: self.artworkView, duration: 0.3, options: .transitionCrossDissolve) {
                    self.artworkView.contentMode = .scaleAspectFill
                    self.artworkView.image = image
                }
                self.live.setImage(image)
                self.imageAspect = aspect
                self.applyAspect(showingVideo: self.videoView.alpha == 1)
            }
            if let color { self.setTint(color) }
        }
    }

    /// Рамка обложки — по форме того, что сейчас видно: видео (размер кадра у системного плеера) или картинки.
    private func applyAspect(showingVideo: Bool) {
        if showingVideo, let size = videoLayer.player?.currentItem?.presentationSize, size.width > 0, size.height > 0 {
            videoAspect = min(2.2, max(0.45, size.width / size.height))
        } else if !showingVideo {
            videoAspect = nil
        }
        let aspect = (showingVideo ? videoAspect : nil) ?? imageAspect
        guard abs(aspect - artworkAspect) > 0.01 else { return }
        artworkAspect = aspect
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    /// Светящийся ореол вокруг обложки/видео цветом картинки (вместо чёрной тени).
    private func setGlow(_ color: UIColor?) {
        let animation = CABasicAnimation(keyPath: "shadowColor")
        animation.fromValue = artworkContainer.layer.shadowColor
        animation.duration = 1.2
        artworkContainer.layer.add(animation, forKey: "glow")
        artworkContainer.layer.shadowColor = (color ?? .black).cgColor
        artworkContainer.layer.shadowOpacity = color == nil ? 0.5 : 0.8
        artworkContainer.layer.shadowRadius = color == nil ? 24 : 42
        artworkContainer.layer.shadowOffset = color == nil ? CGSize(width: 0, height: 12) : .zero
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
        setSymbol(playButton, paused ? "play.fill" : "pause.fill", 44)
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
        // Отпускание не пришло (касание отменила система) — через 4 с без движения ползунок снова идёт сам.
        if scrubbing, Date().timeIntervalSince(scrubTouched) > 4 { scrubbing = false }
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
        if slider.frame.insetBy(dx: -8, dy: -16).contains(point) || volumeSlider.frame.insetBy(dx: -8, dy: -16).contains(point) { return true }
        // iPad: по обложке вверх/вниз — смена трека, поэтому плеер оттуда не сворачивается (язычок ⌄ сверху).
        return isPad && artworkFrame.contains(point)
    }

    /// iPad: жесты по обложке другие (просьба владельца после 1.82): вверх — следующий, вниз — предыдущий, влево — «Далее».
    private var isPad: Bool { traitCollection.userInterfaceIdiom == .pad }
    private var artworkFrame: CGRect {
        let b = artworkContainer.bounds, c = artworkContainer.center
        return CGRect(x: c.x - b.width / 2, y: c.y - b.height / 2, width: b.width, height: b.height)
    }
    private var swipeVertical = false

    // MARK: - Кнопки

    @objc private func collapseTapped() { onCollapse?() }

    @objc private func downloadTapped() {
        guard let track else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch OfflineStore.shared.state(for: track.id) {
        case .downloaded: toast("Уже скачан — есть в «Скачанных»")
        case .waiting: toast("Уже качается")
        case .missing:
            OfflineStore.shared.download([track])
            toast("Скачиваю — появится в «Скачанных»")
        }
    }

    private func downloadMix() {
        guard let track else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        toast("Скачиваю микс…")
        OfflineStore.shared.downloadMix(seed: track.id) { [weak self] count in
            self?.toast(count > 0 ? "Микс: \(count) треков — появятся в «Скачанных»" : "Микс не загрузился")
        }
    }

    private func toast(_ text: String) {
        showToast(text, at: CGPoint(x: bounds.midX, y: bounds.height - safeAreaInsets.bottom - 120))
    }

    /// ↓ — не скачан, ⋯↓ — качается, ↓ закрашенная красная — скачан.
    @objc private func updateDownload() {
        let state = track.map { OfflineStore.shared.state(for: $0.id) } ?? OfflineStore.State.missing
        let symbol: String
        switch state {
        case .missing: symbol = "arrow.down.circle"
        case .waiting: symbol = "arrow.down.circle.dotted"
        case .downloaded: symbol = "arrow.down.circle.fill"
        }
        setSymbol(downloadButton, symbol, 18)
        downloadButton.tintColor = state == .downloaded ? PlayerView.accent : .white
        downloadButton.accessibilityLabel = state == .downloaded ? "Скачан" : "Скачать"
    }
    @objc private func queueTapped() { onShowUpNext?() } // «Далее» — и у обычного плеера YouTube (там же «Страница»)

    @objc private func handleUpSwipe(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        if pan.translation(in: self).y < -50 || pan.velocity(in: self).y < -600 { onShowUpNext?() }
    }
    @objc private func videoTapped() { onVideoMode?() }
    /// Свайп обложки — только горизонтальный; вертикальный вниз сворачивает плеер, вверх — «Далее».
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === upSwipe {
            let v = upSwipe.velocity(in: self)
            return !isPad && v.y < 0 && -v.y > abs(v.x) * 1.5 && !blocksDrag(at: upSwipe.location(in: self))
        }
        guard gestureRecognizer === artworkSwipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let v = artworkSwipe.velocity(in: self)
        if isPad {
            swipeVertical = abs(v.y) > abs(v.x)
            return swipeVertical ? abs(v.y) > abs(v.x) * 1.2 : (v.x < 0 && abs(v.x) > abs(v.y) * 1.2)
        }
        return abs(v.x) > abs(v.y) * 1.2
    }

    /// iPad: вверх/вниз — трек, влево — «Далее».
    private func handlePadSwipe(_ pan: UIPanGestureRecognizer) {
        let scale = paused ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
        let t = pan.translation(in: self), v = pan.velocity(in: self)
        let springBack = {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                self.artworkContainer.transform = scale
                self.artworkContainer.alpha = 1
            }
        }
        if !swipeVertical {
            switch pan.state {
            case .changed:
                artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: rubber(min(0, t.x)), y: 0))
            case .ended where t.x < -80 || v.x < -600:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                springBack()
                onShowUpNext?()
            case .ended, .cancelled, .failed:
                springBack()
            default:
                break
            }
            return
        }
        switch pan.state {
        case .changed:
            artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: 0, y: t.y))
            artworkContainer.alpha = 1 - min(0.5, abs(t.y) / bounds.height)
        case .ended where abs(t.y) > 80 || abs(v.y) > 600:
            let forward = (abs(v.y) > 600 ? v.y : t.y) < 0 // вверх — следующий
            let out = forward ? -bounds.height * 0.6 : bounds.height * 0.6
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onCommand?(forward ? "next" : "prev")
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn], animations: {
                self.artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: 0, y: out))
                self.artworkContainer.alpha = 0
            }) { _ in
                self.artworkContainer.transform = scale.concatenating(CGAffineTransform(translationX: 0, y: -out * 0.5))
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                    self.artworkContainer.transform = self.paused ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
                    self.artworkContainer.alpha = 1
                }
            }
        case .ended, .cancelled, .failed:
            springBack()
        default:
            break
        }
    }

    private func rubber(_ x: CGFloat) -> CGFloat {
        let limit: CGFloat = 160
        return x < 0 ? -limit * (1 - 1 / (-x / limit + 1)) : x
    }

    @objc private func handleArtworkSwipe(_ pan: UIPanGestureRecognizer) {
        if isPad { handlePadSwipe(pan); return }
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

    /// Перетаскивание — от касания (`touchDown`) до отпускания. Не по `isTracking`: на iOS 26 он у ползунка бывает
    /// false посреди перетаскивания, и раз в 0,25 с ползунок отпрыгивал к месту игры (запись экрана после 1.89).
    /// `valueChanged` без касания (на SDK iOS 26 его шлёт и программная установка значения) — не перетаскивание.
    @objc private func sliderBegan() {
        scrubbing = true
        scrubTouched = Date()
    }

    @objc private func sliderChanged() {
        guard scrubbing else { return }
        scrubTouched = Date()
        showTimes(Double(slider.value))
    }

    @objc private func sliderEnded() {
        guard scrubbing else { return }
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
        live.frame = bounds

        let side: CGFloat = w > 600 ? 40 : 24
        let top = safe.top
        // Сверху — «язычок» (свернуть) и откуда играет; кнопки очереди и режима видео — в нижнем ряду.
        collapseButton.frame = CGRect(x: w / 2 - 40, y: top, width: 80, height: 30)
        sourceLabel.frame = CGRect(x: 40, y: top + 28, width: max(0, w - 80), height: 16)
        let contentTop = top + 54
        let contentBottom = h - max(safe.bottom, 16) - 8

        let art: CGFloat
        let artCenter: CGPoint
        if w > h * 1.15 {
            // Альбомная ориентация: обложка слева, управление справа.
            art = max(120, min((contentBottom - contentTop) * artworkAspect, w * 0.42))
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
            art = max(120, min(pw, space * artworkAspect))
            artCenter = CGPoint(x: w / 2, y: contentTop + space / 2 + 4)
        }
        artworkContainer.bounds = CGRect(x: 0, y: 0, width: art, height: art / artworkAspect)
        artworkContainer.center = artCenter
        artworkView.frame = artworkContainer.bounds
        videoView.frame = artworkContainer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = videoView.bounds
        CATransaction.commit()
        artworkContainer.layer.shadowPath = UIBezierPath(roundedRect: artworkContainer.bounds, cornerRadius: 10).cgPath
    }

    private func layoutPanel(x: CGFloat, y: CGFloat, width: CGFloat) {
        panelGlass.frame = CGRect(x: x - 16, y: y - 14, width: width + 32, height: panelHeight + 18)
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
        prevButton.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        prevButton.center = CGPoint(x: cx - offset, y: cy)
        nextButton.bounds = prevButton.bounds
        nextButton.center = CGPoint(x: cx + offset, y: cy)
        let vy = y + 216
        volumeLow.frame = CGRect(x: x, y: vy, width: 20, height: 30)
        volumeHigh.frame = CGRect(x: x + width - 24, y: vy, width: 24, height: 30)
        volumeSlider.frame = CGRect(x: x + 28, y: vy, width: max(0, width - 60), height: 30)
        // Нижний ряд, как в Apple Music: повтор · режим видео · скачать · AirPlay · очередь («Далее»).
        let by = y + 282
        let row: [UIView] = [loopButton, videoButton, downloadButton, routeButton, queueButton]
        for (index, item) in row.enumerated() {
            item.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            item.center = CGPoint(x: x + width * (CGFloat(index) * 2 + 1) / CGFloat(row.count * 2), y: by)
        }
    }
}

extension MusicPlayerView: UIGestureRecognizerDelegate {}
