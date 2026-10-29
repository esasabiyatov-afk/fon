import UIKit
import AVFoundation
import Security

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Кэш сети побольше: подсказки поиска, обложки YouTube Music и т. п. не качаются заново.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024, directory: nil)
        // Журнал отладки убран в 1.69 — стираем его следы (тексты попыток и токен GitHub в Keychain).
        UserDefaults.standard.removeObject(forKey: "nativeAudioLog")
        UserDefaults.standard.removeObject(forKey: "nativeAudioLogHistory")
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.personal.fon",
                       kSecAttrAccount as String: "github-log-token"] as CFDictionary)
        // Категория .playback + UIBackgroundModes=audio в Info.plist —
        // это разрешение iOS играть звук, когда приложение свёрнуто.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// Окно приложения. Через сцену iPad позволяет растянуть окно на весь экран и менять его размер.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = MainViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
