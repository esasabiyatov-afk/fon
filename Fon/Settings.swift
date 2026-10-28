import Foundation

/// Общие настройки приложения (живут в UserDefaults).
enum Settings {
    /// Режим музыки: обложка вместо видео, 144p, музыкальная главная, Mix-плейлисты. По умолчанию включён.
    static var musicMode: Bool {
        get { UserDefaults.standard.object(forKey: "musicMode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "musicMode") }
    }
}

extension Settings {
    /// Своя громкость YouTube (0…1), отдельно от громкости телефона: музыку можно сделать тише игры.
    static var youtubeVolume: Double {
        get { UserDefaults.standard.object(forKey: "youtubeVolume") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeVolume") }
    }
}
