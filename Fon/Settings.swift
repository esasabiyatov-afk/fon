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
}

/// Оформление плеера и фона (настройщик «Оформление», просьба владельца после 1.91: «дай мне настройщик плеера,
/// где я могу кастомизировать дизайн»). Меняется сразу (`designChanged`), на воспроизведение не влияет.
enum BackdropStyle: Int, CaseIterable {
    /// Мягкий: размытая обложка вращается, пятна её цветов плывут медленно (фон 1.89).
    case soft
    /// Неон: яркие контрастные пятна и лучи на глубоком чёрном, перелив цветов.
    case neon
    /// Чёрный: почти чёрный фон с едва заметным свечением — тёмное видео «выходит» за рамку.
    case black
    /// Контур: тонкие светящиеся линии-контуры плывут по глубокому чёрному (референсы владельца: «шёлк» с голубой каймой).
    case contour
    /// Аврора: много тонких световых нитей, как северное сияние.
    case aurora
    /// Лента: светящаяся лента волной.
    case ribbon
    /// Туман: мягкий матовый туман цвета обложки, как матовое стекло.
    case haze

    var title: String {
        switch self {
        case .soft: return tr("Мягкий")
        case .neon: return tr("Неон")
        case .black: return tr("Чёрный")
        case .contour: return tr("Контур")
        case .aurora: return tr("Аврора")
        case .ribbon: return tr("Лента")
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
