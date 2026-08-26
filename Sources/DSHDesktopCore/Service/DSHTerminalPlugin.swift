import Foundation

/// DSD Pancake 自带的底部终端插件。它与提醒插件使用同一类 App 私有 resolver，
/// 但拥有独立 package 和独立 `--patch`，任何普通 `dsh web` 都不会自动加载它。
public struct DSHTerminalPlugin: Equatable, Sendable {
    public static let packageName = "@dsd-pancake/dsh-desktop-terminal"
    public static let resourcesDirectoryName = "DSHTerminal"

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
            throw DSHTerminalPluginError(error)
        }
    }
}

public enum DSHTerminalPluginError: LocalizedError, Equatable, Sendable {
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
            "DSD Pancake 的终端插件解析路径已被其他文件占用：\(path)"
        case let .preparationFailed(message):
            "无法准备 DSD Pancake 的终端插件：\(message)"
        }
    }
}
