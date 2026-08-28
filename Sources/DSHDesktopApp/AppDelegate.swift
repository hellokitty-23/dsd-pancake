import AppKit
import DSHDesktopCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var coordinator: AppCoordinator?
    private let preferences = UserPreferences()
    private let dshUpdateService = DSHUpdateService()
    private lazy var updateStatus = UpdateStatusController(
        preferences: preferences,
        dshUpdateService: dshUpdateService
    )
    private let updateOverlay = UpdateOverlayController()
    private var completionNotificationModeMenuItems: [DesktopNotificationDeliveryMode: NSMenuItem] = [:]
    private var checkUpdatesMenuItem: NSMenuItem?
    private var updateTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        installDockIcon()
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "DSD Pancake")
        let aboutItem = NSMenuItem(
            title: "关于 DSD Pancake",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        let checkUpdatesItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        checkUpdatesMenuItem = checkUpdatesItem
        let completionNotificationsItem = NSMenuItem(
            title: "完成提醒",
            action: nil,
            keyEquivalent: ""
        )
        let completionNotificationsMenu = NSMenu(title: "完成提醒")
        let selectedNotificationMode = preferences.completionNotificationMode
        for mode in DesktopNotificationDeliveryMode.allCases {
            let modeItem = NSMenuItem(
                title: completionNotificationModeTitle(for: mode),
                action: #selector(selectCompletionNotificationMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = mode == selectedNotificationMode ? .on : .off
            completionNotificationModeMenuItems[mode] = modeItem
            completionNotificationsMenu.addItem(modeItem)
        }
        completionNotificationsItem.submenu = completionNotificationsMenu
        let quitItem = NSMenuItem(
            title: "退出 DSD Pancake",
            action: #selector(requestQuit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(checkUpdatesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = StandardEditMenu.makeMenu()
        mainMenu.addItem(editMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let closeItem = NSMenuItem(
            title: "关闭窗口",
            action: #selector(closeMainWindow(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        let terminalItem = NSMenuItem(
            title: "显示/隐藏终端",
            action: #selector(toggleTerminalPanel(_:)),
            keyEquivalent: "j"
        )
        terminalItem.keyEquivalentModifierMask = [.command]
        terminalItem.target = self
        terminalItem.toolTip = "显示/隐藏底部终端 ⌘J"
        viewMenu.addItem(terminalItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let messageMenuItem = NSMenuItem()
        let messageMenu = NSMenu(title: "消息")
        messageMenu.addItem(completionNotificationsItem)
        messageMenuItem.submenu = messageMenu
        mainMenu.addItem(messageMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.hellokitty-23.dsd-pancake"
        do {
            guard let lock = try SingleInstanceLock.acquire(bundleIdentifier: bundleIdentifier) else {
                activateExistingInstance(bundleIdentifier: bundleIdentifier)
                NSApp.terminate(nil)
                return
            }

            let coordinator = AppCoordinator(
                instanceLock: lock,
                preferences: preferences
            )
            self.coordinator = coordinator
            coordinator.installMainWindow()
            updateStatus.onAvailabilityChange = { [weak self] availability in
                self?.coordinator?.setUpdateAvailability(availability)
                self?.updateOverlay.updateAvailability(availability)
            }
            coordinator.onUpdateIndicatorPressed = { [weak self] button in
                self?.updateOverlay.toggle(relativeTo: button)
            }
            updateOverlay.onRequestDSHUpdate = { [weak self] _ in
                self?.startDSHUpdateFromOverlay()
            }
            updateStatus.start()
            coordinator.prepareNotificationAuthorization()
            coordinator.beginStartup()
        } catch {
            presentFatalError(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateStatus.stop()
        updateOverlay.cancelAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.restoreMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updateTask != nil {
            return cancelTerminationWithAlert(
                title: "更新流程尚未结束",
                message: "请等待检查或可选更新完成后再退出 DSD Pancake，避免中断 npm。"
            )
        }
        if updateStatus.isChecking {
            return cancelTerminationWithAlert(
                title: "正在检查更新",
                message: "请等待本次只读检查结束后再退出，或稍后重试。"
            )
        }
        if updateOverlay.isDownloading {
            return cancelTerminationWithAlert(
                title: "正在下载更新",
                message: "请先在更新浮层中取消或等待下载完成，避免留下不完整文件。"
            )
        }
        return coordinator?.applicationShouldTerminate() ?? .terminateNow
    }

    private func cancelTerminationWithAlert(
        title: String,
        message: String
    ) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        if let window = coordinator?.alertHostWindow {
            // `⌘W` 只把主窗口隐藏。此时直接挂 sheet 会得到一个不可见的退出拦截：
            // App 已取消退出，但用户既看不到原因也无法关闭提示。先恢复同一个主窗口，
            // 再附着 sheet；窗口本来可见时则保持现有层级与焦点语义。
            if !window.isVisible {
                coordinator?.restoreMainWindow()
            }
            if window.attachedSheet == nil {
                alert.beginSheetModal(for: window)
            }
        }
        return .terminateCancel
    }

    /// 首次 `⌘Q` 仍交给 AppKit 发起正常退出；当 AppKit 已处于 `.terminateLater`
    /// 的异步退出事务中，第二次 `⌘Q` 则必须直接交给协调器确认，不能再依赖
    /// `applicationShouldTerminate` 被重复调用。
    @objc private func requestQuit(_ sender: Any?) {
        if coordinator?.consumePendingQuitCommand() == true {
            return
        }
        NSApp.terminate(sender)
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        startManualUpdateCheck()
    }

    private func startManualUpdateCheck() {
        guard updateTask == nil, !updateStatus.isChecking else { return }
        checkUpdatesMenuItem?.isEnabled = false
        checkUpdatesMenuItem?.title = "正在检查更新…"
        updateTask = Task { @MainActor [weak self] in
            await self?.runUpdateFlow()
        }
    }

    private func runUpdateFlow() async {
        defer {
            checkUpdatesMenuItem?.title = "检查更新…"
            checkUpdatesMenuItem?.isEnabled = true
            updateTask = nil
        }

        guard let coordinator else {
            await presentUpdateAlert(
                title: "DSD Pancake 尚未准备好",
                message: "主窗口完成启动后再检查更新。",
                style: .warning
            )
            return
        }

        guard let report = await updateStatus.checkManually() else { return }
        let hasOptionalUpdate = report.hasOptionalUpdate || updateStatus.availability.hasUpdates
        let summaryResponse = await presentUpdateAlert(
            title: "更新检查完成",
            message: report.summary,
            primaryButton: hasOptionalUpdate ? "查看可选更新" : "好",
            secondaryButton: hasOptionalUpdate ? "稍后" : nil
        )
        guard hasOptionalUpdate, summaryResponse == .alertFirstButtonReturn else { return }
        coordinator.presentAvailableUpdatesFromMenu()
    }

    private func startDSHUpdateFromOverlay() {
        guard updateTask == nil, !updateStatus.isChecking else { return }
        updateTask = Task { @MainActor [weak self] in
            await self?.runDSHUpdateFromOverlay()
        }
    }

    private func runDSHUpdateFromOverlay() async {
        defer {
            checkUpdatesMenuItem?.title = "检查更新…"
            checkUpdatesMenuItem?.isEnabled = true
            updateTask = nil
        }
        guard let coordinator else {
            await presentUpdateAlert(
                title: "DSD Pancake 尚未准备好",
                message: "主窗口完成启动后再更新 DeepSeek Harness。",
                style: .warning
            )
            return
        }
        guard let result = await updateStatus.checkDSHForExplicitUpdate() else { return }
        switch result {
        case let .available(check):
            await offerDSHUpdate(check, coordinator: coordinator)
        case let .current(check):
            await presentUpdateAlert(
                title: "DeepSeek Harness 已是最新版本",
                message: DSHCheckResult.current(check).summary
            )
        case let .failed(message):
            await presentUpdateAlert(
                title: "无法检查 DeepSeek Harness 更新",
                message: message,
                style: .warning
            )
        }
    }

    private func offerDSHUpdate(_ check: DSHUpdateCheck, coordinator: AppCoordinator) async {
        let response = await presentUpdateAlert(
            title: "DeepSeek Harness 有新版本",
            message: "当前版本：\(check.currentVersion)\n"
                + "最新版本：\(check.latestVersion)\n\n"
                + "更新会正常停止由 DSD Pancake 创建的 DSH，然后执行：\n"
                + "可执行文件：\(check.npmExecutable.path)\n"
                + "参数：\(DSHUpdateService.updateArguments.joined(separator: " "))\n\n"
                + "只有点击“更新 DSH”才会修改 npm；选择“稍后”不产生写操作。",
            style: .warning,
            primaryButton: "更新 DSH",
            secondaryButton: "稍后"
        )
        guard response == .alertFirstButtonReturn else { return }

        switch await coordinator.prepareForDSHUpdate() {
        case .ready:
            break
        case .externalServiceActive:
            await presentUpdateAlert(
                title: "检测到外部 DSH 服务",
                message: "\(LocalService.hostAndPort) 上的服务不能确认由本次 App 创建。为避免修改正在运行的外部 DSH，请先自行停止该服务，再重新检查更新。",
                style: .warning
            )
            return
        case let .busy(message):
            await presentUpdateAlert(title: "现在不能更新", message: message, style: .warning)
            return
        case .stopTimedOut:
            await presentUpdateAlert(
                title: "等待 DSH 停止超时",
                message: "不会强制结束进程，也没有执行 npm 更新。请等待日志清理完成后重试。",
                style: .warning
            )
            return
        }

        checkUpdatesMenuItem?.title = "正在更新 DeepSeek Harness…"
        do {
            let result = try await dshUpdateService.update(using: check)
            coordinator.finishDSHUpdateAndRestart()
            updateStatus.clearCachedDSHUpdate()
            await presentUpdateAlert(
                title: "DeepSeek Harness 更新完成",
                message: "\(result.previousVersion) → \(result.installedVersion)\n\n"
                    + "DSD Pancake 正在重新启动本次 DSH 服务。"
            )
        } catch is CancellationError {
            coordinator.finishDSHUpdateAndRestart()
        } catch {
            coordinator.finishDSHUpdateAndRestart()
            await presentUpdateAlert(
                title: "无法更新 DeepSeek Harness",
                message: error.localizedDescription,
                style: .critical
            )
        }
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let credits = NSMutableAttributedString(string: "GitHub 项目地址：\n")
        credits.append(
            NSAttributedString(
                string: AppUpdateService.repositoryURL.absoluteString,
                attributes: [
                    .link: AppUpdateService.repositoryURL,
                    .foregroundColor: NSColor.linkColor,
                ]
            )
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @discardableResult
    private func presentUpdateAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .informational,
        primaryButton: String = "好",
        secondaryButton: String? = nil
    ) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primaryButton)
        if let secondaryButton {
            alert.addButton(withTitle: secondaryButton)
        }
        guard let window = coordinator?.alertHostWindow ?? NSApp.mainWindow,
              window.attachedSheet == nil else {
            return .abort
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    /// 这是 App 自己的投递偏好，不是 macOS 系统授权。切换后立即更新新事件的
    /// 投递规则；不重启 DSH，也不清除系统里已经允许的通知权限。
    @objc private func selectCompletionNotificationMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = DesktopNotificationDeliveryMode(rawValue: rawValue) else {
            return
        }
        preferences.completionNotificationMode = mode
        for (candidate, item) in completionNotificationModeMenuItems {
            item.state = candidate == mode ? .on : .off
        }
    }

    private func completionNotificationModeTitle(for mode: DesktopNotificationDeliveryMode) -> String {
        switch mode {
        case .never:
            "永不"
        case .whenUnfocused:
            "仅在未聚焦时"
        case .always:
            "一律"
        }
    }

    private func activateExistingInstance(bundleIdentifier: String) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @objc private func closeMainWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(sender)
    }

    @objc private func toggleTerminalPanel(_ sender: Any?) {
        coordinator?.toggleTerminalPanel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updateTask == nil && !updateStatus.isChecking
        }
        guard menuItem.action == #selector(toggleTerminalPanel(_:)) else { return true }
        menuItem.state = coordinator?.isTerminalPanelVisible == true ? .on : .off
        return coordinator?.canToggleTerminalPanel == true
    }

    /// `PancakeAppIcon` 保持为 bundle 身份图标，供 Finder 与原生通知读取；Dock 单独用
    /// `DockIcon`，这样小尺寸提醒图标的留白不会影响正在运行 App 的可见大小。
    private func installDockIcon() {
        guard let iconURL = Bundle.main.url(forResource: "DockIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    private func presentFatalError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法启动 DSD Pancake"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
