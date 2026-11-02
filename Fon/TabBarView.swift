import UIKit

/// Своя нижняя панель вкладок в стиле iOS 26 (просьба владельца по скриншотам Apple Music): плавающая
/// стеклянная капсула с вкладками (выбранная — на светлой «таблетке») и рядом круглая стеклянная кнопка поиска.
/// Лента прокручивается под стеклом. Вне капсулы и кнопки касания проходят насквозь (к ленте).
/// Системный UITabBar не используем: на новых iOS он рисовал иконки выше своей границы и налезал на мини-плеер.
final class TabBarView: UIView {
    /// Высота области над безопасной зоной снизу (капсула может заходить в безопасную зону у полоски «домой»).
    static let contentHeight: CGFloat = 58

    var onSelect: ((Int) -> Void)?
    var onSearch: (() -> Void)?
    private(set) var selectedIndex = 0
    /// Цвет выбранной вкладки: в режиме музыки — красный, как в Apple Music.
    var selectedColor: UIColor = .white { didSet { buttons.indices.forEach(refresh) } }

    private let capsule = Glass.make(cornerRadius: 30)
    private let searchCircle = Glass.make(cornerRadius: 30, interactive: true)
    private let searchButton = UIButton(type: .system)
    private let pill = UIView()
    private var buttons: [UIButton] = []
    private var titles: [String] = []
    private var icons: [String] = []
    private var colors: [UIColor?] = []

    init(items: [(title: String, icon: String)]) {
        super.init(frame: .zero)
        backgroundColor = .clear

        addSubview(capsule)
        pill.backgroundColor = UIColor(white: 1, alpha: 0.13)
        pill.layer.cornerCurve = .continuous
        capsule.contentView.addSubview(pill)

        for (index, item) in items.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            buttons.append(button)
            titles.append(item.title)
            icons.append(item.icon)
            colors.append(nil)
            capsule.contentView.addSubview(button)
        }

        addSubview(searchCircle)
        searchButton.setImage(UIImage(systemName: "magnifyingglass",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)), for: .normal)
        searchButton.tintColor = .white
        searchButton.accessibilityLabel = "Поиск"
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        searchCircle.contentView.addSubview(searchButton)

        buttons.indices.forEach(refresh)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Верх капсулы в своих координатах — над ним мини-плеер и низ ленты.
    var capsuleTop: CGFloat { capsule.frame.minY }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaInsets
        // У полоски «домой» капсула заходит в безопасную зону, как в iOS 26; без неё — отступ 8.
        let bottomGap = safe.bottom > 0 ? max(8, safe.bottom - 14) : 8
        let height = min(60, bounds.height - bottomGap - 2)
        let y = bounds.height - bottomGap - height
        let left = safe.left + 16, right = safe.right + 16
        let spacing: CGFloat = 10
        // На iPad и в альбомной — не во всю ширину, а по центру.
        let available = bounds.width - left - right - height - spacing
        let width = min(available, 520)
        let x = left + (available - width) / 2
        capsule.frame = CGRect(x: x, y: y, width: width, height: height)
        capsule.layer.cornerRadius = height / 2
        searchCircle.frame = CGRect(x: capsule.frame.maxX + spacing, y: y, width: height, height: height)
        searchCircle.layer.cornerRadius = height / 2
        searchButton.frame = searchCircle.bounds

        let inset: CGFloat = 4
        let itemWidth = (width - inset * 2) / CGFloat(max(1, buttons.count))
        for (i, button) in buttons.enumerated() {
            button.frame = CGRect(x: inset + CGFloat(i) * itemWidth, y: inset, width: itemWidth, height: height - inset * 2)
        }
        placePill()
    }

    private func placePill() {
        guard buttons.indices.contains(selectedIndex) else { pill.alpha = 0; return }
        pill.alpha = 1
        pill.frame = buttons[selectedIndex].frame
        pill.layer.cornerRadius = pill.bounds.height / 2
    }

    /// Касания — только капсуле и кнопке поиска; остальное место панели прозрачно для ленты.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        capsule.frame.insetBy(dx: -4, dy: -6).contains(point) || searchCircle.frame.insetBy(dx: -4, dy: -6).contains(point)
    }

    /// color — свой цвет иконки и подписи (например, розовая «Музыка»); nil — обычный.
    func setItem(_ index: Int, title: String, icon: String, color: UIColor? = nil) {
        guard buttons.indices.contains(index) else { return }
        titles[index] = title
        icons[index] = icon
        colors[index] = color
        refresh(index)
    }

    /// Индекс вне вкладок (например, открыт поиск) — «таблетка» прячется.
    func select(_ index: Int) {
        let changed = index != selectedIndex
        selectedIndex = index
        buttons.indices.forEach(refresh)
        guard changed, window != nil else { placePill(); return }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.placePill()
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        onSelect?(sender.tag)
    }

    @objc private func searchTapped() {
        onSearch?()
    }

    private func refresh(_ index: Int) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icons[index], withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        config.imagePlacement = .top
        config.imagePadding = 2
        var title = AttributedString(titles[index])
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        config.attributedTitle = title
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0)
        let selected = index == selectedIndex
        config.baseForegroundColor = colors[index] ?? (selected ? selectedColor : UIColor(white: 0.92, alpha: 1))
        buttons[index].configuration = config
        buttons[index].accessibilityTraits = selected ? [.button, .selected] : .button
    }
}
