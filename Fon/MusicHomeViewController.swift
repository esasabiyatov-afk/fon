import UIKit

/// Главная режима музыки — подборки в стиле Spotify: быстрый доступ, «Миксы для вас»
/// (Mix YouTube по исполнителям, которых вы слушаете и лайкаете), «Недавно слушали», «Понравившиеся».
final class MusicHomeViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    var onPlay: PlayHandler?
    var onOpenLikes: (() -> Void)?
    var onOpenFeed: (() -> Void)?
    var onSearch: (() -> Void)?

    fileprivate enum Style { case quick, large, small }

    fileprivate struct Item {
        let title: String
        let subtitle: String
        let artworkID: String?
        let symbol: String?
        let action: () -> Void
    }

    fileprivate struct Section {
        let title: String
        let style: Style
        let items: [Item]
    }

    private var sections: [Section] = []
    private var collectionView: UICollectionView!

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
        collectionView.register(HeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        view.addSubview(collectionView)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: CloudLikes.didChange, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    func scrollToTop() {
        collectionView?.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    // MARK: - Подборки

    @objc private func reload() {
        guard isViewLoaded else { return }
        sections = buildSections()
        collectionView.reloadData()
    }

    private func buildSections() -> [Section] {
        let likes = Array(CloudLikes.shared.tracks.reversed()) // новые лайки — первыми
        let history = Library.shared.history
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

        var quick: [Item] = [Item(title: "Понравившиеся", subtitle: "", artworkID: nil, symbol: "heart.fill") { [weak self] in
            self?.onOpenLikes?()
        }]
        if let seed = history.first ?? likes.first {
            quick.append(Item(title: "Мой микс", subtitle: "", artworkID: seed.id, symbol: nil) { [weak self] in
                if let url = YouTubeLinks.myMix(seed: seed.id) { self?.onPlay?(url, "Мой микс", nil) }
            })
        }
        for track in history.prefix(6 - quick.count) {
            quick.append(mixItem(track, title: track.title))
        }
        if history.isEmpty && likes.isEmpty {
            quick.append(Item(title: "Лента YouTube: музыка", subtitle: "", artworkID: nil, symbol: "play.rectangle.on.rectangle") { [weak self] in
                self?.onOpenFeed?()
            })
        }
        result.append(Section(title: Self.greeting(), style: .quick, items: quick))

        if !seeds.isEmpty {
            result.append(Section(title: "Миксы для вас", style: .large, items: seeds.map { seed in
                Item(title: "Микс: \(seed.artist)", subtitle: "\(seed.title) и похожие", artworkID: seed.id, symbol: nil) { [weak self] in
                    if let url = YouTubeLinks.mix(seed.id) { self?.onPlay?(url, "Микс: \(seed.artist)", nil) }
                }
            }))
        }
        if !history.isEmpty {
            result.append(Section(title: "Недавно слушали", style: .small, items: history.prefix(20).map { mixItem($0, title: $0.title) }))
        }
        if !likes.isEmpty {
            let ids = CloudLikes.shared.tracks.map(\.id)
            result.append(Section(title: "Понравившиеся", style: .small, items: likes.prefix(20).map { track in
                Item(title: track.title, subtitle: track.artist, artworkID: track.id, symbol: nil) { [weak self] in
                    if let url = CloudLikes.shared.playURL(startingAt: track.id) { self?.onPlay?(url, "Понравившиеся", ids) }
                }
            }))
        }
        if !(history.isEmpty && likes.isEmpty) {
            result.append(Section(title: "Ещё", style: .quick, items: [
                Item(title: "Лента YouTube: музыка", subtitle: "", artworkID: nil, symbol: "play.rectangle.on.rectangle") { [weak self] in
                    self?.onOpenFeed?()
                }
            ]))
        }
        return result
    }

    /// Трек и похожие на него (Mix YouTube).
    private func mixItem(_ track: Track, title: String) -> Item {
        Item(title: title, subtitle: track.artist, artworkID: track.id, symbol: nil) { [weak self] in
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
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, self.sections.indices.contains(index) else { return nil }
            let section: NSCollectionLayoutSection
            switch self.sections[index].style {
            case .quick:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalHeight(1)))
                item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(56)), subitems: [item])
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 8
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 24, trailing: 12)
            case .large, .small:
                let side: CGFloat = self.sections[index].style == .large ? 160 : 132
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side + 46)), subitems: [item])
                section = NSCollectionLayoutSection(group: group)
                section.orthogonalScrollingBehavior = .continuous
                section.interGroupSpacing = 14
                section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16)
            }
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(self.sections[index].style == .quick && index == 0 ? 56 : 40)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
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
        if section.style == .quick {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "quick", for: indexPath) as! QuickCell
            cell.configure(item)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! CardCell
        cell.configure(item, large: section.style == .large)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! HeaderView
        let first = indexPath.section == 0
        header.configure(sections[indexPath.section].title, big: first, onSearch: first ? { [weak self] in self?.onSearch?() } : nil)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sections[indexPath.section].items[indexPath.item].action()
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

    private final class QuickCell: UICollectionViewCell {
        private let artwork = UIImageView()
        private let titleLabel = UILabel()
        private var artworkID: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.backgroundColor = UIColor(white: 0.14, alpha: 1)
            contentView.layer.cornerRadius = 6
            contentView.clipsToBounds = true
            artwork.contentMode = .scaleAspectFill
            artwork.clipsToBounds = true
            artwork.tintColor = .white
            titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
            titleLabel.textColor = .white
            titleLabel.numberOfLines = 2
            contentView.addSubview(artwork)
            contentView.addSubview(titleLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        fileprivate func configure(_ item: Item) {
            titleLabel.text = item.title
            artworkID = item.artworkID
            if let id = item.artworkID {
                artwork.image = nil
                artwork.contentMode = .scaleAspectFill
                artwork.backgroundColor = UIColor(white: 0.2, alpha: 1)
                ArtworkLoader.shared.load(id, size: .small) { [weak self] image, _ in
                    guard self?.artworkID == id else { return }
                    self?.artwork.image = image
                }
            } else {
                artwork.image = UIImage(systemName: item.symbol ?? "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold))
                artwork.contentMode = .center
                artwork.backgroundColor = item.symbol == "heart.fill" ? PlayerView.accent : UIColor(white: 0.25, alpha: 1)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let h = contentView.bounds.height
            artwork.frame = CGRect(x: 0, y: 0, width: h, height: h)
            titleLabel.frame = CGRect(x: h + 10, y: 0, width: max(0, contentView.bounds.width - h - 16), height: h)
        }
    }

    private final class CardCell: UICollectionViewCell {
        private let artwork = UIImageView()
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private var artworkID: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            artwork.contentMode = .scaleAspectFill
            artwork.clipsToBounds = true
            artwork.layer.cornerRadius = 8
            artwork.backgroundColor = UIColor(white: 0.16, alpha: 1)
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            titleLabel.textColor = .white
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1)
            [artwork, titleLabel, subtitleLabel].forEach { contentView.addSubview($0) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        fileprivate func configure(_ item: Item, large: Bool) {
            titleLabel.text = item.title
            subtitleLabel.text = item.subtitle
            artworkID = item.artworkID
            artwork.image = nil
            guard let id = item.artworkID else { return }
            ArtworkLoader.shared.load(id, size: large ? .large : .small) { [weak self] image, _ in
                guard self?.artworkID == id else { return }
                self?.artwork.image = image
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = contentView.bounds.width
            artwork.frame = CGRect(x: 0, y: 0, width: w, height: w)
            titleLabel.frame = CGRect(x: 0, y: w + 6, width: w, height: 18)
            subtitleLabel.frame = CGRect(x: 0, y: w + 25, width: w, height: 16)
        }
    }
}
