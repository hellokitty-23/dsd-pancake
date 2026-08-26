import Darwin
import Foundation
import DSHDesktopCore
import WebKit

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

        await run("App 私有提醒插件与桥协议") {
            try verifyNotificationPluginAndBridgeProtocol()
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

        let sameVersion = AppUpdateCheck(
            currentVersion: currentVersion,
            currentBuild: "36",
            latestVersion: currentVersion,
            releasePageURL: check.releasePageURL,
            downloadURL: check.downloadURL
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

private struct VerificationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
