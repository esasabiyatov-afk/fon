import UIKit

/// Своя нижняя панель вкладок. Системный UITabBar на новых iOS рисует иконки выше своей границы,
/// и они налезали на мини-плеер; здесь раскладка целиком наша: 50 pt кнопок + отступ снизу.
final class TabBarView: UIView {
    static let contentHeight: CGFloat = 50

    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private let stack = UIStackView()
    private var buttons: [UIButton] = []
    private var titles: [String] = []
    private var icons: [String] = []
    private var colors: [UIColor?] = []

    init(items: [(title: String, icon: String)]) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.06, alpha: 1)

        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: Self.contentHeight)
        ])

        for (index, item) in items.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            buttons.append(button)
            titles.append(item.title)
            icons.append(item.icon)
            colors.append(nil)
            stack.addArrangedSubview(button)
        }
        buttons.indices.forEach(refresh)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// color — свой цвет иконки и подписи (например, розовая «Музыка»); nil — обычный.
    func setItem(_ index: Int, title: String, icon: String, color: UIColor? = nil) {
        guard buttons.indices.contains(index) else { return }
        titles[index] = title
        icons[index] = icon
        colors[index] = color
        refresh(index)
    }

    func select(_ index: Int) {
        selectedIndex = index
        buttons.indices.forEach(refresh)
    }

    @objc private func tapped(_ sender: UIButton) {
        onSelect?(sender.tag)
    }

    private func refresh(_ index: Int) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icons[index], withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium))
        config.imagePlacement = .top
        config.imagePadding = 3
        var title = AttributedString(titles[index])
        title.font = .systemFont(ofSize: 10, weight: .medium)
        config.attributedTitle = title
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)
        let selected = index == selectedIndex
        config.baseForegroundColor = colors[index] ?? (selected ? .white : UIColor(white: 0.6, alpha: 1))
        buttons[index].configuration = config
        buttons[index].accessibilityTraits = selected ? [.button, .selected] : .button
    }
}
