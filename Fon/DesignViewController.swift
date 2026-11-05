import UIKit

/// Настройщик «Оформление» (просьба владельца после 1.91: «дай мне настройщик плеера, где я могу кастомизировать
/// дизайн»): стиль живого фона (Мягкий/Неон/Чёрный), подложка под кнопками (матовая/глянец/без), ореол обложки,
/// живой фон на остальных экранах. Позади — тот же фон с текущей обложкой, всё меняется сразу (предпросмотр).
/// Открывается кнопкой 🎨 в плеере и из ⚙ «Медиатеки». Только внешний вид — воспроизведение не трогает.
final class DesignViewController: UIViewController {
    private let artwork: UIImage?
    private let backdrop = LiveBackdrop()
    private let preview = UIImageView()
    private let previewHolder = UIView()
    private let panel = GlassPanel()
    /// Стили фона — «чипсы» в прокручиваемой полосе (их семь, в сегменты не влезают).
    private let styleScroll = UIScrollView()
    private var styleChips: [UIButton] = []
    private let panelControl = UISegmentedControl(items: PanelStyle.allCases.map(\.title))
    private let glowSwitch = UISwitch()
    private let everywhereSwitch = UISwitch()
    private let styleNote = UILabel()
    private var glowColor: UIColor?

    init(artwork: UIImage?) {
        self.artwork = artwork
        super.init(nibName: nil, bundle: nil)
        title = tr("Оформление")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if navigationController?.viewControllers.first === self { // открыт из плеера листом, а не из ⚙
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: tr("Готово"), image: nil, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        backdrop.onColors = { [weak self] colors in
            self?.glowColor = colors.first
            self?.panel.setTint(colors.first)
            self?.updateGlow()
        }
        if let artwork {
            backdrop.setImage(artwork)
        } else {
            backdrop.setDefault()
            // Открыто из настроек (ничего не играет прямо сейчас) — для примера берём последний трек из истории.
            if let id = Library.shared.history.first?.id {
                ArtworkLoader.shared.load(id, size: .player) { [weak self] image, _ in
                    guard let self, let image else { return }
                    self.preview.image = image
                    self.backdrop.setImage(image)
                }
            }
        }

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        // Предпросмотр: обложка с ореолом, как в плеере.
        preview.image = artwork
        preview.backgroundColor = UIColor(white: 0.16, alpha: 1)
        preview.contentMode = .scaleAspectFill
        preview.clipsToBounds = true
        preview.layer.cornerRadius = 10
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.addSubview(preview)

        // Настройки — на той самой подложке, которую выбирают.
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.cornerRadius = 26
        card.addSubview(panel)

        let chipRow = UIStackView()
        chipRow.axis = .horizontal
        chipRow.spacing = 8
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        styleScroll.showsHorizontalScrollIndicator = false
        styleScroll.translatesAutoresizingMaskIntoConstraints = false
        styleScroll.addSubview(chipRow)
        for (index, style) in BackdropStyle.allCases.enumerated() {
            let chip = UIButton(type: .system)
            chip.setTitle(style.title, for: .normal)
            chip.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            chip.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            chip.layer.cornerRadius = 17
            chip.addAction(UIAction { [weak self] _ in self?.styleChanged(index) }, for: .touchUpInside)
            chipRow.addArrangedSubview(chip)
            styleChips.append(chip)
        }
        NSLayoutConstraint.activate([
            chipRow.leadingAnchor.constraint(equalTo: styleScroll.contentLayoutGuide.leadingAnchor),
            chipRow.trailingAnchor.constraint(equalTo: styleScroll.contentLayoutGuide.trailingAnchor),
            chipRow.topAnchor.constraint(equalTo: styleScroll.contentLayoutGuide.topAnchor),
            chipRow.bottomAnchor.constraint(equalTo: styleScroll.contentLayoutGuide.bottomAnchor),
            chipRow.heightAnchor.constraint(equalTo: styleScroll.frameLayoutGuide.heightAnchor),
            styleScroll.heightAnchor.constraint(equalToConstant: 36)
        ])
        updateChips()
        panelControl.selectedSegmentIndex = PanelStyle.allCases.firstIndex(of: Settings.panelStyle) ?? 0
        glowSwitch.isOn = Settings.artworkGlow
        everywhereSwitch.isOn = Settings.ambientEverywhere
        for control in [panelControl] {
            control.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.28)
            control.backgroundColor = UIColor(white: 0, alpha: 0.25)
            control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        }
        [glowSwitch, everywhereSwitch].forEach { $0.onTintColor = PlayerView.accent }
        panelControl.addAction(UIAction { [weak self] _ in self?.panelChanged() }, for: .valueChanged)
        glowSwitch.addAction(UIAction { [weak self] _ in
            Settings.artworkGlow = self?.glowSwitch.isOn ?? true
            self?.updateGlow()
        }, for: .valueChanged)
        everywhereSwitch.addAction(UIAction { [weak self] _ in
            Settings.ambientEverywhere = self?.everywhereSwitch.isOn ?? true
        }, for: .valueChanged)

        styleNote.font = .systemFont(ofSize: 13)
        styleNote.textColor = UIColor(white: 1, alpha: 0.6)
        styleNote.numberOfLines = 0
        styleNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rows = UIStackView(arrangedSubviews: [
            header(tr("Фон")), styleScroll, styleNote,
            header(tr("Подложка под кнопками")), panelControl,
            switchRow(tr("Ореол вокруг обложки"), glowSwitch),
            switchRow(tr("Живой фон на всех экранах"), everywhereSwitch)
        ])
        rows.axis = .vertical
        rows.spacing = 10
        rows.setCustomSpacing(18, after: styleNote)
        rows.setCustomSpacing(18, after: panelControl)
        rows.setCustomSpacing(14, after: rows.arrangedSubviews[5])
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)

        let content = UIStackView(arrangedSubviews: [previewHolder, card])
        content.axis = .vertical
        content.spacing = 36
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let guide = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -32),
            // Ширина: по экрану с отступами 24, на iPad — не шире 520. Длинные подписи (английский) сжимаются/переносятся,
            // а не растягивают экран (в английском интерфейсе содержимое выезжало за края).
            content.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24).withPriority(UILayoutPriority(999)),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24).withPriority(UILayoutPriority(999)),
            preview.centerXAnchor.constraint(equalTo: previewHolder.centerXAnchor),
            preview.topAnchor.constraint(equalTo: previewHolder.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewHolder.bottomAnchor),
            preview.widthAnchor.constraint(equalTo: previewHolder.widthAnchor, multiplier: 0.78),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 9.0 / 16),
            panel.topAnchor.constraint(equalTo: card.topAnchor),
            panel.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18)
        ])
        updateNote()
        updatePanel()
        updateGlow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewHolder.layer.shadowPath = UIBezierPath(roundedRect: preview.frame, cornerRadius: 10).cgPath
    }

    private func header(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.65)
        return label
    }

    private func switchRow(_ text: String, _ control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16)
        label.textColor = .white
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        let row = UIStackView(arrangedSubviews: [label, control])
        row.alignment = .center
        row.spacing = 12
        control.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func styleChanged(_ index: Int) {
        guard BackdropStyle.allCases.indices.contains(index) else { return }
        Settings.backdropStyle = BackdropStyle.allCases[index]
        updateChips()
        updateNote()
    }

    private func updateChips() {
        let current = BackdropStyle.allCases.firstIndex(of: Settings.backdropStyle) ?? 0
        for (index, chip) in styleChips.enumerated() {
            let selected = index == current
            chip.backgroundColor = selected ? UIColor(white: 1, alpha: 0.28) : UIColor(white: 0, alpha: 0.25)
            chip.setTitleColor(.white, for: .normal)
        }
    }

    private func panelChanged() {
        let index = panelControl.selectedSegmentIndex
        Settings.panelStyle = PanelStyle.allCases.indices.contains(index) ? PanelStyle.allCases[index] : .matte
        updatePanel()
    }

    private func updateNote() {
        switch Settings.backdropStyle {
        case .soft: styleNote.text = tr("Размытая обложка плавно вращается, мягкие пятна её цветов.")
        case .neon: styleNote.text = tr("Яркие контрастные пятна и лучи на чёрном, цвета переливаются.")
        case .black: styleNote.text = tr("Глубокий чёрный с лёгким свечением — тёмное видео сливается с фоном.")
        case .contour: styleNote.text = tr("Тонкие светящиеся контуры плывут по глубокому чёрному.")
        case .aurora: styleNote.text = tr("Мягкие световые нити, как северное сияние.")
        case .ribbon: styleNote.text = tr("Светящаяся лента плавно изгибается на тёмном фоне.")
        case .haze: styleNote.text = tr("Мягкий туман цвета обложки, как матовое стекло.")
        }
    }

    private func updatePanel() {
        panel.isHidden = Settings.panelStyle == .off
        panel.glossy = Settings.panelStyle == .gloss
        panel.frosted = Settings.panelStyle == .frost
    }

    private func updateGlow() {
        let color = Settings.artworkGlow ? glowColor : nil
        let layer = previewHolder.layer
        layer.shadowColor = (color ?? .black).cgColor
        layer.shadowOpacity = color == nil ? 0.5 : 0.8
        layer.shadowRadius = color == nil ? 20 : 34
        layer.shadowOffset = color == nil ? CGSize(width: 0, height: 10) : .zero
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
