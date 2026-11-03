import UIKit

/// Настройки приложения (⚙ в «Медиатеке»). Пока одна: системный плеер для музыки.
final class SettingsViewController: UITableViewController {
    private let nativeSwitch = UISwitch()

    init() {
        super.init(style: .insetGrouped)
        title = "Настройки"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .black
        nativeSwitch.onTintColor = PlayerView.accent
        nativeSwitch.isOn = Settings.nativeAudio
        nativeSwitch.addTarget(self, action: #selector(nativeChanged), for: .valueChanged)
    }

    @objc private func nativeChanged() {
        Settings.nativeAudio = nativeSwitch.isOn
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Воспроизведение" : "Внешний вид"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return "Фон, подложка под кнопками и ореол обложки. Также — кнопкой 🎨 в плеере." }
        return "В режиме музыки звук играет системный плеер iOS напрямую, без веб-страницы YouTube: "
            + "стабильнее в фоне и на экране блокировки. "
            + "Только с ним работает ползунок громкости в плеере (музыку можно сделать тише игры). "
            + "Если YouTube не отдаст поток, трек сам включится в обычном плеере. "
            + "Включится со следующего трека, который вы откроете."
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        navigationController?.pushViewController(DesignViewController(artwork: nil), animated: true)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 1 {
            content.text = "Оформление плеера"
            content.image = UIImage(systemName: "paintpalette")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        content.text = "Системный плеер для музыки"
        content.image = UIImage(systemName: "waveform")
        content.imageProperties.tintColor = PlayerView.accent
        cell.contentConfiguration = content
        cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
        cell.selectionStyle = .none
        cell.accessoryView = nativeSwitch
        return cell
    }
}
