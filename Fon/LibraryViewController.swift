import UIKit

typealias PlayTracksHandler = (_ tracks: [Track], _ start: Int, _ shuffle: Bool, _ name: String) -> Void

/// Медиатека режима музыки: «Понравившиеся» и свои плейлисты.
final class LibraryViewController: UITableViewController {
    var onPlay: PlayTracksHandler?

    init() {
        super.init(style: .insetGrouped)
        title = "Медиатека"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .black
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
    }

    @objc private func reload() { tableView.reloadData() }

    private var playlists: [Playlist] { Library.shared.playlists }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : playlists.count + 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "Плейлисты" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = PlayerView.accent
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
        if indexPath.section == 0 {
            content.text = "Понравившиеся"
            content.secondaryText = LibraryViewController.tracksCount(Library.shared.liked.count)
            content.image = UIImage(systemName: "heart.fill")
        } else if indexPath.row == 0 {
            content.text = "Новый плейлист"
            content.textProperties.color = PlayerView.accent
            content.image = UIImage(systemName: "plus")
            cell.accessoryType = .none
        } else {
            let playlist = playlists[indexPath.row - 1]
            content.text = playlist.name
            content.secondaryText = LibraryViewController.tracksCount(playlist.tracks.count)
            content.image = UIImage(systemName: "music.note.list")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            open(.liked)
        } else if indexPath.row == 0 {
            LibraryViewController.askName(title: "Новый плейлист", initial: "", from: self) { [weak self] name in
                let playlist = Library.shared.createPlaylist(named: name)
                self?.open(.playlist(playlist.id))
            }
        } else {
            open(.playlist(playlists[indexPath.row - 1].id))
        }
    }

    private func open(_ source: TrackListSource) {
        let list = TrackListViewController(source: source)
        list.onPlay = onPlay
        navigationController?.pushViewController(list, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, indexPath.row > 0 else { return nil }
        let playlist = playlists[indexPath.row - 1]
        let delete = UIContextualAction(style: .destructive, title: "Удалить") { _, _, done in
            Library.shared.deletePlaylist(playlist.id)
            done(true)
        }
        let rename = UIContextualAction(style: .normal, title: "Имя") { [weak self] _, _, done in
            guard let self else { return done(false) }
            LibraryViewController.askName(title: "Переименовать", initial: playlist.name, from: self) { name in
                Library.shared.renamePlaylist(playlist.id, to: name)
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, rename])
    }

    // MARK: - Общие помощники

    static func askName(title: String, initial: String, from presenter: UIViewController, done: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.placeholder = "Название"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Готово", style: .default) { _ in
            let name = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            done(name.isEmpty ? "Мой плейлист" : name)
        })
        presenter.present(alert, animated: true)
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

/// Список треков плейлиста или «Понравившихся»: слушать, перемешать, удалить, поменять порядок.
final class TrackListViewController: UITableViewController {
    var onPlay: PlayTracksHandler?
    private let source: TrackListSource
    private var tracks: [Track] = []
    private var editingLocally = false

    init(source: TrackListSource) {
        self.source = source
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .black
        tableView.rowHeight = 64
        tableView.separatorInset.left = 76
        tableView.register(TrackCell.self, forCellReuseIdentifier: "track")
        navigationItem.rightBarButtonItem = editButtonItem
        tableView.tableHeaderView = makeHeader()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
        reload()
    }

    @objc private func reload() {
        guard !editingLocally else { return }
        title = Library.shared.title(of: source)
        tracks = Library.shared.tracks(in: source)
        tableView.reloadData()
        if tracks.isEmpty {
            let label = UILabel()
            label.text = source == .liked
                ? "Нажмите ♡ в плеере,\nчтобы трек появился здесь"
                : "Добавляйте треки кнопкой ⊕ в плеере"
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
        tableView.tableHeaderView?.isHidden = tracks.isEmpty
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

    private func playAll(shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        onPlay?(tracks, shuffle ? Int.random(in: 0..<tracks.count) : 0, shuffle, title ?? "Плейлист")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tracks.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "track", for: indexPath) as! TrackCell
        cell.configure(tracks[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onPlay?(tracks, indexPath.row, false, title ?? "Плейлист")
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        editingLocally = true
        Library.shared.removeTrack(at: indexPath.row, from: source)
        tracks.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        editingLocally = false
        if tracks.isEmpty { reload() }
    }

    override func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        "Удалить"
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        editingLocally = true
        Library.shared.moveTrack(from: from.row, to: to.row, in: source)
        tracks.insert(tracks.remove(at: from.row), at: to.row)
        editingLocally = false
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
