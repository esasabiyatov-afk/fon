import UIKit
import AVFoundation

/// Режим «Видео»: «Главная» и «Подписки» — свои плавные ленты, как в приложении YouTube (просьба владельца после 1.78:
/// «всё плавно и не грузит снова и снова»). Данные — внутренний API YouTube из скрытого окна (`__fonCloud.videoFeed`),
/// страница за страницей при прокрутке; загруженное держится в памяти — при переключении вкладок не грузится заново,
/// обновить — потянуть вниз. Видео играет обычный плеер YouTube (качество как в приложении).
/// iPhone — одна колонка во всю ширину, iPad — сетка (колонка на каждые ~360 pt).
final class VideoFeedViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    struct Video {
        let id: String
        let title: String
        let channel: String
        let channelID: String
        let avatar: URL?
        let meta: String
        let duration: String

        init?(_ dict: [String: Any]) {
            guard let id = dict["id"] as? String, let title = dict["title"] as? String, !title.isEmpty else { return nil }
            self.id = id
            self.title = title
            channel = dict["channel"] as? String ?? ""
            channelID = dict["channelId"] as? String ?? ""
            avatar = (dict["avatar"] as? String).flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
            meta = dict["meta"] as? String ?? ""
            duration = dict["duration"] as? String ?? ""
        }
    }

    var onPlay: ((URL) -> Void)?

    private let browseID: String
    private var videos: [Video] = []
    private var nextToken: String?
    private var loading = false
    private var message: String?
    private var collectionView: UICollectionView!
    /// Автовоспроизведение в ленте (как в приложении YouTube): верхняя целиком видимая карточка играет без звука.
    private let preview = InlinePreview()
    private var previewTimer: Timer?
    private var visibilityTimer: Timer?

    init(browseID: String, title: String) {
        self.browseID = browseID
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        collectionView.register(VideoCell.self, forCellWithReuseIdentifier: "video")
        collectionView.register(StatusCell.self, forCellWithReuseIdentifier: "status")
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)
        load(reset: true)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        // Ленту закрыли другой вкладкой или плеером (они не вызывают viewWillDisappear) — превью останавливаем; вернулись — снова.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.preview.isActive {
                if !self.canPreview { self.preview.stop() }
            } else if self.canPreview, !self.collectionView.isDragging, !self.collectionView.isDecelerating {
                self.updatePreview() // вернулись к ленте (свернули плеер, открыли вкладку)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    deinit { visibilityTimer?.invalidate() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        schedulePreview()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        preview.stop()
    }

    @objc private func appBackground() { preview.stop() }
    @objc private func appActive() { schedulePreview() }

    // MARK: - Автовоспроизведение

    /// Лента на экране: окно есть, ни она, ни её вкладка не спрятаны, плеер не развёрнут, Wi-Fi.
    private var canPreview: Bool {
        guard isViewLoaded, view.window != nil, UIApplication.shared.applicationState == .active,
              !PlayerView.coversContent, OfflineStore.shared.onWiFi else { return false }
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha < 0.01 { return false }
            current = v.superview
        }
        return true
    }

    private func schedulePreview(after delay: TimeInterval = 0.5) {
        previewTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.updatePreview() }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    /// Верхняя карточка, у которой превью видно целиком, — играет; остальные — нет.
    private func updatePreview() {
        guard canPreview, !collectionView.isDragging, !collectionView.isDecelerating else {
            if !canPreview { preview.stop() }
            return
        }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var best: (cell: VideoCell, index: Int, y: CGFloat, x: CGFloat)?
        for case let cell as VideoCell in collectionView.visibleCells {
            guard let path = collectionView.indexPath(for: cell), videos.indices.contains(path.item) else { continue }
            let frame = cell.previewHost.convert(cell.previewHost.bounds, to: collectionView)
            guard visible.insetBy(dx: -1, dy: -1).contains(frame) else { continue }
            if best == nil || frame.minY < best!.y - 1 || (abs(frame.minY - best!.y) <= 1 && frame.minX < best!.x) {
                best = (cell, path.item, frame.minY, frame.minX)
            }
        }
        if let best {
            preview.play(videos[best.index].id, in: best.cell.previewHost)
        } else {
            preview.stop()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Карточка с превью ушла из виду больше чем наполовину — стоп.
        guard preview.isActive, let host = preview.host else { return }
        let frame = host.convert(host.bounds, to: collectionView)
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        if frame.intersection(visible).height < frame.height / 2 { preview.stop() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { schedulePreview() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        schedulePreview()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        schedulePreview()
    }

    func scrollToTop() {
        collectionView?.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    @objc private func pullToRefresh() {
        load(reset: true) { [weak self] in self?.collectionView.refreshControl?.endRefreshing() }
    }

    // MARK: - Данные

    private func load(reset: Bool, completion: (() -> Void)? = nil) {
        guard !loading, reset || nextToken != nil else {
            completion?()
            return
        }
        loading = true
        if videos.isEmpty { message = "Загрузка…" }
        let browseID = browseID
        let token: Any = reset ? NSNull() : (nextToken.map { $0 as Any } ?? NSNull())
        HiddenPage.youtube.call("__fonCloud.videoFeed(browseId, token)", { ["browseId": browseID, "token": token] }) { [weak self] result in
            guard let self else { return }
            self.loading = false
            let before = self.videos.count
            switch result {
            case .success(let value):
                let dict = value as? [String: Any] ?? [:]
                let page = (dict["items"] as? [[String: Any]] ?? []).compactMap(Video.init)
                if reset {
                    self.videos = page
                } else {
                    let known = Set(self.videos.map(\.id))
                    self.videos += page.filter { !known.contains($0.id) }
                }
                self.nextToken = dict["next"] as? String
                self.message = self.videos.isEmpty ? "Здесь пока пусто.\nПотяните вниз, чтобы обновить." : nil
            case .failure(let error):
                let text = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
                if self.videos.isEmpty {
                    self.message = text.contains("signed-out")
                        ? "Войдите в аккаунт Google: «Вы» → «Войти»."
                        : "Лента не загрузилась.\nПотяните вниз, чтобы повторить."
                }
            }
            // Следующая страница — только новые карточки, уже показанные не перерисовываются (прокрутка не дёргается).
            if !reset, before > 0 {
                let added = (before..<self.videos.count).map { IndexPath(item: $0, section: 0) }
                if !added.isEmpty { UIView.performWithoutAnimation { self.collectionView.insertItems(at: added) } }
            } else {
                self.preview.stop()
                self.collectionView.reloadData()
            }
            self.schedulePreview(after: 0.8)
            completion?()
        }
    }

    // MARK: - Раскладка

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            let width = environment.container.effectiveContentSize.width
            if self?.videos.isEmpty ?? true {
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(200))
                return NSCollectionLayoutSection(group: .horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
            }
            // iPhone — во всю ширину без полей, как в приложении; iPad — сетка карточек со скруглением.
            let columns = max(1, Int(width / 360))
            let inset: CGFloat = columns == 1 ? 0 : 16
            let spacing: CGFloat = 16
            let itemWidth = (width - inset * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (itemWidth * 9 / 16).rounded() + VideoCell.textHeight
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                                                           repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = columns == 1 ? 8 : 20
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: inset, bottom: 24, trailing: inset)
            return section
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.collectionView.collectionViewLayout.invalidateLayout() })
    }

    // MARK: - UICollectionView

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        videos.isEmpty ? 1 : videos.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if videos.isEmpty {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "status", for: indexPath) as! StatusCell
            cell.label.text = message ?? "Загрузка…"
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "video", for: indexPath) as! VideoCell
        cell.configure(videos[indexPath.item], rounded: view.bounds.width >= 720)
        return cell
    }

    /// Обложки следующих карточек грузим заранее, пока их ещё не видно.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where videos.indices.contains(indexPath.item) {
            ArtworkLoader.shared.load(videos[indexPath.item].id, size: .large) { _, _ in }
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Подгружаем следующую страницу заранее — лента не «упирается» в конец.
        if !videos.isEmpty, indexPath.item >= videos.count - 6 { load(reset: false) }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? VideoCell, preview.host === cell.previewHost { preview.stop() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        preview.stop()
        guard videos.indices.contains(indexPath.item),
              let url = YouTubeLinks.watch(videos[indexPath.item].id) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onPlay?(url)
    }

    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        UIView.animate(withDuration: 0.12) { collectionView.cellForItem(at: indexPath)?.alpha = 0.6 }
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        UIView.animate(withDuration: 0.25) { collectionView.cellForItem(at: indexPath)?.alpha = 1 }
    }
}

/// Карточка видео, как в приложении YouTube: превью 16:9 с длительностью, ниже аватар канала, название в две строки
/// и «канал · просмотры · когда».
private final class VideoCell: UICollectionViewCell {
    static let textHeight: CGFloat = 84

    private let thumbnail = UIImageView()
    private let durationLabel = UILabel()
    private let avatar = UIImageView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private var videoID: String?
    private var avatarURL: URL?
    private var rounded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.backgroundColor = UIColor(white: 0.14, alpha: 1)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor(white: 0, alpha: 0.75)
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 4
        durationLabel.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.backgroundColor = UIColor(white: 0.2, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.textColor = UIColor(white: 0.65, alpha: 1)
        metaLabel.numberOfLines = 1
        [thumbnail, durationLabel, avatar, titleLabel, metaLabel].forEach { contentView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Сюда кладётся видео автовоспроизведения (поверх обложки, под длительностью).
    var previewHost: UIView { thumbnail }

    func configure(_ video: VideoFeedViewController.Video, rounded: Bool) {
        self.rounded = rounded
        titleLabel.text = video.title
        metaLabel.text = [video.channel, video.meta].filter { !$0.isEmpty }.joined(separator: " · ")
        durationLabel.text = video.duration
        durationLabel.isHidden = video.duration.isEmpty
        videoID = video.id
        thumbnail.image = nil
        ArtworkLoader.shared.load(video.id, size: .large) { [weak self] image, _ in
            guard self?.videoID == video.id else { return }
            self?.thumbnail.image = image
        }
        avatarURL = video.avatar
        avatar.image = nil
        if let url = video.avatar {
            ArtworkLoader.shared.load(url: url) { [weak self] image in
                guard self?.avatarURL == url else { return }
                self?.avatar.image = image
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let thumbHeight = (w * 9 / 16).rounded()
        thumbnail.frame = CGRect(x: 0, y: 0, width: w, height: thumbHeight)
        thumbnail.layer.cornerRadius = rounded ? 12 : 0
        let durationSize = durationLabel.sizeThatFits(CGSize(width: 120, height: 20))
        durationLabel.frame = CGRect(x: w - durationSize.width - 18, y: thumbHeight - 26, width: durationSize.width + 10, height: 20)
        let pad: CGFloat = rounded ? 0 : 12
        avatar.frame = CGRect(x: pad, y: thumbHeight + 12, width: 36, height: 36)
        avatar.layer.cornerRadius = 18
        let textX = avatar.frame.maxX + 12
        let textW = max(0, w - textX - pad)
        let titleSize = titleLabel.sizeThatFits(CGSize(width: textW, height: 44))
        titleLabel.frame = CGRect(x: textX, y: thumbHeight + 10, width: textW, height: min(42, titleSize.height))
        metaLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + 3, width: textW, height: 16)
    }
}

private final class StatusCell: UICollectionViewCell {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 15)
        label.textColor = UIColor(white: 0.6, alpha: 1)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.frame = contentView.bounds.insetBy(dx: 24, dy: 0)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Автовоспроизведение в ленте, как в приложении YouTube (просьба владельца после 1.86): видео карточки играет
/// без звука прямо на месте обложки, по кругу. Поток — как у системного плеера (`DirectStream`: файл 360p),
/// просмотр YouTube не засчитывается (статистика не отправляется). Только по Wi-Fi; на iPad (только SABR) — не играет.
final class InlinePreview {
    private let player = AVPlayer()
    private let layer = AVPlayerLayer()
    private var token = UUID()
    private var readyObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private(set) weak var host: UIView?
    private(set) var currentID: String?
    /// Найденные ссылки (живут несколько часов) — повторно карточка заиграет сразу.
    private static var links: [String: (stream: AudioStream, found: Date)] = [:]

    var isActive: Bool { currentID != nil }

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        layer.opacity = 0
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ id: String, in view: UIView) {
        if currentID == id, host === view { return }
        stop()
        currentID = id
        host = view
        let current = UUID()
        token = current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = view.bounds
        layer.cornerRadius = view.layer.cornerRadius
        layer.masksToBounds = true
        view.layer.addSublayer(layer)
        CATransaction.commit()
        if let saved = Self.links[id], Date().timeIntervalSince(saved.found) < 3 * 3600 {
            start(saved.stream, token: current)
            return
        }
        Task { [weak self] in
            let found = await DirectStream.find(id)
            let stream = found.streams.first { $0.client != "Прямо звук" }
            await MainActor.run {
                guard let self, self.token == current, let stream else { return }
                Self.links[id] = (stream, Date())
                self.start(stream, token: current)
            }
        }
    }

    private func start(_ stream: AudioStream, token current: UUID) {
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8
        player.replaceCurrentItem(with: item)
        player.play()
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            DispatchQueue.main.async {
                guard let self, self.token == current, layer.isReadyForDisplay else { return }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.35
                layer.add(fade, forKey: "fade")
                layer.opacity = 1
            }
        }
    }

    func stop() {
        token = UUID()
        currentID = nil
        host = nil
        readyObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.removeFromSuperlayer()
        CATransaction.commit()
    }
}
