import Foundation

/// 正式 App 始终使用固定身份与 3080。只有打包脚本显式写入 test 标记、且 bundle ID
/// 与正式身份不同时，才接受隔离端口和独立 DSH_HOME；因此 Test App 可以与当前正式
/// App 并行运行，又不会把测试开关变成普通用户可注入的进程环境变量。
public struct AppRuntimeConfiguration: Equatable, Sendable {
    public static let productionBundleIdentifier = "io.github.hellokitty-23.dsd-pancake"
    public static let defaultServicePort = 3_080
    public static let defaultTestServicePort = 13_080
    public static let current = AppRuntimeConfiguration(
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    public let isIsolatedTestBuild: Bool
    public let servicePort: Int
    public let dshHomeOverride: URL?
    public let downloadDirectoryOverride: URL?

    public var usesPersistentWebDataStore: Bool {
        !isIsolatedTestBuild
    }

    public init(infoDictionary: [String: Any], bundleIdentifier: String?) {
        let markedAsTest = (infoDictionary["DSDPancakeTestMode"] as? NSNumber)?.boolValue == true
        let hasDistinctIdentity = bundleIdentifier.map {
            $0.caseInsensitiveCompare(Self.productionBundleIdentifier) != .orderedSame
        } ?? false
        isIsolatedTestBuild = markedAsTest && hasDistinctIdentity

        if isIsolatedTestBuild {
            if let configuredPort = (infoDictionary["DSDPancakeServicePort"] as? NSNumber)?.intValue,
               (1_024 ... 65_535).contains(configuredPort),
               configuredPort != Self.defaultServicePort {
                servicePort = configuredPort
            } else {
                // Test 标记存在但配置损坏时也绝不能退回正式 3080。
                servicePort = Self.defaultTestServicePort
            }
        } else {
            servicePort = Self.defaultServicePort
        }

        guard isIsolatedTestBuild, let bundleIdentifier else {
            dshHomeOverride = nil
            downloadDirectoryOverride = nil
            return
        }

        let fallbackRoot = (FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("isolated-test", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let configuredRoot = Self.safeAbsoluteDirectory(
            infoDictionary["DSDPancakeTestRoot"] as? String
        )
        let testRoot = configuredRoot ?? fallbackRoot

        dshHomeOverride = Self.safeChildDirectory(
            infoDictionary["DSDPancakeDSHHome"] as? String,
            under: testRoot
        ) ?? testRoot.appendingPathComponent("test-dsh-home", isDirectory: true)
        downloadDirectoryOverride = Self.safeChildDirectory(
            infoDictionary["DSDPancakeDownloadsDirectory"] as? String,
            under: testRoot
        ) ?? testRoot.appendingPathComponent("test-downloads", isDirectory: true)
    }

    private static func safeAbsoluteDirectory(_ rawPath: String?) -> URL? {
        guard let rawPath, rawPath.hasPrefix("/"), !rawPath.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL
        guard !isSamePath(directory, filesystemRoot), !isSamePath(directory, home) else {
            return nil
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(Self.productionBundleIdentifier, isDirectory: true)
        let protectedSubtrees = [
            Optional(home.appendingPathComponent(".dsh", isDirectory: true)),
            Optional(home.appendingPathComponent("Downloads", isDirectory: true)),
            applicationSupport,
        ].compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath() }
        guard !protectedSubtrees.contains(where: {
            isSameOrDescendant(directory, of: $0)
        }) else { return nil }
        return directory
    }

    private static func safeChildDirectory(_ rawPath: String?, under root: URL) -> URL? {
        guard let directory = safeAbsoluteDirectory(rawPath) else { return nil }
        guard !isSamePath(directory, root), isSameOrDescendant(directory, of: root) else {
            return nil
        }
        return directory
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidateComponents = candidate.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        return candidateComponents.count >= rootComponents.count
            && zip(candidateComponents.prefix(rootComponents.count), rootComponents).allSatisfy {
                $0.caseInsensitiveCompare($1) == .orderedSame
            }
    }

    private static func isSamePath(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsComponents = lhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rhsComponents = rhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return lhsComponents.count == rhsComponents.count
            && zip(lhsComponents, rhsComponents).allSatisfy {
                $0.caseInsensitiveCompare($1) == .orderedSame
            }
    }

    public func applyingLaunchOverrides(to baseEnvironment: [String: String]) -> [String: String] {
        var environment = baseEnvironment
        if let dshHomeOverride {
            environment["DSH_HOME"] = dshHomeOverride.path
        }
        if isIsolatedTestBuild {
            environment["DSH_TELEMETRY_DISABLED"] = "1"
        }
        return environment
    }
}
