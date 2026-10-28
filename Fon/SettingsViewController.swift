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

    override func numberOfSections(in tableView: UITableView) -> Int { Settings.nativeAudio ? 2 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : 2 }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        if indexPath.row == 1 { return askToken() }
        // Журнал — в буфер обмена: владелец вставляет его в чат (ссылки и номера видео целиком, без скриншотов).
        UIPasteboard.general.string = NativeAudio.fullLog
        let alert = UIAlertController(title: "Журнал скопирован", message: "Вставьте его в чат.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Воспроизведение" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else {
            var text = "«Скопировать» — текущая и 10 прошлых попыток одним текстом. «На GitHub» — итог каждой попытки сразу "
                + "уходит в обсуждение репозитория (#\(LogUploader.issue)), Claude читает его без скриншотов. Репозиторий "
                + "публичный: ссылки вычищаются, номера видео остаются."
            if !LogUploader.lastStatus.isEmpty { text += "\n\nGitHub: " + LogUploader.lastStatus }
            return text
        }
        var text = "Экспериментально. В режиме музыки звук играет системный плеер iOS напрямую, без веб-страницы YouTube: "
            + "стабильнее в фоне и на экране блокировки, меньше расход батареи и трафика. "
            + "Только с ним работает ползунок громкости в плеере (музыку можно сделать тише игры). "
            + "Если YouTube не отдаст поток, трек сам включится в обычном плеере. "
            + "Включится со следующего трека, который вы откроете."
        if Settings.nativeAudio {
            text += "\n\nПоследняя попытка: " + NativeAudio.lastLog
        }
        return text
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 && indexPath.row == 1 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = "Журнал на GitHub"
            content.secondaryText = LogUploader.enabled ? "вкл" : "выкл"
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if indexPath.section == 1 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = "Скопировать журнал"
            content.textProperties.color = PlayerView.accent
            content.image = UIImage(systemName: "doc.on.doc")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 0.1, alpha: 1)
            return cell
        }
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

    /// Токен GitHub для журнала: вставить (сохранится в Keychain) или пусто — выключить.
    private func askToken() {
        let alert = UIAlertController(title: "Журнал на GitHub",
                                      message: "Вставьте токен GitHub (fine-grained, только репозиторий fon, Issues: Read and write). "
                                        + "Хранится только на этом телефоне.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "github_pat_…"
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            guard !value.isEmpty else { return }
            LogUploader.token = value
            LogUploader.send("Журнал включён (проверка связи)")
            self?.tableView.reloadData()
        })
        if LogUploader.enabled {
            alert.addAction(UIAlertAction(title: "Выключить", style: .destructive) { [weak self] _ in
                LogUploader.token = nil
                self?.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }
}
