import UIKit

/// Что показывает «Далее»: очередь системного плеера или обычного плеера YouTube.
protocol UpNextSource: AnyObject {
    var currentTrack: Track? { get }
    var upcoming: [Track] { get }
    func rawTitle(for trackID: String) -> String?
    func playUpcoming(at offset: Int)
    func canRemoveUpcoming(at offset: Int) -> Bool
    func removeUpcoming(at offset: Int)
    func insertUpcoming(_ track: Track, at offset: Int)
    func playNow(_ track: Track)
}

extension NativeAudio: UpNextSource {
    func canRemoveUpcoming(at offset: Int) -> Bool { true }
}

enum UpNext {
    /// Системный плеер играет — его очередь, иначе — очередь обычного плеера YouTube.
    static var source: UpNextSource { NativeAudio.shared.active ? NativeAudio.shared : WebQueue.shared }
}

/// «Далее» для обычного плеера YouTube в режиме музыки (на iPad системный плеер недоступен — YouTube отдаёт
/// только SABR; просьба владельца после 1.82: «такие же списки и другие версии»). Очередь = свои добавленные
/// треки (играют первыми, по порядку) + список YouTube на странице (микс `RD…` или плейлист — через `next`).
/// Свои треки включает страница: за секунду до конца трека (`__fon.setQueue`, сообщение `queueTook`).
final class WebQueue: UpNextSource {
    static let shared = WebQueue()

    /// Выполнить JS на странице плеера (ставит `PlayerView`).
    var runJS: ((String) -> Void)?

    private(set) var currentTrack: Track?
    private var rawTitles: [String: String] = [:]
    private var inserted: [Track] = []
    private var pageList: [Track] = []
    private var listID: String?
    private var loadingKey: String?
    private var listenedSince: Date?

    var upcoming: [Track] {
        let ids = Set(inserted.map(\.id))
        var rest: [Track] = []
        if let id = currentTrack?.id, let i = pageList.firstIndex(where: { $0.id == id }) {
            rest = Array(pageList[(i + 1)...])
        } else {
            rest = pageList
        }
        return inserted + rest.filter { !ids.contains($0.id) && $0.id != currentTrack?.id }
    }

    func rawTitle(for trackID: String) -> String? { rawTitles[trackID] }

    /// Состояние страницы (раз в секунду, пока приложение открыто).
    func update(track: Track, rawTitle: String, url: URL?) {
        rawTitles[track.id] = rawTitle
        let list = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "list" }?.value }
        let changed = currentTrack?.id != track.id
        currentTrack = track
        if changed {
            listenedSince = Date()
            // Начал играть свой трек — убираем его из своих (страница могла не успеть сообщить).
            if let i = inserted.firstIndex(where: { $0.id == track.id }) { inserted.remove(at: i); syncPage() }
            notify()
        }
        // Другие версии — заранее, после 3 с игры, как у системного плеера.
        if let since = listenedSince, Date().timeIntervalSince(since) >= 3 {
            listenedSince = nil
            TrackVersions.prepare(track, rawTitle: rawTitle)
        }
        // Список YouTube: загрузить, если сменился или текущего трека в нём нет.
        let listKey = list ?? "RD\(track.id)"
        let inList = pageList.contains { $0.id == track.id }
        if (listKey != listID || !inList) && loadingKey != listKey + track.id {
            loadingKey = listKey + track.id
            let videoID = track.id
            Task { @MainActor in
                let tracks = await YouTubeStreams.queue(videoID: videoID, playlistID: listKey)
                self.loadingKey = nil
                guard !tracks.isEmpty else { return }
                self.listID = listKey
                self.pageList = tracks
                self.notify()
            }
        }
    }

    /// Страница сама включила наш трек.
    func took(_ id: String) {
        if let i = inserted.firstIndex(where: { $0.id == id }) { inserted.remove(at: i) }
        notify()
    }

    func playUpcoming(at offset: Int) {
        let list = upcoming
        guard list.indices.contains(offset) else { return }
        let track = list[offset]
        if let i = inserted.firstIndex(where: { $0.id == track.id }) { inserted.remove(at: i); syncPage() }
        play(track.id)
    }

    func canRemoveUpcoming(at offset: Int) -> Bool { offset < inserted.count }

    func removeUpcoming(at offset: Int) {
        guard inserted.indices.contains(offset) else { return }
        inserted.remove(at: offset)
        syncPage()
        notify()
    }

    func insertUpcoming(_ track: Track, at offset: Int) {
        guard track.id != currentTrack?.id else { return }
        inserted.removeAll { $0.id == track.id }
        inserted.insert(track, at: min(inserted.count, max(0, offset)))
        syncPage()
        notify()
    }

    /// Другая версия — сразу; список YouTube остаётся прежним.
    func playNow(_ track: Track) {
        inserted.removeAll { $0.id == track.id }
        syncPage()
        play(track.id)
    }

    private func play(_ id: String) {
        runJS?("window.__fon && __fon.playID && __fon.playID(\(Self.quoted(id)))")
    }

    private func syncPage() {
        let ids = inserted.map { Self.quoted($0.id) }.joined(separator: ",")
        runJS?("window.__fon && __fon.setQueue && __fon.setQueue([\(ids)])")
    }

    /// Страница загрузилась заново — передать ей свою очередь ещё раз.
    func pageReloaded() { syncPage() }

    private func notify() {
        NotificationCenter.default.post(name: NativeAudio.queueDidChange, object: nil)
    }

    private static func quoted(_ id: String) -> String {
        "'" + id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } + "'"
    }
}
