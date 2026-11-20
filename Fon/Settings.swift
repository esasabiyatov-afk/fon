import UIKit
import notify

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
    /// Работает только у системного плеера (у веб-страницы на iPhone громкость не меняется).
    static var youtubeVolume: Double {
        get { UserDefaults.standard.object(forKey: "youtubeVolume") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeVolume") }
    }

    /// Системный плеер для музыки: звук режима музыки играет AVPlayer напрямую, без веб-страницы. С 1.65 включён
    /// по умолчанию (владелец: работает стабильно), выключается в ⚙. Не вышло — трек играет обычный веб-плеер.
    /// Видео вместо обложки в музыкальном плеере (кнопка в углу обложки; владелец: «когда не хочется смотреть видео»).
    static var videoArtwork: Bool {
        get { UserDefaults.standard.object(forKey: "videoArtwork") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "videoArtwork") }
    }

    static var nativeAudio: Bool {
        get { UserDefaults.standard.object(forKey: "nativeAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nativeAudio") }
    }

    /// Свой видеоплеер (SABR): выбранное качество (высота кадра) и скорость — запоминаются.
    static var sabrVideoHeight: Int {
        get { UserDefaults.standard.object(forKey: "sabrVideoHeight") as? Int ?? (UIDevice.current.userInterfaceIdiom == .pad ? 1080 : 720) }
        set { UserDefaults.standard.set(newValue, forKey: "sabrVideoHeight") }
    }

    /// Субтитры своего видеоплеера: код языка выбранной дорожки, "" — выключены, nil — не выбирали.
    static var sabrSubtitles: String? {
        get { UserDefaults.standard.string(forKey: "sabrSubtitles") }
        set { UserDefaults.standard.set(newValue, forKey: "sabrSubtitles") }
    }

    /// Не реагировать на кнопки наушников (просьба владельца: китайские наушники без своего приложения ставили на
    /// паузу от случайного касания). В 1.114 пропускалась только «переключить паузу» — не помогло: эти наушники
    /// шлют обычную «паузу», ту же, что экран блокировки (iOS не говорит, откуда команда). С 1.115 ▶/⏸/⏭/⏮ извне
    /// пропускаются, только когда экран погашен (`skipRemoteNow`) — экран блокировки при горящем экране работает.
    /// Долгое нажатие (Siri) обрабатывает сама iOS — приложению оно не приходит.
    static var ignoreHeadphoneTap: Bool {
        get { UserDefaults.standard.bool(forKey: "ignoreHeadphoneTap") }
        set {
            UserDefaults.standard.set(newValue, forKey: "ignoreHeadphoneTap")
            NotificationCenter.default.post(name: headphonesChanged, object: nil)
        }
    }

    static let headphonesChanged = Notification.Name("FonHeadphonesChanged")

    /// Пропускать ли кнопку извне прямо сейчас: функция включена (по умолчанию выкл.) и экран погашен. Кнопки экрана
    /// блокировки нажимают при горящем экране, а случайные касания наушников — в кармане (владелец после 1.114:
    /// «делай с погашенным экраном»). Не узнали, погашен ли экран, — не пропускаем.
    static var skipRemoteNow: Bool {
        ignoreHeadphoneTap && ScreenState.isBlank == true
    }
}

/// Погашен ли экран — служебный сигнал SpringBoard `com.apple.springboard.hasBlankedScreen` (1 — погашен).
/// Для App Store не годится, для Fon на SideStore — да; может перестать работать в новой iOS (тогда nil).
enum ScreenState {
    private static let name = "com.apple.springboard.hasBlankedScreen"
    private static var token: Int32 = {
        var token: Int32 = 0
        return notify_register_check(name, &token) == 0 ? token : -1
    }()

    static var isBlank: Bool? {
        guard token >= 0 else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == 0 else { return nil }
        return state != 0
    }

    /// Экран погас или включился — сообщаем (`Settings.headphonesChanged`: веб-плееру обновить флаг).
    static func startWatching() {
        var watch: Int32 = 0
        _ = notify_register_dispatch(name, &watch, DispatchQueue.main) { _ in
            NotificationCenter.default.post(name: Settings.headphonesChanged, object: nil)
        }
    }
}

extension Settings {
    static var sabrVideoSpeed: Float {
        get { UserDefaults.standard.object(forKey: "sabrVideoSpeed") as? Float ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "sabrVideoSpeed") }
    }
}

/// Оформление плеера и фона (настройщик «Оформление», просьба владельца после 1.91: «дай мне настройщик плеера,
/// где я могу кастомизировать дизайн»). Меняется сразу (`designChanged`), на воспроизведение не влияет.
enum BackdropStyle: Int, CaseIterable {
    /// Мягкий: размытая обложка вращается, пятна её цветов плывут медленно (фон 1.89).
    case soft = 0
    /// Неон: яркие контрастные пятна и лучи на глубоком чёрном, перелив цветов.
    case neon = 1
    /// Чёрный: почти чёрный фон с едва заметным свечением — тёмное видео «выходит» за рамку.
    case black = 2
    /// Туман: мягкий матовый туман цвета обложки, как матовое стекло.
    case haze = 6

    var title: String {
        switch self {
        case .soft: return tr("Мягкий")
        case .neon: return tr("Неон")
        case .black: return tr("Чёрный")
        case .haze: return tr("Туман")
        }
    }
}

enum PanelStyle: Int, CaseIterable {
    case matte = 0, gloss = 1
    /// Светлое матовое стекло, как карточки на референсах владельца.
    case frost = 3
    case off = 2

    var title: String {
        switch self {
        case .matte: return tr("Матовое")
        case .gloss: return tr("Глянец")
        case .off: return tr("Без")
        case .frost: return tr("Светлое")
        }
    }
}

extension Settings {
    static let designChanged = Notification.Name("FonDesignChanged")

    static var backdropStyle: BackdropStyle {
        get { BackdropStyle(rawValue: UserDefaults.standard.integer(forKey: "backdropStyle")) ?? .soft }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "backdropStyle"); notifyDesign() }
    }

    /// Подложка под названием и кнопками плеера: нет / матовое стекло / глянец (владелец после 1.91:
    /// «убери-ка этот глянец или оставь как тему» — по умолчанию матовое, глянец — на выбор).
    static var panelStyle: PanelStyle {
        get { PanelStyle(rawValue: UserDefaults.standard.integer(forKey: "panelStyle")) ?? .matte }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "panelStyle"); notifyDesign() }
    }

    /// Светящийся ореол цвета трека вокруг обложки/видео.
    static var artworkGlow: Bool {
        get { UserDefaults.standard.object(forKey: "artworkGlow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "artworkGlow"); notifyDesign() }
    }

    /// Живой фон и на остальных своих экранах (главная, медиатека, ленты).
    static var ambientEverywhere: Bool {
        get { UserDefaults.standard.object(forKey: "ambientEverywhere") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ambientEverywhere"); notifyDesign() }
    }

    private static func notifyDesign() {
        NotificationCenter.default.post(name: designChanged, object: nil)
    }
}
