import UIKit
import WebKit

enum WebViewFactory {
    /// Оба окна (лента и плеер) используют одно хранилище — вход в аккаунт общий.
    static func make(scripts: [String], handler: WKScriptMessageHandler) -> WKWebView {
        let contentController = WKUserContentController()
        for source in scripts {
            contentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        contentController.add(WeakScriptHandler(handler), name: "fon")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.websiteDataStore = .default()
        if #available(iOS 15.4, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent()
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }

    /// User-Agent обычного Safari, чтобы Google пускал войти в аккаунт.
    static func safariUserAgent() -> String {
        let version = UIDevice.current.systemVersion
        let parts = version.split(separator: ".")
        let short = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : "\(parts.first ?? "17").0"
        let underscored = version.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(underscored) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(short) Mobile/15E148 Safari/604.1"
    }

    static let internalHosts = ["youtube.com", "youtu.be", "google.com", "gstatic.com", "googleusercontent.com", "ytimg.com"]

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// Общие правила переходов: свои схемы (youtube://) блокируем, чужие сайты — в Safari.
    static func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data"].contains(scheme) { return .cancel }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if isMainFrame, action.navigationType == .linkActivated, !isInternal(url) {
            UIApplication.shared.open(url)
            return .cancel
        }
        return .allow
    }
}

/// Обёртка, чтобы WKUserContentController не держал контроллер в памяти вечно.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
