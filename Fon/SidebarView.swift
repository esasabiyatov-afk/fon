import UIKit

/// Боковая панель на iPad в режиме музыки — как в Apple Music (просьба владельца после 1.77): заголовок, поле поиска,
/// разделы с красными значками, выбранный — на подложке; внизу — переход в режим видео. Те же вкладки, что у
/// нижней панели (`TabBarView`), и те же номера; номер `items.count` — поиск.
final class SidebarView: UIView {
    static let width: CGFloat = 260

    var onSelect: ((Int) -> Void)?
    var onSearch: (() -> Void)?

    private let titleLabel = UILabel()
    private let searchRow = UIButton(type: .system)
    private let line = UIView()
    private var rows: [UIButton] = []
    private var titles: [String]
    private var icons: [String]
    private let modeIndex: Int
    private var selectedIndex = 0

    init(items: [(title: String, icon: String)], modeIndex: Int) {
        titles = items.map(\.title)
        icons = items.map(\.icon)
        self.modeIndex = modeIndex
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 1)

        titleLabel.text = "Fon"
        titleLabel.font = .systemFont(ofSize: 30, weight: .heavy)
        titleLabel.textColor = .white
        addSubview(titleLabel)

        searchRow.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        searchRow.contentHorizontalAlignment = .leading
        addSubview(searchRow)

        for index in items.indices {
            let row = UIButton(type: .system)
            row.tag = index
            row.contentHorizontalAlignment = .leading
            row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            rows.append(row)
            addSubview(row)
        }
        line.backgroundColor = UIColor(white: 1, alpha: 0.08)
        addSubview(line)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Подпись и значок раздела (у переключателя режима — свои, см. `refresh`).
    func setItem(_ index: Int, title: String, icon: String) {
        guard rows.indices.contains(index) else { return }
        titles[index] = title
        icons[index] = icon
        refresh()
    }

    func select(_ index: Int) {
        selectedIndex = index
        refresh()
    }

    @objc private func rowTapped(_ sender: UIButton) { onSelect?(sender.tag) }
    @objc private func searchTapped() { onSearch?() }

    private func refresh() {
        var search = UIButton.Configuration.plain()
        search.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        search.imagePadding = 8
        var searchTitle = AttributedString("Поиск")
        searchTitle.font = .systemFont(ofSize: 16)
        search.attributedTitle = searchTitle
        search.baseForegroundColor = UIColor(white: 0.6, alpha: 1)
        search.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        search.background.backgroundColor = selectedIndex == rows.count ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 1, alpha: 0.1)
        search.background.cornerRadius = 10
        searchRow.configuration = search

        for (index, row) in rows.enumerated() {
            // Боковая панель есть только в режиме музыки: переключатель ведёт в режим видео.
            let isMode = index == modeIndex
            let selected = index == selectedIndex && !isMode
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: isMode ? "play.rectangle" : icons[index],
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            config.imagePadding = 12
            config.imageColorTransformer = UIConfigurationColorTransformer { _ in isMode ? UIColor(white: 0.6, alpha: 1) : PlayerView.accent }
            var title = AttributedString(isMode ? "Режим видео" : titles[index])
            title.font = .systemFont(ofSize: 17, weight: selected ? .semibold : .regular)
            config.attributedTitle = title
            config.baseForegroundColor = isMode ? UIColor(white: 0.6, alpha: 1) : .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            config.background.backgroundColor = selected ? UIColor(white: 1, alpha: 0.12) : .clear
            config.background.cornerRadius = 10
            row.configuration = config
            row.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let top = safeAreaInsets.top
        let x: CGFloat = 12
        titleLabel.frame = CGRect(x: 20, y: top + 14, width: w - 40, height: 40)
        searchRow.frame = CGRect(x: x, y: titleLabel.frame.maxY + 12, width: w - x * 2, height: 38)
        var y = searchRow.frame.maxY + 18
        for (index, row) in rows.enumerated() where index != modeIndex {
            row.frame = CGRect(x: x, y: y, width: w - x * 2, height: 44)
            y += 46
        }
        if rows.indices.contains(modeIndex) {
            rows[modeIndex].frame = CGRect(x: x, y: bounds.height - max(safeAreaInsets.bottom, 12) - 52, width: w - x * 2, height: 44)
        }
        line.frame = CGRect(x: w - 0.5, y: 0, width: 0.5, height: bounds.height)
    }
}
