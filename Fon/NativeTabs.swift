import UIKit

/// Системная панель вкладок iOS 26 (просьба владельца после 1.84: «стекло же нативно делают»): настоящий
/// `UITabBarController` — плавающая стеклянная капсула, отдельная круглая вкладка поиска (`UISearchTab`)
/// и мини-плеер режима музыки в `bottomAccessory`, как в Apple Music. Только iPhone на iOS 26 и сборка Xcode 26;
/// иначе — своя `TabBarView`.
///
/// Содержимое вкладок у приложения общее (`browseContainer`: окна YouTube и свои экраны) — оно переезжает
/// в пустой экран выбранной вкладки. Нажатия на вкладки система не выполняет сама (`shouldSelectTab` → false):
/// их обрабатывает `MainViewController` (переключатель режима, повторное нажатие, поиск) и потом выбирает вкладку.
protocol SystemTabs: AnyObject {
    var controller: UIViewController { get }
    var onSelect: ((Int) -> Void)? { get set }
    var onSearch: (() -> Void)? { get set }
    /// Сменилась раскладка экрана вкладки (безопасная зона: панель, мини-плеер).
    var onLayout: (() -> Void)? { get set }
    func select(_ index: Int)
    func setItem(_ index: Int, title: String, icon: String)
    func setTint(_ color: UIColor)
    /// Перенести общее содержимое в экран выбранной вкладки.
    func attach(_ content: UIView)
    /// Мини-плеер над панелью (nil — убрать).
    func setAccessory(_ view: UIView?)
    var hasAccessory: Bool { get }
    /// Верх панели (и мини-плеера над ней) в координатах окна.
    var contentBottom: CGFloat { get }
}

enum SystemTabsFactory {
    static func make(items: [(title: String, icon: String)]) -> SystemTabs? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
            return NativeTabs(items: items)
        }
        #endif
        return nil
    }
}

/// Пустой экран вкладки: в него переезжает общее содержимое.
final class TabHostViewController: UIViewController {
    var onLayout: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        onLayout?()
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
final class NativeTabs: NSObject, SystemTabs, UITabBarControllerDelegate {
    private let tabController = UITabBarController()
    private var hosts: [TabHostViewController] = []
    private var items: [UITab] = []
    private var searchTab: UISearchTab!
    private var accessory: UIView?

    var controller: UIViewController { tabController }
    var onSelect: ((Int) -> Void)?
    var onSearch: (() -> Void)?
    var onLayout: (() -> Void)? {
        didSet { hosts.forEach { $0.onLayout = onLayout } }
    }

    init(items list: [(title: String, icon: String)]) {
        super.init()
        for (index, item) in list.enumerated() {
            let host = TabHostViewController()
            hosts.append(host)
            items.append(UITab(title: item.title, image: UIImage(systemName: item.icon), identifier: "tab\(index)") { _ in host })
        }
        let searchHost = TabHostViewController()
        hosts.append(searchHost)
        searchTab = UISearchTab { _ in searchHost }
        tabController.tabs = items + [searchTab]
        tabController.delegate = self
        tabController.overrideUserInterfaceStyle = .dark
        tabController.view.backgroundColor = .black
    }

    private var currentHost: UIViewController {
        tabController.selectedTab?.viewController ?? hosts[0]
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if tab === searchTab {
            onSearch?()
        } else if let index = items.firstIndex(where: { $0 === tab }) {
            onSelect?(index)
        }
        return false // вкладку выберет приложение (`select`) — после своей логики
    }

    func select(_ index: Int) {
        let tab: UITab = items.indices.contains(index) ? items[index] : searchTab
        if tabController.selectedTab !== tab { tabController.selectedTab = tab }
    }

    func setItem(_ index: Int, title: String, icon: String) {
        guard items.indices.contains(index) else { return }
        if items[index].title != title { items[index].title = title }
        items[index].image = UIImage(systemName: icon)
    }

    func setTint(_ color: UIColor) {
        tabController.tabBar.tintColor = color
    }

    func attach(_ content: UIView) {
        let host = currentHost.view!
        guard content.superview !== host else { return }
        content.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(content)
        onLayout?()
    }

    func setAccessory(_ view: UIView?) {
        guard view !== accessory else { return }
        accessory = view
        tabController.bottomAccessory = view.map { UITabAccessory(contentView: $0) }
    }

    var hasAccessory: Bool { accessory != nil }

    var contentBottom: CGFloat {
        let host = currentHost.view!
        let safeLine = host.convert(CGPoint(x: 0, y: host.bounds.height - host.safeAreaInsets.bottom), to: nil).y
        let bar = tabController.tabBar
        let barTop = bar.isHidden ? safeLine : bar.convert(CGPoint.zero, to: nil).y
        var top = min(safeLine, barTop)
        // Если безопасная зона не учла мини-плеер над панелью — отступаем на его высоту сами.
        if accessory != nil, let frame = accessory?.superview?.convert(accessory!.frame, to: nil), frame.height > 0 {
            top = min(top, frame.minY)
        }
        return top
    }
}
#endif
