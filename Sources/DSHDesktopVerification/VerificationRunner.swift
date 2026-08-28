import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

@main
struct DSHDesktopVerification {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--fixture-lock-probe" {
            exit(runLockProbe(arguments: Array(arguments.dropFirst())))
        }
        if arguments.first == "--fixture-listener" {
            exit(runListener(arguments: Array(arguments.dropFirst())))
        }
        if arguments.first == "--fixture-http-listener" {
            exit(runHTTPListener(arguments: Array(arguments.dropFirst())))
        }
        if arguments.first == "--fixture-term-state" {
            exit(runTermStateProbe())
        }
        if arguments.first == "--fixture-terminal-injected-error" {
            exit(await runInjectedTerminalUnavailableFixture())
        }

        let skipsCurrentExternalProbe = arguments.contains("--skip-current-external-probe")

        var failures: [String] = []

        await run("固定地址与状态机") {
            try verifyLocalAddressAndStateReducer()
        } failures: { failures.append($0) }

        await run("DSH 定位与启动环境") {
            try verifyLocatorAndEnvironment()
        } failures: { failures.append($0) }

        await run("DSH 更新检查基础设施") {
            try await verifyDSHUpdateFoundation()
        } failures: { failures.append($0) }

        await run("App Release 只读检查基础设施") {
            try verifyAppUpdateFoundation()
        } failures: { failures.append($0) }

        await run("自动更新检查与安全下载基础设施") {
            try await verifyAutomaticUpdateAndDownloadFoundation()
        } failures: { failures.append($0) }

        await run("App 私有提醒插件与桥协议") {
            try verifyNotificationPluginAndBridgeProtocol()
        } failures: { failures.append($0) }

        await run("App 私有终端插件、bridge 与底部布局") {
            try verifyTerminalPluginBridgeAndDockLayout()
        } failures: { failures.append($0) }

        await run("App 私有执行操作折叠插件") {
            try verifyOperationFoldingPlugin()
        } failures: { failures.append($0) }

        await run("App 私有双 Esc 快捷键插件") {
            try verifyShortcutPlugin()
        } failures: { failures.append($0) }

        await run("真实 PTY 与工作区终端进程组清理") {
            try await verifyPTYProcessGroupCleanup()
        } failures: { failures.append($0) }

        await run("SIGCHLD 与单实例锁") {
            try verifySIGCHLDDispositionAndSingleInstanceLock()
        } failures: { failures.append($0) }

        await run("有界日志与导航策略") {
            try verifyRingLogAndNavigationPolicy()
        } failures: { failures.append($0) }

        await run("WebKit 持久数据存储") {
            try verifyPersistentWebsiteDataStore()
        } failures: { failures.append($0) }

        await run("标准编辑快捷键响应链") {
            try verifyStandardEditMenu()
        } failures: { failures.append($0) }

        await run("受控 HTTP Probe 场景") {
            try await verifyServiceProbeFixtures()
        } failures: { failures.append($0) }

        if skipsCurrentExternalProbe {
            print("SKIP: 当前 3080 的只读 Probe（调用方明确要求不访问现有服务）")
        } else {
            await run("当前 3080 的只读 Probe") {
                try await verifyCurrentExternalProbe()
            } failures: { failures.append($0) }
        }

        await run("受控子进程的 spawn/reap/TERM") {
            try await verifyProcessSupervisor()
        } failures: { failures.append($0) }

        await run("受控监听端口归属") {
            try await verifyLocalServiceOwnership()
        } failures: { failures.append($0) }

        await run("terminal-unavailable 安全降级") {
            try await verifyTerminalUnavailableSafety()
        } failures: { failures.append($0) }

        if failures.isEmpty {
            print("PASS: DSHDesktopVerification")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }

    @MainActor
    private static func run(
        _ name: String,
        body: @MainActor () async throws -> Void,
        failures: (String) -> Void
    ) async {
        do {
            try await body()
            print("PASS: \(name)")
        } catch {
            failures("\(name)：\(error.localizedDescription)")
        }
    }

}
