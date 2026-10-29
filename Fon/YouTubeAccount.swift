import Foundation

/// Какой аккаунт выбран на страницах YouTube: номер входа Google (`SESSION_INDEX` → заголовок `X-Goog-AuthUser`)
/// и канал бренда (`DELEGATED_SESSION_ID` → `X-Goog-PageId` и `context.user.onBehalfOfUser`).
/// Страницы сообщают его скриптом `common`; скрытые запросы приложения (понравившиеся, подборки, подписки,
/// очередь микса) идут от него же. До 1.68 они всегда шли от первого аккаунта — у владельца два аккаунта,
/// и «понравившиеся и рекомендации смешались» (29.10.2026).
enum YouTubeAccount {
    static let didChange = Notification.Name("FonYouTubeAccountDidChange")

    private static let indexKey = "ytSessionIndex"
    private static let pageKey = "ytPageID"

    static var index: String { UserDefaults.standard.string(forKey: indexKey) ?? "0" }
    static var pageID: String? { UserDefaults.standard.string(forKey: pageKey) }

    /// Сообщение страницы `{type: 'account', index, pageId}`.
    static func update(_ body: [String: Any]) {
        let newIndex = (body["index"] as? NSNumber)?.stringValue ?? (body["index"] as? String) ?? "0"
        let newPage = (body["pageId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard newIndex != index || newPage != pageID else { return }
        UserDefaults.standard.set(newIndex, forKey: indexKey)
        UserDefaults.standard.set(newPage, forKey: pageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var headers: [String: String] {
        var result = ["X-Goog-AuthUser": index]
        if let pageID { result["X-Goog-PageId"] = pageID }
        return result
    }

    /// Контекст запроса от имени выбранного канала.
    static func context(_ context: [String: Any]) -> [String: Any] {
        var context = context
        var user = context["user"] as? [String: Any] ?? [:]
        user["onBehalfOfUser"] = pageID
        context["user"] = user
        return context
    }

    /// Для скриптов скрытых окон (`window.__fonAccount`).
    static var script: [String: Any] { ["index": index, "pageId": pageID ?? NSNull()] }
}
