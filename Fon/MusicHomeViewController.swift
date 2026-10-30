import UIKit

/// Режим музыки, как в стриминговых сервисах.
/// «Главная»: быстрый доступ (Понравившиеся, Мой микс, последние) и подборки YouTube Music вашего
/// аккаунта: «Быстрый выбор» — ряды треков, миксы, альбомы, исполнители. Пока подборки не загрузились
/// (или без сети) — свои: «Миксы для вас» по истории и лайкам, «Недавно слушали», «Понравившиеся».
/// «Подписки»: исполнители, на которых вы подписаны, и их новые треки — без остальных видео.
final class MusicHomeViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    enum Kind { case home, subscriptions }

    var onPlay: PlayHandler?
    var onOpenLikes: (() -> Void)?
    var onOpenFeed: (() -> Void)?
    var onSearch: (() -> Void)?

    fileprivate enum Style { case quick, large, small, round, rows, list, message }

    fileprivate struct Item {
        var title: String
        var subtitle: String = ""
        var artworkID: String? = nil
        var artworkURL: URL? = nil
        var symbol: String? = nil
        var round = false
        var action: (() -> Void)? = nil
        /// Исполнитель из подписок — по долгому нажатию «Отписаться». Ставится после создания карточки.
        var unsubscribe: (() -> Void)? = nil

        /// Свой init: замыкание после скобок — всегда `action`. С автоматическим init Swift 5 отдавал его
        /// последнему параметру (`unsubscribe`), и в 1.68–1.69 карточки «Главной» не нажимались.
        init(title: String, subtitle: String = "", artworkID: String? = nil, artworkURL: URL? = nil,
             symbol: String? = nil, round: Bool = false, action: (() -> Void)? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.artworkID = artworkID
            self.artworkURL = artworkURL
            self.symbol = symbol
            self.round = round
            self.action = action
        }
    }

    fileprivate struct Section {
        let title: String
        let style: Style
        let items: [Item]
    }

    private let kind: Kind
    private var sections: [Section] = []
    private var signature = ""
    private var collectionView: UICollectionView!

    init(kind: Kind = .home) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(QuickCell.self, forCellWithReuseIdentifier: "quick")
        collectionView.register(CardCell.self, forCellWithReuseIdentifier: "card")
        collectionView.register(RowCell.self, forCellWithReuseIdentifier: "row")
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: "message")
        collectionView.register(HeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: CloudLikes.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: MusicFeed.didChange, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reload()
        switch kind {
        case .home: MusicFeed.shared.loadHome()
        case .subscriptions: MusicFeed.shared.loadSubscriptions()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    func scrollToTop() {
        collectionView?.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    @objc private func pullToRefresh() {
        let done: () -> Void = { [weak self] in self?.collectionView.refreshControl?.endRefreshing() }
        switch kind {
        case .home:
            CloudLikes.shared.refresh()
            MusicFeed.shared.loadHome(force: true, completion: done)
        case .subscriptions:
            MusicFeed.shared.loadSubscriptions(force: true, completion: done)
        }
    }

    // MARK: - Подборки

    /// Перерисовываем, только если что-то поменялось, — иначе карусели сбрасывали бы прокрутку.
    @objc private func reload() {
        guard isViewLoaded else { return }
        let built = kind == .home ? homeSections() : subscriptionSections()
        let newSignature = built.map { section in
            section.title + "|" + section.items.map { $0.title + $0.subtitle + ($0.artworkURL?.absoluteString ?? $0.artworkID ?? "") }.joined(separator: ",")
        }.joined(separator: "\n")
        sections = built
        guard newSignature != signature else { return }
        signature = newSignature
        collectionView.reloadData()
    }

    private func homeSections() -> [Section] {
        let likes = Array(CloudLikes.shared.tracks.reversed()) // новые лайки — первыми
        let history = Library.shared.history
        let shelves = MusicFeed.shared.shelves
        var result: [Section] = []

        var quick: [Item] = [Item(title: "Понравившиеся", symbol: "heart.fill") { [weak self] in self?.onOpenLikes?() }]
        if let seed = history.first ?? likes.first {
            quick.append(Item(title: "Мой микс", artworkID: seed.id) { [weak self] in
                if let url = YouTubeLinks.myMix(seed: seed.id) { self?.onPlay?(url, "Мой микс", nil) }
            })
        }
        let quickCount = view.bounds.width > 600 ? 6 : 4 // сетка карточек: 2 ряда
        for track in history.prefix(quickCount - quick.count) {
            quick.append(mixItem(track))
        }
        result.append(Section(title: Self.greeting(), style: .quick, items: quick))

        if shelves.isEmpty {
            result += localSections(history: history, likes: likes)
        } else {
            for shelf in shelves {
                switch shelf.kind {
                case .songs:
                    result.append(Section(title: shelf.title, style: .rows, items: shelf.items.map { musicItem($0, source: shelf.title) }))
                case .artists:
                    result.append(Section(title: shelf.title, style: .round, items: shelf.items.map { musicItem($0, source: "Радио: \($0.title)") }))
                case .cards:
                    result.append(Section(title: shelf.title, style: .large, items: shelf.items.map {
                        musicItem($0, source: $0.artist ? "Радио: \($0.title)" : $0.title)
                    }))
                }
            }
        }

        result.append(Section(title: "Ещё", style: .quick, items: [
            Item(title: "Лента YouTube: музыка", symbol: "play.rectangle.on.rectangle") { [weak self] in self?.onOpenFeed?() }
        ]))
        return result
    }

    /// Свои подборки — пока не пришли подборки YouTube Music (или если они недоступны).
    private func localSections(history: [Track], likes: [Track]) -> [Section] {
        var result: [Section] = []
        // Зёрна для миксов: разные исполнители из истории и лайков.
        var seeds: [Track] = []
        var artists = Set<String>()
        for track in history.prefix(40) + likes.prefix(40) where seeds.count < 10 {
            let key = track.artist.lowercased()
            guard !key.isEmpty, !artists.contains(key) else { continue }
            artists.insert(key)
            seeds.append(track)
        }
        if !seeds.isEmpty {
            result.append(Section(title: "Миксы для вас", style: .large, items: seeds.map { seed in
                Item(title: "Микс: \(seed.artist)", subtitle: "\(seed.title) и похожие", artworkID: seed.id) { [weak self] in
                    if let url = YouTubeLinks.mix(seed.id) { self?.onPlay?(url, "Микс: \(seed.artist)", nil) }
                }
            }))
        }
        if !history.isEmpty {
            result.append(Section(title: "Недавно слушали", style: .small, items: history.prefix(20).map(mixItem)))
        }
        if !likes.isEmpty {
            let ids = CloudLikes.shared.tracks.map(\.id)
            result.append(Section(title: "Понравившиеся", style: .small, items: likes.prefix(20).map { track in
                Item(title: track.title, subtitle: track.artist, artworkID: track.id) { [weak self] in
                    if let url = CloudLikes.shared.playURL(startingAt: track.id) { self?.onPlay?(url, "Понравившиеся", ids) }
                }
            }))
        }
        if MusicFeed.shared.isLoadingHome {
            result.append(Section(title: "", style: .message, items: [Item(title: "Загружаем подборки…")]))
        } else if let error = MusicFeed.shared.homeError {
            result.append(Section(title: "", style: .message, items: [Item(title: error + "\nПотяните вниз, чтобы повторить.")]))
        }
        return result
    }

    private func subscriptionSections() -> [Section] {
        let feed = MusicFeed.shared
        let artists = feed.artists
        let message: (String) -> Section = { Section(title: "", style: .message, items: [Item(title: $0)]) }

        guard !artists.isEmpty else {
            let text: String
            if feed.isLoadingSubscriptions || (!feed.subscriptionsLoaded && feed.subscriptionsError == nil) {
                text = "Загружаем ваших исполнителей…"
            } else if feed.signedOut {
                text = "Войдите в аккаунт Google (режим «Видео» → «Вы»), чтобы видеть исполнителей, на которых вы подписаны."
            } else if let error = feed.subscriptionsError {
                text = error + "\nПотяните вниз, чтобы повторить."
            } else {
                text = "Здесь будут исполнители, на которых вы подписаны на YouTube, и их новые треки."
            }
            return [Section(title: "Подписки", style: .message, items: [Item(title: text)])]
        }

        var result = [Section(title: "Подписки", style: .round, items: artists.map { artist in
            var item = musicItem(artist, source: "Радио: \(artist.title)")
            if artist.browseId != nil { item.unsubscribe = { [weak self] in self?.confirmUnsubscribe(artist) } }
            return item
        })]
        let releases = feed.releases
        if releases.isEmpty {
            if feed.isLoadingSubscriptions {
                result.append(message("Ищем новые треки…"))
            } else if let error = feed.subscriptionsError {
                result.append(message(error))
            } else {
                result.append(message("Новых треков от ваших исполнителей в ленте подписок пока нет."))
            }
        } else {
            // Нажатый трек и следующие за ним — одной очередью.
            let ids = releases.compactMap(\.videoId)
            result.append(Section(title: "Новое", style: .list, items: releases.enumerated().map { index, release in
                Item(title: release.title, subtitle: release.subtitle, artworkID: release.videoId) { [weak self] in
                    let queue = Array(ids[index...].prefix(50))
                    if let url = YouTubeLinks.queue(queue) { self?.onPlay?(url, "Подписки", queue) }
                }
            }))
        }
        return result
    }

    /// Карточка YouTube Music: что включить, выясняется по нажатию (у альбома — первый трек и т. д.).
    private func musicItem(_ music: MusicItem, source: String) -> Item {
        Item(title: music.title, subtitle: music.subtitle,
             artworkID: music.thumb == nil ? music.videoId : nil, artworkURL: music.thumb,
             symbol: music.artist ? "person.fill" : "music.note", round: music.artist) { [weak self] in
            MusicFeed.shared.resolve(music) { url in
                guard let self else { return }
                if let url {
                    self.onPlay?(url, source, nil)
                } else {
                    self.view.showToast("Не удалось включить", at: CGPoint(x: self.view.bounds.midX, y: self.view.bounds.height - 60))
                }
            }
        }
    }

    private func confirmUnsubscribe(_ artist: MusicItem) {
        let alert = UIAlertController(title: "Отписаться от «\(artist.title)»?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Отписаться", style: .destructive) { [weak self] _ in
            MusicFeed.shared.unsubscribe(artist) { ok in
                guard let self else { return }
                self.view.showToast(ok ? "Вы отписались" : "Не удалось отписаться",
                                    at: CGPoint(x: self.view.bounds.midX, y: self.view.bounds.height - 60))
            }
        })
        present(alert, animated: true)
    }

    /// Трек и похожие на него (Mix YouTube).
    private func mixItem(_ track: Track) -> Item {
        Item(title: track.title, subtitle: track.artist, artworkID: track.id) { [weak self] in
            if let url = YouTubeLinks.mix(track.id) { self?.onPlay?(url, "Микс", nil) }
        }
    }

    private static func greeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Доброе утро"
        case 12..<18: return "Добрый день"
        case 18..<23: return "Добрый вечер"
        default: return "Доброй ночи"
        }
    }

    // MARK: - Раскладка

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, self.sections.indices.contains(index) else { return nil }
            let style = self.sections[index].style
            let wide = environment.container.effectiveContentSize.width > 600 // iPad
            let section: NSCollectionLayoutSection
            switch style {
            case .quick:
                // Быстрый доступ — сетка карточек 16:9 (обложка сверху, название под ней).
                let columns: CGFloat = wide ? 3 : 2
                let thumbWidth = (environment.container.effectiveContentSize.width - 24) / columns - 8
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / columns), heightDimension: .fractionalHeight(1)))
                item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute((thumbWidth * 9 / 16).rounded() + 42)), subitems: [item])
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 8
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 24, trailing: 12)
            case .large, .small, .round:
                // Карточки 16:9; исполнители — круглые аватары, как у каналов YouTube.
                let side: CGFloat = style == .large ? 240 : (style == .round ? 120 : 190)
                let artHeight = style == .round ? side : (side * 9 / 16).rounded()
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(artHeight + 46)), subitems: [item])
                section = NSCollectionLayoutSection(group: group)
                section.orthogonalScrollingBehavior = .continuous
                section.interGroupSpacing = 14
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16)
            case .rows:
                // «Быстрый выбор» как в YouTube Music: столбики по 4 трека, листаются вбок.
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(56)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(wide ? 0.45 : 0.88), heightDimension: .absolute(56 * 4 + 6 * 3)),
                                                             repeatingSubitem: item, count: 4)
                group.interItemSpacing = .fixed(6)
                section = NSCollectionLayoutSection(group: group)
                section.orthogonalScrollingBehavior = .groupPaging
                section.interGroupSpacing = 12
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16)
            case .list:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(64)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(64)), subitems: [item])
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 4
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16)
            case .message:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
                section = NSCollectionLayoutSection(group: .horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 24, bottom: 24, trailing: 24)
            }
            let title = self.sections[index].title
            if !title.isEmpty {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(index == 0 ? 56 : 40)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }

    // MARK: - UICollectionView

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let section = sections[indexPath.section]
        let item = section.items[indexPath.item]
        switch section.style {
        case .quick:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "quick", for: indexPath) as! QuickCell
            cell.configure(item)
            return cell
        case .rows, .list:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! RowCell
            cell.configure(item)
            return cell
        case .message:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "message", for: indexPath) as! MessageCell
            cell.configure(item.title)
            return cell
        case .large, .small, .round:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! CardCell
            cell.configure(item, large: section.style == .large)
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! HeaderView
        let first = indexPath.section == 0
        header.configure(sections[indexPath.section].title, big: first, onSearch: first ? { [weak self] in self?.onSearch?() } : nil)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section].items[indexPath.item].action != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let action = sections[indexPath.section].items[indexPath.item].action else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
    }

    // Лёгкое «нажатие» карточки, как в музыкальных приложениях.
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        animatePress(collectionView.cellForItem(at: indexPath), down: true)
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        animatePress(collectionView.cellForItem(at: indexPath), down: false)
    }

    private func animatePress(_ cell: UICollectionViewCell?, down: Bool) {
        UIView.animate(withDuration: down ? 0.12 : 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            cell?.transform = down ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
        }
    }

    // MARK: - Ячейки

    /// Картинка карточки: обложка YouTube Music по ссылке или квадрат из превью видео по id.
    /// Ключ ячейка запоминает ДО загрузки: картинка из кэша приходит сразу, в том же вызове.
    fileprivate static func artworkKey(_ item: Item) -> String? {
        item.artworkURL?.absoluteString ?? item.artworkID
    }

    fileprivate static func loadArtwork(_ item: Item, large: Bool, completion: @escaping (String, UIImage?) -> Void) {
        if let url = item.artworkURL {
            ArtworkLoader.shared.load(url: url) { completion(url.absoluteString, $0) }
        } else if let id = item.artworkID {
            ArtworkLoader.shared.load(id, size: large ? .large : .small) { image, _ in completion(id, image) }
        }
    }

    /// Заголовок раздела; у первого (приветствие) справа — лупа поиска.
    private final class HeaderView: UICollectionReusableView {
        private let label = UILabel()
        private let searchButton = UIButton(type: .system)
        private var onSearch: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textColor = .white
            addSubview(label)
            searchButton.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)), for: .normal)
            searchButton.tintColor = .white
            searchButton.accessibilityLabel = "Поиск"
            searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
            addSubview(searchButton)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ text: String, big: Bool, onSearch: (() -> Void)?) {
            label.text = text
            label.font = .systemFont(ofSize: big ? 26 : 21, weight: .bold)
            self.onSearch = onSearch
            searchButton.isHidden = onSearch == nil
            setNeedsLayout()
        }

        @objc private func searchTapped() { onSearch?() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let buttonSide: CGFloat = 44
            searchButton.frame = CGRect(x: bounds.width - buttonSide - 6, y: (bounds.height - buttonSide) / 2, width: buttonSide, height: buttonSide)
            label.frame = CGRect(x: 16, y: 0, width: max(0, bounds.width - 32 - (searchButton.isHidden ? 0 : buttonSide)), height: bounds.height)
        }
    }

    /// Быстрый доступ: обложка 16:9 сверху, название под ней (у «Понравившихся» — сердце на цветном фоне).
    private final class QuickCell: UICollectionViewCell {
        private let artwork = UIImageView()
        private let titleLabel = UILabel()
        private var artworkKey: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            artwork.clipsToBounds = true
            artwork.layer.cornerRadius = 8
            artwork.tintColor = .white
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.numberOfLines = 2
            contentView.addSubview(artwork)
            contentView.addSubview(titleLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        fileprivate func configure(_ item: Item) {
            titleLabel.text = item.title
            if item.artworkID != nil || item.artworkURL != nil {
                artwork.contentMode = .scaleAspectFill
                artwork.backgroundColor = UIColor(white: 0.2, alpha: 1)
                artwork.image = nil
                artworkKey = MusicHomeViewController.artworkKey(item)
                MusicHomeViewController.loadArtwork(item, large: false) { [weak self] key, image in
                    if self?.artworkKey == key { self?.artwork.image = image }
                }
            } else {
                artworkKey = nil
                artwork.image = UIImage(systemName: item.symbol ?? "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))
                artwork.contentMode = .center
                artwork.backgroundColor = item.symbol == "heart.fill" ? PlayerView.accent : UIColor(white: 0.25, alpha: 1)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = contentView.bounds.width
            let artHeight = (w * 9 / 16).rounded()
            artwork.frame = CGRect(x: 0, y: 0, width: w, height: artHeight)
            titleLabel.frame = CGRect(x: 0, y: artHeight + 4, width: w, height: max(0, contentView.bounds.height - artHeight - 4))
            titleLabel.sizeToFit()
            titleLabel.frame.size.width = w
        }
    }

    /// Карточка: обложка 16:9 (у исполнителя — круглая) и подписи под ней.
    private final class CardCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
        private let artwork = UIImageView()
        /// Меню «Отписаться» — только у исполнителей в «Подписках» и только на самой ячейке: в 1.68 меню на всём
        /// списке совпало с жалобой «на главной ничего не нажимается».
        private var unsubscribe: (() -> Void)?
        private var menu: UIContextMenuInteraction?
        private let placeholder = UIImageView()
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private var artworkKey: String?
        private var round = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            artwork.contentMode = .scaleAspectFill
            artwork.clipsToBounds = true
            artwork.backgroundColor = UIColor(white: 0.16, alpha: 1)
            placeholder.tintColor = UIColor(white: 0.4, alpha: 1)
            placeholder.contentMode = .center
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            titleLabel.textColor = .white
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1)
            [artwork, placeholder, titleLabel, subtitleLabel].forEach { contentView.addSubview($0) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let unsubscribe else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [UIAction(title: "Отписаться", image: UIImage(systemName: "person.badge.minus"),
                                           attributes: .destructive) { _ in unsubscribe() }])
            }
        }

        fileprivate func configure(_ item: Item, large: Bool) {
            unsubscribe = item.unsubscribe
            if unsubscribe != nil, menu == nil {
                let interaction = UIContextMenuInteraction(delegate: self)
                addInteraction(interaction)
                menu = interaction
            } else if unsubscribe == nil, let interaction = menu {
                removeInteraction(interaction)
                menu = nil
            }
            titleLabel.text = item.title
            subtitleLabel.text = item.subtitle
            round = item.round
            titleLabel.textAlignment = round ? .center : .natural
            subtitleLabel.textAlignment = titleLabel.textAlignment
            placeholder.image = UIImage(systemName: item.symbol ?? "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .medium))
            placeholder.isHidden = false
            artwork.image = nil
            artworkKey = MusicHomeViewController.artworkKey(item)
            MusicHomeViewController.loadArtwork(item, large: large) { [weak self] key, image in
                guard let self, self.artworkKey == key, let image else { return }
                self.artwork.image = image
                self.placeholder.isHidden = true
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = contentView.bounds.width
            let artHeight = round ? w : (w * 9 / 16).rounded() // карточки 16:9, исполнители — круг
            artwork.frame = CGRect(x: 0, y: 0, width: w, height: artHeight)
            artwork.layer.cornerRadius = round ? w / 2 : 8
            placeholder.frame = artwork.frame
            titleLabel.frame = CGRect(x: 0, y: artHeight + 6, width: w, height: 18)
            subtitleLabel.frame = CGRect(x: 0, y: artHeight + 25, width: w, height: 16)
        }
    }

    /// Строка трека: обложка слева, название и исполнитель.
    private final class RowCell: UICollectionViewCell {
        private let artwork = UIImageView()
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private var artworkKey: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            artwork.contentMode = .scaleAspectFill
            artwork.clipsToBounds = true
            artwork.layer.cornerRadius = 4
            artwork.backgroundColor = UIColor(white: 0.16, alpha: 1)
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            titleLabel.textColor = .white
            subtitleLabel.font = .systemFont(ofSize: 13)
            subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1)
            [artwork, titleLabel, subtitleLabel].forEach { contentView.addSubview($0) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        fileprivate func configure(_ item: Item) {
            titleLabel.text = item.title
            subtitleLabel.text = item.subtitle
            artwork.image = nil
            artworkKey = MusicHomeViewController.artworkKey(item)
            MusicHomeViewController.loadArtwork(item, large: false) { [weak self] key, image in
                if self?.artworkKey == key { self?.artwork.image = image }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let h = contentView.bounds.height
            let side = h - 4
            artwork.frame = CGRect(x: 0, y: 2, width: (side * 16 / 9).rounded(), height: side) // 16:9
            let x = artwork.frame.maxX + 12
            let w = max(0, contentView.bounds.width - x)
            titleLabel.frame = CGRect(x: x, y: h / 2 - 20, width: w, height: 20)
            subtitleLabel.frame = CGRect(x: x, y: h / 2 + 1, width: w, height: 18)
        }
    }

    /// Пояснение вместо раздела: загрузка, нет входа, пусто.
    private final class MessageCell: UICollectionViewCell {
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.font = .systemFont(ofSize: 15)
            label.textColor = UIColor(white: 0.6, alpha: 1)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ text: String) { label.text = text }
    }
}
