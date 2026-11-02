import UIKit

/// «Жидкое стекло» iOS 26 (просьба владельца по скриншотам Apple Music на iOS 26): панель вкладок капсулой,
/// круглая кнопка поиска, мини-плеер, поле поиска. На iOS 26 — системное стекло `UIGlassEffect`
/// (нужна сборка Xcode 26 — `build.yml` выбирает его, если он есть на машине GitHub); раньше или при сборке
/// старым Xcode — размытие `systemUltraThinMaterialDark` с тонкой светлой обводкой.
enum Glass {
    /// Подложка-стекло со скруглением; содержимое класть в `contentView`.
    static func make(cornerRadius: CGFloat, interactive: Bool = false) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = interactive
            view.effect = glass
            return view
        }
        #endif
        view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        view.clipsToBounds = true
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        view.contentView.backgroundColor = UIColor(white: 0.12, alpha: 0.35)
        return view
    }

    /// Настоящее стекло iOS 26 (иначе — запасное размытие).
    static var isNative: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}
