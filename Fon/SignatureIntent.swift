import AppIntents

/// Действие для «Команд»: сколько целых дней осталось до конца подписи Fon (просьба владельца:
/// автоматизация каждый день, а Refresh All в SideStore — только когда осталось ≤ 3 дней).
/// SideStore продлевает все приложения разом, так что срок Fon подходит для всех.
/// Подписи нет (сборка без embedded.mobileprovision) — 0, чтобы автоматизация продлила.
struct SignatureDaysLeftIntent: AppIntent {
    static var title: LocalizedStringResource = "Дней до конца подписи Fon"
    static var description = IntentDescription("Сколько целых дней осталось до конца подписи Fon. Продлевает SideStore → Refresh All.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let days = Signature.expiration.map { max(0, Int($0.timeIntervalSinceNow / 86400)) } ?? 0
        return .result(value: days)
    }
}
