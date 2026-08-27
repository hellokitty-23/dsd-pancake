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
    public let checksumURL: URL?
    public let disposition: AppUpdateDisposition

    public init(
        currentVersion: SemanticVersion,
        currentBuild: String,
        latestVersion: SemanticVersion,
        releasePageURL: URL,
        downloadURL: URL?,
        checksumURL: URL? = nil
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.latestVersion = latestVersion
        self.releasePageURL = releasePageURL
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
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
        session: URLSession? = nil
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

        let session = session ?? Self.makeEphemeralSession()
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
        let assetFilename = Self.assetFilename(for: latestVersion)
        let downloadAddress = Self.repositoryURL.absoluteString
            + "/releases/download/\(tag)/\(assetFilename)"
        guard let downloadURL = trustedGitHubURL(
            URL(string: downloadAddress),
            requiredPathPrefix: downloadPathPrefix
        ) else {
            throw AppUpdateError.untrustedReleaseURL(downloadAddress)
        }
        let checksumAddress = downloadAddress + ".sha256"
        guard let checksumURL = trustedGitHubURL(
            URL(string: checksumAddress),
            requiredPathPrefix: downloadPathPrefix
        ) else {
            throw AppUpdateError.untrustedReleaseURL(checksumAddress)
        }

        return AppUpdateCheck(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            latestVersion: latestVersion,
            releasePageURL: releasePageURL,
            downloadURL: downloadURL,
            checksumURL: checksumURL
        )
    }

    /// 缓存中只保存正式 SemVer（语义版本）；恢复时重新生成固定仓库的 Release 与资产地址，
    /// 因此不会把过期的重定向 URL 或外部输入持久化为下载来源。
    public static func cachedCheck(
        currentVersion: String,
        currentBuild: String,
        latestVersion: String
    ) -> AppUpdateCheck? {
        guard let currentVersion = SemanticVersion(currentVersion),
              let latestVersion = SemanticVersion(latestVersion),
              !latestVersion.isPrerelease,
              let releasePageURL = releasePageURL(for: latestVersion),
              let downloadURL = downloadURL(for: latestVersion),
              let checksumURL = checksumURL(for: latestVersion) else {
            return nil
        }
        return AppUpdateCheck(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            latestVersion: latestVersion,
            releasePageURL: releasePageURL,
            downloadURL: downloadURL,
            checksumURL: checksumURL
        )
    }

    public static func assetFilename(for version: SemanticVersion) -> String {
        "DSD-Pancake-v\(version)-arm64.dmg"
    }

    public static func releasePageURL(for version: SemanticVersion) -> URL? {
        guard !version.isPrerelease else { return nil }
        return trustedGitHubURL(
            repositoryURL.appending(path: "releases/tag/v\(version)"),
            requiredPathPrefix: releasePathPrefix
        )
    }

    public static func downloadURL(for version: SemanticVersion) -> URL? {
        guard !version.isPrerelease else { return nil }
        return trustedGitHubURL(
            repositoryURL.appending(path: "releases/download/v\(version)/\(assetFilename(for: version))"),
            requiredPathPrefix: downloadPathPrefix
        )
    }

    public static func checksumURL(for version: SemanticVersion) -> URL? {
        guard let downloadURL = downloadURL(for: version) else { return nil }
        return trustedGitHubURL(
            URL(string: downloadURL.absoluteString + ".sha256"),
            requiredPathPrefix: downloadPathPrefix
        )
    }

    package static func isTrustedReleaseAssetRedirect(
        _ url: URL?,
        expectedInitialURL: URL
    ) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.port == nil,
              components.user == nil,
              components.password == nil else {
            return false
        }

        let host = components.host?.lowercased() ?? ""
        if host == "github.com" {
            return url == expectedInitialURL
        }

        // GitHub Release 资产会在同一次请求中跳转至其受控的下载主机。只允许 HTTPS、
        // 无用户信息／自定义端口的显式主机集合；不接受任意 CDN、任意子域或任意初始 URL。
        let allowedReleaseAssetHosts: Set<String> = [
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
            "github-production-release-asset-2e65be.s3.amazonaws.com",
        ]
        return allowedReleaseAssetHosts.contains(host) && !components.path.isEmpty
    }

    private static func makeEphemeralSession() -> URLSession {
        URLSession(configuration: UpdateNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 15,
            resourceTimeout: 15
        ))
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
