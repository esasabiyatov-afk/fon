import Foundation

/// Общие настройки приложения (живут в UserDefaults).
enum Settings {
    /// Режим музыки: обложка вместо видео, 144p, музыкальная главная, Mix-плейлисты. По умолчанию включён.
    static var musicMode: Bool {
        get { UserDefaults.standard.object(forKey: "musicMode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "musicMode") }
    }
}
