import Foundation

/// App 更新检查与 Release 资产下载共用的无状态网络策略。请求生命周期、文件写入和
/// 取消竞态仍由各自请求类负责，避免为了去重而模糊安全边界。
enum UpdateNetworkPolicy {
    private static let maximumRedirects = 5

    static func makeEphemeralConfiguration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    static func makeReleaseAssetRequest(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("DSD-Pancake-Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func redirectError(
        for proposedURL: URL?,
        expectedInitialURL: URL,
        redirectCount: Int
    ) -> AppReleaseDownloadError? {
        guard redirectCount <= maximumRedirects else {
            return .tooManyRedirects
        }
        guard AppUpdateService.isTrustedReleaseAssetRedirect(
            proposedURL,
            expectedInitialURL: expectedInitialURL
        ) else {
            return .untrustedRedirect(proposedURL?.absoluteString ?? "未知地址")
        }
        return nil
    }

    static func mapNetworkError(_ error: Error) -> AppReleaseDownloadError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           URLError.Code(rawValue: nsError.code) == .timedOut {
            return .requestTimedOut
        }
        return .downloadFailed(error.localizedDescription)
    }
}
