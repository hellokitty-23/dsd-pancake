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

    private static func verifyLocalAddressAndStateReducer() throws {
        try expect(LocalService.url.absoluteString == "http://127.0.0.1:3080/", "固定本地地址不正确")
        try expect(
            TerminationGateSnapshot.spawnTransaction.requiresDeferredTermination
                && TerminationGateSnapshot.spawnTransaction.waitsForSpawnResult,
            "spawn transaction 必须阻止 AppKit 提前退出"
        )
        try expect(
            !TerminationGateSnapshot.clear.requiresDeferredTermination
                && !TerminationGateSnapshot.clear.waitsForSpawnResult,
            "clear termination gate 不应阻止正常退出"
        )

        var terminationTransactions = TerminationTransactionRegistry()
        let firstTermination = terminationTransactions.begin(originalGate: .stoppable)
        try expect(terminationTransactions.isActive(firstTermination), "首个退出事务未激活")
        try expect(
            terminationTransactions.restoredGateAfterCancellation(for: firstTermination) == .stoppable,
            "未发送信号时未保留原本的 stoppable 门控"
        )
        try expect(
            terminationTransactions.markSignalRequested(for: firstTermination),
            "首个退出事务未能标记 SIGTERM 请求"
        )
        try expect(
            terminationTransactions.restoredGateAfterCancellation(for: firstTermination) == .cleanupPending,
            "已请求 SIGTERM 后错误恢复 stoppable 门控"
        )
        try expect(terminationTransactions.markReplySent(for: firstTermination), "首个退出事务未取得 reply 权")
        try expect(!terminationTransactions.markReplySent(for: firstTermination), "同一退出事务错误允许第二次 reply")
        try expect(terminationTransactions.cancel(firstTermination), "首个退出事务无法取消")
        let secondTermination = terminationTransactions.begin(originalGate: .cleanupPending)
        try expect(secondTermination != firstTermination, "取消后没有生成新的退出事务 ID")
        try expect(!terminationTransactions.isActive(firstTermination), "旧退出事务仍可影响新事务")
        try expect(!terminationTransactions.markReplySent(for: firstTermination), "旧退出事务错误取得新 reply 权")
        try expect(terminationTransactions.markReplySent(for: secondTermination), "新退出事务未取得 reply 权")

        var confirmationGate = TerminationConfirmationGate()
        try expect(confirmationGate.takePresentedTransaction() == nil, "未展示确认框时错误取得确认权")
        confirmationGate.present(for: secondTermination)
        try expect(
            confirmationGate.takePresentedTransaction() == secondTermination,
            "重复退出未取得当前确认框的确认权"
        )
        try expect(confirmationGate.takePresentedTransaction() == nil, "同一确认框错误允许第二次确认")
        confirmationGate.present(for: secondTermination)
        confirmationGate.clear(for: firstTermination)
        try expect(
            confirmationGate.takePresentedTransaction() == secondTermination,
            "历史事务错误清除了当前确认框"
        )

        let initial = CoordinatedState()
        let probing = StateReducer.reduce(initial, action: .beginProbe(generation: 7))
        let stale = StateReducer.reduce(probing, action: .probeCompleted(generation: 6, result: .dshLikely))
        try expect(stale == probing, "过期 generation 结果不应改变状态")

        let unavailable = StateReducer.reduce(
            probing,
            action: .probeCompleted(generation: 7, result: .unavailable(.connectionFailed))
        )
        try expect(unavailable.phase == .locating, "无响应后应进入定位")
        try expect(unavailable.mayStartNewProcess, "无活动句柄时应允许预检后启动")

        let unknown = StateReducer.reduce(
            probing,
            action: .probeCompleted(generation: 7, result: .reachableUnknown(.manifestMissing))
        )
        try expect(unknown.phase == .awaitingConsent(.reachableUnknown(.manifestMissing)), "未知服务未进入确认状态")
        let rejected = StateReducer.reduce(unknown, action: .rejectedUnknownService)
        try expect(rejected.phase == .idle, "拒绝未知服务后未回到 idle")

        let preflight = StateReducer.reduce(unavailable, action: .beginPreflight(generation: 8))
        let spawning = StateReducer.reduce(preflight, action: .beginSpawn)
        let waitingReady = StateReducer.reduce(spawning, action: .spawned)
        try expect(waitingReady.hasActiveHandle, "spawned 后未记录活动 handle")
        let ownershipLost = StateReducer.reduce(waitingReady, action: .ownershipLost)
        try expect(
            ownershipLost.cleanup == .supervisionOnly && !ownershipLost.mayStartNewProcess,
            "失去停止权后仍允许新的 spawn"
        )
        let exited = StateReducer.reduce(waitingReady, action: .processExited)
        try expect(
            exited.cleanup == .drainingPipes && !exited.hasActiveHandle && !exited.mayStartNewProcess,
            "主进程退出后未保持 drain 阻塞"
        )
        let drained = StateReducer.reduce(exited, action: .pipesDrained)
        try expect(drained.phase == .serviceStopped && drained.mayStartNewProcess, "双 pipe EOF 后未恢复安全启动权")

        let invalidSpawn = StateReducer.reduce(exited, action: .beginSpawn)
        try expect(invalidSpawn == exited, "drain 未完成时错误允许新的 spawn")
        let cancelledQuit = StateReducer.reduce(exited, action: .cancelQuit)
        try expect(cancelledQuit.phase == .drainingProcessCleanup, "cleanup pending 时取消退出丢失 drain 状态")
    }

    private static func verifyLocatorAndEnvironment() throws {
        let echoURL = URL(fileURLWithPath: "/bin/echo")
        guard let executable = DSHExecutable(url: echoURL) else {
            throw VerificationError("测试可执行文件 /bin/echo 不可用")
        }
        let spec = LaunchEnvironment.makeSpec(
            executable: executable,
            baseEnvironment: ["PATH": "/usr/bin:/bin:/usr/bin", "HOME": "/tmp/dshd-home", "TMPDIR": "/tmp/dshd-tmp"]
        )
        try expect(spec.executable == echoURL, "启动对象未保持绝对路径")
        try expect(spec.arguments == ["web", "--no-open", "--host", "127.0.0.1", "--port", "3080"], "启动参数发生变化")
        try expect(spec.environment["PATH"]?.split(separator: ":").first == "/bin", "可执行文件目录未置于 PATH 首位")
        try expect(spec.environment["PATH"]?.split(separator: ":").filter { $0 == "/usr/bin" }.count == 1, "PATH 未去重")
        try expect(spec.workingDirectory.path == FileManager.default.homeDirectoryForCurrentUser.path, "工作目录不是用户主目录")
        let fallbackSpec = LaunchEnvironment.makeSpec(executable: executable, baseEnvironment: [:])
        try expect(fallbackSpec.environment["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path, "缺失 HOME 时未使用用户主目录")
        try expect(!(fallbackSpec.environment["TMPDIR"] ?? "").isEmpty, "缺失 TMPDIR 时未填充临时目录")
        let patchURL = URL(fileURLWithPath: "/tmp/dsd-pancake-notifications.yml")
        let patchedSpec = LaunchEnvironment.makeSpec(
            executable: executable,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/dshd-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/dshd-home", isDirectory: true),
            notificationPatchURL: patchURL
        )
        try expect(
            patchedSpec.arguments == [
                "--profile", "web",
                "--patch", patchURL.path,
                "--no-open",
                "--host", "127.0.0.1",
                "--port", "3080",
            ],
            "带提醒覆盖层时没有使用 DSH launcher 的 --profile/--patch 参数"
        )
        let terminalPatchURL = URL(fileURLWithPath: "/tmp/dsd-pancake-terminal.yml")
        let doublyPatchedSpec = LaunchEnvironment.makeSpec(
            executable: executable,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/dshd-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/dshd-home", isDirectory: true),
            notificationPatchURL: patchURL,
            terminalPatchURL: terminalPatchURL
        )
        try expect(
            doublyPatchedSpec.arguments == [
                "--profile", "web",
                "--patch", patchURL.path,
                "--patch", terminalPatchURL.path,
                "--no-open",
                "--host", "127.0.0.1",
                "--port", "3080",
            ],
            "两个 App 私有插件没有以独立 launcher --patch 顺序启动"
        )
        try expect(
            DSHLocator().locate(lastChosenPath: echoURL.path)?.url == echoURL,
            "用户上次选择路径未优先于固定候选路径"
        )
    }

    private static func verifyDSHUpdateFoundation() async throws {
        guard let rc2 = SemanticVersion("0.1.1-rc.2"),
              let rc10 = SemanticVersion("0.1.1-rc.10"),
              let stable = SemanticVersion("0.1.1"),
              let nextPatch = SemanticVersion("0.1.2"),
              let buildOne = SemanticVersion("1.0.0+build.1"),
              let buildTwo = SemanticVersion("1.0.0+build.2") else {
            throw VerificationError("合法 SemVer（语义版本）无法解析")
        }
        try expect(rc2 < rc10 && rc10 < stable && stable < nextPatch, "预发布版本比较顺序错误")
        try expect(buildOne == buildTwo, "SemVer build metadata（构建元数据）错误影响版本优先级")
        try expect(
            SemanticVersion.extract(from: "DeepSeek Harness dsh v0.1.1-rc.2\n") == rc2,
            "无法从 dsh --version 输出提取版本"
        )
        try expect(
            SemanticVersion.extract(from: "DeepSeek Harness dsh 0.1.1oops\n") == nil,
            "版本提取错误接受了尾随字符"
        )
        try expect(
            DSHUpdateService.parseNPMViewLatestOutput(#""0.1.1-rc.2""#) == rc2,
            "无法解析 npm latest 的 JSON 字符串输出"
        )
        try expect(
            DSHUpdateService.parseNPMViewLatestOutput("[\n  \"0.1.1-rc.2\"\n]") == rc2,
            "无法解析 npm 12 的单元素 JSON 数组输出"
        )
        try expect(
            DSHUpdateService.parseNPMViewLatestOutput(#"["0.1.1-rc.2", "0.1.1"]"#) == nil,
            "错误接受了含多个 latest 版本的歧义 JSON 数组"
        )
        try expect(SemanticVersion("01.0.0") == nil, "接受了带前导零的非法 SemVer")

        let dummyDSH = URL(fileURLWithPath: "/opt/example/lib/node_modules/@deepseek-ai/dsh/lib/bin.js")
        let dummyNPM = URL(fileURLWithPath: "/opt/example/bin/npm")
        let dummyRoot = URL(fileURLWithPath: "/opt/example/lib/node_modules", isDirectory: true)
        try expect(
            DSHUpdateCheck(
                dshExecutable: dummyDSH,
                npmExecutable: dummyNPM,
                npmGlobalRoot: dummyRoot,
                currentVersion: rc2,
                latestVersion: rc10
            ).disposition == .updateAvailable,
            "旧版本没有判定为可更新"
        )
        try expect(
            DSHUpdateCheck(
                dshExecutable: dummyDSH,
                npmExecutable: dummyNPM,
                npmGlobalRoot: dummyRoot,
                currentVersion: stable,
                latestVersion: rc10
            ).disposition == .newerThanLatest,
            "较新版本错误触发降级"
        )
        try expect(
            DSHUpdateService.path(
                dummyDSH,
                isInside: dummyRoot
                    .appendingPathComponent("@deepseek-ai", isDirectory: true)
                    .appendingPathComponent("dsh", isDirectory: true)
            ),
            "全局 npm 包内的 dsh 没有通过来源边界"
        )
        try expect(
            !DSHUpdateService.path(
                URL(fileURLWithPath: "/opt/example/lib/node_modules/@deepseek-ai/dsh-evil/lib/bin.js"),
                isInside: dummyRoot
                    .appendingPathComponent("@deepseek-ai", isDirectory: true)
                    .appendingPathComponent("dsh", isDirectory: true)
            ),
            "相似路径前缀错误通过全局 npm 来源边界"
        )
        try expect(
            DSHUpdateService.updateArguments == [
                "install", "--global", "@deepseek-ai/dsh@latest", "--no-audit", "--no-fund",
            ],
            "更新命令不是固定的 @deepseek-ai/dsh@latest 参数数组"
        )

        let commandOutput = try await OneShotCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["0.1.1-rc.2\n"],
            timeout: 5,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "TMPDIR": "/tmp"],
            homeDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        try expect(commandOutput.succeeded, "受控单次命令执行失败")
        try expect(commandOutput.stdout == "0.1.1-rc.2", "单次命令没有分离并保留 stdout")
    }

    private static func verifyAppUpdateFoundation() throws {
        guard let currentVersion = SemanticVersion("0.0.1") else {
            throw VerificationError("无法构造 App 当前版本 fixture")
        }
        let releaseURL = URL(
            string: "https://github.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2"
        )!
        let check = try AppUpdateService.parseLatestReleaseURL(
            releaseURL,
            currentVersion: currentVersion,
            currentBuild: "36"
        )
        try expect(check.disposition == .updateAvailable, "较新的 App Release 未判定为可选更新")
        try expect(check.latestVersion == SemanticVersion("0.0.2"), "App Release tag 版本解析错误")
        try expect(
            check.releasePageURL.absoluteString
                == "https://github.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2",
            "App Release 页面地址解析错误"
        )
        try expect(
            check.downloadURL?.absoluteString
                == "https://github.com/hellokitty-23/dsd-pancake/releases/download/v0.0.2/DSD-Pancake-v0.0.2-arm64.dmg",
            "App 更新检查没有生成受约束的 arm64 DMG 下载地址"
        )
        try expect(
            check.checksumURL?.absoluteString
                == "https://github.com/hellokitty-23/dsd-pancake/releases/download/v0.0.2/DSD-Pancake-v0.0.2-arm64.dmg.sha256",
            "App 更新检查没有生成与 DMG 对应的 SHA-256 校验地址"
        )

        let sameVersion = AppUpdateCheck(
            currentVersion: currentVersion,
            currentBuild: "36",
            latestVersion: currentVersion,
            releasePageURL: check.releasePageURL,
            downloadURL: check.downloadURL,
            checksumURL: check.checksumURL
        )
        try expect(sameVersion.disposition == .upToDate, "相同 App 版本未判定为最新")

        do {
            _ = try AppUpdateService.parseLatestReleaseURL(
                URL(string: "https://example.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2")!,
                currentVersion: currentVersion,
                currentBuild: "36"
            )
            throw VerificationError("非 GitHub 项目地址错误通过 App 更新来源边界")
        } catch let error as AppUpdateError {
            guard case .untrustedReleaseURL = error else {
                throw VerificationError("非 GitHub 项目地址返回了错误类型：\(error)")
            }
        }

        do {
            _ = try AppUpdateService.parseLatestReleaseURL(
                URL(
                    string: "https://github.com/hellokitty-23/dsd-pancake/releases/tag/v0.0.2-rc.1"
                )!,
                currentVersion: currentVersion,
                currentBuild: "36"
            )
            throw VerificationError("预发布 App Release 错误进入正式更新通道")
        } catch let error as AppUpdateError {
            guard error == .unstableRelease else {
                throw VerificationError("预发布 App Release 返回了错误类型：\(error)")
            }
        }
    }

    private static func verifyAutomaticUpdateAndDownloadFoundation() async throws {
        guard let current = SemanticVersion("0.0.1"),
              let latest = SemanticVersion("0.0.2") else {
            throw VerificationError("无法构造自动更新检查版本 fixture")
        }

        let origin = Date(timeIntervalSince1970: 1_000_000)
        let schedule = AutomaticUpdateCheckSchedule.hourly
        try expect(
            schedule.dueSources(lastAppCheckAt: nil, lastDSHCheckAt: nil, now: origin) == [.app, .dsh],
            "首次启动没有同时检查 App 和 DSH"
        )
        try expect(
            schedule.dueSources(
                lastAppCheckAt: origin,
                lastDSHCheckAt: origin,
                now: origin.addingTimeInterval(59 * 60)
            ).isEmpty,
            "未满一小时错误触发自动检查"
        )
        try expect(
            schedule.dueSources(
                lastAppCheckAt: origin,
                lastDSHCheckAt: origin,
                now: origin.addingTimeInterval(60 * 60)
            ) == [.app, .dsh],
            "恰满一小时没有触发独立自动检查"
        )
        try expect(
            schedule.dueSources(
                lastAppCheckAt: origin.addingTimeInterval(60 * 60),
                lastDSHCheckAt: origin,
                now: origin.addingTimeInterval(60 * 60)
            ) == [.dsh],
            "手动刷新 App 后错误重复检查 App，或遗漏到期 DSH"
        )
        try expect(
            schedule.nextCheckAt(
                lastAppCheckAt: origin.addingTimeInterval(-2 * 60 * 60),
                lastDSHCheckAt: origin.addingTimeInterval(-3 * 60 * 60),
                now: origin
            ) == origin,
            "睡眠恢复后下一次检查不应补跑多个历史时点"
        )

        let cachedApp = CachedAppUpdate(latestVersion: latest)
        try expect(cachedApp.applies(to: current), "较新的 App 缓存没有恢复为提示")
        try expect(!cachedApp.applies(to: latest), "相同 App 版本错误保留旧提示")

        let cachedDSH = CachedDSHUpdate(
            executablePath: "/opt/homebrew/bin/dsh",
            currentVersion: current,
            latestVersion: latest
        )
        try expect(
            cachedDSH.applies(to: "/opt/homebrew/bin/dsh", currentVersion: current),
            "同一路径和版本的 DSH 缓存没有恢复"
        )
        try expect(
            !cachedDSH.applies(to: "/usr/local/bin/dsh", currentVersion: current)
                && !cachedDSH.applies(to: "/opt/homebrew/bin/dsh", currentVersion: latest),
            "路径或当前版本变化后仍错误保留 DSH 缓存"
        )

        var cacheState = AutomaticUpdateCheckState(dshUpdate: cachedDSH)
        let manualCheckAt = origin.addingTimeInterval(123)
        cacheState.apply(
            appResult: .available(cachedApp),
            dshResult: .failed,
            checkedAt: manualCheckAt
        )
        try expect(
            cacheState.lastAppCheckAt == manualCheckAt
                && cacheState.lastDSHCheckAt == manualCheckAt
                && cacheState.appUpdate == cachedApp
                && cacheState.dshUpdate == cachedDSH,
            "App 成功与 DSH 失败没有独立刷新时间并保留既有缓存"
        )
        try expect(
            cacheState.availableUpdateCount == 2
                && UpdateIndicatorPresentation.label(forAvailableUpdateCount: 2) == "发现 2 项可选更新"
                && UpdateIndicatorPresentation.label(forAvailableUpdateCount: 1) == "发现 1 项可选更新"
                && UpdateIndicatorPresentation.label(forAvailableUpdateCount: 0) == nil
                && UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: 1)
                && !UpdateIndicatorPresentation.isVisible(forAvailableUpdateCount: 0),
            "标题栏更新图标没有严格跟随可选更新状态"
        )

        let laterCheckAt = manualCheckAt.addingTimeInterval(1)
        cacheState.apply(
            appResult: .current,
            dshResult: .available(cachedDSH),
            checkedAt: laterCheckAt
        )
        try expect(
            cacheState.lastAppCheckAt == laterCheckAt
                && cacheState.lastDSHCheckAt == laterCheckAt
                && cacheState.appUpdate == nil
                && cacheState.dshUpdate == cachedDSH,
            "手动检查后的 current / available 独立归约不正确"
        )

        cacheState.invalidateDSHUpdate(
            executablePath: "/usr/local/bin/dsh",
            currentVersion: current
        )
        try expect(cacheState.dshUpdate == nil, "DSH 路径变化后没有失效旧更新缓存")
        cacheState = AutomaticUpdateCheckState(appUpdate: cachedApp)
        cacheState.invalidateAppUpdate(for: latest)
        try expect(cacheState.appUpdate == nil, "App 版本追平后没有失效旧更新缓存")

        guard let cachedCheck = AppUpdateService.cachedCheck(
            currentVersion: current.rawValue,
            currentBuild: "36",
            latestVersion: latest.rawValue
        ) else {
            throw VerificationError("App 缓存无法恢复固定 Release 地址")
        }
        try expect(
            cachedCheck.disposition == .updateAvailable
                && cachedCheck.downloadURL?.lastPathComponent == "DSD-Pancake-v0.0.2-arm64.dmg"
                && cachedCheck.checksumURL?.lastPathComponent == "DSD-Pancake-v0.0.2-arm64.dmg.sha256",
            "App 缓存没有以固定 Release 文件名恢复可选更新"
        )
        let fixedURLs = try AppReleaseDownloadService.fixedReleaseURLs(for: cachedCheck)
        try expect(
            fixedURLs.0 == cachedCheck.downloadURL && fixedURLs.1 == cachedCheck.checksumURL,
            "安全下载没有接受由固定 Release tag 推导出的地址"
        )

        let forgedAssetCheck = AppUpdateCheck(
            currentVersion: current,
            currentBuild: "36",
            latestVersion: latest,
            releasePageURL: cachedCheck.releasePageURL,
            downloadURL: URL(string: "https://objects.githubusercontent.com/forged.dmg")!,
            checksumURL: URL(string: "https://objects.githubusercontent.com/forged.dmg.sha256")!
        )
        do {
            _ = try AppReleaseDownloadService.fixedReleaseURLs(for: forgedAssetCheck)
            throw VerificationError("下载器错误接受了非固定 GitHub 初始地址")
        } catch let error as AppReleaseDownloadError {
            try expect(
                error == .untrustedRedirect("https://objects.githubusercontent.com/forged.dmg"),
                "伪造 Release 资产地址返回了错误类型：\(error)"
            )
        }

        guard let initialURL = cachedCheck.downloadURL else {
            throw VerificationError("缺少固定 DMG 初始地址")
        }
        try expect(
            AppUpdateService.isTrustedReleaseAssetRedirect(initialURL, expectedInitialURL: initialURL),
            "固定 GitHub 初始地址错误被拒绝"
        )
        try expect(
            AppUpdateService.isTrustedReleaseAssetRedirect(
                URL(string: "https://objects.githubusercontent.com/github-production-release-asset/example")!,
                expectedInitialURL: initialURL
            ),
            "GitHub 受控 Release 资产主机错误被拒绝"
        )
        try expect(
            !AppUpdateService.isTrustedReleaseAssetRedirect(
                URL(string: "https://github.com/hellokitty-23/dsd-pancake/releases/download/v0.0.2/other.dmg")!,
                expectedInitialURL: initialURL
            )
                && !AppUpdateService.isTrustedReleaseAssetRedirect(
                    URL(string: "https://downloads.example.com/DSD-Pancake-v0.0.2-arm64.dmg")!,
                    expectedInitialURL: initialURL
                ),
            "非固定 GitHub 初始地址或任意下载主机错误通过信任边界"
        )

        let filename = "DSD-Pancake-v0.0.2-arm64.dmg"
        let expectedHash = String(repeating: "a", count: 64)
        let validSidecar = Data("\(expectedHash)  \(filename)\n".utf8)
        try expect(
            try AppReleaseDownloadService.parseSHA256Sidecar(
                validSidecar,
                expectedFilename: filename
            ) == expectedHash,
            "严格 SHA-256 sidecar 无法解析"
        )
        for invalidSidecar in [
            Data("\(expectedHash)  other.dmg\n".utf8),
            Data("\(expectedHash)  \(filename)\n\n".utf8),
            Data("not-a-hash  \(filename)\n".utf8),
        ] {
            do {
                _ = try AppReleaseDownloadService.parseSHA256Sidecar(
                    invalidSidecar,
                    expectedFilename: filename
                )
                throw VerificationError("错误接受了格式或文件名不可信的 SHA-256 sidecar")
            } catch let error as AppReleaseDownloadError {
                try expect(error == .invalidChecksumFile, "损坏 sidecar 返回了错误类型：\(error)")
            }
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "dsd-pancake-update-download-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let existingFile = directory.appendingPathComponent(filename)
        try Data("old".utf8).write(to: existingFile, options: .withoutOverwriting)
        let uniqueDestination = try AppReleaseDownloadService.uniqueDestinationURL(
            in: directory,
            filename: filename
        )
        try expect(
            uniqueDestination.lastPathComponent == "DSD-Pancake-v0.0.2-arm64 (1).dmg"
                && fileManager.fileExists(atPath: existingFile.path),
            "下载目标没有保留同名既有文件并生成无覆盖名称"
        )

        let digestFixture = directory.appendingPathComponent("digest-fixture")
        try Data("abc".utf8).write(to: digestFixture, options: .withoutOverwriting)
        try expect(
            try AppReleaseDownloadService.sha256(of: digestFixture)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "下载文件的 SHA-256 计算错误"
        )

        let cancelledDownload = AppReleaseDownloadCancellation()
        cancelledDownload.cancel()
        try expect(cancelledDownload.isCancelled, "下载取消令牌没有保存已取消状态")
        do {
            _ = try AppReleaseDownloadService.sha256(
                of: digestFixture,
                cancellation: cancelledDownload
            )
            throw VerificationError("已取消下载仍继续计算文件哈希")
        } catch is CancellationError {
            // 取消后不读取或保留本次临时文件，是下载器的基础边界。
        }

        let releaseFixtureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "dsd-pancake-release-download-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: releaseFixtureDirectory, withIntermediateDirectories: true)
        defer {
            ReleaseAssetURLProtocol.reset()
            try? fileManager.removeItem(at: releaseFixtureDirectory)
        }

        let fixtureDownloader = AppReleaseDownloadService(
            makeSessionConfiguration: { requestTimeout, resourceTimeout in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = requestTimeout
                configuration.timeoutIntervalForResource = resourceTimeout
                configuration.protocolClasses = [ReleaseAssetURLProtocol.self]
                return configuration
            }
        )
        let fixtureDMG = Data("fixture-dmg-payload".utf8)
        let fixtureDigestURL = releaseFixtureDirectory.appendingPathComponent("expected-digest")
        try fixtureDMG.write(to: fixtureDigestURL, options: .withoutOverwriting)
        let fixtureDigest = try AppReleaseDownloadService.sha256(of: fixtureDigestURL)
        try fileManager.removeItem(at: fixtureDigestURL)
        let fixtureSidecar = Data("\(fixtureDigest)  \(filename)\n".utf8)

        ReleaseAssetURLProtocol.install { request in
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            let body = isChecksum ? fixtureSidecar : fixtureDMG
            return ReleaseAssetURLProtocol.Fixture(
                status: 200,
                headers: [
                    "Content-Type": isChecksum ? "text/plain" : "application/x-apple-diskimage",
                    "Content-Length": "\(body.count)",
                ],
                body: body
            )
        }
        let preflightDigest = try await fixtureDownloader.verifyChecksum(for: cachedCheck)
        try expect(
            preflightDigest == fixtureDigest,
            "Popover 下载预验证没有接受有效 checksum sidecar"
        )
        let currentReleaseCheck = AppUpdateCheck(
            currentVersion: latest,
            currentBuild: "37",
            latestVersion: latest,
            releasePageURL: cachedCheck.releasePageURL,
            downloadURL: cachedCheck.downloadURL,
            checksumURL: cachedCheck.checksumURL
        )
        do {
            _ = try await fixtureDownloader.verifyChecksum(for: currentReleaseCheck)
            throw VerificationError("当前已是最新版本时仍进入内置下载预验证")
        } catch let error as AppReleaseDownloadError {
            try expect(error == .updateNotAvailable, "非可选更新预验证返回了错误类型：\(error)")
        }
        let existingDownload = releaseFixtureDirectory.appendingPathComponent(filename)
        try Data("user-file".utf8).write(to: existingDownload, options: .withoutOverwriting)
        let downloaded = try await fixtureDownloader.download(
            check: cachedCheck,
            downloadsDirectory: releaseFixtureDirectory
        )
        let preservedUserFile = try Data(contentsOf: existingDownload)
        let downloadedDMG = try Data(contentsOf: downloaded.fileURL)
        let successfulDownloadEntries = try fileManager.contentsOfDirectory(
            at: releaseFixtureDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            downloaded.fileURL.lastPathComponent == "DSD-Pancake-v0.0.2-arm64 (1).dmg"
                && preservedUserFile == Data("user-file".utf8)
                && downloadedDMG == fixtureDMG
                && successfulDownloadEntries.allSatisfy { !$0.lastPathComponent.hasSuffix(".part") },
            "受控下载没有保留同名用户文件、验证内容或清理 .part 临时文件"
        )

        let mismatchDirectory = releaseFixtureDirectory.appendingPathComponent("mismatch", isDirectory: true)
        try fileManager.createDirectory(at: mismatchDirectory, withIntermediateDirectories: true)
        ReleaseAssetURLProtocol.install { request in
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            let body = isChecksum ? fixtureSidecar : Data("tampered-dmg".utf8)
            return ReleaseAssetURLProtocol.Fixture(
                status: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body
            )
        }
        do {
            _ = try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: mismatchDirectory
            )
            throw VerificationError("哈希不匹配的 DMG 错误完成下载")
        } catch let error as AppReleaseDownloadError {
            guard case .checksumMismatch = error else {
                throw VerificationError("哈希不匹配返回了错误类型：\(error)")
            }
        }
        let mismatchEntries = try fileManager.contentsOfDirectory(
            at: mismatchDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            mismatchEntries.isEmpty,
            "哈希不匹配后残留了最终文件或 .part 临时文件"
        )

        let missingChecksumDirectory = releaseFixtureDirectory.appendingPathComponent(
            "missing-checksum",
            isDirectory: true
        )
        try fileManager.createDirectory(at: missingChecksumDirectory, withIntermediateDirectories: true)
        ReleaseAssetURLProtocol.install { request in
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            return ReleaseAssetURLProtocol.Fixture(
                status: isChecksum ? 404 : 500,
                headers: ["Content-Length": "0"],
                body: Data()
            )
        }
        do {
            _ = try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: missingChecksumDirectory
            )
            throw VerificationError("缺少 checksum sidecar 时错误开始了内置下载")
        } catch let error as AppReleaseDownloadError {
            try expect(
                error == .checksumUnavailable(statusCode: 404),
                "缺少 checksum sidecar 返回了错误类型：\(error)"
            )
        }
        let missingChecksumEntries = try fileManager.contentsOfDirectory(
            at: missingChecksumDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(
            missingChecksumEntries.isEmpty,
            "缺少 checksum sidecar 时仍写入了下载文件"
        )

        let cancelledDirectory = releaseFixtureDirectory.appendingPathComponent(
            "cancelled-before-start",
            isDirectory: true
        )
        try fileManager.createDirectory(at: cancelledDirectory, withIntermediateDirectories: true)
        let cancellationBeforeStart = AppReleaseDownloadCancellation()
        cancellationBeforeStart.cancel()
        do {
            _ = try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: cancelledDirectory,
                cancellation: cancellationBeforeStart
            )
            throw VerificationError("已取消下载仍开始了网络或文件写入")
        } catch is CancellationError {
            // 预期：开始前取消不会创建 .part 或最终文件。
        }
        let cancelledEntries = try fileManager.contentsOfDirectory(
            at: cancelledDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(cancelledEntries.isEmpty, "取消下载后残留了临时或最终文件")

        let inFlightCancellationDirectory = releaseFixtureDirectory.appendingPathComponent(
            "cancelled-in-flight",
            isDirectory: true
        )
        try fileManager.createDirectory(at: inFlightCancellationDirectory, withIntermediateDirectories: true)
        let requestRecorder = ReleaseAssetRequestRecorder()
        ReleaseAssetURLProtocol.install { request in
            requestRecorder.record(request)
            let isChecksum = request.url?.lastPathComponent.hasSuffix(".sha256") == true
            let body = isChecksum ? fixtureSidecar : fixtureDMG
            return ReleaseAssetURLProtocol.Fixture(
                status: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body,
                delay: isChecksum ? 0 : 0.5
            )
        }
        let inFlightCancellation = AppReleaseDownloadCancellation()
        let inFlightTask = Task {
            try await fixtureDownloader.download(
                check: cachedCheck,
                downloadsDirectory: inFlightCancellationDirectory,
                cancellation: inFlightCancellation
            )
        }
        var dmGRequestStarted = false
        for _ in 0 ..< 100 {
            if requestRecorder.containsPath(suffix: "/\(filename)") {
                dmGRequestStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(dmGRequestStarted, "受控下载没有在取消测试前进入 DMG 请求阶段")
        inFlightCancellation.cancel()
        do {
            _ = try await inFlightTask.value
            throw VerificationError("下载进行中取消后仍返回了成功结果")
        } catch is CancellationError {
            // 预期：取消会终止 URLSession 任务，并由下载器清理本次 .part 文件。
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let inFlightEntries = try fileManager.contentsOfDirectory(
            at: inFlightCancellationDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(inFlightEntries.isEmpty, "下载进行中取消后残留了 .part 或最终文件")
    }

    private static func verifyNotificationPluginAndBridgeProtocol() throws {
        let replyEvent = DesktopNotificationEvent(eventID: "reply:session-1:42", kind: .reply)
        try expect(replyEvent != nil, "有效提醒事件 ID 被拒绝")
        let expectedReply = DesktopNotificationBridgeAction.notify(replyEvent!)
        let replyBody: [String: Any] = [
            "version": NSNumber(value: DesktopNotificationBridge.protocolVersion),
            "action": "notify",
            "eventID": "reply:session-1:42",
            "kind": "reply",
        ]
        try expect(DesktopNotificationBridge.decode(replyBody) == expectedReply, "有效 reply 桥事件未被解析")
        try expect(
            DesktopNotificationBridge.decode([
                "version": NSNumber(value: true),
                "action": "capabilities",
            ]) == nil,
            "Boolean 被错误接受为协议版本"
        )
        try expect(
            DesktopNotificationBridge.decode([
                "version": NSNumber(value: DesktopNotificationBridge.protocolVersion),
                "action": "capabilities",
                "extra": "forbidden",
            ]) == nil,
            "未知桥字段未被拒绝"
        )
        try expect(
            DesktopNotificationBridge.decode([
                "version": NSNumber(value: DesktopNotificationBridge.protocolVersion),
                "action": "notify",
                "eventID": "含有自由文本",
                "kind": "reply",
            ]) == nil,
            "自由文本事件 ID 未被拒绝"
        )
        try expect(
            DesktopNotificationKind.goalComplete.body == "任务已完成"
                && DesktopNotificationKind.goalBlocked.body == "任务需要你处理",
            "通知正文不应从网页携带内容"
        )
        try expect(
            !DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "前台可见窗口仍会显示重复提醒"
        )
        try expect(
            DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: true,
                mainWindowIsVisible: false,
                mainWindowIsMiniaturized: false
            ) && DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: false,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ) && DesktopNotificationPresentationPolicy.shouldPresent(
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: true
            ),
            "窗口隐藏、失焦或最小化时应允许提醒"
        )
        try expect(
            !DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .never,
                applicationIsActive: false,
                mainWindowIsVisible: false,
                mainWindowIsMiniaturized: false
            ),
            "永不模式仍允许投递"
        )
        try expect(
            DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .whenUnfocused,
                applicationIsActive: false,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "仅在未聚焦时模式错误阻断失焦提醒"
        )
        try expect(
            !DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .whenUnfocused,
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "仅在未聚焦时模式错误允许前台可见提醒"
        )
        try expect(
            DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: .always,
                applicationIsActive: true,
                mainWindowIsVisible: true,
                mainWindowIsMiniaturized: false
            ),
            "一律模式错误阻断前台可见提醒"
        )

        var recent = RecentNotificationEventIDs(capacity: 2)
        try expect(recent.insertIfNew("one"), "首个事件未被接受")
        try expect(!recent.insertIfNew("one"), "重复事件未去重")
        try expect(recent.insertIfNew("two") && recent.insertIfNew("three"), "有界去重未接受新事件")
        try expect(recent.insertIfNew("one"), "超出容量后最旧事件未允许重新出现")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsd-pancake-notification-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try fileManager.createDirectory(
            at: pluginDirectory.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-notifications\"}".utf8)
            .write(to: pluginDirectory.appendingPathComponent("package.json"))
        try Data("[]\n".utf8).write(to: pluginDirectory.appendingPathComponent("cordis.patch.yml"))
        try Data("export function apply() {}\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/index.js"))
        try Data("window.__ModuleLoader__.load({})\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/client.js"))

        guard let plugin = DSHNotificationPlugin(directory: pluginDirectory) else {
            throw VerificationError("完整的 App 私有提醒插件未被识别")
        }
        let workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let configuredHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let resolverLink = configuredHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        let linkedPath = try fileManager.destinationOfSymbolicLink(atPath: resolverLink.path)
        try expect(
            URL(fileURLWithPath: linkedPath, isDirectory: true).standardizedFileURL == pluginDirectory.standardizedFileURL,
            "提醒插件 resolver 链接未指向 App 私有插件"
        )
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        try expect(plugin.patchURL.lastPathComponent == "cordis.patch.yml", "提醒覆盖层路径不正确")

        try expect(
            DSHNotificationPlugin.resolveDSHHome(
                baseEnvironment: ["DSH_HOME": "relative-home"],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            ) == workingDirectory.appendingPathComponent("relative-home", isDirectory: true).standardizedFileURL,
            "相对 DSH_HOME 没有按 DSH 工作目录解析"
        )
        try expect(
            DSHNotificationPlugin.resolveDSHHome(
                baseEnvironment: ["DSH_HOME": "~/custom-dsh"],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            ) == homeDirectory.appendingPathComponent("custom-dsh", isDirectory: true).standardizedFileURL,
            "波浪号 DSH_HOME 没有按用户目录展开"
        )

        let occupiedHome = root.appendingPathComponent("occupied-home", isDirectory: true)
        let occupiedPath = occupiedHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: occupiedPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a symlink".utf8).write(to: occupiedPath)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": occupiedHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("占用的 resolver 路径被错误覆盖")
        } catch let error as DSHNotificationPluginError {
            guard case .resolverPathOccupied = error else {
                throw VerificationError("占用 resolver 路径返回了错误类型：\(error)")
            }
        }

        let foreignHome = root.appendingPathComponent("foreign-link-home", isDirectory: true)
        let foreignTarget = root.appendingPathComponent("foreign-plugin", isDirectory: true)
        try fileManager.createDirectory(at: foreignTarget, withIntermediateDirectories: true)
        try Data("{\"name\":\"@someone-else/plugin\"}".utf8)
            .write(to: foreignTarget.appendingPathComponent("package.json"))
        let foreignLink = foreignHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: foreignLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: foreignLink.path, withDestinationPath: foreignTarget.path)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": foreignHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("未知 resolver 符号链接被错误覆盖")
        } catch let error as DSHNotificationPluginError {
            guard case .resolverPathOccupied = error else {
                throw VerificationError("未知 resolver 符号链接返回了错误类型：\(error)")
            }
        }
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: foreignLink.path) == foreignTarget.path,
            "未知 resolver 符号链接被修改"
        )

        let sameNameHome = root.appendingPathComponent("same-name-link-home", isDirectory: true)
        let sameNameTarget = root.appendingPathComponent("same-name-plugin", isDirectory: true)
        try fileManager.createDirectory(at: sameNameTarget, withIntermediateDirectories: true)
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-notifications\"}".utf8)
            .write(to: sameNameTarget.appendingPathComponent("package.json"))
        let sameNameLink = sameNameHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: sameNameLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: sameNameLink.path, withDestinationPath: sameNameTarget.path)
        do {
            try plugin.prepareResolver(
                baseEnvironment: ["DSH_HOME": sameNameHome.path],
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            throw VerificationError("现存同名 resolver 符号链接被错误覆盖")
        } catch let error as DSHNotificationPluginError {
            guard case .resolverPathOccupied = error else {
                throw VerificationError("现存同名 resolver 符号链接返回了错误类型：\(error)")
            }
        }
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: sameNameLink.path) == sameNameTarget.path,
            "现存同名 resolver 符号链接被修改"
        )

        let staleHome = root.appendingPathComponent("stale-link-home", isDirectory: true)
        let staleLink = staleHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-notifications")
        try fileManager.createDirectory(at: staleLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: staleLink.path,
            withDestinationPath: root.appendingPathComponent("missing-old-app-plugin").path
        )
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": staleHome.path],
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        try expect(
            try fileManager.destinationOfSymbolicLink(atPath: staleLink.path) == pluginDirectory.path,
            "移动 App 后的失效 resolver 链接未被修复"
        )
    }

    private static func verifyTerminalPluginBridgeAndDockLayout() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsd-pancake-terminal-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        guard let request = DesktopTerminalWorkspaceRequest(
            sessionID: "session-42",
            workspacePath: workspaceURL.path
        ), let workspace = DesktopTerminalWorkspace(request: request, fileManager: fileManager) else {
            throw VerificationError("有效终端 workspace 请求未通过本机目录校验")
        }

        let syncBody: [String: Any] = [
            "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
            "action": "syncWorkspace",
            "sessionID": request.sessionID,
            "workspacePath": request.workspacePath,
        ]
        try expect(
            DesktopTerminalBridge.decode(syncBody) == .syncWorkspace(request),
            "有效终端 workspace bridge 请求未被解析"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "clearWorkspace",
            ]) == .clearWorkspace,
            "有效终端 workspace 清除请求未被解析"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: true),
                "action": "capabilities",
            ]) == nil,
            "Boolean 被错误接受为终端 bridge 协议版本"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "syncWorkspace",
                "sessionID": request.sessionID,
                "workspacePath": request.workspacePath,
                "command": "echo forbidden",
            ]) == nil,
            "包含 command 的终端 bridge 请求未被拒绝"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "syncWorkspace",
                "sessionID": request.sessionID,
                "workspacePath": "relative/workspace",
            ]) == nil,
            "相对 workspace path 被终端 bridge 接受"
        )
        try expect(
            DesktopTerminalBridge.decode([
                "version": NSNumber(value: DesktopTerminalBridge.protocolVersion),
                "action": "toggle",
                "sessionID": request.sessionID,
                "workspacePath": request.workspacePath,
            ]) == nil,
            "网页仍可通过 bridge 请求显示或隐藏原生终端"
        )
        try expect(
            DesktopTerminalWorkspaceRequest(
                sessionID: "session-42",
                workspacePath: workspaceURL.path + "\nunsafe"
            ) == nil,
            "带控制字符的 workspace path 被终端 bridge 接受"
        )

        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: false,
                isMainFrame: true,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == nil,
            "bridge 被禁用时仍接收终端操作"
        )
        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: true,
                isMainFrame: false,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == nil,
            "非主 frame 的终端 bridge 消息被接收"
        )
        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: true,
                isMainFrame: true,
                originScheme: "https",
                originHost: "example.com",
                originPort: 443
            ) == nil,
            "错误 origin 的终端 bridge 消息被接收"
        )
        try expect(
            DesktopTerminalBridgeAdmission.decode(
                syncBody,
                bridgeEnabled: true,
                isMainFrame: true,
                originScheme: LocalService.url.scheme ?? "",
                originHost: LocalService.host,
                originPort: LocalService.port
            ) == .syncWorkspace(request),
            "已启用的本地主 frame 终端 bridge 消息未通过"
        )
        try expect(
            DesktopTerminalWorkspace(
                request: DesktopTerminalWorkspaceRequest(
                    sessionID: "session-42",
                    workspacePath: root.appendingPathComponent("missing", isDirectory: true).path
                )!,
                fileManager: fileManager
            ) == nil,
            "不存在的 workspace 允许启动终端"
        )

        let response = DesktopTerminalBridgeResponse.payload(supported: false, isOpen: false, workspaceAccepted: false)
        try expect(
            response["supported"] as? Bool == false
                && response["open"] as? Bool == false
                && response["workspacePath"] == nil,
            "终端 bridge 禁用响应泄漏路径或状态错误"
        )
        try expect(
            !DesktopTerminalBridgePolicy.mayEnable(serviceOwnership: .external, terminalPatchPrepared: true)
                && !DesktopTerminalBridgePolicy.mayEnable(serviceOwnership: .owned, terminalPatchPrepared: false)
                && DesktopTerminalBridgePolicy.mayEnable(serviceOwnership: .owned, terminalPatchPrepared: true),
            "external DSH 或缺失私有 patch 仍能启用终端 bridge"
        )

        var state = WorkspaceTerminalState()
        try expect(state.show(workspace: workspace) == .created, "首个 workspace 没有创建独立终端")
        guard let firstTab = state.activeTab else {
            throw VerificationError("首个 workspace 没有激活终端标签")
        }
        state.hide()
        try expect(
            !state.isPanelVisible && state.knownWorkspaces.contains(workspace) && state.tabs(for: workspace) == [firstTab],
            "收起面板错误结束了 shell 身份"
        )
        try expect(state.show(workspace: workspace) == .reused, "同一 workspace 切换 session 时没有复用终端")
        let secondTab = state.createTab(workspace: workspace)
        try expect(
            secondTab.id != firstTab.id
                && secondTab.ordinal == 2
                && state.tabs(for: workspace).count == 2
                && state.activeTab == secondTab,
            "新建终端标签没有创建独立 shell 身份"
        )
        try expect(
            state.select(tabID: firstTab.id) == firstTab && state.activeTab == firstTab,
            "同一 workspace 的终端标签不能切换"
        )
        try expect(
            state.close(tabID: firstTab.id) == firstTab
                && state.activeTab == secondTab
                && state.isPanelVisible,
            "关闭一个终端标签错误结束了同 workspace 的其它 shell"
        )

        let secondWorkspaceURL = root.appendingPathComponent("workspace-two", isDirectory: true)
        try fileManager.createDirectory(at: secondWorkspaceURL, withIntermediateDirectories: true)
        let secondRequest = DesktopTerminalWorkspaceRequest(
            sessionID: "session-43",
            workspacePath: secondWorkspaceURL.path
        )!
        let secondWorkspace = DesktopTerminalWorkspace(request: secondRequest, fileManager: fileManager)!
        try expect(state.show(workspace: secondWorkspace) == .created, "不同 workspace 错误复用了第一个终端")
        guard let secondWorkspaceTab = state.activeTab else {
            throw VerificationError("第二个 workspace 没有创建终端标签")
        }
        try expect(state.knownWorkspaces.count == 2, "不同 workspace 没有隔离终端状态")
        state.synchronize(workspace: workspace)
        try expect(
            !state.isPanelVisible && state.activeWorkspace == workspace && state.activeTab == secondTab,
            "workspace 切换时旧终端仍显示在新会话"
        )
        try expect(
            state.select(tabID: secondWorkspaceTab.id) == nil && state.activeTab == secondTab,
            "其它 workspace 的终端标签能显示在当前会话"
        )
        state.clearActiveWorkspace()
        try expect(
            !state.isPanelVisible && state.activeWorkspace == nil && state.knownWorkspaces.count == 2,
            "没有有效 workspace 时错误结束了已有 shell 或保留了旧会话身份"
        )
        state.synchronize(workspace: workspace)
        try expect(state.closeActiveTab() == secondTab, "关闭当前终端标签未返回正确标签")
        try expect(!state.knownWorkspaces.contains(workspace) && state.knownWorkspaces.contains(secondWorkspace), "关闭一个标签错误影响其它 workspace")
        try expect(state.closeAll() == Set([secondWorkspace]), "关闭全部终端没有精确返回待清理 workspace")

        let collapsed = TerminalDockLayout.collapsed(totalHeight: 700)
        let expanded = TerminalDockLayout.expanded(totalHeight: 700, requestedPanelHeight: 280)
        let oversized = TerminalDockLayout.expanded(totalHeight: 700, requestedPanelHeight: 9_999)
        let undersized = TerminalDockLayout.expanded(totalHeight: 700, requestedPanelHeight: 1)
        try expect(
            collapsed.webHeight == 700 && collapsed.panelHeight == 0,
            "收起状态没有让 WebView 占满原生内容区"
        )
        try expect(
            expanded.panelHeight == 280 && expanded.webHeight == collapsed.webHeight,
            "展开终端错误缩短了同时承载 DSH 侧栏的 WKWebView"
        )
        try expect(
            collapsed.conversationReservedHeight == 0
                && expanded.conversationReservedHeight == expanded.panelHeight + expanded.dividerHeight,
            "终端 dock 没有为右侧对话流提供与原生面板一致的预留高度"
        )
        try expect(
            oversized.panelHeight <= (700 - TerminalDockLayout.dividerHeight) * TerminalDockLayout.maximumFraction,
            "终端面板突破窗口 50% 高度上限"
        )
        try expect(
            TerminalDockLayout.dividerHeight == 1,
            "终端 dock 的可见分隔线必须保持为 1pt，避免割裂对话与终端"
        )
        try expect(TerminalDockLayout.maximumFraction == 0.5, "终端高度上限必须固定为可用窗口高度的 50%")
        try expect(
            undersized.panelHeight >= TerminalDockLayout.minimumPanelHeight,
            "常规窗口下终端面板未遵守 160px 最小高度"
        )
        let contentRegion = TerminalDockLayout.contentRegion(totalWidth: 1_280, sidebarWidth: 368)
        try expect(
            contentRegion.leading == 368 && contentRegion.width == 912,
            "终端 dock 没有从 DSH 左侧工程栏右边开始"
        )
        let fallbackRegion = TerminalDockLayout.contentRegion(totalWidth: 500, sidebarWidth: nil)
        try expect(
            fallbackRegion.leading == 260 && fallbackRegion.width == TerminalDockLayout.minimumContentWidth,
            "网页侧栏宽度尚未到达时的终端 dock 回退区域不安全"
        )

        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try fileManager.createDirectory(
            at: pluginDirectory.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@dsd-pancake/dsh-desktop-terminal\"}".utf8)
            .write(to: pluginDirectory.appendingPathComponent("package.json"))
        try Data("[]\n".utf8).write(to: pluginDirectory.appendingPathComponent("cordis.patch.yml"))
        try Data("export function apply() {}\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/index.js"))
        try Data("window.__ModuleLoader__.load({})\n".utf8)
            .write(to: pluginDirectory.appendingPathComponent("lib/client.js"))

        guard let plugin = DSHTerminalPlugin(directory: pluginDirectory, fileManager: fileManager) else {
            throw VerificationError("完整的 App 私有终端插件未被识别")
        }
        let configuredHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try plugin.prepareResolver(
            baseEnvironment: ["DSH_HOME": configuredHome.path],
            workingDirectory: workspaceURL,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            fileManager: fileManager
        )
        let resolverLink = configuredHome
            .appendingPathComponent("profiles/node_modules/@dsd-pancake/dsh-desktop-terminal")
        try expect(
            URL(
                fileURLWithPath: try fileManager.destinationOfSymbolicLink(atPath: resolverLink.path),
                isDirectory: true
            ).standardizedFileURL == pluginDirectory.standardizedFileURL,
            "终端插件 resolver 链接未指向 App 私有插件"
        )
        try expect(plugin.patchURL.lastPathComponent == "cordis.patch.yml", "终端覆盖层路径不正确")
    }

    private static func verifyPTYProcessGroupCleanup() async throws {
        let delegate = PTYFixtureDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: DispatchQueue(label: "io.github.hellokitty-23.dsd-pancake.verify.pty")
        )
        defer { process.terminate() }

        // `LocalProcess` / `forkpty` 是与 App 内 LocalProcessTerminalView 相同的 PTY
        // 后端。后台 sleep 用来证明我们清理的是 shell 所在的完整 process group，而
        // 不是只向直接 shell PID 发送一个普通信号。
        process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "sleep 30 & child=$!; printf '__DSD_PTY_CHILD__:%s\\n' \"$child\"; wait"],
            environment: [
                "PATH=/usr/bin:/bin",
                "HOME=/tmp",
                "TERM=xterm-256color",
                "LANG=en_US.UTF-8",
            ],
            execName: "-sh",
            currentDirectory: "/tmp"
        )

        let childPID = try await delegate.waitForChildPID(timeoutNanoseconds: 3_000_000_000)
        let shellPID = process.shellPid
        try expect(shellPID > 1, "真实 PTY 未返回 shell PID")
        let shellGroup = getpgid(shellPID)
        let childGroup = getpgid(childPID)
        try expect(shellGroup > 1 && shellGroup == childGroup, "PTY shell 与子进程不在同一 process group")

        try expect(TerminalProcessGroup.send(SIGTERM, to: shellGroup), "无法向 PTY process group 发送 SIGTERM")
        // 当前测试进程有时继承了忽略 SIGTERM 的 disposition（信号处理状态）；这正是
        // App 终端控制器必须有 SIGKILL 兜底的原因。先给正常退出窗口，再验证兜底能
        // 清理仍存活的完整 group。
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Darwin.kill(childPID, 0) == 0 {
            try expect(
                TerminalProcessGroup.send(SIGKILL, to: shellGroup),
                "PTY process group 未响应 SIGTERM 时无法执行 SIGKILL 兜底"
            )
        }
        process.terminate()
        try expect(
            await waitForDirectChildToReap(shellPID, timeoutNanoseconds: 3_000_000_000),
            "关闭终端后 shell 没有被 waitpid 回收"
        )
        try expect(
            await waitForProcessToExit(childPID, timeoutNanoseconds: 3_000_000_000),
            "关闭终端后 PTY 子进程仍然存活"
        )
    }

    private static func waitForDirectChildToReap(_ processID: pid_t, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            switch TerminalProcessGroup.reapIfExited(processID) {
            case .reaped, .noChild:
                return true
            case .running:
                break
            case .failed:
                return false
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func waitForProcessToExit(_ processID: pid_t, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            if Darwin.kill(processID, 0) != 0, errno == ESRCH {
                return true
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func verifySIGCHLDDispositionAndSingleInstanceLock() throws {
        var action = sigaction()
        try expect(sigaction(SIGCHLD, nil, &action) == 0, "无法读取 SIGCHLD disposition")
        let currentHandler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        let ignoredHandler = unsafeBitCast(SIG_IGN, to: UInt.self)
        try expect(currentHandler != ignoredHandler, "SIGCHLD 不得设为 SIG_IGN")
        try expect((action.sa_flags & Int32(SA_NOCLDWAIT)) == 0, "SIGCHLD 不得设置 SA_NOCLDWAIT")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshdesktop-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SingleInstanceLock.acquire(
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.verification",
            rootDirectory: root
        )
        try expect(first != nil, "首实例未能取得测试锁")
        let second = try SingleInstanceLock.acquire(
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.verification",
            rootDirectory: root
        )
        try expect(second == nil, "第二实例错误取得了启动权")
        withExtendedLifetime(first) {}
    }

    private static func verifyRingLogAndNavigationPolicy() throws {
        let log = RingLog(lineLimit: 2, byteLimit: 256)
        log.append(Data("first\nsecond".utf8), stream: .stdout)
        log.finish(stream: .stdout)
        log.append(Data("token=secret\nthird\n".utf8), stream: .stderr)
        let entries = log.snapshot()
        try expect(entries.count == 2, "环形日志未按行数上限覆盖")
        try expect(entries.contains { $0.text.contains("[REDACTED]") }, "敏感键值未遮盖")
        let redactedText = entries.map(\.text).joined(separator: "\n")
        try expect(!redactedText.contains("secret"), "普通敏感键值泄漏到日志")
        try expect(log.bytes <= 256, "环形日志超出字节上限")

        let authorizationLog = RingLog(lineLimit: 4, byteLimit: 1_024)
        authorizationLog.append(
            Data("Authorization: Bearer auth-secret\nAuthorization: Basic basic-secret\nCookie: session=session-secret; csrf=csrf-secret\nSet-Cookie: session-cookie-secret; Path=/\n".utf8),
            stream: .stderr
        )
        authorizationLog.finish(stream: .stderr)
        let authorizationText = authorizationLog.snapshot().map(\.text).joined(separator: "\n")
        try expect(!authorizationText.contains("auth-secret"), "Authorization Bearer 值泄漏到日志")
        try expect(!authorizationText.contains("basic-secret"), "Authorization Basic 值泄漏到日志")
        // `Set-Cookie` 可能在日志里被拆成多行；逐条断言而非拼接后跨行匹配，
        // 以验证每个原始头值都已在自己的输出行中遮盖。
        try expect(
            !authorizationLog.snapshot().contains {
                $0.text.contains("session-secret")
                    || $0.text.contains("csrf-secret")
                    || $0.text.contains("session-cookie-secret")
            },
            "Cookie 值泄漏到日志"
        )

        let byteBoundedLog = RingLog(lineLimit: 10, byteLimit: 64)
        byteBoundedLog.append(Data(repeating: 0x61, count: 512), stream: .stdout)
        byteBoundedLog.finish(stream: .stdout)
        try expect(byteBoundedLog.bytes <= 64, "单条超长日志未受字节上限约束")

        let oneByteLog = RingLog(lineLimit: 1, byteLimit: 1)
        oneByteLog.append(Data("😀".utf8), stream: .stdout)
        oneByteLog.finish(stream: .stdout)
        try expect(oneByteLog.bytes <= 1, "多字节日志在极小上限下越界")

        let noNewlineLog = RingLog(lineLimit: 4, byteLimit: 256)
        noNewlineLog.append(Data(repeating: 0x78, count: 512 * 1_024), stream: .stdout)
        try expect(
            noNewlineLog.retainedBytes <= 256,
            "无换行输出使日志驻留内存突破字节上限：\(noNewlineLog.retainedBytes)"
        )
        noNewlineLog.finish(stream: .stdout)
        try expect(noNewlineLog.retainedBytes <= 256, "无换行输出 finish 后仍突破内存上限")

        let fragmentedHeaderLog = RingLog(lineLimit: 8, byteLimit: 1_024)
        let delayedSecret = String(repeating: "p", count: 160) + "fragmented-cookie-secret"
        fragmentedHeaderLog.append(
            Data("Cookie: session=\(delayedSecret)\n".utf8),
            stream: .stdout
        )
        fragmentedHeaderLog.finish(stream: .stdout)
        try expect(
            !fragmentedHeaderLog.snapshot().contains { $0.text.contains("fragmented-cookie-secret") },
            "被切开的超长 Cookie 后半段泄漏到日志"
        )

        let twoStreamLog = RingLog(lineLimit: 32, byteLimit: 256)
        var twoStreamLine = Data(repeating: 0x6F, count: 224)
        twoStreamLine.append(0x0A)
        twoStreamLog.append(twoStreamLine, stream: .stdout)
        twoStreamLog.append(Data(repeating: 0x61, count: 32), stream: .stdout)
        twoStreamLog.append(Data(repeating: 0x62, count: 32), stream: .stderr)
        try expect(twoStreamLog.retainedBytes <= 256, "两路 pending 共同突破日志内存上限")

        let policy = WebNavigationPolicy()
        try expect(
            policy.decision(for: LocalService.url, isMainFrame: true, isUserInitiated: false) == .allowInWebView,
            "同源顶层导航应留在 WebView"
        )
        try expect(
            policy.decision(for: URL(string: "https://example.com")!, isMainFrame: true, isUserInitiated: true) == .openInDefaultBrowser,
            "用户点击外链应交给默认浏览器"
        )
        if case .cancelAndExplain = policy.decision(for: URL(string: "https://example.com")!, isMainFrame: true, isUserInitiated: false) {
            // 预期结果。
        } else {
            throw VerificationError("非用户触发的外链未被阻止")
        }
        if case .cancelAndExplain = policy.decision(for: URL(string: "mailto:test@example.com")!, isMainFrame: true, isUserInitiated: true) {
            // 预期结果。
        } else {
            throw VerificationError("未知协议未被阻止")
        }
        try expect(
            policy.decision(for: URL(string: "https://example.com/image.png")!, isMainFrame: false, isUserInitiated: false) == .allowInWebView,
            "子资源请求不应被顶层导航策略误拦截"
        )
    }

    @MainActor
    private static func verifyPersistentWebsiteDataStore() throws {
        try expect(WKWebsiteDataStore.default().isPersistent, "默认 WKWebsiteDataStore 必须为持久化存储")
    }

    @MainActor
    private static func verifyStandardEditMenu() throws {
        let menu = StandardEditMenu.makeMenu()
        try expect(menu.title == "编辑", "标准编辑菜单标题不正确")

        let expectedItems: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("撤销", "undo:", "z", .command),
            ("重做", "redo:", "z", [.command, .shift]),
            ("剪切", "cut:", "x", .command),
            ("拷贝", "copy:", "c", .command),
            ("粘贴", "paste:", "v", .command),
            ("全选", "selectAll:", "a", .command),
        ]
        for (title, selectorName, keyEquivalent, modifiers) in expectedItems {
            guard let item = menu.items.first(where: { $0.title == title }) else {
                throw VerificationError("编辑菜单缺少 \(title)")
            }
            try expect(item.action == Selector(selectorName), "\(title) 没有标准 selector")
            try expect(item.keyEquivalent == keyEquivalent, "\(title) 快捷键不正确")
            try expect(item.keyEquivalentModifierMask == modifiers, "\(title) 修饰键不正确")
            try expect(item.target == nil, "\(title) 不应绕过 responder chain 设置固定 target")
        }
    }

    private static func verifyServiceProbeFixtures() async throws {
        let dshServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .html()
            case "/manifest.webmanifest": .manifest()
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { dshServer.close() }
        try expect(await ServiceProbe(rootURL: dshServer.rootURL).probe() == .dshLikely, "正常 DSH fixture 未被识别")

        let unknownServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .html()
            case "/manifest.webmanifest": .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { unknownServer.close() }
        try expect(
            await ServiceProbe(rootURL: unknownServer.rootURL).probe() == .reachableUnknown(.manifestMissing),
            "manifest 缺失未进入确认分支"
        )

        let nonHTMLServer = try FixtureHTTPServer { _ in
            .response(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        defer { nonHTMLServer.close() }
        try expect(
            await ServiceProbe(rootURL: nonHTMLServer.rootURL).probe() == .reachableNonHTML(.rootNotHTML("application/json")),
            "非 HTML 根响应未进入端口异常分支"
        )

        let statusServer = try FixtureHTTPServer { _ in
            .response(status: 503, headers: ["Content-Type": "text/html"], body: Data("down".utf8))
        }
        defer { statusServer.close() }
        try expect(
            await ServiceProbe(rootURL: statusServer.rootURL).probe() == .reachableNonHTML(.rootNon2xx(503)),
            "非 2xx 根响应未阻止 spawn"
        )

        let sameOriginRedirectServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .response(status: 302, headers: ["Location": "/ready"], body: Data())
            case "/ready": .html()
            case "/manifest.webmanifest": .manifest()
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { sameOriginRedirectServer.close() }
        try expect(
            await ServiceProbe(rootURL: sameOriginRedirectServer.rootURL).probe() == .dshLikely,
            "同源重定向后的 HTML 未继续软识别"
        )

        let redirectTarget = try FixtureHTTPServer { _ in .html() }
        defer { redirectTarget.close() }
        let crossOriginRedirectServer = try FixtureHTTPServer { _ in
            .response(
                status: 302,
                headers: ["Location": redirectTarget.rootURL.absoluteString],
                body: Data()
            )
        }
        defer { crossOriginRedirectServer.close() }
        let crossOriginResult = await ServiceProbe(rootURL: crossOriginRedirectServer.rootURL).probe()
        try expect(
            crossOriginResult == .reachableNonHTML(.rootCrossOriginRedirect),
            "跨源重定向未进入端口异常分支：\(crossOriginResult)"
        )

        let manifestRedirectTarget = try FixtureHTTPServer { _ in .manifest() }
        defer { manifestRedirectTarget.close() }
        let manifestRedirectServer = try FixtureHTTPServer { path in
            switch path {
            case "/": .html()
            case "/manifest.webmanifest": .response(
                status: 302,
                headers: ["Location": manifestRedirectTarget.rootURL.absoluteString],
                body: Data()
            )
            default: .response(status: 404, headers: ["Content-Type": "text/plain"], body: Data())
            }
        }
        defer { manifestRedirectServer.close() }
        try expect(
            await ServiceProbe(rootURL: manifestRedirectServer.rootURL).probe() == .reachableUnknown(.manifestRedirectRejected),
            "manifest 跨源重定向未进入确认分支"
        )

        let largeBodyServer = try FixtureHTTPServer { _ in
            .response(
                status: 200,
                headers: ["Content-Type": "text/html", "Content-Length": "600000"],
                body: Data()
            )
        }
        defer { largeBodyServer.close() }
        try expect(
            await ServiceProbe(rootURL: largeBodyServer.rootURL).probe() == .reachableNonHTML(.rootBodyTooLarge),
            "超大根响应未被有界读取拒绝"
        )

        let timeoutServer = try FixtureHTTPServer { _ in .holdOpen(microseconds: 5_000_000) }
        defer { timeoutServer.close() }
        let timeoutResult = await ServiceProbe(rootURL: timeoutServer.rootURL).probe()
        try expect(
            timeoutResult == .unavailable(.totalTimeoutBeforeHTTPResponse),
            "无 HTTP 响应的总超时未归类为 unavailable：\(timeoutResult)"
        )
    }

    private static func verifyCurrentExternalProbe() async throws {
        let result = await ServiceProbe().probe()
        switch result {
        case .dshLikely:
            // 当前 external DSH 可被软识别；这是本轮开发机的常见状态。
            return
        case .unavailable:
            // owned Finder 验收前，用户可以明确提供一个临时空闲 3080；
            // 验证程序只读检查，不应把这一合法前置条件误报为失败。
            return
        case .reachableUnknown, .reachableNonHTML:
            throw VerificationError("当前 3080 有非 DSH 的 HTTP 响应：\(result)")
        }
    }

    private static func verifyProcessSupervisor() async throws {
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

    private static func verifyLocalServiceOwnership() async throws {
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

    private static func verifyPipeDrainFixture() async throws {
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

    private static func verifyImmediateExitStatusSurvivesDrain() async throws {
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

    private static func verifyHighVolumeLogFixture() async throws {
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

    private static func verifyProcessLaunchContext() async throws {
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

    private static func verifySpawnRestoresTermSignalState() async throws {
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

    private static func verifyLockDescriptorDoesNotLeakToChild() async throws {
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

    private static func verifyOwnershipLossRevokesSignalCapability() async throws {
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
    private static func verifyTerminationRaceAndGenerationIsolation() async throws {
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

    private static func verifyTerminalUnavailableSafety() async throws {
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
    private static func verifyInjectedTerminalUnavailableSafety() async throws {
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

    private static func runInjectedTerminalUnavailableFixture() async -> Int32 {
        var original = sigaction()
        guard sigaction(SIGCHLD, nil, &original) == 0 else {
            print("TERMINAL_INJECTED_ERROR_SIGCHLD_READ_FAILED")
            return 64
        }
        var ignored = original
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        ignored.sa_flags = 0
        guard sigaction(SIGCHLD, &ignored, nil) == 0 else {
            print("TERMINAL_INJECTED_ERROR_SIGCHLD_SET_FAILED")
            return 65
        }
        defer {
            var restored = original
            _ = sigaction(SIGCHLD, &restored, nil)
        }

        guard let executable = DSHExecutable(url: URL(fileURLWithPath: "/bin/sh")) else {
            print("TERMINAL_INJECTED_ERROR_EXECUTABLE_MISSING")
            return 66
        }

        let supervisor = ProcessSupervisor(
            testingHooks: ProcessSupervisorTestingHooks(waitErrorForPID: { _ in EINVAL })
        )
        do {
            let handle = try await supervisor.spawn(
                LaunchSpec(
                    executable: executable.url,
                    arguments: ["-c", "printf 'terminal injected fixture\\n'; exit 0"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    environment: ProcessInfo.processInfo.environment
                )
            )
            guard await supervisor.terminalIncompatibilityError() == EINVAL else {
                print("TERMINAL_INJECTED_ERROR_NOT_RECORDED")
                return 67
            }
            guard await supervisor.checkExit(handle) == .terminalUnavailable(EINVAL) else {
                print("TERMINAL_INJECTED_ERROR_CHECK_EXIT_FAILED")
                return 68
            }
            guard await supervisor.requestTermination(handle) == .terminalUnavailable(EINVAL) else {
                print("TERMINAL_INJECTED_ERROR_SIGNAL_NOT_REVOKED")
                return 69
            }
            do {
                try await waitUntil("内层 injected terminal pipe EOF") {
                    await supervisor.cleanupComplete()
                }
            } catch {
                print("TERMINAL_INJECTED_ERROR_PIPE_TIMEOUT")
                return 70
            }
            guard !(await supervisor.canSpawn()) else {
                print("TERMINAL_INJECTED_ERROR_SPAWN_NOT_BLOCKED")
                return 71
            }
            print("TERMINAL_INJECTED_ERROR_OK")
            return 0
        } catch {
            print("TERMINAL_INJECTED_ERROR_UNEXPECTED")
            return 72
        }
    }

    private static func waitUntil(
        _ name: String,
        attempts: Int = 50,
        intervalNanoseconds: UInt64 = 100_000_000,
        condition: () async -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if await condition() { return }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        throw VerificationError("等待超时：\(name)")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError(message) }
    }

    private static func runLockProbe(arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            print("LOCK_PROBE_INVALID_ARGUMENTS")
            return 64
        }

        let lockPath = arguments[0]
        let readyPath = arguments[1]
        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: readyPath) { break }
            usleep(50_000)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            print("LOCK_PROBE_READY_TIMEOUT")
            return 65
        }

        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            print("LOCK_PROBE_OPEN_FAILED")
            return 66
        }
        defer { _ = close(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            print("LOCK_PROBE_ACQUIRED")
            return 0
        }
        print("LOCK_PROBE_CONFLICT")
        return 67
    }

    private static func runTermStateProbe() -> Int32 {
        var action = sigaction()
        guard sigaction(SIGTERM, nil, &action) == 0 else {
            print("TERM_STATE_ACTION_FAILED")
            return 64
        }
        var mask = sigset_t()
        guard pthread_sigmask(SIG_SETMASK, nil, &mask) == 0 else {
            print("TERM_STATE_MASK_FAILED")
            return 65
        }

        let handlerAddress: UInt = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
        let defaultHandlerAddress: UInt = unsafeBitCast(SIG_DFL, to: UInt.self)
        let usesDefault = handlerAddress == defaultHandlerAddress
        let isUnblocked = sigismember(&mask, SIGTERM) == 0
        print("TERM_DEFAULT=\(usesDefault ? 1 : 0) TERM_UNBLOCKED=\(isUnblocked ? 1 : 0)")
        return usesDefault && isUnblocked ? 0 : 66
    }

    private static func runListener(arguments: [String]) -> Int32 {
        guard arguments.count == 3,
              let requestedPort = UInt16(arguments[0]) else {
            print("LISTENER_INVALID_ARGUMENTS")
            return 64
        }

        let readyURL = URL(fileURLWithPath: arguments[1])
        let stopURL = URL(fileURLWithPath: arguments[2])
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            print("LISTENER_SOCKET_FAILED")
            return 65
        }
        defer { _ = Darwin.close(descriptor) }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            print("LISTENER_SETSOCKOPT_FAILED")
            return 66
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        let parsedLoopback = "127.0.0.1".withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard parsedLoopback == 1 else {
            print("LISTENER_ADDRESS_FAILED")
            return 67
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, SOMAXCONN) == 0 else {
            print("LISTENER_BIND_FAILED")
            return 68
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            print("LISTENER_NAME_FAILED")
            return 69
        }

        let boundPort = UInt16(bigEndian: boundAddress.sin_port)
        do {
            try Data("\(boundPort)\n".utf8).write(to: readyURL, options: .withoutOverwriting)
        } catch {
            print("LISTENER_READY_FAILED")
            return 70
        }

        while true {
            if FileManager.default.fileExists(atPath: stopURL.path) {
                return 0
            }
            usleep(50_000)
        }
    }

    /// 仅供 App 级端口竞争验收使用。它固定绑定调用方给出的 loopback 端口，
    /// 并返回最小 HTML/未知 manifest 响应；实际停机仍由外层受控 fixture 决定。
    private static func runHTTPListener(arguments: [String]) -> Int32 {
        guard arguments.count == 3,
              let requestedPort = UInt16(arguments[0]) else {
            print("HTTP_LISTENER_INVALID_ARGUMENTS")
            return 64
        }

        let readyURL = URL(fileURLWithPath: arguments[1])
        let stopURL = URL(fileURLWithPath: arguments[2])
        let server: FixtureHTTPServer
        do {
            server = try FixtureHTTPServer(port: requestedPort) { path in
                switch path {
                case "/":
                    return .html()
                case "/manifest.webmanifest":
                    return .response(
                        status: 404,
                        headers: ["Content-Type": "text/plain"],
                        body: Data()
                    )
                default:
                    return .response(
                        status: 404,
                        headers: ["Content-Type": "text/plain"],
                        body: Data()
                    )
                }
            }
        } catch {
            print("HTTP_LISTENER_BIND_FAILED")
            return 65
        }
        defer { server.close() }

        do {
            try Data("\(server.port)\n".utf8).write(to: readyURL, options: .withoutOverwriting)
        } catch {
            print("HTTP_LISTENER_READY_FAILED")
            return 66
        }

        while !FileManager.default.fileExists(atPath: stopURL.path) {
            usleep(50_000)
        }
        return 0
    }

    private static func requestListenerFixtureExit(at stopURL: URL) throws {
        try Data().write(to: stopURL, options: .withoutOverwriting)
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

/// 真实 PTY fixture 的输出只在内存中短暂保存，且仅接受我们固定脚本输出的数字 PID。
/// 它不执行任何来自网页或用户输入的命令。
private final class PTYFixtureDelegate: NSObject, LocalProcessDelegate {
    private let lock = NSLock()
    private var output = ""
    private var childPID: pid_t?

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard let text = String(bytes: slice, encoding: .utf8) else { return }
        lock.withLock {
            output.append(text)
            guard childPID == nil,
                  let range = output.range(of: "__DSD_PTY_CHILD__:") else {
                return
            }
            let suffix = output[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let parsed = Int32(digits), parsed > 1 {
                childPID = pid_t(parsed)
            }
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    func waitForChildPID(timeoutNanoseconds: UInt64) async throws -> pid_t {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let childPID = lock.withLock({ childPID }) {
                return childPID
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        throw VerificationError("真实 PTY fixture 未在期限内报告子进程 PID")
    }
}

private struct VerificationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
