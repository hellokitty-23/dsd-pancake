import AppKit
import Combine
import DSHDesktopCore
import SwiftUI

/// 只向界面公开当前退出确认状态。停止句柄仍留在协调器内部，界面不能直接
/// 请求结束任何进程；`stopsOwnedService` 仅描述第二次确认是否会停止本次 App
/// 创建的 DSH。
struct QuitConfirmation: Equatable, Identifiable {
    let transactionID: UInt64
    let stopsOwnedService: Bool

    var id: UInt64 { transactionID }
}

@MainActor
final class AppCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private struct ReadinessDeadline {
        let handle: SpawnHandle
        let generation: UInt64
        let uptimeNanoseconds: UInt64
    }

    private struct PendingQuitConfirmation {
        let transactionID: UInt64
        let ownedHandle: SpawnHandle?
    }

    private static let readinessTimeoutNanoseconds: UInt64 = 60_000_000_000
    private static let readinessPollIntervalNanoseconds: UInt64 = 500_000_000
    private static let stopConfirmationAutoCancelNanoseconds: UInt64 = 4_000_000_000

    enum Presentation: Equatable {
        case checking
        case locating
        case starting
        case waitingForService
        case ready
        case unknownExistingService(ReachableUnknownReason)
        case portAbnormal(ReachableNonHTMLReason)
        case dshNotFound
        case launchFailed(String)
        case readinessTimedOut
        case portConflict
        case ownershipLost
        case serviceStopped
        case drainingCleanup
        case terminalUnavailable(Int32)
        case stopping
        case stopTimedOut
    }

    @Published private(set) var presentation: Presentation = .checking
    @Published private(set) var webContainer: WebContainer?
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var quitConfirmation: QuitConfirmation?

    private let bundleIdentifier: String
    private let instanceLock: SingleInstanceLock
    private let probe = ServiceProbe()
    private let locator = DSHLocator()
    private let preferences: UserPreferences
    private let supervisor = ProcessSupervisor()
    private lazy var notificationCoordinator = NotificationCoordinator(
        shouldDeliver: { [weak self] in
            guard let self else { return false }
            return DesktopNotificationDeliveryPolicy.shouldDeliver(
                mode: self.preferences.completionNotificationMode,
                applicationIsActive: NSApp.isActive,
                mainWindowIsVisible: self.window?.isVisible ?? false,
                mainWindowIsMiniaturized: self.window?.isMiniaturized ?? false
            )
        },
        shouldPresentWhenActive: { [weak self] in
            self?.preferences.completionNotificationMode == .always
        },
        restoreMainWindow: { [weak self] in
            self?.restoreMainWindow()
        }
    )

    private var window: NSWindow?
    private var windowChrome: WindowChromeContainer?
    private var currentHandle: SpawnHandle?
    private var operationGeneration: UInt64 = 0
    private var startupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var terminationGate: TerminationGateSnapshot = .clear
    private var quitPending = false
    private var terminationTransactions = TerminationTransactionRegistry()
    private var terminationConfirmation = TerminationConfirmationGate()
    private var pendingQuitConfirmation: PendingQuitConfirmation?
    private var stopConfirmationAutoCancelTask: Task<Void, Never>?
    private var presentationBeforeTermination: Presentation?
    private var reconciledExitedHandle: SpawnHandle?
    private var reachableServiceAfterExitHandle: SpawnHandle?
    private var readinessDeadline: ReadinessDeadline?
    private var lastObservedExit: (handle: SpawnHandle, status: ProcessExitStatus)?
    /// 只有本次 App 用 `--patch` 创建并仍保持 owned 语义的 DSH，才获得原生通知桥。
    /// 已存在或后继 external 服务即使显示在 WebView 中，也不能请求 App 通知。
    private var notificationBridgeEnabled = false
    /// 记录哪一个直接子进程带着 App 私有覆盖层启动。若它在网页就绪前退出，
    /// App 只自动重试一次不带插件的标准 DSH，避免提醒功能约束 DSH 升级。
    private var notificationOverlayHandle: SpawnHandle?
    private var skipNotificationPluginForNextSpawn = false
    /// 已处理过失权的 handle 不再重复 probe；停止权一旦撤销，绝不恢复。
    private var ownershipLossReconciledHandle: SpawnHandle?

    init(
        bundleIdentifier: String,
        instanceLock: SingleInstanceLock,
        preferences: UserPreferences
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.instanceLock = instanceLock
        self.preferences = preferences
        super.init()
    }

    func installMainWindow() {
        let content = NSHostingView(rootView: RootView(coordinator: self))
        let chrome = WindowChromeContainer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DSD Pancake"
        // 让标题栏成为网页左右表面的延伸。实际网页内容仍约束在
        // 安全内容区域，避免红绿灯压住 DSH 的任何控件。
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        // 在网页尚未报告当前主题前，仍由系统动态窗口底色兜底，避免白色首帧。
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentView = chrome
        chrome.install(hostingView: content, safeAreaLayoutGuide: chrome.safeAreaLayoutGuide)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DSHDesktopMainWindow")
        if !window.setFrameUsingName("DSHDesktopMainWindow") {
            window.center()
        }
        self.window = window
        self.windowChrome = chrome
        restoreMainWindow()
    }

    func beginStartup() {
        startupTask?.cancel()
        setNotificationBridgeEnabled(false)
        notificationOverlayHandle = nil
        operationGeneration &+= 1
        let generation = operationGeneration
        presentation = .checking
        startupTask = Task { [weak self] in
            await self?.runStartup(generation: generation)
        }
    }

    /// 通知授权是 App 级偏好，而不是网页初始化副作用。首次打开 App 就询问一次，
    /// 后续是否真正投递仍严格受“本次 App 托管的 DSH + 私有插件”约束。
    func prepareNotificationAuthorization() {
        notificationCoordinator.activateIfNeeded()
    }

    func retry() {
        if currentHandle != nil, !quitPending {
            continueWaitingForService()
            return
        }
        guard terminationGate == .clear else { return }
        beginStartup()
    }

    func continueWaitingForService() {
        guard canContinueWaitingForService,
              let handle = currentHandle,
              !quitPending else { return }
        startupTask?.cancel()
        let generation = operationGeneration
        resetReadinessDeadline(for: handle, generation: generation)
        // 立刻离开带操作按钮的旧状态，既给出明确反馈，也避免同一轮 probe
        // 被连续点击取消并重建。此处不调用 spawn，仍只复用已有句柄。
        presentation = .checking
        startupTask = Task { [weak self] in
            await self?.waitForReadiness(handle: handle, generation: generation)
        }
    }

    func chooseDSHFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择当前已安装的 dsh 可执行文件"
        panel.prompt = "选择 dsh"
        panel.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard DSHExecutable(url: url) != nil else {
                self.presentation = .launchFailed("所选文件不可执行。")
                return
            }
            self.preferences.selectedDSHPath = url.path
            self.beginStartup()
        }
    }

    func acceptUnknownExistingService() {
        guard case .unknownExistingService = presentation else { return }
        showWebContainer(reloadExisting: true)
    }

    func rejectUnknownExistingService() {
        guard case .unknownExistingService = presentation else { return }
        presentation = .serviceStopped
    }

    func showLogs() {
        Task { [weak self] in
            guard let self else { return }
            self.logEntries = await self.supervisor.logSnapshot()
        }
    }

    func restoreMainWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if quitPending {
            confirmPresentedQuitFromRepeatedCommandIfNeeded()
            return .terminateLater
        }
        // 无论 DSH 归属为何，第一次退出都先显示同一份确认层。只有第二次
        // `⌘Q` 才允许真正退出；是否需要停止 DSH 由当前持有的 owned handle 决定。
        beginDeferredTermination()
        return .terminateLater
    }

    /// 由 App 菜单的 `⌘Q` 调用。AppKit 收到 `.terminateLater` 后不承诺会再一次
    /// 调用 `applicationShouldTerminate`，所以有活动退出事务时直接消费本次命令；
    /// 若确认层已经出现，就将它确认一次。
    ///
    /// 返回 `true` 表示命令已消费，调用方不得再次调用 `NSApp.terminate`。
    func consumePendingQuitCommand() -> Bool {
        guard quitPending else { return false }
        confirmPresentedQuitFromRepeatedCommandIfNeeded()
        return true
    }

    /// `Esc`、取消按钮、背景点击和自动超时共用同一条取消路径。
    /// 只有已呈现的当前事务可取消，确保不会影响后续新的退出事务。
    func cancelQuitConfirmation() {
        guard let confirmation = quitConfirmation else { return }
        cancelTermination(transactionID: confirmation.transactionID)
    }

    private func runStartup(generation: UInt64) async {
        let initial = await probe.probe()
        guard generation == operationGeneration, !Task.isCancelled else { return }

        switch initial {
        case .dshLikely:
            showWebContainer(reloadExisting: true)
        case let .reachableUnknown(reason):
            presentation = .unknownExistingService(reason)
        case let .reachableNonHTML(reason):
            presentation = .portAbnormal(reason)
        case .unavailable:
            await locateAndSpawn(generation: generation)
        }
    }

    private func locateAndSpawn(generation: UInt64) async {
        guard generation == operationGeneration, !Task.isCancelled else { return }
        presentation = .locating
        guard let executable = locator.locate(lastChosenPath: preferences.selectedDSHPath) else {
            presentation = .dshNotFound
            return
        }

        let preflight = await probe.probe()
        guard generation == operationGeneration, !Task.isCancelled else { return }
        switch preflight {
        case .dshLikely:
            showWebContainer(reloadExisting: true)
            return
        case let .reachableUnknown(reason):
            presentation = .unknownExistingService(reason)
            return
        case let .reachableNonHTML(reason):
            presentation = .portAbnormal(reason)
            return
        case .unavailable:
            break
        }

        guard await supervisor.canSpawn() else {
            presentation = .launchFailed("上一次创建的进程或日志清理尚未收敛，不能再次启动。")
            return
        }

        let baseEnvironment = ProcessInfo.processInfo.environment
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let notificationPatchURL = prepareNotificationPlugin(
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory
        )
        let spec = LaunchEnvironment.makeSpec(
            executable: executable,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory,
            notificationPatchURL: notificationPatchURL
        )
        // 此门控必须早于任何 pipe、attr 或 posix_spawn 资源准备。
        terminationGate = .spawnTransaction
        presentation = .starting

        do {
            let handle = try await supervisor.spawn(spec)
            guard generation == operationGeneration else {
                currentHandle = handle
                terminationGate = .cleanupPending
                await continueDeferredTerminationAfterSpawnIfNeeded()
                return
            }
            currentHandle = handle
            notificationOverlayHandle = notificationPatchURL == nil ? nil : handle
            reconciledExitedHandle = nil
            reachableServiceAfterExitHandle = nil
            lastObservedExit = nil
            ownershipLossReconciledHandle = nil
            resetReadinessDeadline(for: handle, generation: generation)
            let ownership = await supervisor.verifyOwnership(handle)
            terminationGate = ownership == .verified ? .stoppable : .cleanupPending
            presentation = ownership == .verified ? .waitingForService : .ownershipLost
            startMonitoring(handle: handle, generation: generation)
            if quitPending {
                // 退出请求可能在 SpawnHandle 安装前到达。确认页真正出现前，
                // 用此刻已知的状态替换最初的 .starting 快照，取消退出时才能
                // 回到真实的等待/竞争状态。
                presentationBeforeTermination = presentation
                await continueDeferredTerminationAfterSpawnIfNeeded()
            } else if ownership == .verified {
                await waitForReadiness(handle: handle, generation: generation)
            }
        } catch {
            terminationGate = .clear
            notificationOverlayHandle = nil
            setNotificationBridgeEnabled(false)
            presentation = .launchFailed(describe(error))
            await continueDeferredTerminationAfterSpawnIfNeeded()
        }
    }

    private func waitForReadiness(handle: SpawnHandle, generation: UInt64) async {
        while hasRemainingReadinessTime(for: handle, generation: generation) {
            guard generation == operationGeneration, currentHandle == handle, !Task.isCancelled, !quitPending else { return }
            guard let timeout = remainingReadinessTimeout(for: handle, generation: generation) else { break }
            let result = await probe.probe(timeout: timeout)
            guard generation == operationGeneration, currentHandle == handle, !Task.isCancelled, !quitPending else { return }

            switch result {
            case .dshLikely, .reachableUnknown, .reachableNonHTML:
                await handleReachableServiceDuringStartup(
                    result,
                    handle: handle,
                    generation: generation
                )
                return
            case .unavailable:
                break
            }

            switch await supervisor.checkExit(handle) {
            case .running:
                break
            case let .reaped(status):
                await reconcileExitedProcess(handle: handle, generation: generation, exitStatus: status)
                return
            case .terminalUnavailable, .staleHandle:
                await reconcileExitedProcess(handle: handle, generation: generation)
                return
            }
            await sleepUntilNextReadinessPoll(for: handle, generation: generation)
        }

        guard currentHandle == handle, !Task.isCancelled, !quitPending else { return }
        presentation = .readinessTimedOut
    }

    private func startMonitoring(handle: SpawnHandle, generation: UInt64) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.currentHandle == handle, generation == self.operationGeneration {
                let observation = await self.supervisor.checkExit(handle)
                switch observation {
                case .running:
                    await self.reconcileOwnershipLossIfNeeded(handle: handle, generation: generation)
                case let .reaped(status):
                    await self.reconcileExitedProcess(handle: handle, generation: generation, exitStatus: status)
                case .terminalUnavailable, .staleHandle:
                    await self.reconcileExitedProcess(handle: handle, generation: generation)
                }
                // 退出确认、SIGTERM 与超时选择只由 `quitTask` 串行处理。
                // 监视器继续负责观察退出，不能并行弹出第二个超时提示。
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// `runningOwned` 不是永久授权。只要后续 PID、启动时间或 PGID 的实测值不再
    /// 匹配，本次会话立即永久失去停止权；此处只读探测服务，绝不停止、接管或重启
    /// 端口上的任何进程。
    private func reconcileOwnershipLossIfNeeded(handle: SpawnHandle, generation: UInt64) async {
        let ownership = await supervisor.verifyOwnership(handle)
        guard currentHandle == handle,
              generation == operationGeneration,
              !Task.isCancelled,
              !quitPending else {
            return
        }
        guard ownership != .verified,
              ownershipLossReconciledHandle != handle else {
            return
        }

        ownershipLossReconciledHandle = handle
        setNotificationBridgeEnabled(false)
        terminationGate = .cleanupPending
        clearReadinessDeadline(for: handle)
        let result = await probe.probe()
        guard currentHandle == handle,
              generation == operationGeneration,
              !Task.isCancelled,
              !quitPending else {
            return
        }
        await presentExternalServiceAfterOwnershipLoss(result)
    }

    private func showWebContainer(reloadExisting: Bool = false) {
        if let webContainer {
            webContainer.setNotificationBridgeEnabled(notificationBridgeEnabled)
            if reloadExisting {
                webContainer.loadLocalService()
            }
            presentation = .ready
            return
        }
        let container = WebContainer(notificationCoordinator: notificationCoordinator)
        container.setNotificationBridgeEnabled(notificationBridgeEnabled)
        container.onChromeStyleChange = { [weak self] style in
            self?.windowChrome?.apply(style: style)
        }
        webContainer = container
        container.loadLocalService()
        presentation = .ready
    }

    /// 这些状态都还保留本次 `SpawnHandle`。重新检查只会复用该句柄和
    /// probe（服务探测），绝不会创建、停止或重新认领任何进程。
    private var canContinueWaitingForService: Bool {
        switch presentation {
        case .readinessTimedOut, .portConflict, .ownershipLost, .drainingCleanup, .launchFailed:
            return true
        default:
            return false
        }
    }

    private func resetReadinessDeadline(for handle: SpawnHandle, generation: UInt64) {
        readinessDeadline = ReadinessDeadline(
            handle: handle,
            generation: generation,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ Self.readinessTimeoutNanoseconds
        )
    }

    private func hasRemainingReadinessTime(for handle: SpawnHandle, generation: UInt64) -> Bool {
        guard let readinessDeadline,
              readinessDeadline.handle == handle,
              readinessDeadline.generation == generation else {
            return false
        }
        return DispatchTime.now().uptimeNanoseconds < readinessDeadline.uptimeNanoseconds
    }

    private func remainingReadinessTimeout(for handle: SpawnHandle, generation: UInt64) -> TimeInterval? {
        guard let readinessDeadline,
              readinessDeadline.handle == handle,
              readinessDeadline.generation == generation else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < readinessDeadline.uptimeNanoseconds else { return nil }
        return TimeInterval(readinessDeadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private func clearReadinessDeadline(for handle: SpawnHandle) {
        guard readinessDeadline?.handle == handle else { return }
        readinessDeadline = nil
    }

    private func sleepUntilNextReadinessPoll(for handle: SpawnHandle, generation: UInt64) async {
        guard let readinessDeadline,
              readinessDeadline.handle == handle,
              readinessDeadline.generation == generation else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < readinessDeadline.uptimeNanoseconds else { return }
        let remaining = readinessDeadline.uptimeNanoseconds - now
        try? await Task.sleep(nanoseconds: min(Self.readinessPollIntervalNanoseconds, remaining))
    }

    /// 根请求已收到 HTTP 响应后，不再假设该响应属于刚创建的子进程。
    /// 先在同一 `ReapCoordinator` 串行域复核直接子 PID 的身份与监听 socket。
    private func handleReachableServiceDuringStartup(
        _ result: ProbeResult,
        handle: SpawnHandle,
        generation: UInt64
    ) async {
        let ownership = await supervisor.verifyLocalServiceOwnership(
            handle,
            port: UInt16(LocalService.port)
        )
        guard currentHandle == handle, generation == operationGeneration, !Task.isCancelled else { return }

        switch ownership {
        case .verified:
            terminationGate = .stoppable
            clearReadinessDeadline(for: handle)
            switch result {
            case .dshLikely, .reachableUnknown:
                // 当前会话直接创建且 listener 已证明归属时，manifest 只保留兼容提示作用。
                showWebContainer(reloadExisting: true)
            case let .reachableNonHTML(reason):
                presentation = .launchFailed("本次 dsh 已监听 3080，但根页面不能作为 DSH HTML 加载（\(nonHTMLReasonText(reason))）。可继续检查或查看本次内存日志。")
            case .unavailable:
                break
            }

        case .notListening:
            // 端口在 spawn 后被其他服务占用。保留直接子进程凭据，
            // 但绝不把该网页服务或其监听者认定为 owned。
            terminationGate = .stoppable
            setNotificationBridgeEnabled(false)
            clearReadinessDeadline(for: handle)
            presentation = .portConflict

        case .ownershipLost:
            setNotificationBridgeEnabled(false)
            terminationGate = .cleanupPending
            clearReadinessDeadline(for: handle)
            await presentExternalServiceAfterOwnershipLoss(result)

        case let .alreadyExited(status):
            await reconcileExitedProcess(handle: handle, generation: generation, exitStatus: status)
        case .terminalUnavailable, .staleHandle:
            await reconcileExitedProcess(handle: handle, generation: generation)
        }
    }

    /// 身份或监听复核失败后，端口页面一律按 external 重新处理。
    private func presentExternalServiceAfterOwnershipLoss(_ result: ProbeResult) async {
        setNotificationBridgeEnabled(false)
        switch result {
        case .dshLikely:
            showWebContainer(reloadExisting: true)
        case let .reachableUnknown(reason):
            presentation = .unknownExistingService(reason)
        case let .reachableNonHTML(reason):
            presentation = .portAbnormal(reason)
        case .unavailable:
            presentation = .ownershipLost
        }
    }

    private func nonHTMLReasonText(_ reason: ReachableNonHTMLReason) -> String {
        switch reason {
        case .rootCrossOriginRedirect: return "根路径重定向到了非本机同源地址"
        case let .rootNon2xx(status): return "根路径返回 HTTP \(status)"
        case let .rootNotHTML(contentType): return "根路径不是 HTML（Content-Type：\(contentType ?? "缺失")）"
        case .rootRedirectLoop: return "根路径重定向次数超过上限"
        case .rootBodyTooLarge: return "根路径响应超过探测上限"
        case .rootInvalidResponse: return "根路径返回了无效响应"
        }
    }

    /// 主 PID 一旦退出，立即撤销 owned 停止语义；端口上的任何后继服务只能重新按 external 处理。
    private func reconcileExitedProcess(
        handle: SpawnHandle,
        generation: UInt64,
        exitStatus: ProcessExitStatus? = nil
    ) async {
        guard currentHandle == handle else { return }
        // 主 PID 已退出或已无法可靠确认；端口上即使仍有页面，也只能按 external 处理。
        setNotificationBridgeEnabled(false)
        if let exitStatus {
            lastObservedExit = (handle: handle, status: exitStatus)
        }
        let effectiveExitStatus = exitStatus ?? (lastObservedExit?.handle == handle ? lastObservedExit?.status : nil)

        let cleanupComplete = await supervisor.cleanupComplete()
        if let terminalError = await supervisor.terminalIncompatibilityError() {
            if cleanupComplete {
                currentHandle = nil
                reconciledExitedHandle = nil
                reachableServiceAfterExitHandle = nil
                lastObservedExit = nil
                clearReadinessDeadline(for: handle)
                terminationGate = quitPending ? .quitPending : .clear
                if !quitPending {
                    presentation = .terminalUnavailable(terminalError)
                }
            } else {
                terminationGate = .cleanupPending
                if !quitPending {
                    presentation = .drainingCleanup
                }
            }
            return
        }

        if cleanupComplete {
            currentHandle = nil
            terminationGate = quitPending ? .quitPending : .clear
        } else {
            terminationGate = .cleanupPending
        }

        guard !quitPending else { return }
        let hasReachableSuccessor = reachableServiceAfterExitHandle == handle
        let shouldProbeAfterExit = !hasReachableSuccessor
            && (reconciledExitedHandle != handle || hasRemainingReadinessTime(for: handle, generation: generation))

        if !shouldProbeAfterExit {
            if cleanupComplete {
                clearReadinessDeadline(for: handle)
                if hasReachableSuccessor {
                    await refreshExternalServiceAfterCleanup(
                        handle: handle,
                        generation: generation,
                        exitStatus: effectiveExitStatus
                    )
                } else if !retryWithoutNotificationPluginIfNeeded(handle: handle) {
                    presentCompletedExitWithoutReachableServiceIfNeeded(effectiveExitStatus)
                }
            }
            return
        }
        reconciledExitedHandle = handle

        let result: ProbeResult
        if let timeout = remainingReadinessTimeout(for: handle, generation: generation) {
            result = await probe.probe(timeout: timeout)
        } else {
            // 服务已经处于 ready 后才退出时，仍保留一次受默认 2 秒限制的
            // post-exit probe；它不属于启动就绪等待窗口。
            result = await probe.probe()
        }
        guard generation == operationGeneration, !quitPending else { return }
        switch result {
        case .dshLikely:
            reachableServiceAfterExitHandle = handle
            clearReadinessDeadline(for: handle)
            showWebContainer(reloadExisting: true)
        case let .reachableUnknown(reason):
            reachableServiceAfterExitHandle = handle
            clearReadinessDeadline(for: handle)
            presentation = .unknownExistingService(reason)
        case let .reachableNonHTML(reason):
            reachableServiceAfterExitHandle = handle
            clearReadinessDeadline(for: handle)
            presentation = .portAbnormal(reason)
        case .unavailable:
            if cleanupComplete {
                clearReadinessDeadline(for: handle)
                if !retryWithoutNotificationPluginIfNeeded(handle: handle) {
                    presentCompletedExitWithoutReachableServiceIfNeeded(effectiveExitStatus)
                }
            } else {
                presentation = .drainingCleanup
            }
        }
    }

    /// 后继服务已在主 PID 退出后被归为 external，但它也可能在两路 pipe EOF 前
    /// 自己结束。清理完成时再次只读探测，避免把旧的“可达”快照留在界面上；此处
    /// 不会创建、认领或停止任何进程。
    private func refreshExternalServiceAfterCleanup(
        handle: SpawnHandle,
        generation: UInt64,
        exitStatus: ProcessExitStatus?
    ) async {
        let result = await probe.probe()
        guard generation == operationGeneration,
              !quitPending,
              currentHandle == nil,
              reachableServiceAfterExitHandle == handle else { return }

        switch result {
        case .dshLikely:
            showWebContainer(reloadExisting: true)
        case let .reachableUnknown(reason):
            presentation = .unknownExistingService(reason)
        case let .reachableNonHTML(reason):
            presentation = .portAbnormal(reason)
        case .unavailable:
            reachableServiceAfterExitHandle = nil
            presentCompletedExitWithoutReachableServiceIfNeeded(exitStatus)
        }
    }

    private func presentCompletedExitWithoutReachableServiceIfNeeded(_ exitStatus: ProcessExitStatus?) {
        guard webContainer == nil, let exitStatus else {
            presentation = .serviceStopped
            return
        }
        presentation = .launchFailed(
            "本次 dsh 在服务就绪前退出（\(exitStatusText(exitStatus))）。可查看本次内存日志。"
        )
    }

    /// 找到 bundle 内完整的已构建插件后，才建立 DSH 的 resolver 链接并启用
    /// 本次启动覆盖层。准备失败不妨碍薄壳的核心启动路径，只会安全地没有提醒。
    private func prepareNotificationPlugin(
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        if skipNotificationPluginForNextSpawn {
            skipNotificationPluginForNextSpawn = false
            setNotificationBridgeEnabled(false)
            return nil
        }
        guard let resourceRoot = Bundle.main.resourceURL,
              let plugin = DSHNotificationPlugin(
                directory: resourceRoot.appendingPathComponent(
                    DSHNotificationPlugin.resourcesDirectoryName,
                    isDirectory: true
                )
              ) else {
            setNotificationBridgeEnabled(false)
            return nil
        }

        do {
            try plugin.prepareResolver(
                baseEnvironment: baseEnvironment,
                workingDirectory: homeDirectory,
                homeDirectory: homeDirectory
            )
            setNotificationBridgeEnabled(true)
            return plugin.patchURL
        } catch {
            setNotificationBridgeEnabled(false)
            return nil
        }
    }

    private func setNotificationBridgeEnabled(_ enabled: Bool) {
        notificationBridgeEnabled = enabled
        webContainer?.setNotificationBridgeEnabled(enabled)
    }

    /// 覆盖层只要让 DSH 在页面就绪前失败一次，就退回标准启动命令。此路径没有
    /// 轮询或守护进程：它复用原有的退出收敛后启动流程，而且每次失败只尝试一次。
    private func retryWithoutNotificationPluginIfNeeded(handle: SpawnHandle) -> Bool {
        guard notificationOverlayHandle == handle,
              webContainer == nil,
              !quitPending else {
            return false
        }
        notificationOverlayHandle = nil
        skipNotificationPluginForNextSpawn = true
        beginStartup()
        return true
    }

    private func exitStatusText(_ status: ProcessExitStatus) -> String {
        switch status {
        case let .exited(code): return "退出码 \(code)"
        case let .signaled(signal): return "收到信号 \(signal)"
        case let .other(rawStatus): return "原始状态 \(rawStatus)"
        }
    }

    private func beginTerminationTransaction() -> UInt64 {
        terminationTransactions.begin(originalGate: terminationGate)
    }

    private func isActiveTerminationTransaction(_ transactionID: UInt64) -> Bool {
        quitPending && terminationTransactions.isActive(transactionID)
    }

    private func beginDeferredTermination() {
        guard !quitPending else { return }
        let waitsForSpawnResult = terminationGate.waitsForSpawnResult
        presentationBeforeTermination = presentation
        quitPending = true
        let transactionID = beginTerminationTransaction()

        // 这里不能把正在进行的 spawn 误当作“没有活动 handle”。
        // `posix_spawn` 已可能创建子进程；必须等其成功后安装/收尾，或失败后释放资源，
        // 再通过 `continueDeferredTerminationAfterSpawnIfNeeded()` 回复 AppKit。
        if waitsForSpawnResult {
            return
        }
        terminationGate = .quitPending

        guard let handle = currentHandle else {
            presentQuitConfirmation(ownedHandle: nil, transactionID: transactionID)
            return
        }

        quitTask?.cancel()
        quitTask = Task { [weak self] in
            guard let self else { return }
            let cleanupState = await self.supervisor.cleanupState(handle)
            guard self.isActiveTerminationTransaction(transactionID) else { return }
            switch cleanupState {
            case .awaitingReap:
                let ownership = await self.supervisor.verifyOwnership(handle)
                guard self.isActiveTerminationTransaction(transactionID) else { return }
                if ownership == .verified {
                    self.presentQuitConfirmation(ownedHandle: handle, transactionID: transactionID)
                } else {
                    await self.waitForCleanupAndReply(
                        handle: handle,
                        timeoutNanoseconds: 10_000_000_000,
                        transactionID: transactionID
                    )
                }
            case .supervisionOnly, .terminalUnavailable, .drainingPipes, .orphanDrainIncompatible:
                await self.waitForCleanupAndReply(
                    handle: handle,
                    timeoutNanoseconds: 10_000_000_000,
                    transactionID: transactionID
                )
            case .clear:
                self.replyToTermination(allow: true, transactionID: transactionID)
            }
        }
    }

    private func continueDeferredTerminationAfterSpawnIfNeeded() async {
        guard let transactionID = terminationTransactions.activeID,
              isActiveTerminationTransaction(transactionID) else { return }
        guard let handle = currentHandle else {
            presentQuitConfirmation(ownedHandle: nil, transactionID: transactionID)
            return
        }
        let cleanupState = await supervisor.cleanupState(handle)
        guard isActiveTerminationTransaction(transactionID) else { return }
        if cleanupState == .awaitingReap {
            let ownership = await supervisor.verifyOwnership(handle)
            guard isActiveTerminationTransaction(transactionID) else { return }
            if ownership == .verified {
                presentQuitConfirmation(ownedHandle: handle, transactionID: transactionID)
                return
            }
        }
        await waitForCleanupAndReply(
            handle: handle,
            timeoutNanoseconds: 10_000_000_000,
            transactionID: transactionID
        )
    }

    private func presentQuitConfirmation(ownedHandle: SpawnHandle?, transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID),
              quitConfirmation == nil,
              pendingQuitConfirmation == nil else {
            return
        }

        // 提示层出现时保留原页面，不提前发送信号，也不切换为“正在停止”。
        // 只有用户再次按 ⌘Q 后才会退出；仅带有 owned handle 的确认会停止 DSH。
        terminationConfirmation.present(for: transactionID)
        pendingQuitConfirmation = PendingQuitConfirmation(
            transactionID: transactionID,
            ownedHandle: ownedHandle
        )
        quitConfirmation = QuitConfirmation(
            transactionID: transactionID,
            stopsOwnedService: ownedHandle != nil
        )
        scheduleStopConfirmationAutoCancellation(for: transactionID)
    }

    /// 再次 `⌘Q` 原子地取得确认权。提示消失后，owned DSH 才会被请求停止；
    /// external DSH 或无 DSH 时则直接回复 AppKit 允许退出。
    private func confirmPresentedQuitFromRepeatedCommandIfNeeded() {
        guard let confirmation = takePresentedQuitConfirmation() else {
            return
        }
        if let handle = confirmation.ownedHandle {
            requestOwnedTermination(handle: handle, transactionID: confirmation.transactionID)
        } else {
            replyToTermination(allow: true, transactionID: confirmation.transactionID)
        }
    }

    private func requestOwnedTermination(handle: SpawnHandle, transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID) else { return }
        presentation = .stopping
        quitTask?.cancel()
        quitTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.supervisor.requestTermination(handle)
            guard self.isActiveTerminationTransaction(transactionID) else { return }
            switch result {
            case .signalSent:
                guard self.terminationTransactions.markSignalRequested(for: transactionID) else { return }
                self.presentation = .stopping
            case .alreadyExited, .ownershipLost, .terminalUnavailable, .signalFailed, .staleHandle:
                self.presentation = .stopping
            }
            await self.waitForCleanupAndReply(
                handle: handle,
                timeoutNanoseconds: 10_000_000_000,
                transactionID: transactionID
            )
        }
    }

    private func waitForCleanupAndReply(
        handle: SpawnHandle,
        timeoutNanoseconds: UInt64,
        transactionID: UInt64
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while isActiveTerminationTransaction(transactionID), !Task.isCancelled {
            if await supervisor.cleanupComplete() {
                guard isActiveTerminationTransaction(transactionID) else { return }
                currentHandle = nil
                replyToTermination(allow: true, transactionID: transactionID)
                return
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                guard isActiveTerminationTransaction(transactionID) else { return }
                presentation = .stopTimedOut
                presentTimeoutChoices(handle: handle, transactionID: transactionID)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func presentTimeoutChoices(handle: SpawnHandle, transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID) else { return }
        let alert = NSAlert()
        alert.messageText = "DSH 或日志清理尚未结束"
        alert.informativeText = "不会强制结束进程，也不会关闭日志读取端。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "取消退出")
        alert.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow()) { [weak self] response in
            guard let self, self.isActiveTerminationTransaction(transactionID) else { return }
            if response == .alertFirstButtonReturn {
                self.quitTask = Task { [weak self] in
                    await self?.waitForCleanupAndReply(
                        handle: handle,
                        timeoutNanoseconds: 10_000_000_000,
                        transactionID: transactionID
                    )
                }
            } else {
                self.cancelTermination(transactionID: transactionID)
            }
        }
    }

    private func cancelTermination(transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID) else { return }
        dismissQuitConfirmation(for: transactionID)
        terminationConfirmation.clear(for: transactionID)
        guard let restoredGate = terminationTransactions.restoredGateAfterCancellation(for: transactionID) else { return }
        let signalWasRequested = terminationTransactions.didRequestSignal(for: transactionID)
        let restoredPresentation = presentationBeforeTermination
        quitTask?.cancel()
        quitTask = nil
        quitPending = false
        _ = terminationTransactions.cancel(transactionID)

        guard let handle = currentHandle else {
            terminationGate = restoredGate == .quitPending ? .clear : restoredGate
            presentation = restoredPresentation ?? (webContainer == nil ? .serviceStopped : .ready)
            presentationBeforeTermination = nil
            replyToTermination(allow: false, transactionID: transactionID)
            return
        }

        // 先移除旧事务，再恢复它开始时最后一次确认的真实门控快照，最后才
        // reply(false)。若已发过 SIGTERM，则信号权不可恢复，只能保持 cleanupPending。
        terminationGate = restoredGate == .quitPending ? .cleanupPending : restoredGate
        if signalWasRequested {
            presentation = webContainer == nil ? .drainingCleanup : .ready
        } else if let restoredPresentation {
            presentation = restoredPresentation
        } else {
            presentation = webContainer == nil ? .waitingForService : .ready
        }
        presentationBeforeTermination = nil
        replyToTermination(allow: false, transactionID: transactionID)
        resumeReadinessAfterCancelledTermination(handle: handle, signalWasRequested: signalWasRequested)

        Task { [weak self] in
            guard let self else { return }
            let cleanupState = await self.supervisor.cleanupState(handle)
            guard self.currentHandle == handle,
                  !self.quitPending,
                  self.terminationTransactions.activeID == nil,
                  self.terminationTransactions.latestID == transactionID else { return }
            if cleanupState == .awaitingReap {
                let ownership = await self.supervisor.verifyOwnership(handle)
                guard self.currentHandle == handle,
                      !self.quitPending,
                      self.terminationTransactions.activeID == nil,
                      self.terminationTransactions.latestID == transactionID else { return }
                if ownership == .verified {
                    self.terminationGate = .stoppable
                    self.presentation = self.webContainer == nil ? .waitingForService : .ready
                    return
                }
            }

            let cleanupComplete = await self.supervisor.cleanupComplete()
            guard self.currentHandle == handle,
                  !self.quitPending,
                  self.terminationTransactions.activeID == nil,
                  self.terminationTransactions.latestID == transactionID else { return }
            if cleanupComplete {
                self.currentHandle = nil
                self.terminationGate = .clear
                if let terminalError = await self.supervisor.terminalIncompatibilityError() {
                    guard !self.quitPending,
                          self.terminationTransactions.activeID == nil,
                          self.terminationTransactions.latestID == transactionID else { return }
                    self.presentation = .terminalUnavailable(terminalError)
                } else if self.reachableServiceAfterExitHandle == handle {
                    await self.refreshExternalServiceAfterCleanup(
                        handle: handle,
                        generation: self.operationGeneration,
                        exitStatus: self.lastObservedExit?.handle == handle
                            ? self.lastObservedExit?.status
                            : nil
                    )
                } else {
                    self.presentation = .serviceStopped
                }
            } else {
                self.terminationGate = .cleanupPending
                self.presentation = .drainingCleanup
            }
        }
    }

    private func resumeReadinessAfterCancelledTermination(
        handle: SpawnHandle,
        signalWasRequested: Bool
    ) {
        guard !signalWasRequested,
              terminationGate == .stoppable,
              currentHandle == handle,
              webContainer == nil,
              presentation == .waitingForService else { return }
        startupTask?.cancel()
        let generation = operationGeneration
        startupTask = Task { [weak self] in
            await self?.waitForReadiness(handle: handle, generation: generation)
        }
    }

    private func replyToTermination(allow: Bool, transactionID: UInt64) {
        dismissQuitConfirmation(for: transactionID)
        terminationConfirmation.clear(for: transactionID)
        guard terminationTransactions.markReplySent(for: transactionID) else { return }
        NSApp.reply(toApplicationShouldTerminate: allow)
    }

    private func scheduleStopConfirmationAutoCancellation(for transactionID: UInt64) {
        stopConfirmationAutoCancelTask?.cancel()
        stopConfirmationAutoCancelTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.stopConfirmationAutoCancelNanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.quitConfirmation?.transactionID == transactionID,
                  self.isActiveTerminationTransaction(transactionID) else {
                return
            }
            self.cancelTermination(transactionID: transactionID)
        }
    }

    private func takePresentedQuitConfirmation() -> PendingQuitConfirmation? {
        guard let confirmation = quitConfirmation,
              let pending = pendingQuitConfirmation,
              confirmation.transactionID == pending.transactionID,
              isActiveTerminationTransaction(confirmation.transactionID),
              terminationConfirmation.takePresentedTransaction() == confirmation.transactionID else {
            return nil
        }

        dismissQuitConfirmation(for: confirmation.transactionID)
        return pending
    }

    private func dismissQuitConfirmation(for transactionID: UInt64) {
        let isPresented = quitConfirmation?.transactionID == transactionID
            || pendingQuitConfirmation?.transactionID == transactionID
        guard isPresented else { return }

        stopConfirmationAutoCancelTask?.cancel()
        stopConfirmationAutoCancelTask = nil
        if quitConfirmation?.transactionID == transactionID {
            quitConfirmation = nil
        }
        if pendingQuitConfirmation?.transactionID == transactionID {
            pendingQuitConfirmation = nil
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let error as ProcessSupervisorError:
            switch error {
            case .invalidExecutable: return "dsh 路径不可执行。"
            case let .spawnFailed(code): return "无法启动 dsh（posix_spawn 错误 \(code)）。"
            case .cleanupPending: return "上一次进程清理尚未完成。"
            case let .terminalIncompatible(code): return "当前 App 会话无法可靠回收子进程（waitpid 错误 \(code)），已禁止再次启动。"
            default: return "启动准备失败：\(error)。"
            }
        default:
            return error.localizedDescription
        }
    }
}
