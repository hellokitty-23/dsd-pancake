import Foundation

public struct LaunchSpec: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public enum LaunchEnvironment {
    public static let requiredArguments = ["web", "--no-open", "--host", LocalService.host, "--port", "\(LocalService.port)"]
    public static let standardPATHEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// 构建结构化启动信息。不会执行 Shell，也不会将完整环境写入日志或磁盘。
    public static func makeSpec(
        executable: DSHExecutable,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        notificationPatchURL: URL? = nil
    ) -> LaunchSpec {
        var environment = baseEnvironment
        let executableDirectory = executable.url.deletingLastPathComponent().path
        let inheritedPATH = baseEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let pathEntries = deduplicatedPaths([executableDirectory] + standardPATHEntries + inheritedPATH)
        environment["PATH"] = pathEntries.joined(separator: ":")
        environment["HOME"] = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory.path
        environment["TMPDIR"] = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()

        return LaunchSpec(
            executable: executable.url,
            arguments: launchArguments(notificationPatchURL: notificationPatchURL),
            workingDirectory: homeDirectory,
            environment: environment
        )
    }

    /// `--patch` 属于 DSH launcher，而不是 `web` 子命令；有覆盖层时必须使用
    /// `--profile web` 形式，才能让覆盖层只附着于本次启动。
    public static func launchArguments(notificationPatchURL: URL?) -> [String] {
        guard let notificationPatchURL else { return requiredArguments }
        return [
            "--profile", "web",
            "--patch", notificationPatchURL.path,
            "--no-open",
            "--host", LocalService.host,
            "--port", "\(LocalService.port)",
        ]
    }

    public static func deduplicatedPaths(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard !entry.isEmpty, seen.insert(entry).inserted else { return nil }
            return entry
        }
    }
}
