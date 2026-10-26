import UIKit
import MediaPlayer

/// Название, обложка и кнопки на экране блокировки, в Пункте управления и на наушниках.
final class NowPlayingController {
    var onCommand: ((String, Double?) -> Void)?

    private var currentTitle: String?
    private var artworkURL: String?
    private var artwork: MPMediaItemArtwork?
    private var lastInfo: [String: Any] = [:]

    init() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.onCommand?("play", nil); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onCommand?("pause", nil); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onCommand?("toggle", nil); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onCommand?("next", nil); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onCommand?("prev", nil); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onCommand?("seek", event.positionTime)
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    func update(from state: [String: Any]) {
        // Если видео нет (например, ты на главной), оставляем последний трек на экране блокировки.
        guard state["active"] as? Bool == true else { return }

        let title = state["title"] as? String ?? "YouTube"
        let artist = state["artist"] as? String ?? ""
        let duration = (state["duration"] as? NSNumber)?.doubleValue ?? 0
        let time = (state["time"] as? NSNumber)?.doubleValue ?? 0
        let paused = state["paused"] as? Bool ?? true
        let rate = (state["rate"] as? NSNumber)?.doubleValue ?? 1
        let artURL = state["artwork"] as? String ?? ""

        if title != currentTitle {
            currentTitle = title
            artwork = nil
        }
        if artURL != artworkURL {
            artworkURL = artURL
            artwork = nil
            loadArtwork(artURL)
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        lastInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkURL == urlString else { return }
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = art
                self.lastInfo[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.lastInfo
            }
        }.resume()
    }
}
