import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func verifyProcessSupervisor() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sleep")) else {
            throw VerificationError("测试可执行文件 /bin/sleep 不可用")
        }
        let spec = LaunchSpec(
            executable: executable.url,
            arguments: ["3"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(spec)
        try expect(handle.pgid == handle.pid, "子进程未在 spawn 时建立独立进程组")
        let ownership = await supervisor.verifyOwnership(handle)
        try expect(ownership == .verified, "创建的受控进程未通过 PID/PGID/启动时间复核")
        try expect(
            await supervisor.verifyLocalServiceOwnership(handle, port: UInt16(LocalService.port)) == .notListening,
            "没有监听 socket 的受控进程被错误认定为本地服务拥有者"
        )

        var launchState = PrivatePluginLaunchState()
        try expect(launchState.beginPreparation(), "首次私有插件准备被错误跳过")
        launchState.recordPrepared(.notification)
        launchState.recordPrepared(.terminal)
        try expect(
            !PrivatePluginBridgeAdmission.mayEnable(
                .notification,
                ownershipVerification: .verified,
                launchState: launchState,
                handle: handle
            ),
            "resolver prepare 在绑定 SpawnHandle 前错误授予 bridge 能力"
        )
        launchState.bindPreparedPlugins(to: handle)
        try expect(
            PrivatePluginBridgeAdmission.mayEnable(
                .notification,
                ownershipVerification: .verified,
                launchState: launchState,
                handle: handle
            )
                && PrivatePluginBridgeAdmission.mayEnable(
                    .terminal,
                    ownershipVerification: .verified,
                    launchState: launchState,
                    handle: handle
                )
                && !PrivatePluginBridgeAdmission.mayEnable(
                    .operationFolding,
                    ownershipVerification: .verified,
                    launchState: launchState,
                    handle: handle
                )
                && !PrivatePluginBridgeAdmission.mayEnable(
                    .notification,
                    ownershipVerification: .notListening,
                    launchState: launchState,
                    handle: handle
                ),
            "bridge admission 没有同时约束 verified ownership、同句柄和已准备插件"
        )
        launchState.markReady(for: handle)
        try expect(
            !PrivatePluginBridgeAdmission.mayEnable(
                .notification,
                ownershipVerification: .verified,
                launchState: launchState,
                handle: handle
            ),
            "ready 后的一次性启动凭据仍可重新授予 bridge"
        )

        var fallbackState = PrivatePluginLaunchState()
        _ = fallbackState.beginPreparation()
        fallbackState.recordPrepared(.notification)
        fallbackState.bindPreparedPlugins(to: handle)
        try expect(
            fallbackState.scheduleFallbackIfNeeded(for: handle, quitPending: false),
            "带私有插件的进程在 ready 前退出没有安排一次无插件回退"
        )
        try expect(!fallbackState.beginPreparation(), "无插件回退标记没有被下一轮精确消费")
        try expect(fallbackState.beginPreparation(), "无插件回退错误持续阻断后续正常准备")

        let request = await supervisor.requestTermination(handle)
        try expect(request == .signalSent, "受控进程未收到唯一 SIGTERM：\(request)")
        let duplicateRequest = await supervisor.requestTermination(handle)
        try expect(duplicateRequest != .signalSent, "同一 SpawnHandle 错误发送了第二次 SIGTERM")

        try await waitUntil("SIGTERM 后主 PID 回收") {
            let observation = await supervisor.checkExit(handle)
            if case .reaped = observation { return true }
            return await supervisor.cleanupComplete()
        }
        try await waitUntil("SIGTERM 后 stdout/stderr EOF") {
            await supervisor.cleanupComplete()
        }
        try expect(await supervisor.canSpawn(), "stdout/stderr EOF 后的清理未收敛")

        try await verifyPipeDrainFixture()
        try await verifyImmediateExitStatusSurvivesDrain()
        try await verifyHighVolumeLogFixture()
        try await verifyProcessLaunchContext()
        try await verifySpawnRestoresTermSignalState()
        try await verifyLockDescriptorDoesNotLeakToChild()
        try await verifyOwnershipLossRevokesSignalCapability()
        try await verifyTerminationRaceAndGenerationIsolation()
    }

    static func verifyLocalServiceOwnership() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshdesktop-listener-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let readyURL = fixtureDirectory.appendingPathComponent("listener-port", isDirectory: false)
        let stopURL = fixtureDirectory.appendingPathComponent("listener-stop", isDirectory: false)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard let executable = DSHExecutable(url: executableURL) else {
            throw VerificationError("验证程序自身不可作为监听 fixture 子进程")
        }

        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["--fixture-listener", "0", readyURL.path, stopURL.path],
                workingDirectory: fixtureDirectory,
                environment: ProcessInfo.processInfo.environment
            )
        )
        do {
            try await waitUntil("监听 fixture 就绪") {
                FileManager.default.fileExists(atPath: readyURL.path)
            }
            let portText = try String(contentsOf: readyURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = UInt16(portText) else {
                throw VerificationError("监听 fixture 未写入有效端口：\(portText)")
            }

            let ownership = await supervisor.verifyLocalServiceOwnership(handle, port: port)
            try expect(ownership == .verified, "直接子进程的 loopback 监听端口未被确认：\(ownership)")

            let request = await supervisor.requestTermination(handle)
            try expect(request == .signalSent, "监听 fixture 未收到 SIGTERM：\(request)")
            try requestListenerFixtureExit(at: stopURL)
            try await waitUntil("监听 fixture 清理") {
                _ = await supervisor.checkExit(handle)
                return await supervisor.cleanupComplete()
            }
        } catch {
            try? requestListenerFixtureExit(at: stopURL)
            _ = await supervisor.requestTermination(handle)
            _ = try? await waitUntil("失败后的监听 fixture 清理") {
                _ = await supervisor.checkExit(handle)
                return await supervisor.cleanupComplete()
            }
            throw error
        }
    }

    static func verifyPipeDrainFixture() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            throw VerificationError("测试可执行文件 /bin/sh 不可用")
        }
        let supervisor = ProcessSupervisor()
        let spec = LaunchSpec(
            executable: executable.url,
            arguments: ["-c", "(sleep 2) & exit 0"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        let handle = try await supervisor.spawn(spec)
        try await waitUntil("drain fixture 主进程回收") {
            if case .reaped = await supervisor.checkExit(handle) { return true }
            return false
        }
        try expect(
            await supervisor.cleanupState(handle) == .drainingPipes,
            "后继写端仍存活时未进入 drainingPipes"
        )
        try expect(!(await supervisor.canSpawn()), "drainingPipes 时错误允许再次 spawn")
        try await waitUntil("后继写端自然 EOF", attempts: 40) {
            await supervisor.cleanupComplete()
        }
        try expect(await supervisor.canSpawn(), "drain 完成后未恢复正常 spawn 能力")
    }

    static func verifyImmediateExitStatusSurvivesDrain() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            throw VerificationError("测试可执行文件 /bin/sh 不可用")
        }
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["-c", "exit 23"],
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            )
        )
        try await waitUntil("立即退出 fixture 清理") {
            await supervisor.cleanupComplete()
        }
        try expect(
            await supervisor.checkExit(handle) == .reaped(.exited(23)),
            "pipe EOF 后丢失了立即退出进程的退出码"
        )
        try expect(
            await supervisor.requestTermination(handle) == .alreadyExited(.exited(23)),
            "已完成 handle 不应重新取得信号权"
        )
        try expect(await supervisor.canSpawn(), "已完成 handle 错误阻止下一次 spawn")
    }

    static func verifyHighVolumeLogFixture() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            throw VerificationError("测试可执行文件 /bin/sh 不可用")
        }
        let supervisor = ProcessSupervisor()
        let spec = LaunchSpec(
            executable: executable.url,
            arguments: [
                "-c",
                "i=0; while [ \"$i\" -lt 3000 ]; do printf 'out-%s\\n' \"$i\"; printf 'err-%s\\n' \"$i\" >&2; i=$((i + 1)); done",
            ],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        let handle = try await supervisor.spawn(spec)
        try await waitUntil("高输出 fixture 清理", attempts: 100) {
            _ = await supervisor.checkExit(handle)
            return await supervisor.cleanupComplete()
        }
        let entries = await supervisor.logSnapshot()
        try expect(entries.count <= RingLog.defaultLineLimit, "高输出时日志行数未受限")
        try expect(
            entries.reduce(0) { $0 + $1.text.lengthOfBytes(using: .utf8) } <= RingLog.defaultByteLimit,
            "高输出时日志字节数未受限"
        )
    }

    static func verifyProcessLaunchContext() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            throw VerificationError("测试可执行文件 /bin/sh 不可用")
        }
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshdesktop-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let environment = [
            "PATH": "/fixture/bin:/usr/bin:/bin",
            "HOME": "/fixture/home",
            "TMPDIR": "/fixture/tmp",
        ]
        let spec = LaunchSpec(
            executable: executable.url,
            arguments: ["-c", "printf 'PWD=%s\\nPATH=%s\\nHOME=%s\\nTMPDIR=%s\\n' \"$PWD\" \"$PATH\" \"$HOME\" \"$TMPDIR\""],
            workingDirectory: fixtureDirectory,
            environment: environment
        )
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(spec)
        try await waitUntil("启动环境 fixture 清理") {
            _ = await supervisor.checkExit(handle)
            return await supervisor.cleanupComplete()
        }
        let text = await supervisor.logSnapshot().map(\.text).joined(separator: "\n")
        let expectedWorkingDirectory = fixtureDirectory.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let expectedWorkingDirectory else {
            throw VerificationError("无法解析 fixture 工作目录的真实路径")
        }
        try expect(text.contains("PWD=\(expectedWorkingDirectory)"), "子进程 cwd 未按 LaunchSpec 设置：\(text)")
        try expect(text.contains("PATH=/fixture/bin:/usr/bin:/bin"), "子进程 PATH 未按 LaunchSpec 传递：\(text)")
        try expect(text.contains("HOME=/fixture/home"), "子进程 HOME 未按 LaunchSpec 传递：\(text)")
        try expect(text.contains("TMPDIR=/fixture/tmp"), "子进程 TMPDIR 未按 LaunchSpec 传递：\(text)")
    }

    static func verifySpawnRestoresTermSignalState() async throws {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard let executable = DSHExecutable(url: executableURL) else {
            throw VerificationError("验证程序自身不可作为 SIGTERM fixture 子进程")
        }

        let supervisor = ProcessSupervisor()
        let handle: SpawnHandle
        do {
            var original = sigaction()
            try expect(sigaction(SIGTERM, nil, &original) == 0, "无法备份 SIGTERM disposition")
            var ignored = original
            ignored.__sigaction_u.__sa_handler = SIG_IGN
            ignored.sa_flags = 0
            try expect(sigemptyset(&ignored.sa_mask) == 0, "无法初始化 SIGTERM fixture mask")
            try expect(sigaction(SIGTERM, &ignored, nil) == 0, "无法安装 SIGTERM ignore fixture")
            defer {
                var restored = original
                _ = sigaction(SIGTERM, &restored, nil)
            }

            handle = try await supervisor.spawn(
                LaunchSpec(
                    executable: executable.url,
                    arguments: ["--fixture-term-state"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    environment: ProcessInfo.processInfo.environment
                )
            )
        }

        try await waitUntil("SIGTERM disposition fixture 清理") {
            _ = await supervisor.checkExit(handle)
            return await supervisor.cleanupComplete()
        }
        let text = await supervisor.logSnapshot().map(\.text).joined(separator: "\n")
        try expect(
            text.contains("TERM_DEFAULT=1 TERM_UNBLOCKED=1"),
            "posix_spawn 未恢复子进程 SIGTERM 默认处理或未清空 mask：\(text)"
        )
    }

    static func verifyLockDescriptorDoesNotLeakToChild() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshdesktop-lock-inheritance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let bundleIdentifier = "io.github.hellokitty-23.dsd-pancake.lock-inheritance"
        var lock: SingleInstanceLock? = try SingleInstanceLock.acquire(
            bundleIdentifier: bundleIdentifier,
            rootDirectory: fixtureRoot
        )
        guard let lockPath = lock?.fileURL.path else {
            throw VerificationError("锁继承 fixture 未能取得首实例锁")
        }

        let readyURL = fixtureRoot.appendingPathComponent("child-may-probe", isDirectory: false)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard let executable = DSHExecutable(url: executableURL) else {
            throw VerificationError("验证程序自身不可作为锁继承 fixture 子进程")
        }
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["--fixture-lock-probe", lockPath, readyURL.path],
                workingDirectory: fixtureRoot,
                environment: ProcessInfo.processInfo.environment
            )
        )

        // 父进程释放锁后才允许子进程检查；若锁 FD 泄漏到 exec 后，子进程仍会保有同一锁。
        lock = nil
        try Data().write(to: readyURL, options: .withoutOverwriting)
        try await waitUntil("锁 FD CLOEXEC fixture 清理") {
            _ = await supervisor.checkExit(handle)
            return await supervisor.cleanupComplete()
        }
        let text = await supervisor.logSnapshot().map(\.text).joined(separator: "\n")
        try expect(text.contains("LOCK_PROBE_ACQUIRED"), "单实例锁 FD 泄漏给子进程，未在 exec 前关闭")
    }

    static func verifyOwnershipLossRevokesSignalCapability() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sleep")) else {
            throw VerificationError("测试可执行文件 /bin/sleep 不可用")
        }

        let identityCapture = IdentityCaptureSwitch()
        let supervisor = ProcessSupervisor(identityCapture: { pid in
            identityCapture.capture(pid)
        })
        let handle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["2"],
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            )
        )

        try expect(
            await supervisor.verifyOwnership(handle) == .verified,
            "受控 fixture 在身份切换前未通过初始复核"
        )
        identityCapture.failFutureCaptures()
        try expect(
            await supervisor.verifyOwnership(handle) == .lost,
            "身份查询失败后没有撤销停止权"
        )
        try expect(
            await supervisor.cleanupState(handle) == .supervisionOnly,
            "失去身份后没有转为 supervisionOnly"
        )
        try expect(
            await supervisor.requestTermination(handle) == .ownershipLost,
            "失去身份后错误向子进程发送 SIGTERM"
        )
        try expect(!(await supervisor.canSpawn()), "失去身份但主进程仍在时错误允许再次 spawn")
        do {
            _ = try await supervisor.spawn(
                LaunchSpec(
                    executable: executable.url,
                    arguments: ["1"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    environment: ProcessInfo.processInfo.environment
                )
            )
            throw VerificationError("失去身份后错误创建了第二个受控进程")
        } catch let error as ProcessSupervisorError {
            try expect(error == .cleanupPending, "失去身份后的 spawn 未被 cleanupPending 阻止：\(error)")
        }
        try expect(
            await supervisor.checkExit(handle) == .running,
            "失去身份后的停止请求意外结束了仍在运行的子进程"
        )
        try await waitUntil("失权 fixture 自然退出") {
            _ = await supervisor.checkExit(handle)
            return await supervisor.cleanupComplete()
        }
        try expect(await supervisor.canSpawn(), "失权 fixture 的自然退出和日志排空未收敛")
    }

    /// 多个停止请求与退出观察可并发到达，但真正的 `waitpid`、身份复核和信号
    /// 仍由同一 actor 串行化。此处只操作本项目创建的 `/bin/sleep` fixture。
    static func verifyTerminationRaceAndGenerationIsolation() async throws {
        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sleep")) else {
            throw VerificationError("测试可执行文件 /bin/sleep 不可用")
        }

        let supervisor = ProcessSupervisor()
        let firstHandle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["3"],
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            )
        )
        var handleBoundPlugins = PrivatePluginLaunchState()
        _ = handleBoundPlugins.beginPreparation()
        handleBoundPlugins.recordPrepared(.terminal)
        handleBoundPlugins.bindPreparedPlugins(to: firstHandle)

        async let initialObservation = supervisor.checkExit(firstHandle)
        let terminationResults = await withTaskGroup(of: TerminationRequestResult.self, returning: [TerminationRequestResult].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await supervisor.requestTermination(firstHandle)
                }
            }
            var results: [TerminationRequestResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        _ = await initialObservation
        try expect(
            terminationResults.filter { $0 == .signalSent }.count == 1,
            "同一受控 handle 的并发停止请求没有收敛为一次 SIGTERM：\(terminationResults)"
        )
        try await waitUntil("并发停止 fixture 清理") {
            _ = await supervisor.checkExit(firstHandle)
            return await supervisor.cleanupComplete()
        }

        let secondHandle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["3"],
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            )
        )
        try expect(
            !PrivatePluginBridgeAdmission.mayEnable(
                .terminal,
                ownershipVerification: .verified,
                launchState: handleBoundPlugins,
                handle: secondHandle
            ),
            "旧 generation 的私有插件凭据错误授权了新 SpawnHandle"
        )
        try expect(
            await supervisor.requestTermination(firstHandle) == .staleHandle,
            "旧 generation 的 handle 不应影响新子进程"
        )
        try expect(
            await supervisor.checkExit(secondHandle) == .running,
            "旧 handle 操作意外影响了新 generation 的受控子进程"
        )
        try expect(
            await supervisor.requestTermination(secondHandle) == .signalSent,
            "新 generation 的受控子进程未收到 SIGTERM"
        )
        try await waitUntil("新 generation fixture 清理") {
            _ = await supervisor.checkExit(secondHandle)
            return await supervisor.cleanupComplete()
        }
        try expect(await supervisor.canSpawn(), "停止竞态 fixture 后未恢复 spawn 能力")
    }

    static func verifyTerminalUnavailableSafety() async throws {
        var original = sigaction()
        try expect(sigaction(SIGCHLD, nil, &original) == 0, "无法备份 SIGCHLD disposition")
        var ignored = original
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        try expect(sigaction(SIGCHLD, &ignored, nil) == 0, "无法安装 terminal-unavailable fixture")
        defer {
            var restored = original
            _ = sigaction(SIGCHLD, &restored, nil)
        }

        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            throw VerificationError("测试可执行文件 /bin/sh 不可用")
        }
        let spec = LaunchSpec(
            executable: executable.url,
            arguments: ["-c", "printf 'fixture\\n'; exit 0"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(spec)

        var lastObservation: ProcessExitObservation = .running
        for _ in 0 ..< 50 {
            lastObservation = await supervisor.checkExit(handle)
            if await supervisor.terminalIncompatibilityError() == ECHILD {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expect(
            await supervisor.terminalIncompatibilityError() == ECHILD,
            "ECHILD 未永久标记为兼容性失败，最后观察为 \(lastObservation)"
        )
        try await waitUntil("terminal fixture pipe EOF") {
            await supervisor.cleanupComplete()
        }
        try expect(!(await supervisor.canSpawn()), "terminal-unavailable 后错误允许再次 spawn")

        try await verifyInjectedTerminalUnavailableSafety()
    }

    /// 以独立验证子进程覆盖非 `ECHILD` 的不可恢复错误。内层受控子进程由
    /// `SIGCHLD=SIG_IGN` 自动回收，外层仍使用真实 `ProcessSupervisor` 回收这个
    /// 验证子进程；因此测试不遗留 zombie（僵尸进程）或外部进程。
    static func verifyInjectedTerminalUnavailableSafety() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshdesktop-terminal-injected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard let executable = DSHExecutable(url: executableURL) else {
            throw VerificationError("验证程序自身不可作为 terminal-unavailable 子夹具")
        }

        let supervisor = ProcessSupervisor()
        let handle = try await supervisor.spawn(
            LaunchSpec(
                executable: executable.url,
                arguments: ["--fixture-terminal-injected-error"],
                workingDirectory: fixtureDirectory,
                environment: ProcessInfo.processInfo.environment
            )
        )
        try await waitUntil("非 ECHILD terminal-unavailable 子夹具清理") {
            _ = await supervisor.checkExit(handle)
            return await supervisor.cleanupComplete()
        }
        let text = await supervisor.logSnapshot().map(\.text).joined(separator: "\n")
        try expect(
            text.contains("TERMINAL_INJECTED_ERROR_OK"),
            "非 ECHILD terminal-unavailable 子夹具失败：\(text)"
        )
    }

}

/// 仅用于验证身份读取失败的安全降级；它不伪造 PID，也不对系统进程做任何操作。
private final class IdentityCaptureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    func capture(_ pid: pid_t) -> ProcessIdentity? {
        lock.withLock {
            shouldFail ? nil : ProcessIdentity.capture(pid: pid)
        }
    }

    func failFutureCaptures() {
        lock.withLock {
            shouldFail = true
        }
    }
}
