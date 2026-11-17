import Foundation
import UIKit

/// Журнал событий приложения для диагностики (владелец после 1.105: «пусть собирает и другие данные — как работает
/// приложение, функции, какие ответы получает; пригодится для доработок»). Только на телефоне: последние 400 строк
/// в памяти и в `Caches/journal.txt` (переживает перезапуск); наружу уходит только когда владелец сам скопирует
/// диагностику. Без cookies, токенов и адресов потоков — только что произошло и чем закончилось.
enum AppJournal {
    private static let lock = NSLock()
    private static var lines: [String] = load()
    private static var dirty = false
    private static let limit = 400

    private static let file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("journal.txt")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm:ss"
        return formatter
    }()

    /// Записать событие (любой поток).
    static func add(_ text: String) {
        let line = formatter.string(from: Date()) + "  " + text.replacingOccurrences(of: "\n", with: " ")
        lock.lock()
        lines.append(String(line.prefix(500)))
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        let schedule = !dirty
        dirty = true
        lock.unlock()
        // Пишем на диск не чаще раза в 5 с.
        if schedule { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { save() } }
    }

    static var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    static func save() {
        lock.lock()
        let text = lines.joined(separator: "\n")
        dirty = false
        lock.unlock()
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func load() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(limit).map { $0 }
    }

    /// Запуск, уход в фон, возврат, нехватка памяти, звонки и наушники — без участия остального кода.
    /// Когда запущено приложение (для «работает N мин» в диагностике).
    private(set) static var launchedAt = Date()

    static func startWatching() {
        launchedAt = Date()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        add("— запуск Fon \(version), \(UIDevice.current.model) \(UIDevice.current.systemVersion)")
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in add("приложение открыто") }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in add("приложение свёрнуто"); save() }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in add("приложение закрывается"); save() }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in add("iOS: мало памяти") }
        center.addObserver(forName: AVAudioSessionNotifications.interruption, object: nil, queue: nil) { note in
            let type = (note.userInfo?["AVAudioSessionInterruptionTypeKey"] as? UInt) == 1 ? "началось" : "закончилось"
            add("звук прерван (звонок и т. п.): \(type)")
        }
        center.addObserver(forName: AVAudioSessionNotifications.routeChange, object: nil, queue: nil) { note in
            let reason = note.userInfo?["AVAudioSessionRouteChangeReasonKey"] as? UInt ?? 0
            add("звук: смена выхода (причина \(reason))")
        }
    }
}

/// Имена уведомлений аудиосессии без импорта AVFoundation в каждый файл.
private enum AVAudioSessionNotifications {
    static let interruption = Notification.Name("AVAudioSessionInterruptionNotification")
    static let routeChange = Notification.Name("AVAudioSessionRouteChangeNotification")
}
