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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData() // свежая «последняя попытка»
    }

    @objc private func nativeChanged() {
        Settings.nativeAudio = nativeSwitch.isOn
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "Воспроизведение" }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        var text = "Экспериментально. В режиме музыки звук играет системный плеер iOS напрямую, без веб-страницы YouTube: "
            + "стабильнее в фоне и на экране блокировки, меньше расход батареи и трафика. "
            + "Если YouTube не отдаст поток, трек сам включится в обычном плеере. "
            + "Включится со следующего трека, который вы откроете."
        if Settings.nativeAudio {
            text += "\n\nПоследняя попытка: " + NativeAudio.lastLog
        }
        return text
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
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
