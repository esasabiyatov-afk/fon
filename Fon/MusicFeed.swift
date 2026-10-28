import UIKit

/// Карточка YouTube Music: трек, микс, альбом, плейлист или исполнитель.
struct MusicItem: Codable, Hashable {
    let title: String
    let subtitle: String
    let thumb: URL?
    let videoId: String?
    let playlistId: String?
    let params: String?
    let browseId: String?
    let artist: Bool

    init(title: String, subtitle: String, thumb: URL?, videoId: String?, playlistId: String? = nil,
         params: String? = nil, browseId: String? = nil, artist: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.thumb = thumb
        self.videoId = videoId
        self.playlistId = playlistId
        self.params = params
        self.browseId = browseId
        self.artist = artist
    }

    init?(_ dict: [String: Any]) {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        self.init(title: title, subtitle: dict["subtitle"] as? String ?? "",
                  thumb: (dict["thumb"] as? String).flatMap(URL.init(string:)),
                  videoId: dict["videoId"] as? String, playlistId: dict["playlistId"] as? String,
                  params: dict["params"] as? String, browseId: dict["browseId"] as? String,
                  artist: dict["artist"] as? Bool ?? false)
    }

    /// Для JS — обратно в словарь (NSNull вместо nil).
    var dictionary: [String: Any] {
        ["title": title, "videoId": videoId ?? NSNull(), "playlistId": playlistId ?? NSNull(),
         "params": params ?? NSNull(), "browseId": browseId ?? NSNull()]
    }
}

/// Полка главной YouTube Music: «Быстрый выбор» (треки), «Миксы для вас» (карточки), исполнители.
struct MusicShelf: Codable {
    enum Kind: String, Codable { case songs, cards, artists }
    let title: String
    let kind: Kind
    let items: [MusicItem]
}

/// Рекомендации и подписки режима музыки — из YouTube Music того же аккаунта Google
/// (`HiddenPage.music`, скрипт `Scripts.music`). Последний ответ хранится на диске — главная
/// открывается сразу, а свежие подборки подгружаются следом.
final class MusicFeed {
    static let shared = MusicFeed()
    static let didChange = Notification.Name("FonMusicFeedDidChange")

    private struct Cache: Codable {
        var shelves: [MusicShelf] = []
        var homeDate: Date?
        var artists: [MusicItem] = []
        var releases: [MusicItem] = []
        var subscriptionsDate: Date?
    }

    private var cache = Cache()
    private let fileURL: URL
    private var homeCompletions: [() -> Void]?
    private var subscriptionsCompletions: [() -> Void]?

    private(set) var homeError: String?
    private(set) var subscriptionsError: String?
    private(set) var signedOut = false

    var shelves: [MusicShelf] { cache.shelves }
    var artists: [MusicItem] { cache.artists }
    /// Новые треки исполнителей из подписок.
    var releases: [MusicItem] { cache.releases }
    var subscriptionsLoaded: Bool { cache.subscriptionsDate != nil }
    var isLoadingHome: Bool { homeCompletions != nil }
    var isLoadingSubscriptions: Bool { subscriptionsCompletions != nil }

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("music-feed.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = saved
        }
    }

    func start(in view: UIView) {
        HiddenPage.music.start(in: view)
    }

    // MARK: - Главная

    /// force — по жесту «потянуть вниз»; иначе не чаще раза в 30 минут.
    func loadHome(force: Bool = false, completion: (() -> Void)? = nil) {
        if !force, let date = cache.homeDate, Date().timeIntervalSince(date) < 30 * 60, !cache.shelves.isEmpty {
            completion?()
            return
        }
        if homeCompletions != nil {
            if let completion { homeCompletions?.append(completion) }
            return
        }
        homeCompletions = completion.map { [$0] } ?? []
        notify()
        HiddenPage.music.call("__fonMusic.home()", { [:] }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let dict = value as? [String: Any] ?? [:]
                let shelves = Self.parseShelves(dict["shelves"])
                if !shelves.isEmpty {
                    self.cache.shelves = shelves
                    self.cache.homeDate = Date()
                    self.save()
                }
                self.homeError = shelves.isEmpty ? "Подборки YouTube Music не загрузились." : nil
            case .failure(let error):
                self.homeError = CloudLikes.describe(error)
            }
            let completions = self.homeCompletions ?? []
            self.homeCompletions = nil
            self.notify()
            completions.forEach { $0() }
        }
    }

    private static func parseShelves(_ raw: Any?) -> [MusicShelf] {
        (raw as? [[String: Any]] ?? []).compactMap { shelf in
            let items = (shelf["items"] as? [[String: Any]] ?? []).compactMap(MusicItem.init)
            guard !items.isEmpty else { return nil }
            let kind = MusicShelf.Kind(rawValue: shelf["kind"] as? String ?? "") ?? .cards
            return MusicShelf(title: shelf["title"] as? String ?? "", kind: kind, items: items)
        }
    }

    // MARK: - Подписки

    /// Исполнители из подписок (YouTube Music) и их новые видео из ленты подписок YouTube.
    func loadSubscriptions(force: Bool = false, completion: (() -> Void)? = nil) {
        if !force, let date = cache.subscriptionsDate, Date().timeIntervalSince(date) < 15 * 60 {
            completion?()
            return
        }
        if subscriptionsCompletions != nil {
            if let completion { subscriptionsCompletions?.append(completion) }
            return
        }
        subscriptionsCompletions = completion.map { [$0] } ?? []
        notify()
        HiddenPage.music.call("__fonMusic.artists()", { [:] }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let artists = (value as? [[String: Any]] ?? []).compactMap(MusicItem.init)
                self.signedOut = false
                if artists.isEmpty {
                    self.finishSubscriptions(artists: [], releases: [])
                } else {
                    self.loadReleases(of: artists)
                }
            case .failure(let error):
                self.signedOut = CloudLikes.isSignedOut(error)
                self.subscriptionsError = CloudLikes.describe(error)
                self.finishSubscriptions(artists: nil, releases: nil)
            }
        }
    }

    /// Лента подписок YouTube, только видео ваших исполнителей (по id канала или по имени).
    private func loadReleases(of artists: [MusicItem]) {
        let ids = Set(artists.compactMap(\.browseId))
        let names = Set(artists.map { Self.normalized($0.title) })
        HiddenPage.youtube.call("__fonCloud.subscriptionVideos(4)", { [:] }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let releases: [MusicItem] = (value as? [[String: Any]] ?? []).compactMap { video in
                    guard let id = video["id"] as? String else { return nil }
                    let channel = video["channel"] as? String ?? ""
                    let channelId = video["channelId"] as? String ?? ""
                    guard ids.contains(channelId) || names.contains(Self.normalized(channel)) else { return nil }
                    let clean = TrackTitle.clean(title: video["title"] as? String ?? "", artist: channel)
                    let published = video["published"] as? String ?? ""
                    return MusicItem(title: clean.title,
                                     subtitle: [clean.artist, published].filter { !$0.isEmpty }.joined(separator: " · "),
                                     thumb: nil, videoId: id)
                }
                self.finishSubscriptions(artists: artists, releases: releases)
            case .failure(let error):
                self.subscriptionsError = CloudLikes.describe(error)
                self.finishSubscriptions(artists: artists, releases: nil)
            }
        }
    }

    private func finishSubscriptions(artists: [MusicItem]?, releases: [MusicItem]?) {
        if let artists {
            cache.artists = artists
            cache.subscriptionsDate = Date()
        }
        if let releases {
            cache.releases = releases
            subscriptionsError = nil
        }
        save()
        let completions = subscriptionsCompletions ?? []
        subscriptionsCompletions = nil
        notify()
        completions.forEach { $0() }
    }

    /// «Taylor Swift», «TaylorSwiftVEVO», «Taylor Swift - Topic» → «taylorswift».
    private static func normalized(_ name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: " - topic", with: "")
        for junk in ["vevo", "official", " ", ".", "_", "-"] { s = s.replacingOccurrences(of: junk, with: "") }
        return s
    }

    // MARK: - Включить карточку

    /// Ссылка для плеера: трек — с его плейлистом или Mix; альбом и плейлист — с первого трека;
    /// исполнитель — его радио.
    func resolve(_ item: MusicItem, completion: @escaping (URL?) -> Void) {
        if let id = item.videoId {
            completion(item.playlistId != nil ? YouTubeLinks.watch(id, list: item.playlistId) : YouTubeLinks.mix(id))
            return
        }
        HiddenPage.music.call("__fonMusic.resolve(item)", { ["item": item.dictionary] }) { result in
            guard case .success(let value) = result, let dict = value as? [String: Any],
                  let id = dict["videoId"] as? String else {
                completion(nil)
                return
            }
            completion(YouTubeLinks.watch(id, list: dict["playlistId"] as? String))
        }
    }

    // MARK: -

    private func save() {
        let snapshot = cache
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
