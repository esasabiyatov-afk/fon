import Foundation
import Security

/// Журнал системного плеера → комментарий в обсуждении GitHub (esasabiyatov-afk/fon#1), откуда его сразу
/// читает Claude (просьба владельца 29.10.2026: «логи в реальном времени», как раньше через GitHub).
/// Токен (fine-grained, только этот репозиторий, Issues: Read and write) владелец вставляет в настройках —
/// он хранится в Keychain телефона, в приложение не зашит (сборки лежат в открытых Releases).
/// Репозиторий публичный — ссылки из журнала вычищаются (в ссылках googlevideo есть IP-адрес).
enum LogUploader {
    static let repo = "esasabiyatov-afk/fon"
    static let issue = 1
    private static let service = "com.personal.fon"
    private static let account = "github-log-token"

    /// Как прошла последняя отправка — видно в настройках.
    static var lastStatus = ""

    static var enabled: Bool { token != nil }

    static var token: String? {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // отправка и в фоне
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func send(_ text: String) {
        guard let token, !text.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repo)/issues/\(issue)/comments") else { return }
        let body = "```\n" + String(sanitize(text).prefix(60000)) + "\n```"
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["body": body])
        URLSession.shared.dataTask(with: request) { _, reply, error in
            let code = (reply as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                lastStatus = code == 201 ? "последний отправлен" : (error != nil ? "нет сети" : "ошибка \(code)")
            }
        }.resume()
    }

    /// Ссылки — только хост (без пути и параметров: там IP-адрес и подписи).
    static func sanitize(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(blob:)?https?://([^/\\s;,)]+)[^\\s;,)]*") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1<$2>")
    }
}
