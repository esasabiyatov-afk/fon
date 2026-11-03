import UIKit

/// Что включить в плеере: ссылка, подпись «Играет из» и id треков своей очереди (если есть).
typealias PlayHandler = (_ url: URL, _ source: String, _ queue: [String]?) -> Void

/// Медиатека режима музыки: «Понравившиеся» (плейлист YouTube «Fon — музыка») и «Недавно слушали».
final class LibraryViewController: UITableViewController {
    var onPlay: PlayHandler?

    init() {
        super.init(style: .insetGrouped)
        title = tr("Медиатека")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings))
        settings.accessibilityLabel = tr("Настройки")
        navigationItem.rightBarButtonItem = settings
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: CloudLikes.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: OfflineStore.didChange, object: nil)
    }

    @objc private func reload() { tableView.reloadData() }

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func pullToRefresh() {
        CloudLikes.shared.refresh { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let cloud = CloudLikes.shared
        let status = cloud.lastError ?? tr("Понравившиеся хранятся в вашем аккаунте YouTube — плейлист «Fon — музыка».")
        return [status, Signature.untilText].compactMap { $0 }.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = PlayerView.accent
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = UIColor(white: 1, alpha: 0.08) // полупрозрачно — виден живой фон
        if indexPath.row == 0 {
            let cloud = CloudLikes.shared
            content.text = tr("Понравившиеся")
            content.secondaryText = cloud.loaded || !cloud.tracks.isEmpty ? LibraryViewController.tracksCount(cloud.tracks.count) : tr("Загрузка…")
            content.image = UIImage(systemName: "heart.fill")
        } else if indexPath.row == 1 {
            content.text = tr("Недавно слушали")
            content.secondaryText = LibraryViewController.tracksCount(Library.shared.history.count)
            content.image = UIImage(systemName: "clock.arrow.circlepath")
        } else {
            content.text = tr("Скачанные")
            content.secondaryText = LibraryViewController.offlineStatus()
            content.image = UIImage(systemName: "arrow.down.circle.fill")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let list = TrackListViewController(kind: [.liked, .history, .downloaded][indexPath.row])
        list.onPlay = onPlay
        navigationController?.pushViewController(list, animated: true)
    }

    /// «120 треков · 450 МБ из 2 ГБ · качается…»
    static func offlineStatus() -> String {
        let store = OfflineStore.shared
        var parts = [tracksCount(store.tracks.count), OfflineStore.sizeText(store.totalSize) + (AppLanguage.current == .en ? " of " : " из ") + OfflineStore.sizeText(OfflineStore.limit)]
        if !store.online {
            parts.append(tr("нет сети — играют скачанные"))
        } else if store.downloading != nil {
            parts.append(AppLanguage.current == .en ? "downloading, \(store.waitingCount) queued" : "качается, в очереди \(store.waitingCount)")
        } else if store.waitsForWiFi {
            parts.append(tr("ждёт Wi-Fi"))
        }
        return parts.joined(separator: " · ")
    }

    static func tracksCount(_ n: Int) -> String {
        if AppLanguage.current == .en { return n == 1 ? "1 track" : "\(n) tracks" }
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "трек" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "трека" }
        else { word = "треков" }
        return "\(n) \(word)"
    }
}

/// Список треков: «Понравившиеся» (облако), «Недавно слушали» (на телефоне) или музыка исполнителя
/// (видео его канала, только музыкальные — нажатие на исполнителя в плеере).
final class TrackListViewController: UITableViewController {
    enum Kind: Equatable { case liked, history, downloaded, artist(channelID: String, name: String) }

    var onPlay: PlayHandler?
    private let kind: Kind
    private var tracks: [Track] = []
    private var artistTracks: [Track]?
    private var artistError: String?

    init(kind: Kind) {
        self.kind = kind
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        switch kind {
        case .liked: title = tr("Понравившиеся")
        case .history: title = tr("Недавно слушали")
        case .downloaded: title = tr("Скачанные")
        case .artist(_, let name): title = name.replacingOccurrences(of: " - Topic", with: "")
        }
        tableView.backgroundColor = .clear
        tableView.rowHeight = 64
        tableView.separatorInset.left = 76
        tableView.register(TrackCell.self, forCellReuseIdentifier: "track")
        tableView.tableHeaderView = makeHeader()
        if kind == .downloaded {
            // Без кнопок и обновления: качается само.
        } else if kind != .history {
            refreshControl = UIRefreshControl()
            refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: tr("Очистить"), style: .plain, target: self, action: #selector(clearHistory))
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: CloudLikes.didChange, object: nil) // ♡ у треков
        if kind == .history { nc.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil) }
        if kind == .downloaded { nc.addObserver(self, selector: #selector(reload), name: OfflineStore.didChange, object: nil) }
        reload()
        loadArtist()
    }

    private func loadArtist(completion: (() -> Void)? = nil) {
        guard case let .artist(channelID, name) = kind else { return }
        MusicFeed.shared.channelMusic(channelID, channelName: name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tracks):
                self.artistTracks = tracks
                self.artistError = nil
            case .failure(let error):
                self.artistError = CloudLikes.describe(error)
            }
            self.reload()
            completion?()
        }
    }

    /// Шапка с кнопками — по ширине таблицы (иначе «Перемешать» уезжала за край).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width else { return }
        header.frame.size.width = tableView.bounds.width
        tableView.tableHeaderView = header
    }

    @objc private func reload() {
        switch kind {
        case .liked: tracks = CloudLikes.shared.tracks
        case .history: tracks = Library.shared.history
        case .downloaded: tracks = OfflineStore.shared.tracks
        case .artist: tracks = artistTracks ?? []
        }
        if kind == .downloaded { tableView.tableFooterView = offlineFooter() }
        tableView.reloadData()
        if tracks.isEmpty {
            let label = UILabel()
            if case .artist = kind {
                label.text = artistError ?? (artistTracks == nil ? tr("Загрузка…") : tr("На канале не нашлось музыки"))
            } else if kind == .liked {
                label.text = CloudLikes.shared.lastError
                    ?? (CloudLikes.shared.loaded ? tr("Нажмите ♡ в плеере —\nтрек сохранится в ваш плейлист\nYouTube «Fon — музыка»") : tr("Загрузка…"))
            } else if kind == .downloaded {
                label.text = tr("Здесь появятся треки для прослушивания без интернета.\nПриложение скачивает их само по Wi-Fi:\nпонравившиеся, часто слушаемые, миксы\nи немного рекомендаций (до 2 ГБ).")
            } else {
                label.text = tr("Здесь появятся треки,\nкоторые вы слушали в режиме музыки")
            }
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
        tableView.tableHeaderView?.isHidden = tracks.isEmpty
    }

    /// Внизу «Скачанных» — сколько места и что сейчас качается.
    private func offlineFooter() -> UIView {
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 64))
        label.text = LibraryViewController.offlineStatus() + tr("\nСмахните трек, чтобы удалить: сам он больше не скачается.")
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    @objc private func pullToRefresh() {
        let done: () -> Void = { [weak self] in self?.refreshControl?.endRefreshing() }
        if case .artist = kind { loadArtist(completion: done) } else { CloudLikes.shared.refresh(completion: done) }
    }

    @objc private func clearHistory() {
        let alert = UIAlertController(title: tr("Очистить историю?"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: tr("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: tr("Очистить"), style: .destructive) { _ in Library.shared.clearHistory() })
        present(alert, animated: true)
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 72))
        func button(_ title: String, _ symbol: String, filled: Bool, shuffle: Bool) -> UIButton {
            var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            config.title = title
            config.image = UIImage(systemName: symbol)
            config.imagePadding = 6
            config.cornerStyle = .capsule
            config.baseBackgroundColor = filled ? PlayerView.accent : UIColor(white: 0.18, alpha: 1)
            config.baseForegroundColor = .white
            return UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.playAll(shuffle: shuffle) })
        }
        let stack = UIStackView(arrangedSubviews: [
            button(tr("Слушать"), "play.fill", filled: true, shuffle: false),
            button(tr("Перемешать"), "shuffle", filled: false, shuffle: true)
        ])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.frame = header.bounds.insetBy(dx: 16, dy: 14)
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        header.addSubview(stack)
        return header
    }

    private var sourceName: String { title ?? tr("Медиатека") }

    /// Нажатый трек и следующие — одной очередью (исполнитель, скачанные — без сети миксов нет).
    private var playsAsQueue: Bool {
        if case .artist = kind { return true }
        return kind == .downloaded
    }

    private func playAll(shuffle: Bool) {
        guard let first = tracks.first else { return }
        let ids = tracks.map(\.id)
        if shuffle {
            let shuffled = Array(ids.shuffled().prefix(50))
            if let url = YouTubeLinks.queue(shuffled) { onPlay?(url, sourceName, shuffled) }
        } else if kind == .liked, let url = CloudLikes.shared.playURL(startingAt: first.id) {
            onPlay?(url, sourceName, ids) // настоящий плейлист YouTube
        } else if let url = YouTubeLinks.queue(ids) {
            onPlay?(url, sourceName, Array(ids.prefix(50)))
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tracks.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "track", for: indexPath) as! TrackCell
        let track = tracks[indexPath.row]
        cell.configure(track, liked: CloudLikes.shared.isLiked(track.id)) { liked in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            CloudLikes.shared.setLiked(track, liked)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let track = tracks[indexPath.row]
        if kind == .liked, let url = CloudLikes.shared.playURL(startingAt: track.id) {
            onPlay?(url, sourceName, tracks.map(\.id))
        } else if playsAsQueue {
            // Нажатый трек и следующие за ним — одной очередью.
            let queue = Array(tracks[indexPath.row...].map(\.id).prefix(50))
            if let url = YouTubeLinks.queue(queue) { onPlay?(url, sourceName, queue) }
        } else if let url = YouTubeLinks.mix(track.id) {
            onPlay?(url, tr("Микс"), nil) // из истории — трек и похожие на него
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if case .artist = kind { return nil }
        let track = tracks[indexPath.row]
        let title = kind == .liked ? tr("Убрать") : tr("Удалить")
        let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, done in
            guard let self else { return done(false) }
            if self.kind == .downloaded {
                OfflineStore.shared.remove(track.id) // и больше не качать сам
            } else if self.kind == .liked {
                CloudLikes.shared.setLiked(track, false)
            } else {
                Library.shared.removeFromHistory(track.id)
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}

final class TrackCell: UITableViewCell {
    private let artwork = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let likeButton = UIButton(type: .system)
    private var trackID: String?
    private var liked = false
    private var onLike: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = UIColor(white: 0.15, alpha: 1)
        selectedBackgroundView = selected
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 6
        artwork.backgroundColor = UIColor(white: 0.16, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = .white
        artistLabel.font = .systemFont(ofSize: 13)
        artistLabel.textColor = .secondaryLabel
        likeButton.tintColor = PlayerView.accent
        likeButton.accessibilityLabel = tr("Понравившиеся")
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        [artwork, titleLabel, artistLabel, likeButton].forEach { contentView.addSubview($0) }
    }

    /// ♡ справа — добавить в «Понравившиеся» (облачный плейлист) или убрать оттуда.
    @objc private func likeTapped() {
        setLiked(!liked)
        onLike?(liked)
        UIView.animate(withDuration: 0.12, animations: {
            self.likeButton.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        }, completion: { _ in
            UIView.animate(withDuration: 0.2) { self.likeButton.transform = .identity }
        })
    }

    private func setLiked(_ value: Bool) {
        liked = value
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        likeButton.setImage(UIImage(systemName: value ? "heart.fill" : "heart", withConfiguration: config), for: .normal)
        likeButton.tintColor = value ? PlayerView.accent : UIColor(white: 0.6, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ track: Track, liked: Bool, onLike: @escaping (Bool) -> Void) {
        trackID = track.id
        self.onLike = onLike
        setLiked(liked)
        titleLabel.text = track.title
        artistLabel.text = track.artist
        artwork.image = nil
        ArtworkLoader.shared.load(track.id, size: .small) { [weak self] image, _ in
            guard self?.trackID == track.id else { return }
            self?.artwork.image = image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentView.bounds.height
        let w = contentView.bounds.width
        artwork.frame = CGRect(x: 16, y: (h - 48) / 2, width: 85, height: 48) // 16:9
        let x: CGFloat = 113
        likeButton.frame = CGRect(x: w - 52, y: (h - 44) / 2, width: 44, height: 44)
        titleLabel.frame = CGRect(x: x, y: h / 2 - 20, width: max(0, w - x - 56), height: 21)
        artistLabel.frame = CGRect(x: x, y: h / 2 + 2, width: max(0, w - x - 56), height: 18)
    }
}
