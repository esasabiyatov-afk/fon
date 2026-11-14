import UIKit

/// Настройки приложения (⚙ в «Медиатеке»). Пока одна: системный плеер для музыки.
final class SettingsViewController: UITableViewController {
    private let nativeSwitch = UISwitch()

    init() {
        super.init(style: .insetGrouped)
        title = tr("Настройки")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .clear // виден живой фон, как на остальных экранах (владелец после 1.96)
        nativeSwitch.onTintColor = PlayerView.accent
        nativeSwitch.isOn = Settings.nativeAudio
        nativeSwitch.addTarget(self, action: #selector(nativeChanged), for: .valueChanged)
    }

    @objc private func nativeChanged() {
        Settings.nativeAudio = nativeSwitch.isOn
        // Переключили — значит, хотят попробовать снова: забываем «только SABR» (иначе ждать до 6 ч).
        UserDefaults.standard.removeObject(forKey: "sabrOnlyUntil")
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? tr("Воспроизведение") : (section == 1 ? tr("Внешний вид") : tr("О приложении"))
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section != 2 else { return nil }
        guard section == 0 else { return tr("Фон, подложка под кнопками и ореол обложки. Также — кнопкой 🎨 в плеере.") }
        return tr("В режиме музыки звук играет системный плеер iOS напрямую, без веб-страницы YouTube: ")
            + tr("стабильнее в фоне и на экране блокировки. ")
            + tr("Только с ним работает ползунок громкости в плеере (музыку можно сделать тише игры). ")
            + tr("Если YouTube не отдаст поток, трек сам включится в обычном плеере. ")
            + tr("Включится со следующего трека, который вы откроете.")
            + unavailableNote
    }

    /// YouTube не дал этому телефону обычной ссылки (только свой протокол SABR) — Fon тихо играет обычным плеером.
    /// Пишем это здесь, чтобы было видно, почему системного плеера нет (жалоба владельца: на iPhone 17 его нет).
    private var unavailableNote: String {
        guard Settings.nativeAudio, NativeAudio.shared.sabrOnly,
              let until = UserDefaults.standard.object(forKey: "sabrOnlyUntil") as? Date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: until)
        let reason = UserDefaults.standard.string(forKey: "sabrOnlyReason").map { "\n\n" + $0 } ?? ""
        return AppLanguage.current == .en
            ? "\n\nNot available on this device right now: YouTube gives it the stream only in its own format (SABR), so music plays in the regular player. Fon will try again after \(time), or turn the switch off and on to try now." + reason
            : "\n\nСейчас на этом телефоне недоступен: YouTube отдаёт ему поток только в своём формате (SABR), поэтому музыка играет в обычном плеере. Fon попробует снова после \(time) — или выключите и включите переключатель, чтобы попробовать сейчас." + reason
    }

    /// Проба SABR (`SabrProbe`): ~30 с, потом текст с кнопкой «Скопировать» — владелец присылает его.
    private func runSabrProbe() {
        let videoID = NativeAudio.shared.currentTrack?.id ?? "dQw4w9WgXcQ"
        let waiting = UIAlertController(title: "Проверяю SABR…", message: "Около 30 секунд. Не закрывайте экран.", preferredStyle: .alert)
        present(waiting, animated: true)
        let host: UIView = view.window ?? view
        Task { [weak self] in
            let text = await SabrProbe.run(videoID: videoID, in: host)
            await MainActor.run {
                waiting.dismiss(animated: true) {
                    let alert = UIAlertController(title: "Проверка SABR", message: text, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: tr("Скопировать"), style: .default) { _ in UIPasteboard.general.string = text })
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                    self?.present(alert, animated: true)
                }
            }
        }
    }

    /// Язык интерфейса: Авто / Русский / English — после перезапуска.
    private func chooseLanguage() {
        let sheet = UIAlertController(title: tr("Язык"), message: tr("Применится после перезапуска приложения."), preferredStyle: .actionSheet)
        for language in AppLanguage.allCases {
            sheet.addAction(UIAlertAction(title: language.title, style: .default) { [weak self] _ in
                Settings.language = language
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: tr("Отмена"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = CGRect(x: tableView.bounds.midX, y: tableView.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0, indexPath.row == 1 {
            runSabrProbe()
        } else if indexPath.section == 1 {
            if indexPath.row == 0 {
                navigationController?.pushViewController(DesignViewController(artwork: nil), animated: true)
            } else {
                chooseLanguage()
            }
        } else if indexPath.section == 2 {
            if indexPath.row == 0 {
                navigationController?.pushViewController(AboutViewController(), animated: true)
            } else {
                UIApplication.shared.open(AboutViewController.repoURL)
            }
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 2 {
            content.text = indexPath.row == 0 ? tr("О приложении") : tr("Исходный код на GitHub")
            content.image = UIImage(systemName: indexPath.row == 0 ? "info.circle" : "chevron.left.forwardslash.chevron.right")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 1, alpha: 0.08)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if indexPath.section == 1 && indexPath.row == 1 {
            content.text = tr("Язык")
            content.secondaryText = Settings.language.title
            content.image = UIImage(systemName: "globe")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 1, alpha: 0.08)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if indexPath.section == 1 {
            content.text = tr("Оформление плеера")
            content.image = UIImage(systemName: "paintpalette")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 1, alpha: 0.08)
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if indexPath.row == 1 {
            content.text = "Проверить SABR"
            content.secondaryText = "проба для iPad/iPhone без системного плеера"
            content.image = UIImage(systemName: "stethoscope")
            content.imageProperties.tintColor = PlayerView.accent
            cell.contentConfiguration = content
            cell.backgroundColor = UIColor(white: 1, alpha: 0.08)
            return cell
        }
        content.text = tr("Системный плеер для музыки")
        content.image = UIImage(systemName: "waveform")
        content.imageProperties.tintColor = PlayerView.accent
        cell.contentConfiguration = content
        cell.backgroundColor = UIColor(white: 1, alpha: 0.08)
        cell.selectionStyle = .none
        cell.accessoryView = nativeSwitch
        return cell
    }
}
