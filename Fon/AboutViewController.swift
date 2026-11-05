import UIKit

/// «О приложении» (просьба владельца): кто сделал, как и для чего. Текст на русском и английском (`AppLanguage`).
final class AboutViewController: UIViewController {
    static let repoURL = URL(string: "https://github.com/esasabiyatov-afk/fon")!

    private var isEnglish: Bool { AppLanguage.current == .en }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("О приложении")
        view.backgroundColor = .clear
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: tr("Готово"), image: nil, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let name = UILabel()
        name.text = "Fon"
        name.font = .systemFont(ofSize: 34, weight: .bold)
        name.textColor = .white

        let version = UILabel()
        let info = Bundle.main.infoDictionary
        version.text = "\(tr("Версия")) \(info?["CFBundleShortVersionString"] as? String ?? "")"
        version.font = .systemFont(ofSize: 15)
        version.textColor = UIColor(white: 1, alpha: 0.6)

        let body = UILabel()
        body.numberOfLines = 0
        body.font = .systemFont(ofSize: 16)
        body.textColor = UIColor(white: 1, alpha: 0.9)
        body.text = isEnglish ? Self.english : Self.russian

        let link = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = tr("Исходный код на GitHub")
        config.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
        config.imagePadding = 8
        config.baseBackgroundColor = PlayerView.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        link.configuration = config
        link.addAction(UIAction { _ in UIApplication.shared.open(Self.repoURL) }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [name, version, body, link])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(22, after: version)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let guide = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    private static let russian = """
    Fon — неофициальный музыкальный плеер для YouTube с открытым кодом.

    Разработчик: esasabiyatov-afk.

    Я не программист, а обычный пользователь, которому захотелось своё приложение для музыки. \
    Fon сделан с помощью ИИ (Claude) для личного пользования, а потом выложен как открытый проект — \
    берите код, меняйте и делайте свои версии (лицензия MIT).

    Проект не связан с Google и YouTube и не одобрен ими. YouTube — товарный знак Google LLC. \
    Приложение поставляется «как есть», без гарантий; используйте его на свой риск и с учётом правил сервисов.
    """

    private static let english = """
    Fon is an unofficial open-source music player for YouTube.

    Developer: esasabiyatov-afk.

    I'm not a programmer — just an ordinary user who wanted a music app of their own. \
    Fon was built with the help of AI (Claude) for personal use and then published as an open-source project — \
    take the code, change it and make your own versions (MIT license).

    The project is not affiliated with or endorsed by Google or YouTube. YouTube is a trademark of Google LLC. \
    The app is provided “as is”, without warranty; use it at your own risk and in line with the terms of the services you use.
    """
}
