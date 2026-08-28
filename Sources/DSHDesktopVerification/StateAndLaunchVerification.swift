import Darwin
import Dispatch
import Foundation
import DSHDesktopCore
import WebKit
@preconcurrency import SwiftTerm

extension DSHDesktopVerification {
    static func verifyLocalAddressAndStateReducer() throws {
        try expect(LocalService.url.absoluteString == "http://127.0.0.1:3080/", "固定本地地址不正确")
        let releaseRuntime = AppRuntimeConfiguration(
            infoDictionary: [:],
            bundleIdentifier: AppRuntimeConfiguration.productionBundleIdentifier
        )
        let configuredTestRoot = URL(
            fileURLWithPath: "/tmp/dsd-pancake-runtime-test-root",
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let configuredTestHome = configuredTestRoot
            .appendingPathComponent("test-dsh-home", isDirectory: true)
        let configuredTestDownloads = configuredTestRoot
            .appendingPathComponent("test-downloads", isDirectory: true)
        let testRuntime = AppRuntimeConfiguration(
            infoDictionary: [
                "DSDPancakeTestMode": true,
                "DSDPancakeServicePort": 13_081,
                "DSDPancakeTestRoot": configuredTestRoot.path,
                "DSDPancakeDSHHome": configuredTestHome.path,
                "DSDPancakeDownloadsDirectory": configuredTestDownloads.path,
            ],
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.test"
        )
        let invalidTestRuntime = AppRuntimeConfiguration(
            infoDictionary: [
                "DSDPancakeTestMode": true,
                "DSDPancakeServicePort": 3_080,
            ],
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.test.invalid"
        )
        let escapedTestRuntime = AppRuntimeConfiguration(
            infoDictionary: [
                "DSDPancakeTestMode": true,
                "DSDPancakeTestRoot": configuredTestRoot.path,
                "DSDPancakeDSHHome": configuredTestRoot
                    .appendingPathComponent("nested/../../outside", isDirectory: true).path,
                "DSDPancakeDownloadsDirectory": configuredTestRoot
                    .appendingPathComponent("nested/../../Downloads", isDirectory: true).path,
            ],
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.test.escaped"
        )
        let caseVariantProductionRuntime = AppRuntimeConfiguration(
            infoDictionary: ["DSDPancakeTestMode": true],
            bundleIdentifier: "IO.GITHUB.HELLOKITTY-23.DSD-PANCAKE"
        )
        let protectedRootRuntime = AppRuntimeConfiguration(
            infoDictionary: [
                "DSDPancakeTestMode": true,
                "DSDPancakeTestRoot": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".dsh/test-runtime", isDirectory: true).path,
                "DSDPancakeDSHHome": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".dsh/test-runtime/test-dsh-home", isDirectory: true).path,
                "DSDPancakeDownloadsDirectory": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".dsh/test-runtime/test-downloads", isDirectory: true).path,
            ],
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.test.protected-root"
        )
        let caseVariantProtectedRootRuntime = AppRuntimeConfiguration(
            infoDictionary: [
                "DSDPancakeTestMode": true,
                "DSDPancakeTestRoot": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".DSH/test-runtime", isDirectory: true).path,
                "DSDPancakeDSHHome": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".DSH/test-runtime/test-dsh-home", isDirectory: true).path,
                "DSDPancakeDownloadsDirectory": FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".DSH/test-runtime/test-downloads", isDirectory: true).path,
            ],
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.test.protected-case"
        )
        let caseVariantExactRootRuntime = AppRuntimeConfiguration(
            infoDictionary: [
                "DSDPancakeTestMode": true,
                "DSDPancakeTestRoot": configuredTestRoot.path,
                "DSDPancakeDSHHome": configuredTestRoot.path.uppercased(),
                "DSDPancakeDownloadsDirectory": configuredTestRoot.path.uppercased(),
            ],
            bundleIdentifier: "io.github.hellokitty-23.dsd-pancake.test.exact-root-case"
        )
        let testEnvironment = testRuntime.applyingLaunchOverrides(to: ["PATH": "/usr/bin"])
        try expect(
            !releaseRuntime.isIsolatedTestBuild
                && releaseRuntime.servicePort == 3_080
                && releaseRuntime.dshHomeOverride == nil
                && releaseRuntime.usesPersistentWebDataStore,
            "正式运行配置被 Test 开关污染"
        )
        try expect(
            testRuntime.isIsolatedTestBuild
                && testRuntime.servicePort == 13_081
                && testRuntime.dshHomeOverride == configuredTestHome
                && testRuntime.downloadDirectoryOverride == configuredTestDownloads
                && !testRuntime.usesPersistentWebDataStore
                && testEnvironment["DSH_HOME"] == configuredTestHome.path
                && testEnvironment["DSH_TELEMETRY_DISABLED"] == "1",
            "隔离 Test 配置没有隔离端口、DSH_HOME、遥测或 WebKit 策略"
        )
        try expect(
            invalidTestRuntime.servicePort == AppRuntimeConfiguration.defaultTestServicePort
                && invalidTestRuntime.servicePort != AppRuntimeConfiguration.defaultServicePort
                && invalidTestRuntime.dshHomeOverride != nil
                && invalidTestRuntime.downloadDirectoryOverride != nil
                && invalidTestRuntime.downloadDirectoryOverride?.path
                    != FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Downloads", isDirectory: true).path,
            "损坏的 Test 配置错误回退到正式端口、正式 DSH_HOME 或 ~/Downloads"
        )
        try expect(
            escapedTestRuntime.dshHomeOverride
                == configuredTestRoot.appendingPathComponent("test-dsh-home", isDirectory: true)
                && escapedTestRuntime.downloadDirectoryOverride
                    == configuredTestRoot.appendingPathComponent("test-downloads", isDirectory: true),
            "包含 .. 或越出 Test root 的路径没有安全回退到隔离子目录"
        )
        try expect(
            !caseVariantProductionRuntime.isIsolatedTestBuild
                && caseVariantProductionRuntime.servicePort
                    == AppRuntimeConfiguration.defaultServicePort
                && caseVariantProductionRuntime.dshHomeOverride == nil
                && caseVariantProductionRuntime.downloadDirectoryOverride == nil,
            "仅大小写不同的正式 bundle ID 错误取得了 Test 隔离权限"
        )
        let formalDSHHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true).standardizedFileURL
        let protectedFallbacks = [
            protectedRootRuntime.dshHomeOverride,
            protectedRootRuntime.downloadDirectoryOverride,
            caseVariantProtectedRootRuntime.dshHomeOverride,
            caseVariantProtectedRootRuntime.downloadDirectoryOverride,
        ].compactMap { $0?.standardizedFileURL }
        try expect(
            protectedFallbacks.count == 4
                && protectedFallbacks.allSatisfy {
                    !zip(
                        $0.pathComponents.prefix(formalDSHHome.pathComponents.count),
                        formalDSHHome.pathComponents
                    ).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
                },
            "位于正式 ~/.dsh 或其大小写变体内的 Test root 没有安全回退"
        )
        try expect(
            caseVariantExactRootRuntime.dshHomeOverride
                == configuredTestRoot.appendingPathComponent("test-dsh-home", isDirectory: true)
                && caseVariantExactRootRuntime.downloadDirectoryOverride
                    == configuredTestRoot.appendingPathComponent("test-downloads", isDirectory: true),
            "Test 子目录用大小写变体伪装成 Test root 本身时没有安全回退"
        )
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

        // monitor 可能在退出 worker 的 cleanup await 恢复前先观察到
        // child + pipes 已收敛并清掉 handle。handle 已为 nil 不是失败；
        // 当前 transaction 仍必须取得唯一 AppKit reply 权。
        var monitorWinsTransactions = TerminationTransactionRegistry()
        let monitorWinsTransaction = monitorWinsTransactions.begin(originalGate: .stoppable)
        let handleAlreadyClearedByMonitor = true
        try expect(
            handleAlreadyClearedByMonitor
                && monitorWinsTransactions.isActive(monitorWinsTransaction)
                && monitorWinsTransactions.markReplySent(for: monitorWinsTransaction)
                && !monitorWinsTransactions.markReplySent(for: monitorWinsTransaction),
            "monitor 先清除 handle 后，当前退出事务未能 exactly-once reply"
        )

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
        try expect(
            cancelledQuit.phase == .drainingProcessCleanup
                && cancelledQuit.quit == .inactive,
            "cleanup pending 时取消退出丢失 drain 状态"
        )

        let quittingDuringSpawn = StateReducer.reduce(spawning, action: .beginQuit)
        let spawnedWhileQuitting = StateReducer.reduce(quittingDuringSpawn, action: .spawned)
        try expect(
            spawnedWhileQuitting.phase == .waitingReady
                && spawnedWhileQuitting.hasActiveHandle
                && spawnedWhileQuitting.quit == .confirming,
            "退出确认覆盖 spawning 后，迟到的 spawned 回调没有被正常接纳"
        )
        let cancelledDuringReadiness = StateReducer.reduce(spawnedWhileQuitting, action: .cancelQuit)
        try expect(
            cancelledDuringReadiness.phase == .waitingReady
                && cancelledDuringReadiness.hasActiveHandle
                && cancelledDuringReadiness.quit == .inactive,
            "取消退出错误发明或丢失了真实 service lifecycle"
        )

        let disconnected = StateReducer.reduce(waitingReady, action: .listenerLost)
        try expect(
            disconnected.phase == .disconnectedOwned
                && disconnected.cleanup == waitingReady.cleanup
                && disconnected.hasActiveHandle,
            "listener 丢失错误撤销了直接子进程的安全监督/停止状态"
        )

        // 第一次 ⌘Q 只叠加 quit confirmation（退出确认），不得
        // 根据 currentHandle 此刻的 cleanup state 改写服务生命周期。
        // coordinator 因此不应在第一击调用 cleanup/reply/signal 路径。
        let firstStrikeCleanupStates: [ProcessCleanupState] = [
            .clear,
            .awaitingReap,
            .supervisionOnly,
            .drainingPipes,
            .orphanDrainIncompatible,
            .terminalUnavailable,
        ]
        for cleanup in firstStrikeCleanupStates {
            let beforeFirstStrike = CoordinatedState(
                phase: .waitingReady,
                generation: 17,
                cleanup: cleanup,
                hasActiveHandle: true
            )
            let afterFirstStrike = StateReducer.reduce(beforeFirstStrike, action: .beginQuit)
            try expect(
                afterFirstStrike.phase == beforeFirstStrike.phase
                    && afterFirstStrike.generation == beforeFirstStrike.generation
                    && afterFirstStrike.cleanup == beforeFirstStrike.cleanup
                    && afterFirstStrike.hasActiveHandle == beforeFirstStrike.hasActiveHandle
                    && afterFirstStrike.quit == .confirming,
                "第一次 ⌘Q 在 cleanup=\(cleanup) 时提前改写了服务生命周期"
            )
        }

        let listenerLostDuringQuit = StateReducer.reduce(spawnedWhileQuitting, action: .listenerLost)
        let cancelledAfterListenerLoss = StateReducer.reduce(listenerLostDuringQuit, action: .cancelQuit)
        try expect(
            listenerLostDuringQuit.phase == .disconnectedOwned
                && listenerLostDuringQuit.hasActiveHandle
                && listenerLostDuringQuit.quit == .confirming
                && cancelledAfterListenerLoss.phase == .disconnectedOwned
                && cancelledAfterListenerLoss.hasActiveHandle
                && cancelledAfterListenerLoss.quit == .inactive,
            "退出确认期间 listener 丢失后，取消退出错误丢失了直接子进程停止权"
        )

        // 只有 process identity（进程身份）实测失效才收敛为 authority loss
        //（权限丢失）。即使退出确认正覆盖在页面上，reducer 也必须立即保留
        // supervisionOnly，取消退出不能恢复 owned 停止权。
        let authorityLostDuringQuit = StateReducer.reduce(
            spawnedWhileQuitting,
            action: .ownershipLost
        )
        let cancelledAfterAuthorityLossDuringQuit = StateReducer.reduce(
            authorityLostDuringQuit,
            action: .cancelQuit
        )
        try expect(
            authorityLostDuringQuit.phase == .running(.external)
                && authorityLostDuringQuit.cleanup == .supervisionOnly
                && authorityLostDuringQuit.quit == .confirming
                && cancelledAfterAuthorityLossDuringQuit.phase == .running(.external)
                && cancelledAfterAuthorityLossDuringQuit.cleanup == .supervisionOnly
                && cancelledAfterAuthorityLossDuringQuit.quit == .inactive,
            "退出确认期间发生进程 identity 失权后，取消退出错误恢复了停止权"
        )

        let quittingAfterOwnershipLoss = StateReducer.reduce(ownershipLost, action: .beginQuit)
        let cancelledAfterOwnershipLoss = StateReducer.reduce(quittingAfterOwnershipLoss, action: .cancelQuit)
        try expect(
            quittingAfterOwnershipLoss.phase == .running(.external)
                && quittingAfterOwnershipLoss.cleanup == .supervisionOnly
                && quittingAfterOwnershipLoss.quit == .confirming
                && cancelledAfterOwnershipLoss.phase == .running(.external)
                && cancelledAfterOwnershipLoss.cleanup == .supervisionOnly
                && cancelledAfterOwnershipLoss.quit == .inactive,
            "失权后的退出/取消错误恢复了 owned 停止权"
        )

        let stopping = StateReducer.reduce(waitingReady, action: .beginStoppingOwnedService)
        let timedOut = StateReducer.reduce(stopping, action: .stopTimedOut)
        try expect(
            stopping.phase == .waitingReady
                && stopping.quit == .stopping
                && timedOut.phase == .waitingReady
                && timedOut.quit == .timedOut,
            "停止超时 UI 状态覆盖了真实 service lifecycle"
        )
    }

    static func verifyLocatorAndEnvironment() throws {
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
        let operationFoldingPatchURL = URL(fileURLWithPath: "/tmp/dsd-pancake-operation-folding.yml")
        let shortcutPatchURL = URL(fileURLWithPath: "/tmp/dsd-pancake-shortcuts.yml")
        let privatelyPatchedSpec = LaunchEnvironment.makeSpec(
            executable: executable,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/dshd-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/dshd-home", isDirectory: true),
            notificationPatchURL: patchURL,
            terminalPatchURL: terminalPatchURL,
            operationFoldingPatchURL: operationFoldingPatchURL,
            shortcutPatchURL: shortcutPatchURL
        )
        try expect(
            privatelyPatchedSpec.arguments == [
                "--profile", "web",
                "--patch", patchURL.path,
                "--patch", terminalPatchURL.path,
                "--patch", operationFoldingPatchURL.path,
                "--patch", shortcutPatchURL.path,
                "--no-open",
                "--host", "127.0.0.1",
                "--port", "3080",
            ],
            "App 私有插件没有以独立 launcher --patch 顺序启动"
        )
        try expect(
            PrivatePluginFallbackPolicy.shouldRetry(
                overlayPendingForCurrentSpawn: true,
                quitPending: false
            ),
            "复用旧 WebContainer 时，当前带覆盖层 spawn 在就绪前失败没有退回标准启动"
        )
        try expect(
            !PrivatePluginFallbackPolicy.shouldRetry(
                overlayPendingForCurrentSpawn: false,
                quitPending: false
            )
                && !PrivatePluginFallbackPolicy.shouldRetry(
                    overlayPendingForCurrentSpawn: true,
                    quitPending: true
                ),
            "已 ready／无覆盖层的后续退出或 App 退出事务仍错误触发私有覆盖层回退"
        )
        try expect(
            DSHLocator().locate(lastChosenPath: echoURL.path)?.url == echoURL,
            "用户上次选择路径未优先于固定候选路径"
        )
    }

}
