import UIKit

/// Другие версии трека (просьба владельца после 1.69): Slowed, Lyrics (у русских и СНГ-песен — «текст»), Sped up —
/// первый подходящий результат поиска YouTube. Ищутся заранее, пока трек играет (`NativeAudio.tick` → `prepare`),
/// чтобы при свайпе вверх три обложки были уже готовы.
enum TrackVersions {
    enum Kind: CaseIterable {
        case slowed, lyrics, spedUp

        var title: String {
            switch self {
            case .slowed: return "Slowed"
            case .lyrics: return "Lyrics"
            case .spedUp: return "Sped up"
            }
        }
    }

    static let didChange = Notification.Name("FonTrackVersionsDidChange")

    private static var found: [String: [Kind: Track]] = [:]
    private static var loading = Set<String>()
    /// Неудачный поиск (нет сети) — повтор не раньше чем через минуту.
    private static var failedAt: [String: Date] = [:]

    /// nil — ещё ищутся.
    static func versions(for id: String) -> [Kind: Track]? {
        if let versions = found[id] { return versions }
        return loading.contains(id) || failedAt[id] == nil ? nil : [:] // не вышло — карточки «не найдено»
    }

    static func prepare(_ track: Track) {
        guard !track.title.isEmpty, found[track.id] == nil,
              Date().timeIntervalSince(failedAt[track.id] ?? .distantPast) > 60,
              loading.insert(track.id).inserted else { return }
        var artist = track.artist
        for junk in [" - Topic", "VEVO", "Official"] { artist = artist.replacingOccurrences(of: junk, with: "") }
        let base = artist.isEmpty || track.title.localizedCaseInsensitiveContains(artist) ? track.title : "\(artist) \(track.title)"
        let russian = base.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
        Task {
            async let slowed = YouTubeStreams.search(base + " slowed")
            async let lyrics = YouTubeStreams.search(base + (russian ? " текст" : " lyrics"))
            async let spedUp = YouTubeStreams.search(base + " sped up")
            let results: [Kind: [(track: Track, title: String)]] = [.slowed: await slowed, .lyrics: await lyrics, .spedUp: await spedUp]
            await MainActor.run {
                TrackVersions.loading.remove(track.id)
                var picked: [Kind: Track] = [:]
                for (kind, items) in results {
                    if let item = TrackVersions.pick(kind, items, exclude: track.id, russian: russian) { picked[kind] = item }
                }
                // Ничего не ответило (нет сети) — попробуем позже, а не запомним пустоту.
                if results.values.allSatisfy({ $0.isEmpty }) {
                    TrackVersions.failedAt[track.id] = Date()
                    NotificationCenter.default.post(name: TrackVersions.didChange, object: nil)
                    return
                }
                if TrackVersions.found.count > 200 { TrackVersions.found = [:] }
                TrackVersions.found[track.id] = picked
                NotificationCenter.default.post(name: TrackVersions.didChange, object: nil)
            }
        }
    }

    private static let slowMarks = ["slow", "замедл"]
    private static let fastMarks = ["sped", "speed up", "nightcore", "ускор"]
    private static let lyricMarks = ["lyric", "текст", "караоке", "karaoke", "слова"]

    private static func pick(_ kind: Kind, _ items: [(track: Track, title: String)], exclude: String, russian: Bool) -> Track? {
        let candidates = items.filter { $0.track.id != exclude }
        func has(_ title: String, _ marks: [String]) -> Bool {
            let lower = title.lowercased()
            return marks.contains { lower.contains($0) }
        }
        switch kind {
        case .slowed: return candidates.first { has($0.title, slowMarks) }?.track
        case .spedUp: return candidates.first { has($0.title, fastMarks) }?.track
        case .lyrics:
            let plain = candidates.filter { !has($0.title, slowMarks + fastMarks) }
            // Русские тексты часто подписаны как попало — тогда просто первый результат (просьба владельца).
            return (plain.first { has($0.title, lyricMarks) } ?? (russian ? plain.first : nil))?.track
        }
    }
}

/// «Далее» — свайп вверх по музыкальному плееру (или кнопка списка): другие версии трека, очередь системного плеера
/// и «＋» — найти и добавить своё. Только для системного плеера: у веб-плеера очередь ведёт YouTube.
final class UpNextViewController: UITableViewController {
    private var tracks: [Track] = []
    private var currentID: String?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Далее"
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain,
                                                            target: self, action: #selector(addTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Добавить в очередь"
        tableView.register(VersionsCell.self, forCellReuseIdentifier: "versions")
        tableView.register(QueueTrackCell.self, forCellReuseIdentifier: "track")
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: NativeAudio.queueDidChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: TrackVersions.didChange, object: nil)
        reload()
    }

    @objc private func reload() {
        let audio = NativeAudio.shared
        tracks = audio.upcoming
        currentID = audio.currentTrack?.id
        if let track = audio.currentTrack { TrackVersions.prepare(track) }
        tableView.reloadData()
    }

    @objc private func addTapped() {
        navigationController?.pushViewController(AddToQueueViewController(), animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : tracks.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Другие версии" : (tracks.isEmpty ? "Очередь пуста — дальше похожие" : "В очереди")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "versions", for: indexPath) as! VersionsCell
            cell.configure(currentID.flatMap { TrackVersions.versions(for: $0) }) { [weak self] track in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                NativeAudio.shared.playNow(track)
                self?.dismiss(animated: true)
            }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "track", for: indexPath) as! QueueTrackCell
        cell.configure(tracks[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        NativeAudio.shared.playUpcoming(at: indexPath.row)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Убрать") { _, _, done in
            NativeAudio.shared.removeUpcoming(at: indexPath.row)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

/// Поиск YouTube прямо в «Далее»: нажатие ставит трек в очередь (по порядку нажатий, после текущего).
final class AddToQueueViewController: UITableViewController, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private var results: [Track] = []
    private var added = Set<String>()
    private var insertOffset = 0
    private var searchTask: Task<Void, Never>?
    private var status: String?

    init() {
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Добавить"
        searchBar.placeholder = "Поиск на YouTube"
        searchBar.delegate = self
        searchBar.sizeToFit()
        tableView.tableHeaderView = searchBar
        tableView.keyboardDismissMode = .onDrag
        tableView.register(QueueTrackCell.self, forCellReuseIdentifier: "track")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if results.isEmpty { searchBar.becomeFirstResponder() }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        search(searchBar.text ?? "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.search(text) }
        }
    }

    private func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        status = "Поиск…"
        tableView.reloadData()
        Task { [weak self] in
            let found = await YouTubeStreams.search(query)
            await MainActor.run {
                guard let self, self.searchBar.text?.trimmingCharacters(in: .whitespaces) == query else { return }
                self.results = found.map(\.track)
                self.status = found.isEmpty ? "Ничего не нашлось" : nil
                self.tableView.reloadData()
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { status }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "track", for: indexPath) as! QueueTrackCell
        let track = results[indexPath.row]
        cell.configure(track)
        cell.accessoryType = added.contains(track.id) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let track = results[indexPath.row]
        guard added.insert(track.id).inserted else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        NativeAudio.shared.insertUpcoming(track, at: insertOffset)
        insertOffset += 1
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}

/// Строка трека: обложка, название, исполнитель.
private final class QueueTrackCell: UITableViewCell {
    private var artworkID: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ track: Track) {
        var content = defaultContentConfiguration()
        content.text = track.title.isEmpty ? "Трек" : track.title
        content.secondaryText = track.artist
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = 1
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
        content.imageProperties.cornerRadius = 4
        artworkID = track.id
        accessoryType = .none
        content.image = UIImage(systemName: "music.note")
        contentConfiguration = content
        let id = track.id
        ArtworkLoader.shared.load(id, size: .small) { [weak self] image, _ in
            guard let self, self.artworkID == id, let image, var content = self.contentConfiguration as? UIListContentConfiguration else { return }
            content.image = image
            self.contentConfiguration = content
        }
    }
}

/// Три карточки: Slowed · Lyrics · Sped up — обложка найденного видео и подпись.
private final class VersionsCell: UITableViewCell {
    private let stack = UIStackView()
    private var cards: [VersionCard] = []
    private var onPick: ((Track) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        for kind in TrackVersions.Kind.allCases {
            let card = VersionCard(title: kind.title)
            card.addTarget(self, action: #selector(cardTapped(_:)), for: .touchUpInside)
            cards.append(card)
            stack.addArrangedSubview(card)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `versions` nil — ещё ищутся.
    func configure(_ versions: [TrackVersions.Kind: Track]?, onPick: @escaping (Track) -> Void) {
        self.onPick = onPick
        for (card, kind) in zip(cards, TrackVersions.Kind.allCases) {
            card.show(versions.map { $0[kind] }, loading: versions == nil)
        }
    }

    @objc private func cardTapped(_ card: VersionCard) {
        if let track = card.track { onPick?(track) }
    }
}

private final class VersionCard: UIControl {
    private let imageView = UIImageView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private(set) var track: Track?

    init(title: String) {
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        imageView.tintColor = UIColor(white: 0.5, alpha: 1)
        imageView.isUserInteractionEnabled = false
        label.text = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        spinner.hidesWhenStopped = true
        [imageView, label, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : (track == nil ? 0.45 : 1) }
    }

    func show(_ found: Track??, loading: Bool) {
        let track = found ?? nil
        self.track = track
        alpha = track == nil && !loading ? 0.45 : 1
        isEnabled = track != nil
        accessibilityLabel = label.text.map { track == nil ? "\($0) — не найдено" : $0 }
        imageView.image = loading ? nil : (track == nil ? UIImage(systemName: "xmark") : nil)
        imageView.contentMode = track == nil ? .center : .scaleAspectFill
        loading ? spinner.startAnimating() : spinner.stopAnimating()
        guard let id = track?.id else { return }
        ArtworkLoader.shared.load(id, size: .small) { [weak self] image, _ in
            guard self?.track?.id == id else { return }
            self?.imageView.image = image
        }
    }
}
