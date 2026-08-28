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

enum DSHUpdatePreparation: Equatable {
    case ready
    case externalServiceActive
    case busy(String)
    case stopTimedOut
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
        case listenerLost
        case ownershipLost
        case serviceStopped
        case drainingCleanup
        case terminalUnavailable(Int32)
        case preparingDependencyUpdate
        case updatingDependency
        case stopping
        case stopTimedOut
    }

    @Published private(set) var presentation: Presentation = .checking
    @Published private(set) var webContainer: WebContainer?
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var quitConfirmation: QuitConfirmation?

    private let instanceLock: SingleInstanceLock
    private let preferences: UserPreferences
    private let serviceSession = ServiceSessionController()
    private let privatePluginController = PrivatePluginController()
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
    let terminalController = DesktopTerminalController()

    private var window: NSWindow?
    private var windowChrome: WindowChromeContainer?
    /// 由 AppDelegate 挂接原生更新浮层；DSH 页面和私有插件都不会接触这个入口。
    var onUpdateIndicatorPressed: ((NSView) -> Void)?
    /// 标题栏只负责原生控件的展示和点击回调；进程、更新和终端状态仍由本协调器持有。
    private lazy var titlebarControls = AppTitlebarControls(
        onUpdatePressed: { [weak self] control in
            self?.onUpdateIndicatorPressed?(control)
        },
        onTerminalToggle: { [weak self] in
            self?.toggleTerminalPanel()
        }
    )
    private var currentHandle: SpawnHandle? { serviceSession.currentHandle }
    private var operationGeneration: UInt64 { serviceSession.generation }
    private var startupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// generation（启动代次）切换恰好落在 `spawn` 返回边界时，旧子进程仍须
    /// 完成一次身份复核、正常 SIGTERM 和双 pipe 排空。该任务不受旧 startupTask
    /// 的取消状态影响，也不会使用强制信号或猜测 PID。
    private var staleSpawnCleanupTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var terminationGate: TerminationGateSnapshot = .clear
    private var quitPending = false
    private var terminationTransactions = TerminationTransactionRegistry()
    private var terminationConfirmation = TerminationConfirmationGate()
    private var pendingQuitConfirmation: PendingQuitConfirmation?
    /// 第二次 `⌘Q` 只有在 App 自己的 PTY 已全部收敛后才进入 DSH 清理。
    /// spawn 可能跨越这个 await 边界，因此用事务 ID 记录“第二击已确认且
    /// terminal 已完成”，让迟到的 spawn 结果继续同一条退出路径。
    private var confirmedTerminationReadyID: UInt64?
    private var stopConfirmationAutoCancelTask: Task<Void, Never>?
    private var presentationBeforeTermination: Presentation?
    private var reconciledExitedHandle: SpawnHandle?
    private var reachableServiceAfterExitHandle: SpawnHandle?
    private var readinessDeadline: ReadinessDeadline?
    private var lastObservedExit: (handle: SpawnHandle, status: ProcessExitStatus)?
    /// resolver 准备、句柄绑定和 bridge 授权统一由 typed controller 管理。
    private var privatePluginBridgeCapabilities = PrivatePluginBridgeCapabilities.disabled
    /// 已处理过失权的 handle 不再重复 probe；停止权一旦撤销，绝不恢复。
    private var ownershipLossReconciledHandle: SpawnHandle?
    /// 只有菜单中的显式更新确认可以进入此状态。它与 AppKit 退出事务互斥，
    /// 并保证 npm 修改全局安装前，本 App 拥有的 DSH 已完成正常退出和日志排空。
    private var dependencyUpdatePreparationActive = false

    /// 原生提示只作为主窗口的 sheet（窗口附属弹窗）出现；调用方不应创建独立
    /// modal panel（模态面板）或为了显示结果强制把 App 抢到前台。
    var alertHostWindow: NSWindow? { window }

    init(
        instanceLock: SingleInstanceLock,
        preferences: UserPreferences
    ) {
        self.instanceLock = instanceLock
        self.preferences = preferences
        super.init()
        terminalController.onStateChange = { [weak self] _, _ in
            self?.refreshTerminalTitlebarControl()
        }
        terminalController.onConversationReservationChange = { [weak self] height in
            self?.webContainer?.setTerminalConversationReservation(height)
        }
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
        // 在网页尚未报告当前主题前，用与 DSH 深色画布接近的中性底色兜底。
        // 不能使用 `.windowBackgroundColor`：即使最终页面为深色，WebKit 也可能在
        // 首帧按系统默认白色绘制，造成启动时闪白。
        window.backgroundColor = AppLaunchSurface.color
        window.isOpaque = true
        window.contentView = chrome
        chrome.install(hostingView: content, safeAreaLayoutGuide: chrome.safeAreaLayoutGuide)
        titlebarControls.install(in: window, chrome: chrome)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DSHDesktopMainWindow")
        if !window.setFrameUsingName("DSHDesktopMainWindow") {
            window.center()
        }
        self.window = window
        self.windowChrome = chrome
        refreshTerminalTitlebarControl()
        restoreMainWindow()
    }

    func setUpdateAvailability(_ availability: UpdateAvailability) {
        titlebarControls.setUpdateAvailability(availability)
    }

    func presentAvailableUpdatesFromMenu() {
        titlebarControls.presentAvailableUpdatesFromMenu()
    }

    func beginStartup() {
        startupTask?.cancel()
        privatePluginController.beginStartup()
        revokePrivatePluginBridges()
        let generation = serviceSession.beginStartupGeneration()
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
                self.serviceSession.transition(.launchFailed("所选文件不可执行。"))
                self.presentation = .launchFailed("所选文件不可执行。")
                return
            }
            self.preferences.selectedDSHPath = url.path
            self.beginStartup()
        }
    }

    /// 为用户已经确认的 DSH 更新准备安全窗口：只会停止仍可验证为本 App 直接
    /// 创建的进程；external（外部已有）服务、失去归属的 PID 或仍在清理的进程
    /// 都会拒绝更新，不会猜测、扫描或发送强制信号。
    func prepareForDSHUpdate() async -> DSHUpdatePreparation {
        guard !dependencyUpdatePreparationActive else {
            return .busy("已有 DeepSeek Harness 更新正在进行。")
        }
        guard !quitPending, terminationTransactions.activeID == nil else {
            return .busy("DSD Pancake 正在处理退出请求，请取消退出后重试。")
        }
        guard !terminationGate.waitsForSpawnResult else {
            return .busy("DSH 正在创建进程，请等待启动结束后重试。")
        }

        guard let handle = currentHandle else {
            return await prepareForDSHUpdateWithoutOwnedHandle()
        }

        let cleanupState = await serviceSession.cleanupState(handle)
        guard currentHandle == handle else {
            return await prepareForDSHUpdateWithoutOwnedHandle()
        }
        switch cleanupState {
        case .clear:
            guard serviceSession.clearHandle(ifExpected: handle) else {
                return await prepareForDSHUpdateWithoutOwnedHandle()
            }
            terminationGate = .clear
            return await prepareForDSHUpdateWithoutOwnedHandle()
        case .awaitingReap:
            break
        case .supervisionOnly, .drainingPipes, .orphanDrainIncompatible:
            return .busy("DSH 或它的日志仍在清理，完成前不会修改全局安装。")
        case .terminalUnavailable:
            return .busy("当前 App 会话无法可靠回收 DSH，重新打开 App 后再试。")
        }

        guard await serviceSession.verifyOwnership(handle) == .verified,
              currentHandle == handle else {
            return .externalServiceActive
        }

        let terminationResult = await serviceSession.requestTermination(handle)
        guard currentHandle == handle else {
            return await prepareForDSHUpdateWithoutOwnedHandle()
        }
        switch terminationResult {
        case .signalSent, .alreadyExited:
            break
        case .ownershipLost, .staleHandle:
            return .externalServiceActive
        case .terminalUnavailable:
            return .busy("当前 App 会话无法可靠回收 DSH，重新打开 App 后再试。")
        case let .signalFailed(code):
            return .busy("无法正常停止本次 DSH（kill 错误 \(code)），不会继续更新。")
        }

        dependencyUpdatePreparationActive = true
        startupTask?.cancel()
        monitorTask?.cancel()
        let updateGeneration = serviceSession.beginStartupGeneration()
        revokePrivatePluginBridges(for: handle)
        clearReadinessDeadline(for: handle)
        terminationGate = .cleanupPending
        presentation = .preparingDependencyUpdate

        let deadline = DispatchTime.now().uptimeNanoseconds &+ 15_000_000_000
        while currentHandle == handle,
              dependencyUpdatePreparationActive,
              DispatchTime.now().uptimeNanoseconds < deadline {
            _ = await serviceSession.checkExit(handle)
            guard currentHandle == handle,
                  operationGeneration == updateGeneration,
                  dependencyUpdatePreparationActive,
                  !Task.isCancelled else { break }
            let cleanupComplete = await serviceSession.cleanupComplete()
            guard currentHandle == handle,
                  operationGeneration == updateGeneration,
                  dependencyUpdatePreparationActive,
                  !Task.isCancelled else { break }
            if cleanupComplete {
                guard serviceSession.clearHandle(ifExpected: handle) else { break }
                resetRuntimeAfterOwnedDSHStoppedForUpdate()
                let result = await serviceSession.probe()
                guard operationGeneration == updateGeneration,
                      currentHandle == nil,
                      dependencyUpdatePreparationActive,
                      !Task.isCancelled else {
                    return .busy("DeepSeek Harness 更新准备已取消。")
                }
                switch result {
                case .unavailable:
                    webContainer = nil
                    presentation = .updatingDependency
                    return .ready
                case .dshLikely, .reachableUnknown, .reachableNonHTML:
                    dependencyUpdatePreparationActive = false
                    terminationGate = .clear
                    await presentExternalServiceAfterOwnershipLoss(result)
                    return .externalServiceActive
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        dependencyUpdatePreparationActive = false
        terminationGate = .cleanupPending
        presentation = .drainingCleanup
        if currentHandle == handle {
            startMonitoring(handle: handle, generation: updateGeneration)
        }
        return .stopTimedOut
    }

    /// npm 更新无论成功或失败都重新走正常启动预检。若安装已经损坏，既有的
    /// launchFailed 状态会显示真实错误；这里不会循环安装或退回未知版本。
    func finishDSHUpdateAndRestart() {
        guard dependencyUpdatePreparationActive else { return }
        dependencyUpdatePreparationActive = false
        beginStartup()
    }

    private func prepareForDSHUpdateWithoutOwnedHandle() async -> DSHUpdatePreparation {
        let result = await serviceSession.probe()
        guard currentHandle == nil,
              !terminationGate.waitsForSpawnResult,
              !quitPending else {
            return .busy("DSH 状态刚刚发生变化，请稍后重试。")
        }
        guard case .unavailable = result else {
            return .externalServiceActive
        }

        dependencyUpdatePreparationActive = true
        startupTask?.cancel()
        monitorTask?.cancel()
        _ = serviceSession.beginStartupGeneration()
        revokePrivatePluginBridges()
        webContainer = nil
        terminationGate = .clear
        presentation = .updatingDependency
        return .ready
    }

    private func resetRuntimeAfterOwnedDSHStoppedForUpdate() {
        terminationGate = .clear
        privatePluginController.reset()
        reconciledExitedHandle = nil
        reachableServiceAfterExitHandle = nil
        lastObservedExit = nil
        ownershipLossReconciledHandle = nil
        readinessDeadline = nil
    }

    func acceptUnknownExistingService() {
        guard case .unknownExistingService = presentation else { return }
        serviceSession.transition(.acceptedUnknownService)
        showWebContainer(reloadExisting: true)
    }

    func rejectUnknownExistingService() {
        guard case .unknownExistingService = presentation else { return }
        serviceSession.transition(.rejectedUnknownService)
        presentation = .serviceStopped
    }

    func showLogs() {
        Task { [weak self] in
            guard let self else { return }
            self.logEntries = await self.serviceSession.logSnapshot()
        }
    }

    func restoreMainWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var canToggleTerminalPanel: Bool {
        terminalController.canToggleFromMenu
    }

    var isTerminalPanelVisible: Bool {
        terminalController.isPanelVisible
    }

    func toggleTerminalPanel() {
        terminalController.toggleFromMenu()
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
        let initial = await serviceSession.probe()
        guard generation == operationGeneration, !Task.isCancelled else { return }
        serviceSession.recordProbe(initial, generation: generation)

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
        guard let executable = serviceSession.locateExecutable(lastChosenPath: preferences.selectedDSHPath) else {
            serviceSession.transition(.launchFailed("未找到可执行的 dsh。"))
            presentation = .dshNotFound
            return
        }

        serviceSession.beginPreflight(generation: generation)
        let preflight = await serviceSession.probe()
        guard generation == operationGeneration, !Task.isCancelled else { return }
        serviceSession.recordProbe(preflight, generation: generation)
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

        guard await serviceSession.canSpawn() else {
            serviceSession.transition(.launchFailed("上一次创建的进程或日志清理尚未收敛，不能再次启动。"))
            presentation = .launchFailed("上一次创建的进程或日志清理尚未收敛，不能再次启动。")
            return
        }

        let baseEnvironment = AppRuntimeConfiguration.current.applyingLaunchOverrides(
            to: ProcessInfo.processInfo.environment
        )
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let privatePluginPatches = privatePluginController.preparePatches(
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory,
            resourceRoot: Bundle.main.resourceURL
        )
        let spec = LaunchEnvironment.makeSpec(
            executable: executable,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory,
            privatePluginPatches: privatePluginPatches
        )
        // 此门控必须早于任何 pipe、attr 或 posix_spawn 资源准备。
        guard serviceSession.beginSpawn() else {
            presentation = .launchFailed("当前生命周期状态不允许创建新的 DSH。")
            return
        }
        terminationGate = .spawnTransaction
        presentation = .starting

        do {
            let handle = try await serviceSession.spawn(spec)
            guard generation == operationGeneration else {
                let cleanupGeneration = operationGeneration
                serviceSession.adoptHandleForCleanup(handle)
                terminationGate = .cleanupPending
                revokePrivatePluginBridges(for: handle)
                convergeStaleSpawn(handle: handle, generation: cleanupGeneration)
                return
            }
            serviceSession.installSpawnedHandle(handle)
            privatePluginController.bindPreparedPatches(to: handle)
            reconciledExitedHandle = nil
            reachableServiceAfterExitHandle = nil
            lastObservedExit = nil
            ownershipLossReconciledHandle = nil
            resetReadinessDeadline(for: handle, generation: generation)
            let ownership = await serviceSession.verifyOwnership(handle)
            guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
            let postSpawnPresentation: Presentation
            if ownership == .verified {
                terminationGate = .stoppable
                postSpawnPresentation = .waitingForService
            } else {
                _ = revokeOwnedRuntimeAuthority(for: handle)
                postSpawnPresentation = .ownershipLost
            }
            startMonitoring(handle: handle, generation: generation)
            if quitPending {
                // 退出请求可能在 SpawnHandle 安装前到达。确认页真正出现前，
                // 用此刻已知的状态替换最初的 .starting 快照，取消退出时才能
                // 回到真实的等待/竞争状态。
                presentationBeforeTermination = postSpawnPresentation
                await continueDeferredTerminationAfterSpawnIfNeeded()
            } else {
                presentation = postSpawnPresentation
                if ownership == .verified {
                    await waitForReadiness(handle: handle, generation: generation)
                }
            }
        } catch {
            // 旧 startupTask 可能在新 generation 开始后才从 `spawn` 抛错。
            // 它不再拥有 plugin、reducer、termination gate 或 presentation，
            // 因而不得重置新一轮已经建立的状态。
            guard generation == operationGeneration, !Task.isCancelled else { return }
            terminationGate = .clear
            privatePluginController.reset()
            revokePrivatePluginBridges()
            let message = describe(error)
            serviceSession.transition(.launchFailed(message))
            presentation = .launchFailed(message)
            await continueDeferredTerminationAfterSpawnIfNeeded()
        }
    }

    /// 新一轮 startup 已覆盖旧 generation，但旧 `posix_spawn` 仍可能刚刚成功。
    /// 该子进程从未成为可见会话，因此按事务回滚处理：只在身份仍匹配时发送一次
    /// SIGTERM，随后等待 waitpid + stdout/stderr 自然收敛。任何失权或信号失败都
    /// 只进入监督等待，绝不强杀、扫描端口进程或猜测 PID。
    private func convergeStaleSpawn(handle: SpawnHandle, generation: UInt64) {
        guard staleSpawnCleanupTask == nil else { return }
        if !quitPending {
            presentation = .drainingCleanup
        }
        staleSpawnCleanupTask = Task { @MainActor [weak self] in
            await self?.runStaleSpawnConvergence(handle: handle, generation: generation)
        }
    }

    private func runStaleSpawnConvergence(handle: SpawnHandle, generation: UInt64) async {
        defer { staleSpawnCleanupTask = nil }

        let ownership = await serviceSession.verifyOwnership(handle)
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }

        if ownership == .verified {
            _ = await serviceSession.requestTermination(handle)
            guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
        }
        terminationGate = .cleanupPending

        while isCurrentLifecycle(handle: handle, generation: generation) {
            _ = await serviceSession.checkExit(handle)
            guard isCurrentLifecycle(handle: handle, generation: generation) else { return }

            let cleanupComplete = await serviceSession.cleanupComplete()
            guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
            if cleanupComplete {
                let terminalError = await serviceSession.terminalIncompatibilityError()
                guard isCurrentLifecycle(handle: handle, generation: generation) else { return }

                if terminalError == nil {
                    guard serviceSession.clearHandle(ifExpected: handle) else { return }
                } else {
                    guard serviceSession.clearHandle(
                        ifExpected: handle,
                        cleanup: .terminalUnavailable
                    ) else { return }
                }
                terminationGate = quitPending ? .quitPending : .clear

                if quitPending {
                    await continueDeferredTerminationAfterSpawnIfNeeded()
                } else if let terminalError {
                    presentation = .terminalUnavailable(terminalError)
                } else if !dependencyUpdatePreparationActive {
                    // 无论清理期间又收到多少次 retry，最终都只为最新用户意图
                    // 启动一轮；`beginStartup` 自己会生成新的 generation。
                    beginStartup()
                }
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
        }
    }

    private func waitForReadiness(handle: SpawnHandle, generation: UInt64) async {
        while hasRemainingReadinessTime(for: handle, generation: generation) {
            guard generation == operationGeneration, currentHandle == handle, !Task.isCancelled, !quitPending else { return }
            guard let timeout = remainingReadinessTimeout(for: handle, generation: generation) else { break }
            let result = await serviceSession.probe(timeout: timeout)
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

            let exitObservation = await serviceSession.checkExit(handle)
            guard isCurrentLifecycle(handle: handle, generation: generation),
                  !quitPending else { return }
            switch exitObservation {
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
        serviceSession.transition(.readinessTimedOut)
        presentation = .readinessTimedOut
    }

    private func startMonitoring(handle: SpawnHandle, generation: UInt64) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while self.isCurrentLifecycle(handle: handle, generation: generation) {
                let observation = await self.serviceSession.checkExit(handle)
                guard self.isCurrentLifecycle(handle: handle, generation: generation) else { return }
                switch observation {
                case .running:
                    if self.serviceSession.hasVerifiedListener(for: handle) {
                        await self.reconcileVerifiedListener(
                            handle: handle,
                            generation: generation
                        )
                    } else {
                        await self.reconcileProcessOwnershipLossIfNeeded(
                            handle: handle,
                            generation: generation
                        )
                    }
                case let .reaped(status):
                    await self.reconcileExitedProcess(handle: handle, generation: generation, exitStatus: status)
                case .terminalUnavailable, .staleHandle:
                    await self.reconcileExitedProcess(handle: handle, generation: generation)
                }
                guard self.isCurrentLifecycle(handle: handle, generation: generation) else { return }
                // 退出确认、SIGTERM 与超时选择只由 `quitTask` 串行处理。
                // 监视器继续负责观察退出，不能并行弹出第二个超时提示。
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.isCurrentLifecycle(handle: handle, generation: generation) else { return }
            }
        }
    }

    /// 任一异步观察只对启动它的 handle + App generation 生效。`Task` 取消、
    /// 新 generation 开始或后继 handle 安装后，迟到结果都只能静默返回。
    private func isCurrentLifecycle(handle: SpawnHandle, generation: UInt64) -> Bool {
        !Task.isCancelled
            && currentHandle == handle
            && operationGeneration == generation
    }

    /// listener（监听者）授权与直接子进程的停止权是两条独立能力。listener
    /// 消失时必须立即永久撤销本轮 bridge，但只要 handle 和进程身份仍可验证，
    /// App 仍可安全监督并在退出时停止自己创建的子进程。
    @discardableResult
    private func revokeListenerAuthority(
        for handle: SpawnHandle,
        clearReadiness: Bool = true
    ) -> Bool {
        guard currentHandle == handle else { return false }
        serviceSession.transition(.listenerLost)
        revokePrivatePluginBridges(for: handle)
        if clearReadiness {
            clearReadinessDeadline(for: handle)
        }
        return true
    }

    /// 进程身份一旦失去，bridge 与 stopping right（停止权）都必须撤销。
    /// 这条安全副作用不受退出确认 UI 影响；即使 `quitPending`，取消退出也不能
    /// 恢复旧停止权，已展示的确认也不再携带 owned handle。
    @discardableResult
    private func revokeOwnedRuntimeAuthority(
        for handle: SpawnHandle,
        clearReadiness: Bool = true
    ) -> Bool {
        guard currentHandle == handle else { return false }
        ownershipLossReconciledHandle = handle
        serviceSession.transition(.ownershipLost)
        revokePrivatePluginBridges(for: handle)
        if clearReadiness {
            clearReadinessDeadline(for: handle)
        }
        terminationGate = .cleanupPending

        if let pendingQuitConfirmation,
           pendingQuitConfirmation.ownedHandle == handle {
            self.pendingQuitConfirmation = PendingQuitConfirmation(
                transactionID: pendingQuitConfirmation.transactionID,
                ownedHandle: nil
            )
            quitConfirmation = QuitConfirmation(
                transactionID: pendingQuitConfirmation.transactionID,
                stopsOwnedService: false
            )
        }
        return true
    }

    /// bridge（原生桥接）授权不是一次性快照。页面被认定为 owned 后，每轮监视都
    /// 同时复核直接子进程身份和 loopback listener（本机监听者）。listener 一旦
    /// 消失，立即永久撤销本轮 bridge；即使同一子进程稍后恢复监听，也必须从关闭
    /// bridge 的页面状态继续，不能复用旧授权。
    private func reconcileVerifiedListener(handle: SpawnHandle, generation: UInt64) async {
        let ownership = await serviceSession.verifyLocalServiceOwnership(handle)
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }

        switch ownership {
        case .verified:
            return

        case .notListening:
            guard revokeListenerAuthority(for: handle) else { return }
            // 退出确认期间也必须先撤销 bridge 与 verified listener；
            // 只有用于展示端口现状的 probe/presentation 可以被延后；直接
            // 子进程的安全监督与停止权不依赖 listener，因而继续保留。
            guard !quitPending else { return }
            let result = await serviceSession.probe()
            guard isCurrentLifecycle(handle: handle, generation: generation),
                  !quitPending else { return }
            presentServiceAfterListenerLoss(result)

        case .ownershipLost:
            await reconcileConfirmedProcessOwnershipLoss(
                handle: handle,
                generation: generation
            )

        case let .alreadyExited(status):
            await reconcileExitedProcess(handle: handle, generation: generation, exitStatus: status)
        case .terminalUnavailable, .staleHandle:
            await reconcileExitedProcess(handle: handle, generation: generation)
        }
    }

    /// `runningOwned` 不是永久停止授权。只要后续 PID、启动时间或 PGID 的实测值
    /// 不再匹配，本次会话立即永久失去停止权。
    private func reconcileProcessOwnershipLossIfNeeded(
        handle: SpawnHandle,
        generation: UInt64
    ) async {
        let ownership = await serviceSession.verifyOwnership(handle)
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
        guard ownership != .verified else { return }
        await reconcileConfirmedProcessOwnershipLoss(handle: handle, generation: generation)
    }

    /// 已确认失权后只读探测端口，不停止、接管或重启端口上的任何进程。
    private func reconcileConfirmedProcessOwnershipLoss(
        handle: SpawnHandle,
        generation: UInt64,
        knownProbeResult: ProbeResult? = nil
    ) async {
        guard isCurrentLifecycle(handle: handle, generation: generation),
              ownershipLossReconciledHandle != handle else { return }
        guard revokeOwnedRuntimeAuthority(for: handle) else { return }
        guard !quitPending else { return }

        let result = if let knownProbeResult {
            knownProbeResult
        } else {
            await serviceSession.probe()
        }
        guard isCurrentLifecycle(handle: handle, generation: generation),
              !quitPending else { return }
        await presentExternalServiceAfterOwnershipLoss(result)
    }

    /// listener 丢失后，本轮 bridge 永久撤销；端口页面不能继承此前的 bridge
    /// 授权，只能按此刻的只读探测结果重新展示。直接子进程停止权仍独立保留。
    private func presentServiceAfterListenerLoss(_ result: ProbeResult) {
        switch result {
        case .dshLikely:
            showWebContainer(reloadExisting: true)
        case let .reachableUnknown(reason):
            presentation = .unknownExistingService(reason)
        case let .reachableNonHTML(reason):
            presentation = .portAbnormal(reason)
        case .unavailable:
            presentation = .listenerLost
        }
    }

    private func showWebContainer(
        reloadExisting: Bool = false,
        ownership: ServiceOwnership = .external
    ) {
        serviceSession.transition(.serviceReady(ownership: ownership))
        if let webContainer {
            webContainer.setNotificationBridgeEnabled(privatePluginBridgeCapabilities.notification)
            webContainer.setTerminalBridgeEnabled(privatePluginBridgeCapabilities.terminal)
            if reloadExisting {
                webContainer.loadLocalService()
            }
            presentation = .ready
            return
        }
        let container = WebContainer(
            notificationCoordinator: notificationCoordinator,
            terminalController: terminalController
        )
        container.setNotificationBridgeEnabled(privatePluginBridgeCapabilities.notification)
        container.setTerminalBridgeEnabled(privatePluginBridgeCapabilities.terminal)
        container.onChromeStyleChange = { [weak self] style in
            self?.windowChrome?.apply(style: style)
            self?.terminalController.setSidebarWidth(style?.sidebarWidth)
            self?.terminalController.setMainSurfaceColor(style?.mainSurfaceColor)
        }
        webContainer = container
        container.loadLocalService()
        presentation = .ready
    }

    /// 这些状态都还保留本次 `SpawnHandle`。重新检查只会复用该句柄和
    /// probe（服务探测），绝不会创建、停止或重新认领任何进程。
    private var canContinueWaitingForService: Bool {
        switch presentation {
        case .readinessTimedOut, .portConflict, .listenerLost, .ownershipLost, .drainingCleanup, .launchFailed:
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
        let ownership = await serviceSession.verifyLocalServiceOwnership(handle)
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }

        switch ownership {
        case .verified:
            guard !quitPending else { return }
            terminationGate = .stoppable
            clearReadinessDeadline(for: handle)
            switch result {
            case .dshLikely, .reachableUnknown:
                guard serviceSession.markVerifiedListener(for: handle) else { return }
                applyPrivatePluginBridgeCapabilities(
                    privatePluginController.authorizeBridges(
                        ownershipVerification: ownership,
                        handle: handle
                    )
                )
                // 当前会话直接创建且 listener 已证明归属时，manifest 只保留兼容提示作用。
                // typed launch state 只表示“本次带覆盖层且尚未 ready”；消费后即使
                // 持久 WebContainer 仍存在，当前进程后续退出也不会误触发无插件重试。
                privatePluginController.markReady(for: handle)
                showWebContainer(reloadExisting: true, ownership: .owned)
            case let .reachableNonHTML(reason):
                revokePrivatePluginBridges(for: handle)
                presentation = .launchFailed("本次 dsh 已监听 \(LocalService.port)，但根页面不能作为 DSH HTML 加载（\(nonHTMLReasonText(reason))）。可继续检查或查看本次内存日志。")
            case .unavailable:
                _ = revokeListenerAuthority(for: handle)
                presentation = .listenerLost
            }

        case .notListening:
            // 端口在 spawn 后被其他服务占用。保留直接子进程凭据，
            // 但绝不把该网页服务或其监听者认定为 owned；在退出确认期间
            // 同样先撤销权限，只省略 UI 更新。
            guard revokeListenerAuthority(for: handle) else { return }
            if !quitPending {
                presentation = .portConflict
            }

        case .ownershipLost:
            await reconcileConfirmedProcessOwnershipLoss(
                handle: handle,
                generation: generation,
                knownProbeResult: result
            )

        case let .alreadyExited(status):
            await reconcileExitedProcess(handle: handle, generation: generation, exitStatus: status)
        case .terminalUnavailable, .staleHandle:
            await reconcileExitedProcess(handle: handle, generation: generation)
        }
    }

    /// 身份或监听复核失败后，端口页面一律按 external 重新处理。
    private func presentExternalServiceAfterOwnershipLoss(_ result: ProbeResult) async {
        revokePrivatePluginBridges()
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
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
        guard revokeOwnedRuntimeAuthority(for: handle, clearReadiness: false) else { return }
        serviceSession.transition(.processExited)
        // 主 PID 已退出或已无法可靠确认；端口上即使仍有页面，也只能按 external 处理。
        if let exitStatus {
            lastObservedExit = (handle: handle, status: exitStatus)
        }
        let effectiveExitStatus = exitStatus ?? (lastObservedExit?.handle == handle ? lastObservedExit?.status : nil)

        let cleanupComplete = await serviceSession.cleanupComplete()
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }

        let terminalError = await serviceSession.terminalIncompatibilityError()
        guard isCurrentLifecycle(handle: handle, generation: generation) else { return }
        if let terminalError {
            if cleanupComplete {
                guard serviceSession.clearHandle(
                    ifExpected: handle,
                    cleanup: .terminalUnavailable
                ) else { return }
                reconciledExitedHandle = nil
                reachableServiceAfterExitHandle = nil
                lastObservedExit = nil
                clearReadinessDeadline(for: handle)
                terminationGate = quitPending ? .quitPending : .clear
                if !quitPending {
                    presentation = .terminalUnavailable(terminalError)
                }
            } else {
                serviceSession.transition(.cleanupChanged(.drainingPipes))
                terminationGate = .cleanupPending
                if !quitPending {
                    presentation = .drainingCleanup
                }
            }
            return
        }

        if cleanupComplete {
            if quitPending {
                // 退出事务已激活时，handle 的最终清理与 AppKit reply
                // 属于第二击路径。monitor 只记录进程已收敛，不与
                // `waitForCleanupAndReply` 竞争清除同一 handle。
                terminationGate = .quitPending
            } else {
                guard serviceSession.clearHandle(ifExpected: handle) else { return }
                terminationGate = .clear
            }
        } else {
            serviceSession.transition(.cleanupChanged(.drainingPipes))
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
                } else if !retryWithoutPrivatePluginsIfNeeded(handle: handle) {
                    presentCompletedExitWithoutReachableServiceIfNeeded(effectiveExitStatus)
                }
            }
            return
        }
        reconciledExitedHandle = handle

        let result: ProbeResult
        if let timeout = remainingReadinessTimeout(for: handle, generation: generation) {
            result = await serviceSession.probe(timeout: timeout)
        } else {
            // 服务已经处于 ready 后才退出时，仍保留一次受默认 2 秒限制的
            // post-exit probe；它不属于启动就绪等待窗口。
            result = await serviceSession.probe()
        }
        guard generation == operationGeneration,
              !Task.isCancelled,
              !quitPending,
              cleanupComplete ? currentHandle == nil : currentHandle == handle else { return }
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
                if !retryWithoutPrivatePluginsIfNeeded(handle: handle) {
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
        let result = await serviceSession.probe()
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

    private func applyPrivatePluginBridgeCapabilities(_ capabilities: PrivatePluginBridgeCapabilities) {
        privatePluginBridgeCapabilities = capabilities
        webContainer?.setNotificationBridgeEnabled(capabilities.notification)
        webContainer?.setTerminalBridgeEnabled(capabilities.terminal)
        terminalController.setBridgeEnabled(capabilities.terminal)
        refreshTerminalTitlebarControl()
    }

    /// verified listener（已验证监听者）和 native bridge 必须同时撤销，避免只关掉
    /// WebKit message handler，却让监视器继续把旧 listener 授权当作有效快照。
    private func revokePrivatePluginBridges(for handle: SpawnHandle? = nil) {
        serviceSession.revokeVerifiedListener(for: handle)
        applyPrivatePluginBridgeCapabilities(privatePluginController.revokeBridges())
    }

    private func refreshTerminalTitlebarControl() {
        titlebarControls.updateTerminalState(
            canToggle: terminalController.canToggleFromMenu,
            isVisible: terminalController.isPanelVisible
        )
    }

    /// 覆盖层只要让 DSH 在页面就绪前失败一次，就退回标准启动命令。此路径没有
    /// 轮询或守护进程：它复用原有的退出收敛后启动流程，而且每次失败只尝试一次。
    private func retryWithoutPrivatePluginsIfNeeded(handle: SpawnHandle) -> Bool {
        guard privatePluginController.scheduleFallbackIfNeeded(
            for: handle,
            quitPending: quitPending
        ) else {
            return false
        }
        revokePrivatePluginBridges(for: handle)
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
        serviceSession.transition(.beginQuit)
        let originalGate = terminationGate
        presentationBeforeTermination = presentation
        quitPending = true
        let transactionID = beginTerminationTransaction()
        confirmedTerminationReadyID = nil

        // 第一击永远只展示确认层：不 await cleanup、不关闭 PTY、不发信号，
        // 也不因为 handle 已经 clear/draining 就提前回复 AppKit。spawn transaction
        // 仍保留原门控，第二击后由迟到的 spawn 结果继续同一事务。
        if !originalGate.waitsForSpawnResult {
            terminationGate = .quitPending
        }
        let displayedOwnedHandle = originalGate == .stoppable ? currentHandle : nil
        presentQuitConfirmation(
            ownedHandle: displayedOwnedHandle,
            transactionID: transactionID
        )
    }

    private func continueDeferredTerminationAfterSpawnIfNeeded() async {
        guard let transactionID = terminationTransactions.activeID,
              isActiveTerminationTransaction(transactionID) else { return }

        // 确认层已经在第一击同步展示。第二击之前，迟到的 spawn
        // 只更新确认层的 owned 提示；第二击且 PTY 收敛之后，才进入
        // 停止/清理路径。
        guard confirmedTerminationReadyID == transactionID else {
            await refreshPresentedQuitOwnership(transactionID: transactionID)
            return
        }

        // `posix_spawn` 尚未返回时不能把 nil handle 当成“无子进程”。
        // 成功或失败回调会再次进入本方法。
        guard !terminationGate.waitsForSpawnResult else { return }
        await continueConfirmedTermination(transactionID: transactionID)
    }

    private func refreshPresentedQuitOwnership(transactionID: UInt64) async {
        guard isActiveTerminationTransaction(transactionID),
              quitConfirmation?.transactionID == transactionID,
              pendingQuitConfirmation?.transactionID == transactionID else { return }
        guard let handle = currentHandle else {
            updatePresentedQuitOwnership(nil, transactionID: transactionID)
            return
        }
        let cleanupState = await serviceSession.cleanupState(handle)
        guard isActiveTerminationTransaction(transactionID),
              currentHandle == handle else { return }
        guard cleanupState == .awaitingReap else {
            updatePresentedQuitOwnership(nil, transactionID: transactionID)
            return
        }
        let ownership = await serviceSession.verifyOwnership(handle)
        guard isActiveTerminationTransaction(transactionID),
              currentHandle == handle else { return }
        updatePresentedQuitOwnership(
            ownership == .verified ? handle : nil,
            transactionID: transactionID
        )
    }

    private func updatePresentedQuitOwnership(
        _ ownedHandle: SpawnHandle?,
        transactionID: UInt64
    ) {
        guard isActiveTerminationTransaction(transactionID),
              quitConfirmation?.transactionID == transactionID,
              pendingQuitConfirmation?.transactionID == transactionID else { return }
        let effectiveOwnedHandle = ownedHandle.flatMap { handle in
            ownershipLossReconciledHandle == handle ? nil : handle
        }
        pendingQuitConfirmation = PendingQuitConfirmation(
            transactionID: transactionID,
            ownedHandle: effectiveOwnedHandle
        )
        quitConfirmation = QuitConfirmation(
            transactionID: transactionID,
            stopsOwnedService: effectiveOwnedHandle != nil
        )
    }

    /// 只在第二击已确认且 PTY 收敛后调用。每次都重读当前 handle
    /// 和 ownership，不信任第一击时仅用于展示的快照。
    private func continueConfirmedTermination(transactionID: UInt64) async {
        guard isActiveTerminationTransaction(transactionID),
              confirmedTerminationReadyID == transactionID else { return }
        guard let handle = currentHandle else {
            replyToTermination(allow: true, transactionID: transactionID)
            return
        }

        let cleanupState = await serviceSession.cleanupState(handle)
        guard isActiveTerminationTransaction(transactionID),
              confirmedTerminationReadyID == transactionID else { return }
        guard currentHandle == handle else {
            if currentHandle == nil {
                replyToTermination(allow: true, transactionID: transactionID)
            }
            return
        }

        switch cleanupState {
        case .awaitingReap:
            let ownership = await serviceSession.verifyOwnership(handle)
            guard isActiveTerminationTransaction(transactionID),
                  confirmedTerminationReadyID == transactionID,
                  currentHandle == handle else { return }
            if ownership == .verified {
                requestOwnedTermination(handle: handle, transactionID: transactionID)
            } else {
                _ = revokeOwnedRuntimeAuthority(for: handle)
                beginCleanupWait(handle: handle, transactionID: transactionID)
            }

        case .clear:
            guard serviceSession.clearHandle(ifExpected: handle) || currentHandle == nil else {
                return
            }
            replyToTermination(allow: true, transactionID: transactionID)

        case .supervisionOnly, .terminalUnavailable, .drainingPipes, .orphanDrainIncompatible:
            beginCleanupWait(handle: handle, transactionID: transactionID)
        }
    }

    private func beginCleanupWait(handle: SpawnHandle, transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID),
              confirmedTerminationReadyID == transactionID else { return }
        quitTask?.cancel()
        quitTask = Task { [weak self] in
            await self?.waitForCleanupAndReply(
                handle: handle,
                timeoutNanoseconds: 10_000_000_000,
                transactionID: transactionID
            )
        }
    }

    private func presentQuitConfirmation(ownedHandle: SpawnHandle?, transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID),
              quitConfirmation == nil,
              pendingQuitConfirmation == nil else {
            return
        }

        let effectiveOwnedHandle = ownedHandle.flatMap { handle in
            ownershipLossReconciledHandle == handle ? nil : handle
        }

        // 提示层出现时保留原页面，不提前发送信号，也不切换为“正在停止”。
        // 只有用户再次按 ⌘Q 后才会退出；仅带有 owned handle 的确认会停止 DSH。
        terminationConfirmation.present(for: transactionID)
        pendingQuitConfirmation = PendingQuitConfirmation(
            transactionID: transactionID,
            ownedHandle: effectiveOwnedHandle
        )
        quitConfirmation = QuitConfirmation(
            transactionID: transactionID,
            stopsOwnedService: effectiveOwnedHandle != nil
        )
        scheduleStopConfirmationAutoCancellation(for: transactionID)
    }

    /// 再次 `⌘Q` 原子地取得确认权。提示消失后，owned DSH 才会被请求停止；
    /// external DSH 或无 DSH 时则直接回复 AppKit 允许退出。
    private func confirmPresentedQuitFromRepeatedCommandIfNeeded() {
        guard let confirmation = takePresentedQuitConfirmation() else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // DSH 可能是 external，但 terminal 只可能由本 App 创建；退出授权前仍需
            // 等待所有 PTY process group 完成清理。
            await self.terminalController.closeAllAndWait()
            guard self.isActiveTerminationTransaction(confirmation.transactionID) else { return }
            self.confirmedTerminationReadyID = confirmation.transactionID
            await self.continueDeferredTerminationAfterSpawnIfNeeded()
        }
    }

    private func requestOwnedTermination(handle: SpawnHandle, transactionID: UInt64) {
        guard isActiveTerminationTransaction(transactionID) else { return }
        if ownershipLossReconciledHandle == handle {
            // 确认被消费后、真正请求停止前仍可能失去 listener/进程身份。
            // 已撤销的停止权不能因为旧确认对象仍持有 handle 而恢复。
            quitTask?.cancel()
            quitTask = Task { [weak self] in
                await self?.waitForCleanupAndReply(
                    handle: handle,
                    timeoutNanoseconds: 10_000_000_000,
                    transactionID: transactionID
                )
            }
            return
        }
        serviceSession.transition(.beginStoppingOwnedService)
        presentation = .stopping
        quitTask?.cancel()
        quitTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.serviceSession.requestTermination(handle)
            guard self.isActiveTerminationTransaction(transactionID) else { return }
            switch result {
            case .signalSent:
                guard self.terminationTransactions.markSignalRequested(for: transactionID) else { return }
                self.presentation = .stopping
            case .alreadyExited:
                self.presentation = .stopping
            case .ownershipLost, .terminalUnavailable, .signalFailed, .staleHandle:
                // supervisor 已经拒绝信号权。不等 monitor 下一轮，
                // 立即撤销 bridge 和 coordinator 中的 owned 快照。
                _ = self.revokeOwnedRuntimeAuthority(for: handle)
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
            _ = await serviceSession.checkExit(handle)
            guard isActiveTerminationTransaction(transactionID),
                  !Task.isCancelled else { return }
            let cleanupComplete = await serviceSession.cleanupComplete()
            guard isActiveTerminationTransaction(transactionID),
                  !Task.isCancelled else { return }
            if cleanupComplete {
                if currentHandle == handle {
                    guard serviceSession.clearHandle(ifExpected: handle) else { return }
                } else {
                    // monitor 可能在本 await 恢复前已清除同一 handle。
                    // nil 表示相同生命周期已收敛，仍必须由当前事务
                    // exactly-once 回复 AppKit；不同的新 handle 则不能越权放行。
                    guard currentHandle == nil else { return }
                }
                replyToTermination(allow: true, transactionID: transactionID)
                return
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                guard isActiveTerminationTransaction(transactionID) else { return }
                presentation = .stopTimedOut
                serviceSession.transition(.stopTimedOut)
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
        confirmedTerminationReadyID = nil
        serviceSession.transition(.cancelQuit)
        _ = terminationTransactions.cancel(transactionID)

        guard let handle = currentHandle else {
            // 没有 handle 就没有 stopping right（停止权）；旧事务开始时的
            // `.stoppable` 快照绝不能在异步清理已完成后复活。
            terminationGate = .clear
            presentation = restoredPresentation ?? (webContainer == nil ? .serviceStopped : .ready)
            presentationBeforeTermination = nil
            replyToTermination(allow: false, transactionID: transactionID)
            return
        }

        // 先移除旧事务，再恢复它开始时最后一次确认的真实门控快照，最后才
        // reply(false)。若已发过 SIGTERM，则信号权不可恢复，只能保持 cleanupPending。
        terminationGate = ownershipLossReconciledHandle == handle
            ? .cleanupPending
            : (restoredGate == .quitPending ? .cleanupPending : restoredGate)
        if ownershipLossReconciledHandle == handle {
            presentation = .ownershipLost
        } else if signalWasRequested {
            presentation = webContainer == nil ? .drainingCleanup : .ready
        } else if let restoredPresentation {
            presentation = restoredPresentation
        } else {
            presentation = webContainer == nil ? .waitingForService : .ready
        }
        presentationBeforeTermination = nil
        replyToTermination(allow: false, transactionID: transactionID)
        resumeReadinessAfterCancelledTermination(handle: handle, signalWasRequested: signalWasRequested)

        let cancellationGeneration = operationGeneration
        Task { [weak self] in
            guard let self else { return }
            let cleanupState = await self.serviceSession.cleanupState(handle)
            guard self.currentHandle == handle,
                  self.operationGeneration == cancellationGeneration,
                  !Task.isCancelled,
                  !self.quitPending,
                  self.terminationTransactions.activeID == nil,
                  self.terminationTransactions.latestID == transactionID else { return }
            if self.ownershipLossReconciledHandle == handle {
                self.terminationGate = .cleanupPending
                self.presentation = .ownershipLost
                return
            }
            if cleanupState == .awaitingReap {
                let ownership = await self.serviceSession.verifyOwnership(handle)
                guard self.currentHandle == handle,
                      self.operationGeneration == cancellationGeneration,
                      !Task.isCancelled,
                      !self.quitPending,
                      self.terminationTransactions.activeID == nil,
                      self.terminationTransactions.latestID == transactionID,
                      self.ownershipLossReconciledHandle != handle else { return }
                if ownership == .verified {
                    self.terminationGate = .stoppable
                    self.presentation = self.webContainer == nil ? .waitingForService : .ready
                    return
                }
            }

            let cleanupComplete = await self.serviceSession.cleanupComplete()
            guard self.currentHandle == handle,
                  self.operationGeneration == cancellationGeneration,
                  !Task.isCancelled,
                  !self.quitPending,
                  self.terminationTransactions.activeID == nil,
                  self.terminationTransactions.latestID == transactionID else { return }
            if cleanupComplete {
                let terminalError = await self.serviceSession.terminalIncompatibilityError()
                guard self.currentHandle == handle,
                      self.operationGeneration == cancellationGeneration,
                      !Task.isCancelled,
                      !self.quitPending,
                      self.terminationTransactions.activeID == nil,
                      self.terminationTransactions.latestID == transactionID else { return }
                guard self.serviceSession.clearHandle(ifExpected: handle) else { return }
                self.terminationGate = .clear
                if let terminalError {
                    self.presentation = .terminalUnavailable(terminalError)
                } else if self.reachableServiceAfterExitHandle == handle {
                    await self.refreshExternalServiceAfterCleanup(
                        handle: handle,
                        generation: cancellationGeneration,
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
        confirmedTerminationReadyID = nil
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
