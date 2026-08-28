import Darwin
import Foundation

/// App 私有 DSH 插件共用的解析器准备逻辑。它只写 App 保留命名空间中的
/// resolver 符号链接；真正启用仍完全取决于本次 dsh 启动命令里的 `--patch`。
struct DSHPrivatePlugin: Equatable, Sendable {
    static let requiredRelativeFiles = [
        "package.json",
        "cordis.patch.yml",
        "lib/index.js",
        "lib/client.js",
    ]

    let packageName: String
    let packageLeafName: String
    let directory: URL

    init?(packageName: String, directory: URL, fileManager: FileManager = .default) {
        guard packageName.hasPrefix("@dsd-pancake/"),
              let packageLeafName = packageName.split(separator: "/").last.map(String.init),
              !packageLeafName.isEmpty else {
            return nil
        }
        let normalized = directory.standardizedFileURL
        guard Self.requiredRelativeFiles.allSatisfy({
            fileManager.fileExists(atPath: normalized.appendingPathComponent($0).path)
        }),
            Self.packageNameMatches(packageName, at: normalized.appendingPathComponent("package.json")) else {
            return nil
        }
        self.packageName = packageName
        self.packageLeafName = packageLeafName
        self.directory = normalized
    }

    var patchURL: URL {
        directory.appendingPathComponent("cordis.patch.yml", isDirectory: false)
    }

    func prepareResolver(
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
            .appendingPathComponent(packageLeafName, isDirectory: false)
        let parent = link.deletingLastPathComponent()

        do {
            try Self.ensureResolverScopeDirectory(at: parent, fileManager: fileManager)
            try Self.replaceOwnedResolverLinkIfNeeded(
                at: link,
                target: directory,
                fileManager: fileManager
            )
        } catch let error as DSHPrivatePluginError {
            throw error
        } catch {
            throw DSHPrivatePluginError.preparationFailed(error.localizedDescription)
        }
    }

    static func resolveDSHHome(
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

    private static func packageNameMatches(_ packageName: String, at packageURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let package = object as? [String: Any],
              package["name"] as? String == packageName else {
            return false
        }
        return true
    }

    /// App 保留 scope 必须是这个路径上的真实目录，不能是指向其它位置的链接或特殊节点。
    /// 创建后再次用 `lstat` 校验，避免检查与创建之间的竞态把 resolver 写到 scope 外部。
    private static func ensureResolverScopeDirectory(
        at directory: URL,
        fileManager: FileManager
    ) throws {
        var information = stat()
        if lstat(directory.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFDIR else {
                throw DSHPrivatePluginError.resolverPathOccupied(directory.path)
            }
            return
        }

        let inspectionError = errno
        guard inspectionError == ENOENT else {
            throw DSHPrivatePluginError.preparationFailed(
                String(cString: strerror(inspectionError))
            )
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DSHPrivatePluginError.preparationFailed(error.localizedDescription)
        }

        information = stat()
        guard lstat(directory.path, &information) == 0 else {
            let verificationError = errno
            throw DSHPrivatePluginError.preparationFailed(
                String(cString: strerror(verificationError))
            )
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw DSHPrivatePluginError.resolverPathOccupied(directory.path)
        }
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
                throw DSHPrivatePluginError.preparationFailed(error.localizedDescription)
            }

            let destination = resolvedLinkDestination(rawDestination, relativeTo: link.deletingLastPathComponent())
            if destination == target.standardizedFileURL {
                return
            }
            // 仅修复失效链接。即使现有目标的 package 名相同，也不能据此推断
            // 它仍属于当前 App；覆盖一个可访问的目标会改写用户现有解析路径。
            // 让对应能力安全降级，比猜测所有权更符合薄壳边界。
            if fileManager.fileExists(atPath: destination.path) {
                throw DSHPrivatePluginError.resolverPathOccupied(link.path)
            }
            try fileManager.removeItem(at: link)
        } else if fileManager.fileExists(atPath: link.path) {
            throw DSHPrivatePluginError.resolverPathOccupied(link.path)
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

enum DSHPrivatePluginError: Error, Equatable, Sendable {
    case resolverPathOccupied(String)
    case preparationFailed(String)
}
