import Foundation

/// DSD Pancake 自带的网页快捷键插件。它只作为某次 `dsh --patch` 启动的覆盖层挂载，
/// 不写入 DSH profile 的 package.json、bundle 列表或 patch 配置。
public struct DSHShortcutPlugin: Equatable, Sendable {
    public static let packageName = "@dsd-pancake/dsh-desktop-shortcuts"
    public static let resourcesDirectoryName = "DSHShortcuts"

    private let plugin: DSHPrivatePlugin

    public var directory: URL { plugin.directory }

    /// 只接受完整、已构建的极小插件目录；App 不在运行时编译 JavaScript，也不下载依赖。
    public init?(directory: URL, fileManager: FileManager = .default) {
        guard let plugin = DSHPrivatePlugin(
            packageName: Self.packageName,
            directory: directory,
            fileManager: fileManager
        ) else {
            return nil
        }
        self.plugin = plugin
    }

    public var patchURL: URL { plugin.patchURL }

    public func prepareResolver(
        baseEnvironment: [String: String],
        workingDirectory: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            try plugin.prepareResolver(
                baseEnvironment: baseEnvironment,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        } catch let error as DSHPrivatePluginError {
            throw DSHShortcutPluginError(error)
        }
    }

    /// 与 DSH 的 `resolveDshHome()` 语义对齐：非空 `DSH_HOME` 优先，未设置时回退 `~/.dsh`。
    public static func resolveDSHHome(
        baseEnvironment: [String: String],
        workingDirectory: URL,
        homeDirectory: URL
    ) -> URL {
        DSHPrivatePlugin.resolveDSHHome(
            baseEnvironment: baseEnvironment,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
    }
}

public enum DSHShortcutPluginError: LocalizedError, Equatable, Sendable {
    case resolverPathOccupied(String)
    case preparationFailed(String)

    init(_ error: DSHPrivatePluginError) {
        switch error {
        case let .resolverPathOccupied(path): self = .resolverPathOccupied(path)
        case let .preparationFailed(message): self = .preparationFailed(message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .resolverPathOccupied(path):
            "DSD Pancake 的快捷键插件解析路径已被其他文件占用：\(path)"
        case let .preparationFailed(message):
            "无法准备 DSD Pancake 的快捷键插件：\(message)"
        }
    }
}
