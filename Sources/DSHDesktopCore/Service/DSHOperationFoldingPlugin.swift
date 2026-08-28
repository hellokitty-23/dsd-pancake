import Foundation

/// DSD Pancake 自带的执行操作折叠插件。它只通过本次 App 启动命令的
/// `--patch` 挂载，不会改写 DSH profile，也不会影响普通 `dsh web`。
public struct DSHOperationFoldingPlugin: Equatable, Sendable {
    public static let packageName = "@dsd-pancake/dsh-desktop-operation-folding"
    public static let resourcesDirectoryName = "DSHOperationFolding"

    private let plugin: DSHPrivatePlugin

    public var directory: URL { plugin.directory }

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
            throw DSHOperationFoldingPluginError(error)
        }
    }
}

public enum DSHOperationFoldingPluginError: LocalizedError, Equatable, Sendable {
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
            "DSD Pancake 的操作折叠插件解析路径已被其他文件占用：\(path)"
        case let .preparationFailed(message):
            "无法准备 DSD Pancake 的操作折叠插件：\(message)"
        }
    }
}
