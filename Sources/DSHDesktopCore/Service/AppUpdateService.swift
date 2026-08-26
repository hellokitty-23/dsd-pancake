import Foundation

public enum AppUpdateDisposition: Equatable, Sendable {
    case upToDate
    case updateAvailable
    case newerThanLatest
}

public struct AppUpdateCheck: Equatable, Sendable {
    public let currentVersion: SemanticVersion
    public let currentBuild: String
    public let latestVersion: SemanticVersion
    public let releasePageURL: URL
    public let downloadURL: URL?
    public let disposition: AppUpdateDisposition

    public init(
        currentVersion: SemanticVersion,
        currentBuild: String,
        latestVersion: SemanticVersion,
        releasePageURL: URL,
        downloadURL: URL?
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.latestVersion = latestVersion
        self.releasePageURL = releasePageURL
        self.downloadURL = downloadURL
        if currentVersion < latestVersion {
            disposition = .updateAvailable
        } else if currentVersion == latestVersion {
            disposition = .upToDate
        } else {
            disposition = .newerThanLatest
        }
    }
}

public enum AppUpdateError: Error, Equatable, LocalizedError, Sendable {
    case invalidCurrentVersion(String)
    case invalidHTTPResponse
    case requestFailed(statusCode: Int)
    case unstableRelease
    case invalidReleaseVersion(String)
    case untrustedReleaseURL(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidCurrentVersion(version):
            "无法识别当前 DSD Pancake 版本：\(version)"
        case .invalidHTTPResponse:
            "GitHub 没有返回有效的 HTTP 响应。"
        case let .requestFailed(statusCode):
            "GitHub Release 检查失败（HTTP \(statusCode)）。"
        case .unstableRelease:
            "GitHub latest 指向了预发布版本，已拒绝展示。"
        case let .invalidReleaseVersion(version):
            "无法识别 GitHub Release 版本：\(version)"
        case let .untrustedReleaseURL(url):
            "GitHub Release 返回了不受信任的地址：\(url)"
        }
    }
}

public struct AppUpdateService: Sendable {
    public static let repositoryURL = URL(string: "https://github.com/hellokitty-23/dsd-pancake")!
    public static let latestReleaseEndpoint = URL(
        string: "https://github.com/hellokitty-23/dsd-pancake/releases/latest"
    )!

    private static let releasePathPrefix = "/hellokitty-23/dsd-pancake/releases/tag/"
    private static let downloadPathPrefix = "/hellokitty-23/dsd-pancake/releases/download/"

    public init() {}

    /// 只读取固定 GitHub 仓库的 latest 正式 Release 重定向。这里不会下载资源、
    /// 调用受速率限制的 GitHub REST API、写入 App bundle、启动安装器或重启应用。
    public func check(
        currentVersion: String,
        currentBuild: String,
        session: URLSession = .shared
    ) async throws -> AppUpdateCheck {
        guard let parsedCurrentVersion = SemanticVersion(currentVersion) else {
            throw AppUpdateError.invalidCurrentVersion(currentVersion)
        }

        var request = URLRequest(
            url: Self.latestReleaseEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "HEAD"
        request.setValue("DSD-Pancake/\(parsedCurrentVersion)", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidHTTPResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw AppUpdateError.requestFailed(statusCode: httpResponse.statusCode)
        }
        guard let finalURL = httpResponse.url else {
            throw AppUpdateError.invalidHTTPResponse
        }
        return try Self.parseLatestReleaseURL(
            finalURL,
            currentVersion: parsedCurrentVersion,
            currentBuild: currentBuild
        )
    }

    package static func parseLatestReleaseURL(
        _ finalURL: URL,
        currentVersion: SemanticVersion,
        currentBuild: String
    ) throws -> AppUpdateCheck {
        guard let releasePageURL = trustedGitHubURL(
            finalURL,
            requiredPathPrefix: releasePathPrefix
        ) else {
            throw AppUpdateError.untrustedReleaseURL(finalURL.absoluteString)
        }
        let tag = String(releasePageURL.path.dropFirst(releasePathPrefix.count))
        guard !tag.isEmpty, !tag.contains("/"), let latestVersion = SemanticVersion(tag) else {
            throw AppUpdateError.invalidReleaseVersion(tag)
        }
        guard tag == "v\(latestVersion)", !latestVersion.isPrerelease else {
            throw AppUpdateError.unstableRelease
        }
        let downloadAddress = Self.repositoryURL.absoluteString
            + "/releases/download/\(tag)/DSD-Pancake-\(tag)-arm64.dmg"
        guard let downloadURL = trustedGitHubURL(
            URL(string: downloadAddress),
            requiredPathPrefix: downloadPathPrefix
        ) else {
            throw AppUpdateError.untrustedReleaseURL(downloadAddress)
        }

        return AppUpdateCheck(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            latestVersion: latestVersion,
            releasePageURL: releasePageURL,
            downloadURL: downloadURL
        )
    }

    private static func trustedGitHubURL(_ value: URL?, requiredPathPrefix: String) -> URL? {
        guard let value,
              let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path.hasPrefix(requiredPathPrefix),
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        return components.url
    }
}
