import UIKit

/// «Понравившиеся» в облаке: приватный плейлист «Fon — музыка» в аккаунте YouTube.
/// Запросы идут из скрытого окна m.youtube.com (`HiddenPage.youtube`, тот же вход в Google)
/// через внутренний API YouTube — скрипт `Scripts.cloud`. Список держим в памяти:
/// ♡ отвечает сразу, а запрос уходит следом (при ошибке — откат и сообщение).
final class CloudLikes {
    static let shared = CloudLikes()
    static let didChange = Notification.Name("FonCloudLikesDidChange")
    /// object — текст ошибки для пользователя.
    static let didFail = Notification.Name("FonCloudLikesDidFail")

    private(set) var tracks: [Track] = []
    private(set) var loaded = false
    private(set) var lastError: String?

    private var playlistID: String? {
        get { UserDefaults.standard.string(forKey: "cloudPlaylistID") }
        set { UserDefaults.standard.set(newValue, forKey: "cloudPlaylistID") }
    }

    private var refreshCompletions: [() -> Void]?
    private var migrating = false

    /// Последний список с YouTube хранится на телефоне — «Понравившиеся» и ♡ видны сразу при запуске.
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("likes.json")

    private init() {
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = saved
        }
        // Выбран другой аккаунт YouTube — свой плейлист «Fon — музыка» у каждого.
        NotificationCenter.default.addObserver(forName: YouTubeAccount.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.playlistID = nil
            self.tracks = []
            self.loaded = false
            self.saveCache()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            self.refresh()
        }
    }

    private func saveCache() {
        let snapshot = tracks
        let url = cacheURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    func isLiked(_ id: String) -> Bool { tracks.contains { $0.id == id } }

    /// Ссылка, чтобы играть «Понравившиеся» как настоящий плейлист YouTube, начиная с трека.
    func playURL(startingAt id: String) -> URL? {
        guard let pid = playlistID else { return nil }
        var components = URLComponents(string: "https://m.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: id), URLQueryItem(name: "list", value: pid)]
        return components.url
    }

    func start(in view: UIView) {
        HiddenPage.youtube.start(in: view)
        refresh()
    }

    // MARK: - Операции

    func refresh(completion: (() -> Void)? = nil) {
        // Обновление уже в очереди — просто дождаться его.
        if refreshCompletions != nil {
            if let completion { refreshCompletions?.append(completion) }
            return
        }
        refreshCompletions = completion.map { [$0] } ?? []
        call("__fonCloud.list(pid)", { ["pid": self.playlistID ?? NSNull()] }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let dict = value as? [String: Any] ?? [:]
                if let pid = dict["playlistId"] as? String { self.playlistID = pid }
                let raw = dict["tracks"] as? [[String: Any]] ?? []
                self.tracks = raw.compactMap { item in
                    guard let id = item["id"] as? String else { return nil }
                    let clean = TrackTitle.clean(title: item["title"] as? String ?? "", artist: item["artist"] as? String ?? "")
                    return Track(id: id, title: clean.title, artist: clean.artist)
                }
                self.loaded = true
                self.lastError = nil
                self.saveCache()
                self.migrateLegacyLikes()
            case .failure(let error):
                self.lastError = Self.describe(error)
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            let completions = self.refreshCompletions ?? []
            self.refreshCompletions = nil
            completions.forEach { $0() }
        }
    }

    func setLiked(_ track: Track, _ liked: Bool) {
        guard liked != isLiked(track.id) else { return }
        let before = tracks
        if liked { tracks.append(track) } else { tracks.removeAll { $0.id == track.id } }
        NotificationCenter.default.post(name: Self.didChange, object: nil)

        let js = liked ? "__fonCloud.like(pid, [id])" : "__fonCloud.unlike(pid, id)"
        call(js, { ["pid": self.playlistID ?? NSNull(), "id": track.id] }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                if let pid = value as? String { self.playlistID = pid }
                defer { self.saveCache() }
                // Обновление списка из очереди могло прийти раньше и затереть ♡ — вернуть его.
                if liked != self.isLiked(track.id) {
                    if liked { self.tracks.append(track) } else { self.tracks.removeAll { $0.id == track.id } }
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                }
            case .failure(let error):
                self.tracks = before
                self.lastError = Self.describe(error)
                NotificationCenter.default.post(name: Self.didChange, object: nil)
                NotificationCenter.default.post(name: Self.didFail, object: self.lastError)
            }
        }
    }

    /// Лайки из прошлых версий (хранились на телефоне) — один раз переносим в облачный плейлист.
    private func migrateLegacyLikes() {
        guard !migrating else { return }
        let missing = Library.shared.legacyLiked.filter { !isLiked($0.id) }
        guard !missing.isEmpty else {
            if !Library.shared.legacyLiked.isEmpty { Library.shared.clearLegacyLiked() }
            return
        }
        migrating = true
        call("__fonCloud.like(pid, ids)", { ["pid": self.playlistID ?? NSNull(), "ids": missing.map(\.id)] }) { [weak self] result in
            guard let self else { return }
            self.migrating = false
            guard case .success(let value) = result else { return }
            if let pid = value as? String { self.playlistID = pid }
            Library.shared.clearLegacyLiked()
            self.refresh()
        }
    }

    private func call(_ expression: String, _ arguments: @escaping () -> [String: Any],
                      completion: @escaping (Result<Any, Error>) -> Void) {
        HiddenPage.youtube.call(expression, arguments, completion: completion)
    }

    static func isSignedOut(_ error: Error) -> Bool {
        let message = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
        return message.contains("signed-out")
    }

    static func describe(_ error: Error) -> String {
        if isSignedOut(error) {
            return "Войдите в аккаунт Google: режим «Видео» → вкладка «Вы». Понравившиеся хранятся в вашем плейлисте YouTube."
        }
        return "Не удалось связаться с YouTube. Проверьте интернет и попробуйте ещё раз."
    }
}
