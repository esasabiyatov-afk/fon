import UIKit

/// Мини-плеер режима музыки в системном месте над панелью вкладок iOS 26 (`UITabAccessory`), как в Apple Music:
/// обложка, название и исполнитель, ⏯ и ⏭. Нажатие или свайп вверх — развернуть, свайп вниз — закрыть.
/// Стекло рисует система; данные — из `PlayerView.onMiniInfo`.
final class MiniAccessoryView: UIView {
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?
    var onCommand: ((String) -> Void)?

    private let artwork = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private var artworkID: String?
    private var paused = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 7
        artwork.layer.cornerCurve = .continuous
        artwork.backgroundColor = UIColor(white: 0.2, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        artistLabel.font = .systemFont(ofSize: 13)
        artistLabel.textColor = .secondaryLabel
        let symbols = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: symbols), for: .normal)
        playButton.tintColor = .label
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: symbols), for: .normal)
        nextButton.tintColor = .label
        nextButton.accessibilityLabel = "Следующий трек"
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        [artwork, titleLabel, artistLabel, playButton, nextButton].forEach { addSubview($0) }

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(expandTapped)))
        let up = UISwipeGestureRecognizer(target: self, action: #selector(expandTapped))
        up.direction = .up
        addGestureRecognizer(up)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(closeSwiped))
        down.direction = .down
        addGestureRecognizer(down)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(id: String?, title: String, artist: String, paused: Bool) {
        if titleLabel.text != title { titleLabel.text = title }
        if artistLabel.text != artist { artistLabel.text = artist }
        if paused != self.paused {
            self.paused = paused
            let symbols = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
            playButton.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill", withConfiguration: symbols), for: .normal)
            playButton.accessibilityLabel = paused ? "Играть" : "Пауза"
        }
        guard let id, id != artworkID else { return }
        artworkID = id
        ArtworkLoader.shared.load(id, size: .small) { [weak self] image, _ in
            guard self?.artworkID == id else { return }
            self?.artwork.image = image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height, w = bounds.width
        let side = max(0, h - 12)
        artwork.frame = CGRect(x: 8, y: 6, width: (side * 16 / 9).rounded(), height: side)
        let button: CGFloat = 40
        nextButton.frame = CGRect(x: w - button - 6, y: (h - button) / 2, width: button, height: button)
        playButton.frame = CGRect(x: nextButton.frame.minX - button, y: (h - button) / 2, width: button, height: button)
        let textX = artwork.frame.maxX + 10
        let textW = max(0, playButton.frame.minX - textX - 4)
        // Узкое место (свёрнутая панель) — только название.
        let twoLines = h >= 44
        artistLabel.isHidden = !twoLines
        titleLabel.frame = twoLines ? CGRect(x: textX, y: h / 2 - 18, width: textW, height: 19)
                                    : CGRect(x: textX, y: 0, width: textW, height: h)
        artistLabel.frame = CGRect(x: textX, y: h / 2 + 1, width: textW, height: 17)
    }

    @objc private func playTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onCommand?("toggle")
    }

    @objc private func nextTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onCommand?("next")
    }

    @objc private func expandTapped() { onExpand?() }
    @objc private func closeSwiped() { onClose?() }
}
