import Foundation

public enum WebNavigationDecision: Equatable, Sendable {
    case allowInWebView
    case openInDefaultBrowser
    case cancelAndExplain(String)
}

public struct WebNavigationPolicy: Sendable {
    public let localOrigin: URL

    public init(localOrigin: URL = LocalService.url) {
        self.localOrigin = localOrigin
    }

    public func decision(
        for url: URL,
        isMainFrame: Bool,
        isUserInitiated: Bool
    ) -> WebNavigationDecision {
        guard isMainFrame else {
            return .allowInWebView
        }

        if isSameLocalOrigin(url) {
            return .allowInWebView
        }

        guard isUserInitiated else {
            return .cancelAndExplain("已阻止非用户触发的外部跳转。")
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .cancelAndExplain("已阻止未知协议的外部跳转。")
        }

        return .openInDefaultBrowser
    }

    public func isSameLocalOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == localOrigin.scheme?.lowercased()
            && url.host?.lowercased() == localOrigin.host?.lowercased()
            && url.port == localOrigin.port
    }
}
