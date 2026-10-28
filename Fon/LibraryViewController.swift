import UIKit

/// Что включить в плеере: ссылка, подпись «Играет из» и id треков своей очереди (если есть).
typealias PlayHandler = (_ url: URL, _ source: String, _ queue: [String]?) -> Void

/// Медиатека режима музыки: «Понравившиеся» (плейлист YouTube «Fon — музыка») и «Недавно слушали».
final class LibraryViewController: UITableViewController {
    var onPlay: PlayHandler?

    init() {
        super.init(style: .insetGrouped)
        title = "Медиатека"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .black
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: CloudLikes.didChange, object: nil)
    }

    @objc private func reload() { tableView.reloadData() }

    @objc private func pullToRefresh() {
        CloudLikes.shared.refresh { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let cloud = CloudLikes.shared
        let status = cloud.lastError ?? "Понравившиеся хранятся в вашем аккаунте YouTube — плейлист «Fon — музыка»."
        return [status, Signature.untilText].compactMap { $0 }.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = PlayerView.accent
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
        if indexPath.row == 0 {
            let cloud = CloudLikes.shared
            content.text = "Понравившиеся"
            content.secondaryText = cloud.loaded ? LibraryViewController.tracksCount(cloud.tracks.count) : "Загрузка…"
            content.image = UIImage(systemName: "heart.fill")
        } else {
            content.text = "Недавно слушали"
            content.secondaryText = LibraryViewController.tracksCount(Library.shared.history.count)
            content.image = UIImage(systemName: "clock.arrow.circlepath")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let list = TrackListViewController(kind: indexPath.row == 0 ? .liked : .history)
        list.onPlay = onPlay
        navigationController?.pushViewController(list, animated: true)
    }

    static func tracksCount(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "трек" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "трека" }
        else { word = "треков" }
        return "\(n) \(word)"
    }
}

/// Список треков: «Понравившиеся» (облако) или «Недавно слушали» (на телефоне).
final class TrackListViewController: UITableViewController {
    enum Kind { case liked, history }

    var onPlay: PlayHandler?
    private let kind: Kind
    private var tracks: [Track] = []

    init(kind: Kind) {
        self.kind = kind
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = kind == .liked ? "Понравившиеся" : "Недавно слушали"
        tableView.backgroundColor = .black
        tableView.rowHeight = 64
        tableView.separatorInset.left = 76
        tableView.register(TrackCell.self, forCellReuseIdentifier: "track")
        tableView.tableHeaderView = makeHeader()
        if kind == .liked {
            refreshControl = UIRefreshControl()
            refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Очистить", style: .plain, target: self, action: #selector(clearHistory))
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: kind == .liked ? CloudLikes.didChange : Library.didChange, object: nil)
        reload()
    }

    @objc private func reload() {
        tracks = kind == .liked ? CloudLikes.shared.tracks : Library.shared.history
        tableView.reloadData()
        if tracks.isEmpty {
            let label = UILabel()
            if kind == .liked {
                label.text = CloudLikes.shared.lastError
                    ?? (CloudLikes.shared.loaded ? "Нажмите ♡ в плеере —\nтрек сохранится в ваш плейлист\nYouTube «Fon — музыка»" : "Загрузка…")
            } else {
                label.text = "Здесь появятся треки,\nкоторые вы слушали в режиме музыки"
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

    @objc private func pullToRefresh() {
        CloudLikes.shared.refresh { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    @objc private func clearHistory() {
        let alert = UIAlertController(title: "Очистить историю?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Очистить", style: .destructive) { _ in Library.shared.clearHistory() })
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
            button("Слушать", "play.fill", filled: true, shuffle: false),
            button("Перемешать", "shuffle", filled: false, shuffle: true)
        ])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.frame = header.bounds.insetBy(dx: 16, dy: 14)
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        header.addSubview(stack)
        return header
    }

    private var sourceName: String { title ?? "Медиатека" }

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
        cell.configure(tracks[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let track = tracks[indexPath.row]
        if kind == .liked, let url = CloudLikes.shared.playURL(startingAt: track.id) {
            onPlay?(url, sourceName, tracks.map(\.id))
        } else if let url = YouTubeLinks.mix(track.id) {
            onPlay?(url, "Микс", nil) // из истории — трек и похожие на него
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let track = tracks[indexPath.row]
        let title = kind == .liked ? "Убрать" : "Удалить"
        let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, done in
            guard let self else { return done(false) }
            if self.kind == .liked {
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
    private var trackID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .black
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
        [artwork, titleLabel, artistLabel].forEach { contentView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ track: Track) {
        trackID = track.id
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
        artwork.frame = CGRect(x: 16, y: (h - 48) / 2, width: 48, height: 48)
        let x: CGFloat = 76
        titleLabel.frame = CGRect(x: x, y: h / 2 - 20, width: max(0, w - x - 12), height: 21)
        artistLabel.frame = CGRect(x: x, y: h / 2 + 2, width: max(0, w - x - 12), height: 18)
    }
}
