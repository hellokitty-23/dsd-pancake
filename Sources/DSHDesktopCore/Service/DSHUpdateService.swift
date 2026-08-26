import Dispatch
import Foundation

public struct DSHSemanticVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    private enum PrereleaseIdentifier: Comparable, Equatable, Sendable {
        case numeric(Int)
        case text(String)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(left), .numeric(right)):
                left < right
            case (.numeric, .text):
                true
            case (.text, .numeric):
                false
            case let (.text(left), .text(right)):
                left < right
            }
        }
    }

    public let rawValue: String
    private let major: Int
    private let minor: Int
    private let patch: Int
    private let prerelease: [PrereleaseIdentifier]

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let versionAndBuild = withoutPrefix.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard !versionAndBuild.isEmpty,
              versionAndBuild.count <= 2,
              versionAndBuild.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let versionAndPrerelease = versionAndBuild[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !versionAndPrerelease.isEmpty,
              versionAndPrerelease.count <= 2,
              versionAndPrerelease.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let core = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else {
            return nil
        }

        var identifiers: [PrereleaseIdentifier] = []
        if versionAndPrerelease.count == 2 {
            for rawIdentifier in versionAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false) {
                let identifier = String(rawIdentifier)
                guard !identifier.isEmpty,
                      identifier.unicodeScalars.allSatisfy({
                          CharacterSet.alphanumerics.contains($0) || $0 == "-"
                      }) else {
                    return nil
                }
                if identifier.allSatisfy(\.isNumber) {
                    guard identifier == "0" || !identifier.hasPrefix("0"),
                          let number = Int(identifier) else {
                        return nil
                    }
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.text(identifier))
                }
            }
        }

        if versionAndBuild.count == 2 {
            let buildIdentifiers = versionAndBuild[1].split(separator: ".", omittingEmptySubsequences: false)
            guard buildIdentifiers.allSatisfy({ identifier in
                !identifier.isEmpty && identifier.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || $0 == "-"
                }
            }) else {
                return nil
            }
        }

        self.rawValue = withoutPrefix
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = identifiers
    }

    public var description: String { rawValue }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func extract(from output: String) -> Self? {
        let pattern = #"(?:^|[^0-9A-Za-z-])v?([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?![0-9A-Za-z.+-])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Self(String(output[range]))
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              value == "0" || !value.hasPrefix("0") else {
            return nil
        }
        return Int(value)
    }
}

public enum DSHUpdateDisposition: Equatable, Sendable {
    case upToDate
    case updateAvailable
    case newerThanLatest
}

public struct DSHUpdateCheck: Equatable, Sendable {
    public let dshExecutable: URL
    public let npmExecutable: URL
    public let npmGlobalRoot: URL
    public let currentVersion: DSHSemanticVersion
    public let latestVersion: DSHSemanticVersion
    public let disposition: DSHUpdateDisposition

    public init(
        dshExecutable: URL,
        npmExecutable: URL,
        npmGlobalRoot: URL,
        currentVersion: DSHSemanticVersion,
        latestVersion: DSHSemanticVersion
    ) {
        self.dshExecutable = dshExecutable
        self.npmExecutable = npmExecutable
        self.npmGlobalRoot = npmGlobalRoot
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        if currentVersion < latestVersion {
            disposition = .updateAvailable
        } else if currentVersion == latestVersion {
            disposition = .upToDate
        } else {
            disposition = .newerThanLatest
        }
    }
}

public struct DSHUpdateResult: Equatable, Sendable {
    public let previousVersion: DSHSemanticVersion
    public let installedVersion: DSHSemanticVersion

    public init(previousVersion: DSHSemanticVersion, installedVersion: DSHSemanticVersion) {
        self.previousVersion = previousVersion
        self.installedVersion = installedVersion
    }
}

public enum OneShotCommandError: Error, Equatable, LocalizedError, Sendable {
    case timedOut(executable: String, seconds: Int)
    case outputDrainTimedOut(executable: String)
    case terminalUnavailable(Int32)
    case staleHandle

    public var errorDescription: String? {
        switch self {
        case let .timedOut(executable, seconds):
            "命令在 \(seconds) 秒内没有结束：\(executable)"
        case let .outputDrainTimedOut(executable):
            "命令已经退出，但输出管道没有及时收敛：\(executable)"
        case let .terminalUnavailable(code):
            "无法可靠回收命令进程（waitpid 错误 \(code)）。"
        case .staleHandle:
            "命令进程的受控句柄已经失效。"
        }
    }
}

public struct OneShotCommandOutput: Equatable, Sendable {
    public let exitStatus: ProcessExitStatus
    public let stdout: String
    public let stderr: String

    public init(exitStatus: ProcessExitStatus, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        exitStatus == .exited(0)
    }
}

public struct OneShotCommandRunner: Sendable {
    private static let pollNanoseconds: UInt64 = 100_000_000
    private static let drainTimeoutNanoseconds: UInt64 = 5_000_000_000

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> OneShotCommandOutput {
        let ringLog = RingLog(lineLimit: 1_000, byteLimit: 512 * 1_024)
        let supervisor = ProcessSupervisor(ringLog: ringLog)
        let spec = makeSpec(
            executable: executable,
            arguments: arguments,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        let handle = try await supervisor.spawn(spec)
        let timeoutNanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        let status: ProcessExitStatus

        commandLoop: while true {
            if Task.isCancelled {
                _ = await supervisor.requestTermination(handle)
                throw CancellationError()
            }

            switch await supervisor.checkExit(handle) {
            case .running:
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    _ = await supervisor.requestTermination(handle)
                    await waitForBestEffortCleanup(supervisor: supervisor, handle: handle)
                    throw OneShotCommandError.timedOut(
                        executable: executable.path,
                        seconds: Int(timeout.rounded(.up))
                    )
                }
            case let .reaped(exitStatus):
                status = exitStatus
                break commandLoop
            case let .terminalUnavailable(code):
                throw OneShotCommandError.terminalUnavailable(code)
            case .staleHandle:
                throw OneShotCommandError.staleHandle
            }

            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }

        let drainDeadline = DispatchTime.now().uptimeNanoseconds &+ Self.drainTimeoutNanoseconds
        while !(await supervisor.cleanupComplete()) {
            guard DispatchTime.now().uptimeNanoseconds < drainDeadline else {
                throw OneShotCommandError.outputDrainTimedOut(executable: executable.path)
            }
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }

        let entries = await supervisor.logSnapshot()
        let stdout = entries.filter { $0.stream == .stdout }.map(\.text).joined(separator: "\n")
        let stderr = entries.filter { $0.stream == .stderr }.map(\.text).joined(separator: "\n")
        return OneShotCommandOutput(exitStatus: status, stdout: stdout, stderr: stderr)
    }

    private func makeSpec(
        executable: URL,
        arguments: [String],
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) -> LaunchSpec {
        var environment = baseEnvironment
        let inheritedPATH = baseEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let paths = LaunchEnvironment.deduplicatedPaths(
            [executable.deletingLastPathComponent().path]
                + LaunchEnvironment.standardPATHEntries
                + inheritedPATH
        )
        environment["PATH"] = paths.joined(separator: ":")
        environment["HOME"] = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory.path
        environment["TMPDIR"] = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return LaunchSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: homeDirectory,
            environment: environment
        )
    }

    private func waitForBestEffortCleanup(supervisor: ProcessSupervisor, handle: SpawnHandle) async {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ Self.drainTimeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            _ = await supervisor.checkExit(handle)
            if await supervisor.cleanupComplete() { return }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
    }
}

public enum DSHUpdateError: Error, Equatable, LocalizedError, Sendable {
    case npmNotFound(dshPath: String)
    case notGlobalNPMInstallation(dshPath: String)
    case versionUnavailable(command: String, output: String)
    case commandFailed(command: String, status: ProcessExitStatus, output: String)
    case verificationFailed(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .npmNotFound(dshPath):
            "没有找到与当前 dsh 同一安装前缀的 npm：\(dshPath)"
        case let .notGlobalNPMInstallation(dshPath):
            "当前 dsh 不能确认来自 @deepseek-ai/dsh 的全局 npm 安装，因此不会自动更新：\(dshPath)"
        case let .versionUnavailable(command, output):
            "无法从 \(command) 的输出识别版本：\(output)"
        case let .commandFailed(command, status, output):
            "\(command) 执行失败（\(Self.statusText(status))）：\(output)"
        case let .verificationFailed(expected, actual):
            "npm 已结束，但 dsh 版本校验失败；期望至少为 \(expected)，实际为 \(actual)。"
        }
    }

    private static func statusText(_ status: ProcessExitStatus) -> String {
        switch status {
        case let .exited(code): "退出码 \(code)"
        case let .signaled(signal): "收到信号 \(signal)"
        case let .other(raw): "原始状态 \(raw)"
        }
    }
}

public struct DSHUpdateService: Sendable {
    public static let packageName = "@deepseek-ai/dsh"
    public static let updateArguments = [
        "install", "--global", "@deepseek-ai/dsh@latest", "--no-audit", "--no-fund",
    ]

    private let runner = OneShotCommandRunner()

    public init() {}

    public func check(
        executable: DSHExecutable,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) async throws -> DSHUpdateCheck {
        let currentOutput = try await runner.run(
            executable: executable.url,
            arguments: ["--version"],
            timeout: 10,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        guard currentOutput.succeeded else {
            throw commandFailure("dsh --version", output: currentOutput)
        }
        guard let currentVersion = DSHSemanticVersion.extract(from: currentOutput.stdout) else {
            throw DSHUpdateError.versionUnavailable(
                command: "dsh --version",
                output: bounded(currentOutput.stdout)
            )
        }

        let installation = try await locateNPMInstallation(
            for: executable.url,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let latestOutput = try await runner.run(
            executable: installation.npmExecutable,
            arguments: ["view", Self.packageName, "dist-tags.latest", "--json"],
            timeout: 30,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        guard latestOutput.succeeded else {
            throw commandFailure("npm view @deepseek-ai/dsh dist-tags.latest", output: latestOutput)
        }
        guard let latestVersion = Self.parseNPMViewLatestOutput(latestOutput.stdout) else {
            throw DSHUpdateError.versionUnavailable(
                command: "npm view @deepseek-ai/dsh dist-tags.latest",
                output: bounded(latestOutput.stdout)
            )
        }

        return DSHUpdateCheck(
            dshExecutable: executable.url,
            npmExecutable: installation.npmExecutable,
            npmGlobalRoot: installation.globalRoot,
            currentVersion: currentVersion,
            latestVersion: latestVersion
        )
    }

    public func update(
        using check: DSHUpdateCheck,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> DSHUpdateResult {
        let updateOutput = try await runner.run(
            executable: check.npmExecutable,
            arguments: Self.updateArguments,
            timeout: 600,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        guard updateOutput.succeeded else {
            throw commandFailure("npm install --global @deepseek-ai/dsh@latest", output: updateOutput)
        }

        let verificationOutput = try await runner.run(
            executable: check.dshExecutable,
            arguments: ["--version"],
            timeout: 10,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        guard verificationOutput.succeeded else {
            throw commandFailure("dsh --version", output: verificationOutput)
        }
        guard let installedVersion = DSHSemanticVersion.extract(from: verificationOutput.stdout) else {
            throw DSHUpdateError.versionUnavailable(
                command: "dsh --version",
                output: bounded(verificationOutput.stdout)
            )
        }
        guard installedVersion >= check.latestVersion else {
            throw DSHUpdateError.verificationFailed(
                expected: check.latestVersion.rawValue,
                actual: installedVersion.rawValue
            )
        }
        return DSHUpdateResult(
            previousVersion: check.currentVersion,
            installedVersion: installedVersion
        )
    }

    public static func path(_ candidate: URL, isInside directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }

    private func locateNPMInstallation(
        for dshExecutable: URL,
        baseEnvironment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager
    ) async throws -> (npmExecutable: URL, globalRoot: URL) {
        let candidates = Self.npmCandidates(for: dshExecutable)
            .filter { fileManager.isExecutableFile(atPath: $0.path) }
        guard !candidates.isEmpty else {
            throw DSHUpdateError.npmNotFound(dshPath: dshExecutable.path)
        }

        for npmExecutable in candidates {
            let rootOutput: OneShotCommandOutput
            do {
                rootOutput = try await runner.run(
                    executable: npmExecutable,
                    arguments: ["root", "--global"],
                    timeout: 10,
                    baseEnvironment: baseEnvironment,
                    homeDirectory: homeDirectory
                )
            } catch {
                continue
            }
            guard rootOutput.succeeded,
                  let rootLine = rootOutput.stdout
                      .split(whereSeparator: \.isNewline)
                      .map(String.init)
                      .last(where: { $0.hasPrefix("/") }) else {
                continue
            }
            let globalRoot = URL(fileURLWithPath: rootLine, isDirectory: true).standardizedFileURL
            let packageRoot = globalRoot
                .appendingPathComponent("@deepseek-ai", isDirectory: true)
                .appendingPathComponent("dsh", isDirectory: true)
            if Self.path(dshExecutable, isInside: packageRoot) {
                return (npmExecutable.standardizedFileURL, globalRoot)
            }
        }

        throw DSHUpdateError.notGlobalNPMInstallation(dshPath: dshExecutable.path)
    }

    private static func npmCandidates(for dshExecutable: URL) -> [URL] {
        let rawCandidates = [
            dshExecutable.deletingLastPathComponent().appendingPathComponent("npm"),
            URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
            URL(fileURLWithPath: "/usr/local/bin/npm"),
        ]
        var seen = Set<String>()
        return rawCandidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    package static func parseNPMViewLatestOutput(_ output: String) -> DSHSemanticVersion? {
        if let data = output.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) {
            if let string = value as? String {
                return DSHSemanticVersion(string)
            }
            if let strings = value as? [String], strings.count == 1 {
                return DSHSemanticVersion(strings[0])
            }
            return nil
        }
        return DSHSemanticVersion.extract(from: output)
    }

    private func commandFailure(_ command: String, output: OneShotCommandOutput) -> DSHUpdateError {
        let detail = output.stderr.isEmpty ? output.stdout : output.stderr
        return .commandFailed(command: command, status: output.exitStatus, output: bounded(detail))
    }

    private func bounded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "没有输出" }
        return String(trimmed.prefix(2_000))
    }
}
