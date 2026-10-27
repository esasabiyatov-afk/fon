import UIKit

/// Срок подписи приложения: с бесплатным Apple ID — 7 дней, потом Fon перестаёт открываться.
/// Дату берём из embedded.mobileprovision, который SideStore/iloader кладут в приложение при подписи.
enum Signature {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()

    /// «до 3 ноября, 14:20» — для подписи в медиатеке.
    static var untilText: String? {
        guard let expiration else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return "Подпись Fon действует до \(formatter.string(from: expiration))"
    }

    /// «1 д 5 ч» / «7 ч».
    static func leftText(_ seconds: TimeInterval) -> String {
        let hours = max(0, Int(seconds / 3600))
        return hours >= 24 ? "\(hours / 24) д \(hours % 24) ч" : "\(max(1, hours)) ч"
    }

    private static let warnedKey = "signatureWarnedAt"

    /// Меньше двух суток до конца подписи — напоминаем (не чаще раза в 12 часов) и предлагаем открыть SideStore.
    static func warnIfNeeded(from presenter: UIViewController) {
        guard let expiration, presenter.presentedViewController == nil else { return }
        let left = expiration.timeIntervalSinceNow
        guard left > 0, left < 48 * 3600 else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: warnedKey) as? Date, Date().timeIntervalSince(last) < 12 * 3600 { return }
        defaults.set(Date(), forKey: warnedKey)

        let alert = UIAlertController(
            title: "Подпись скоро закончится",
            message: "Через \(leftText(left)) Fon перестанет открываться. Включите LocalDevVPN, откройте SideStore и нажмите Refresh All — плейлисты и вход сохранятся.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Позже", style: .cancel))
        alert.addAction(UIAlertAction(title: "Открыть SideStore", style: .default) { [weak presenter] _ in
            guard let url = URL(string: "sidestore://") else { return }
            UIApplication.shared.open(url) { opened in
                guard !opened, let presenter else { return }
                let missing = UIAlertController(title: "SideStore не найден",
                                                message: "Продлите Fon через iloader на компьютере.",
                                                preferredStyle: .alert)
                missing.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(missing, animated: true)
            }
        })
        presenter.present(alert, animated: true)
    }
}
