import AVKit
import MediaPlayer
import UIKit

/// Свой видеоплеер (SABR → `SabrVideoSession` → AVPlayer): системные кнопки iOS, полный экран, PiP; ⚙ — качество
/// и скорость (запоминаются); в фоне звук идёт дальше (картинка отцепляется, как у системного плеера музыки).
/// Открывается кнопкой в шапке плеера режима видео; закрыли — веб-плеер продолжает с того же места.
final class SabrVideoViewController: UIViewController, AVPlayerViewControllerDelegate {
    private let videoID: String
    private let startTime: Double
    private let videoTitle: String
    /// Где остановились; nil — не заиграло (веб-плеер продолжит как был).
    var onClose: ((Double?) -> Void)?
    /// Заиграло впервые — веб-страницу можно выгрузить.
    var onStarted: (() -> Void)?

    private let player = AVPlayer()
    private let playerController = AVPlayerViewController()
    private let topBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    private var qualities: [SabrVideoSession.Quality] = []
    private var audioTracks: [SabrVideoSession.AudioTrack] = []
    private var session: SabrVideoSession?
    private var loading: SabrVideoSession?
    private var pending: (time: Double, play: Bool)?
    private var seekTimer: Timer?
    private var startedOnce = false
    private var pipActive = false
    private var closed = false
    private var author = ""
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    init(videoID: String, title: String, startTime: Double) {
        self.videoID = videoID
        self.videoTitle = title
        self.startTime = startTime
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        player.defaultRate = Settings.sabrVideoSpeed
        player.allowsExternalPlayback = true
        playerController.player = player
        playerController.delegate = self
        playerController.allowsPictureInPicturePlayback = true
        playerController.canStartPictureInPictureAutomaticallyFromInline = false
        playerController.updatesNowPlayingInfoCenter = false // свой экран блокировки — переживает отцепление в фоне
        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)

        let symbols = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: symbols), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = tr("Закрыть")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        titleLabel.text = videoTitle
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        settingsButton.setImage(UIImage(systemName: "gearshape", withConfiguration: symbols), for: .normal)
        settingsButton.tintColor = .white
        settingsButton.accessibilityLabel = tr("Настройки")
        settingsButton.showsMenuAsPrimaryAction = true
        settingsButton.isEnabled = false
        [closeButton, titleLabel, settingsButton].forEach { topBar.addSubview($0) }
        view.addSubview(topBar)

        spinner.color = .white
        spinner.startAnimating()
        statusLabel.text = tr("Загрузка по SABR…")
        statusLabel.textColor = UIColor(white: 1, alpha: 0.7)
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        [spinner, statusLabel].forEach { view.addSubview($0) }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playbackChanged() }
        }
        // Перемотка ползунком плеера — экран блокировки узнаёт о ней здесь.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            self?.updateNowPlaying()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        try? AVAudioSession.sharedInstance().setActive(true)
        prepare()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.safeAreaInsets
        let w = view.bounds.width
        topBar.frame = CGRect(x: 0, y: 0, width: w, height: insets.top + 44)
        closeButton.frame = CGRect(x: insets.left + 4, y: insets.top, width: 48, height: 44)
        settingsButton.frame = CGRect(x: w - insets.right - 52, y: insets.top, width: 48, height: 44)
        titleLabel.frame = CGRect(x: insets.left + 56, y: insets.top, width: max(0, w - insets.left - insets.right - 112), height: 44)
        playerController.view.frame = CGRect(x: 0, y: topBar.frame.maxY, width: w, height: view.bounds.height - topBar.frame.maxY)
        spinner.center = CGPoint(x: playerController.view.frame.midX, y: playerController.view.frame.midY - 16)
        statusLabel.frame = CGRect(x: 24, y: spinner.frame.maxY + 12, width: w - 48, height: 60)
    }

    // MARK: - Загрузка

    private func prepare() {
        Task { @MainActor in
            guard await LocalHLSServer.shared.start() != nil else { return fail(tr("не запустился сервер внутри приложения")) }
            let info = await DirectStream.sabrSource(videoID)
            guard !closed else { return }
            guard let source = info.source else { return fail(info.reason ?? "нет SABR") }
            if let title = info.title, !title.isEmpty { titleLabel.text = title }
            author = info.author ?? ""
            qualities = SabrVideoSession.qualities(source)
            audioTracks = SabrVideoSession.audioTracks(source)
            guard let quality = SabrVideoSession.preferred(in: qualities) else { return fail(tr("нет видео H.264 (mp4)")) }
            self.source = source
            begin(quality, at: startTime, play: true)
        }
    }

    private var source: SabrEngine.Source?

    private func begin(_ quality: SabrVideoSession.Quality, at time: Double, play: Bool, audioTrack: String?? = nil) {
        guard let source else { return }
        let track = audioTrack ?? (loading ?? session)?.audioTrack
        loading?.close()
        let next = SabrVideoSession(source: source, quality: quality, audioTrack: track)
        loading = next
        showLoading(true)
        updateMenu()
        next.onReady = { [weak self, weak next] error in
            guard let self, let next, self.loading === next else { return }
            if let error { return self.loadFailed(error) }
            self.attach(next, at: time, play: play)
        }
        // Повисло — не ждём вечно.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self, weak next] in
            guard let self, let next, self.loading === next else { return }
            self.loadFailed(tr("слишком долго нет видео"))
        }
    }

    private func attach(_ next: SabrVideoSession, at time: Double, play: Bool) {
        guard let url = next.masterURL else { return loadFailed(tr("сервер внутри приложения остановился")) }
        loading = nil
        let old = session
        session = next
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        old?.close()
        restoreSubtitles(item)
        pending = (time, play)
        seekTimer?.invalidate()
        let started = Date()
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tryPendingSeek(since: started) }
        updateMenu()
    }

    /// Перемотка на нужное место, когда оно скачано (свой плейлист растёт по мере загрузки).
    private func tryPendingSeek(since started: Date) {
        guard let pending, let item = player.currentItem, let session else { return }
        if item.status == .failed {
            seekTimer?.invalidate()
            return loadFailed(item.error?.localizedDescription ?? tr("плеер iOS не открыл видео"))
        }
        if Date().timeIntervalSince(started) > 60 {
            seekTimer?.invalidate()
            return loadFailed(tr("слишком долго нет видео"))
        }
        guard item.status == .readyToPlay else { return }
        let end = item.seekableTimeRanges.last.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) } ?? 0
        let target = pending.time
        guard target < 1 || end >= target + 2 || session.isFinished else {
            statusLabel.text = tr("Загрузка по SABR…") + " \(Int(end)) / \(Int(target)) с"
            return
        }
        seekTimer?.invalidate()
        self.pending = nil
        let finish = { [weak self] in
            guard let self else { return }
            if pending.play { self.player.playImmediately(atRate: Settings.sabrVideoSpeed) }
            self.showLoading(false)
        }
        if target < 1 { return finish() }
        player.seek(to: CMTime(seconds: min(target, max(0, end - 1)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async { finish() }
        }
    }

    private func loadFailed(_ reason: String) {
        loading?.close()
        loading = nil
        if session != nil, player.currentItem?.status != .failed {
            // Сменить качество не вышло — играет прежнее.
            showLoading(false)
            updateMenu()
            let alert = UIAlertController(title: tr("Качество не сменилось"), message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
            return
        }
        fail(reason)
    }

    /// Не заиграло — причина с «Скопировать» и назад к обычному плееру.
    private func fail(_ reason: String) {
        guard !closed else { return }
        spinner.stopAnimating()
        let device = UIDevice.current
        let details = "\(reason)\n\n\(device.model), \(device.systemName) \(device.systemVersion)\n\(YouTubeSession.summary)"
        let alert = UIAlertController(title: tr("Свой плеер не запустился"), message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: tr("Скопировать"), style: .default) { [weak self] _ in
            UIPasteboard.general.string = details
            self?.close()
        })
        alert.addAction(UIAlertAction(title: tr("Обычный плеер"), style: .cancel) { [weak self] _ in self?.close() })
        present(alert, animated: true)
    }

    private func showLoading(_ on: Bool) {
        spinner.isHidden = !on
        statusLabel.isHidden = !on
        if on {
            spinner.startAnimating()
            statusLabel.text = tr("Загрузка по SABR…")
            view.bringSubviewToFront(spinner)
            view.bringSubviewToFront(statusLabel)
        } else {
            spinner.stopAnimating()
        }
    }

    // MARK: - Настройки

    private func updateMenu() {
        let current = (loading ?? session)?.quality
        settingsButton.isEnabled = !qualities.isEmpty
        let qualityItems = qualities.map { quality in
            UIAction(title: quality.label, state: quality == current ? .on : .off) { [weak self] _ in self?.choose(quality) }
        }
        let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        let speedItems = speeds.map { speed in
            UIAction(title: speed == 1 ? tr("Обычная") : String(format: "%g×", speed), state: speed == Settings.sabrVideoSpeed ? .on : .off) { [weak self] _ in
                self?.setSpeed(speed)
            }
        }
        let quality = UIMenu(title: tr("Качество") + (current.map { " · " + $0.label } ?? ""), image: UIImage(systemName: "sparkles.tv"), children: qualityItems)
        let speed = UIMenu(title: tr("Скорость") + " · " + (Settings.sabrVideoSpeed == 1 ? tr("Обычная") : String(format: "%g×", Settings.sabrVideoSpeed)),
                           image: UIImage(systemName: "speedometer"), children: speedItems)
        var menus = [quality, speed]
        if !audioTracks.isEmpty {
            // Оригинал по умолчанию; дубляж/автоперевод YouTube — по выбору (после 1.102: озвучка шла поверх оригинала).
            let chosen = (loading ?? session)?.audioTrack
            let items = audioTracks.map { track in
                let on = chosen == track.id || (chosen == nil && track.original)
                return UIAction(title: track.name + (track.original ? " · " + tr("оригинал") : ""), state: on ? .on : .off) { [weak self] _ in
                    self?.chooseAudio(track)
                }
            }
            menus.append(UIMenu(title: tr("Озвучка"), image: UIImage(systemName: "waveform"), children: items))
        }
        settingsButton.menu = UIMenu(children: menus)
    }

    private func choose(_ quality: SabrVideoSession.Quality) {
        Settings.sabrVideoHeight = quality.height
        guard quality != session?.quality || loading != nil else { return updateMenu() }
        let time = CMTimeGetSeconds(player.currentTime())
        begin(quality, at: time.isFinite ? time : 0, play: player.timeControlStatus != .paused)
    }

    private func chooseAudio(_ track: SabrVideoSession.AudioTrack) {
        let current = (loading ?? session)?.audioTrack
        guard current != track.id, !(current == nil && track.original), let quality = (loading ?? session)?.quality else { return }
        let time = CMTimeGetSeconds(player.currentTime())
        begin(quality, at: time.isFinite ? time : 0, play: player.timeControlStatus != .paused, audioTrack: .some(track.original ? nil : track.id))
    }

    private func setSpeed(_ speed: Float) {
        Settings.sabrVideoSpeed = speed
        player.defaultRate = speed
        if player.rate > 0 { player.rate = speed }
        updateMenu()
        updateNowPlaying()
    }

    // MARK: - Субтитры (выбор — системной кнопкой плеера, запоминается)

    private var restoringSubtitles = false

    private func restoreSubtitles(_ item: AVPlayerItem) {
        NotificationCenter.default.removeObserver(self, name: AVPlayerItem.mediaSelectionDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(subtitlesChanged(_:)), name: AVPlayerItem.mediaSelectionDidChangeNotification, object: item)
        guard let saved = Settings.sabrSubtitles else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            let option = saved.isEmpty ? nil : group.options.first { $0.extendedLanguageTag == saved || $0.locale?.identifier == saved }
            guard saved.isEmpty || option != nil else { return }
            restoringSubtitles = true
            item.select(option, in: group)
            restoringSubtitles = false
        }
    }

    @objc private func subtitlesChanged(_ note: Notification) {
        guard !restoringSubtitles, let item = note.object as? AVPlayerItem else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
            Settings.sabrSubtitles = option?.extendedLanguageTag ?? ""
        }
    }

    // MARK: - Фон, PiP, экран блокировки

    @objc private func didEnterBackground() {
        // Плеер с картинкой iOS в фоне ставит на паузу — отцепляем (звук идёт), кроме «картинки в картинке».
        if !pipActive { playerController.player = nil }
    }

    @objc private func willEnterForeground() {
        playerController.player = player
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { pipActive = true }
    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) { pipActive = false }
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    private func playbackChanged() {
        if player.timeControlStatus == .playing, !startedOnce {
            startedOnce = true
            setUpCommands()
            onStarted?()
        }
        updateNowPlaying()
    }

    private func setUpCommands() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: action)))
        }
        on(center.playCommand) { [weak self] _ in self?.player.play(); return .success }
        on(center.pauseCommand) { [weak self] _ in self?.player.pause(); return .success }
        on(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.player.timeControlStatus == .paused { self.player.play() } else { self.player.pause() }
            return .success
        }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600)) { _ in
                DispatchQueue.main.async { self.updateNowPlaying() }
            }
            return .success
        }
        ArtworkLoader.shared.load(videoID, size: .player) { [weak self] image, _ in
            guard let self, let image, !self.closed, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func updateNowPlaying() {
        guard startedOnce, !closed else { return }
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: titleLabel.text ?? videoTitle,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, CMTimeGetSeconds(player.currentTime())),
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .paused ? 0.0 : Double(Settings.sabrVideoSpeed),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let duration = player.currentItem?.duration, duration.isNumeric { info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration) }
        if let artwork = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
    }

    // MARK: - Закрыть

    @objc private func closeTapped() { close() }

    private func close() {
        guard !closed else { return }
        closed = true
        let time = CMTimeGetSeconds(player.currentTime())
        seekTimer?.invalidate()
        statusObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loading?.close()
        session?.close()
        commandTargets.forEach { $0.0.removeTarget($0.1) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self)
        let result: Double? = startedOnce && time.isFinite ? time : nil
        let callback = onClose
        (presentingViewController ?? self).dismiss(animated: true) { callback?(result) }
    }
}
