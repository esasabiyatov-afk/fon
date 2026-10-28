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
    /// Системный плеер для музыки (эксперимент, выключен по умолчанию): звук режима музыки играет
    /// AVPlayer напрямую, без веб-страницы. Не вышло — тот же трек включается в обычном веб-плеере.
    static var nativeAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "nativeAudio") }
        set { UserDefaults.standard.set(newValue, forKey: "nativeAudio") }
    }
}
