import Darwin
import Foundation

/// DSD Pancake 自带的完成提醒插件。它只作为某次 `dsh --patch` 启动的覆盖层挂载，
/// 不写入 DSH profile 的 package.json、bundle 列表或 patch 配置。
public struct DSHNotificationPlugin: Equatable, Sendable {
    public static let packageName = "@dsd-pancake/dsh-desktop-notifications"
    public static let resourcesDirectoryName = "DSHNotifications"

    private static let requiredRelativeFiles = [
        "package.json",
        "cordis.patch.yml",
        "lib/index.js",
        "lib/client.js",
    ]

    public let directory: URL

    /// 只接受完整的、已构建的极小插件目录；App 不在运行时编译 JavaScript，也不下载依赖。
    public init?(directory: URL, fileManager: FileManager = .default) {
        let normalized = directory.standardizedFileURL
        guard Self.requiredRelativeFiles.allSatisfy({
            fileManager.fileExists(atPath: normalized.appendingPathComponent($0).path)
        }),
            Self.packageNameMatches(at: normalized.appendingPathComponent("package.json")) else {
            return nil
        }
        self.directory = normalized
    }

    public var patchURL: URL {
        directory.appendingPathComponent("cordis.patch.yml", isDirectory: false)
    }

    /// DSH 的 Loader 从 active profile 的 node_modules 解析裸包名。这里仅放置一个
    /// App 保留命名空间的符号链接，让本次 `--patch` 能解析 Bundle 内的插件；插件
    /// 是否加载仍完全由命令行覆盖层决定，普通 `dsh web` 不会因这条链接改变行为。
    public func prepareResolver(
        baseEnvironment: [String: String],
        workingDirectory: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let dshHome = Self.resolveDSHHome(
            baseEnvironment: baseEnvironment,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
        let link = dshHome
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@dsd-pancake", isDirectory: true)
            .appendingPathComponent("dsh-desktop-notifications", isDirectory: false)
        let parent = link.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try Self.replaceOwnedResolverLinkIfNeeded(
                at: link,
                target: directory,
                fileManager: fileManager
            )
        } catch let error as DSHNotificationPluginError {
            throw error
        } catch {
            throw DSHNotificationPluginError.preparationFailed(error.localizedDescription)
        }
    }

    /// 与 DSH 的 `resolveDshHome()` 语义对齐：非空 `DSH_HOME` 优先，未设置时回退 `~/.dsh`。
    public static func resolveDSHHome(
        baseEnvironment: [String: String],
        workingDirectory: URL,
        homeDirectory: URL
    ) -> URL {
        let configured = baseEnvironment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else {
            return homeDirectory.appendingPathComponent(".dsh", isDirectory: true).standardizedFileURL
        }

        let expanded: String
        if configured == "~" {
            expanded = homeDirectory.path
        } else if configured.hasPrefix("~/") || configured.hasPrefix("~\\") {
            expanded = homeDirectory.appendingPathComponent(String(configured.dropFirst(2))).path
        } else {
            expanded = configured
        }

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return workingDirectory.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }

    private static func packageNameMatches(at packageURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let package = object as? [String: Any],
              package["name"] as? String == packageName else {
            return false
        }
        return true
    }

    private static func replaceOwnedResolverLinkIfNeeded(
        at link: URL,
        target: URL,
        fileManager: FileManager
    ) throws {
        if symbolicLinkExists(atPath: link.path) {
            let rawDestination: String
            do {
                rawDestination = try fileManager.destinationOfSymbolicLink(atPath: link.path)
            } catch {
                throw DSHNotificationPluginError.preparationFailed(error.localizedDescription)
            }

            let destination = resolvedLinkDestination(rawDestination, relativeTo: link.deletingLastPathComponent())
            if destination == target.standardizedFileURL {
                return
            }
            if fileManager.fileExists(atPath: destination.path) {
                // 只接管确实指向同名 App 私有包的旧链接，允许用户移动／替换
                // DSD Pancake.app 后更新目标；任何仍指向实际目录的未知链接一律保留。
                guard packageNameMatches(at: destination.appendingPathComponent("package.json")) else {
                    throw DSHNotificationPluginError.resolverPathOccupied(link.path)
                }
            }
            // 失效链接不再指向任何文件；它只占据 App 自己保留的精确命名空间，
            // 因此可安全修复为当前 bundle，避免用户移动 App 后提醒永久失效。
            try fileManager.removeItem(at: link)
        } else if fileManager.fileExists(atPath: link.path) {
            // 不覆盖用户或其他工具创建的真实文件／目录，即使它刚好使用了保留路径。
            throw DSHNotificationPluginError.resolverPathOccupied(link.path)
        }

        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }

    private static func symbolicLinkExists(atPath path: String) -> Bool {
        var information = stat()
        guard lstat(path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }

    private static func resolvedLinkDestination(_ rawDestination: String, relativeTo parent: URL) -> URL {
        if rawDestination.hasPrefix("/") {
            return URL(fileURLWithPath: rawDestination, isDirectory: true).standardizedFileURL
        }
        return parent.appendingPathComponent(rawDestination, isDirectory: true).standardizedFileURL
    }
}

public enum DSHNotificationPluginError: LocalizedError, Equatable, Sendable {
    case resolverPathOccupied(String)
    case preparationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .resolverPathOccupied(path):
            "DSD Pancake 的提醒插件解析路径已被其他文件占用：\(path)"
        case let .preparationFailed(message):
            "无法准备 DSD Pancake 的提醒插件：\(message)"
        }
    }
}
